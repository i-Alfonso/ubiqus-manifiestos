# Optimized Terraform for K3s deployment - Reduced cost ~$25/month
# Uses existing FlowLB instead of ALB + cert-manager for SSL termination
# Repository: ubiqus-test-infra

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (prod, staging, dev)"
  type        = string
  default     = "prod"
}

variable "domain_name" {
  description = "Base domain name for the application"
  type        = string
  default     = "ubiqus.me"
}

variable "key_name" {
  description = "EC2 Key Pair name for SSH access"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for K3s server"
  type        = string
  default     = "t3.small" # Cost-optimized from t3.large
}

# Get the latest Ubuntu 22.04 LTS AMI for the current region
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Simplified VPC - use default VPC
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "default" {
  id = data.aws_subnets.default.ids[0]
}

# Security Group for K3s cluster
resource "aws_security_group" "k3s_sg" {
  name_prefix = "k3s-${var.environment}-"
  vpc_id      = data.aws_vpc.default.id

  # SSH access for administration
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP/HTTPS for FlowLB load balancer
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

  # K3s API Server access
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Flannel VXLAN overlay network
  ingress {
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  # Kubelet metrics and health checks
  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  # NodePort range for K3s services
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound traffic allowed
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "k3s-${var.environment}-sg"
    Environment = var.environment
  }
}

# Elastic IP for fixed public IP address
resource "aws_eip" "k3s_eip" {
  domain = "vpc"

  tags = {
    Name        = "k3s-${var.environment}-eip"
    Environment = var.environment
  }
}

# EC2 Instance for K3s server
resource "aws_instance" "k3s_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]
  subnet_id              = data.aws_subnet.default.id

  # Optimized storage configuration
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  # User data script for K3s initialization
  user_data = base64encode(templatefile("${path.module}/scripts/k3s-init-optimized.sh", {
    domain_name = var.domain_name
    environment = var.environment
  }))

  tags = {
    Name        = "k3s-${var.environment}-server"
    Environment = var.environment
  }
}

# Associate Elastic IP with EC2 instance
resource "aws_eip_association" "k3s_eip_assoc" {
  instance_id   = aws_instance.k3s_server.id
  allocation_id = aws_eip.k3s_eip.id
}

# Route53 zone data source (requires existing hosted zone)
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# Production backend domain record (ubiqus.me)
resource "aws_route53_record" "prod_backend" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.k3s_eip.public_ip]
}

# Production frontend domain record (app.ubiqus.me)
resource "aws_route53_record" "prod_frontend" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "ecard.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.k3s_eip.public_ip]
}

# Staging backend domain record (staging.ubiqus.me)
resource "aws_route53_record" "staging_backend" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "staging.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.k3s_eip.public_ip]
}

# Staging frontend domain record (staging-app.ubiqus.me)
resource "aws_route53_record" "staging_frontend" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "staging-ecard.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.k3s_eip.public_ip]
}

# Development backend domain record (dev.ubiqus.me)
resource "aws_route53_record" "dev_backend" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "dev.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.k3s_eip.public_ip]
}

# Development frontend domain record (dev-app.ubiqus.me)
resource "aws_route53_record" "dev_frontend" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "dev-ecard.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.k3s_eip.public_ip]
}

# End of optimized Terraform configuration
