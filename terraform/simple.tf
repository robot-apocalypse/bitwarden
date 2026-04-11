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
              set -e
              exec > /var/log/user-data.log 2>&1
              
              echo "Starting user_data..."
              export DEBIAN_FRONTEND=noninteractive
              
              # Update and upgrade
              apt-get update
              apt-get upgrade -y
              
              # Install basics
              apt-get install -y ufw docker.io docker-compose git curl vim gnupg
              
              # GitHub CLI
              curl -fsSL https://cli.github.com/packages/ikey.gpg | gpg --dearmor -o /usr/share/keyrings/github.gpg
              echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/github.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
              apt-get update
              apt-get install -y gh
              
              # Set hostname
              hostnamectl set-hostname vaultwarden
              
              # Firewall
              ufw --force enable
              ufw default deny incoming
              ufw default allow outgoing
              ufw allow 80/tcp
              ufw allow 443/tcp
              ufw allow 22/tcp
              
              # SSH hardening
              sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
              sed -i 's/^#*PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
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
              
              echo "User data complete"
              EOF

  tags = { Name = "vaultwarden" }
}

output "public_ip" {
  value = aws_instance.vaultwarden.public_ip
}