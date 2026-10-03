# Simpler Vaultwarden Terraform - uses default VPC
terraform {
  required_version = ">= 1.10"

  # State was originally local and lived only on a laptop that was lost.
  # Re-imported 2026-10-02 (see imports.tf); now remote so that cannot recur.
  backend "s3" {
    bucket       = "peakscale-terraform-state-prod"
    key          = "prod/bitwarden/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.40"
    }
  }
}

provider "aws" {
  region  = "us-west-2"
  profile = "peakscale"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "vaultwarden" {
  name        = "vaultwarden-v3"
  description = "Vaultwarden HTTPS"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_instance_profile" "vaultwarden" {
  name = "terraform-20260411144220783300000001"
  role = aws_iam_role.ssm.name
}

resource "aws_iam_role" "ssm" {
  name = "vaultwarden-ssm-v3"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_instance" "vaultwarden" {
  ami                    = "ami-0d76b909de1a0595d"
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.vaultwarden.id]
  iam_instance_profile   = aws_iam_instance_profile.vaultwarden.name

  user_data = <<-EOF
    #!/bin/bash

    # Set hostname
    hostnamectl set-hostname vaultwarden

    # Update and install packages
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ufw \
      docker.io \
      docker-compose-v2 \
      git \
      curl \
      vim \
      gnupg \
      gh \
      unattended-upgrades

    # UFW configuration
    cat <<UFW_CONF > /etc/ufw/ufw.conf
    # UFW configuration
    ENABLED=yes
    DEFAULT_INPUT_POLICY="DROP"
    DEFAULT_OUTPUT_POLICY="ACCEPT"
    DEFAULT_FORWARD_POLICY="DROP"
    DEFAULT_APPLICATION_POLICY="SKIP"
    ManageBuiltins=yes
    UFW_CONF

    # Unattended-upgrades: a drop-in on top of Ubuntu's stock
    # 50unattended-upgrades, which keeps the default allowed origins. The key
    # is Unattended-Upgrade:: (singular). An earlier version overwrote 50-*
    # with "Unattended-Upgrades::", which apt ignores, so nothing was ever
    # installed, while the daily run still logged success.
    cat <<UA_CONF > /etc/apt/apt.conf.d/52unattended-upgrades-local
    Unattended-Upgrade::Automatic-Reboot "true";
    // UTC. After the 03:00 America/Denver backup.
    Unattended-Upgrade::Automatic-Reboot-Time "10:30";
    UA_CONF

    # UFW setup
    ufw --force enable
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 80/tcp
    ufw allow 443/tcp

    # SSH hardening
    sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl reload sshd || systemctl reload ssh || true

    # Docker
    usermod -aG docker ubuntu || true
    systemctl enable docker
    systemctl start docker

    # Upgrade system
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    echo "Init complete"
  EOF

  tags = { Name = "vaultwarden" }

  # user_data only runs at first boot, and changing it (or the AMI) would
  # stop/start or replace the instance. Edits here are for future rebuilds.
  lifecycle {
    ignore_changes = [user_data, ami]
  }
}

output "public_ip" {
  value = aws_eip.vaultwarden.public_ip
}

output "domain" {
  value = aws_route53_record.bitwarden.name
}

output "instance_id" {
  value = aws_instance.vaultwarden.id
}

# Without a static IP, a stop/start (not a reboot) gives the instance a new
# public IP and silently breaks DNS.
resource "aws_eip" "vaultwarden" {
  domain   = "vpc"
  instance = aws_instance.vaultwarden.id
  tags     = { Name = "vaultwarden" }
}

resource "aws_route53_record" "bitwarden" {
  zone_id = "Z05138461ITQ58LOV0TYH"
  name    = "bitwarden.peakscale.solutions"
  type    = "A"
  # Lowered from 300 ahead of the Elastic IP cutover, to shorten the window
  # in which clients still hold the old ephemeral IP.
  ttl     = 60
  records = [aws_eip.vaultwarden.public_ip]
}
