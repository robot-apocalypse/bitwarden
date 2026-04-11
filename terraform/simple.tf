# Simpler Vaultwarden Terraform - uses default VPC
terraform {
  required_version = ">= 1.0"
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
  ami                    = "ami-0480a06f3f4f52216"
  instance_type          = "t3.nano"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.vaultwarden.id]
  iam_instance_profile   = aws_iam_instance_profile.vaultwarden.name

  user_data = <<-EOF
              #!/bin/bash
              exec > /tmp/userdata.log 2>&1
              set -x
              
              echo "Starting user_data script..."
              
              # Update and install basics
              export DEBIAN_FRONTEND=noninteractive
              apt-get update
              apt-get install -y ufw docker.io docker-compose git unattended-upgrades curl
              
              # Set hostname
              hostnamectl set-hostname vaultwarden
              
              # Configure firewall (skip ufw if not available)
              ufw --force enable || true
              ufw default deny incoming || true
              ufw default allow outgoing || true
              ufw allow 80/tcp || true
              ufw allow 443/tcp || true
              ufw allow 22/tcp || true
              
              # SSH hardening
              sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true
              sed -i 's/^#*PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config || true
              systemctl reload ssh || true
              
              # Unattended upgrades
              cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'UA'
Unattended-Upgrades::Allowed-Origins {
    "Ubuntu:noble-security";
};
Unattended-Upgrades::Automatic-Reboot "true";
Unattended-Upgrades::Automatic-Reboot-Time "02:00";
UA
              
              # Docker
              usermod -aG docker ubuntu || true
              systemctl enable docker || true
              systemctl start docker || true
              
              echo "Done! Manual setup: cd /opt && git clone and configure"
              echo "Done!" >> /tmp/userdata.log
              EOF

  tags = { Name = "vaultwarden" }
}

output "public_ip" {
  value = aws_instance.vaultwarden.public_ip
}