# ---------------------------------------------------------------------------
# SSH key pair — generated fresh for every new stack, stored locally.
# The private key is written to .smoke-keys/smoke.pem (gitignored).
# ---------------------------------------------------------------------------
resource "tls_private_key" "smoke" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "smoke" {
  key_name   = local.resource_name
  public_key = tls_private_key.smoke.public_key_openssh

  tags = {
    Name    = local.resource_name
    Purpose = "smoke-test"
    Stack   = local.stack_name
  }
}

# Write the private key to .smoke-keys/smoke.pem (parent dir created by infra-up.sh).
resource "local_file" "smoke_pem" {
  content         = tls_private_key.smoke.private_key_pem
  filename        = "${path.root}/../../.smoke-keys/smoke.pem"
  file_permission = "0600"
}

# ---------------------------------------------------------------------------
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
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

data "aws_ec2_instance_type_offerings" "available" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  stack_name          = terraform.workspace == "default" ? var.stack_name : terraform.workspace
  resource_name       = "${var.name_prefix}-${local.stack_name}"
  http_ingress_ports  = distinct([80, var.novnc_http_port])
  https_ingress_ports = distinct([443, var.novnc_https_port])
  selected_subnet_id = try([
    for subnet in values(data.aws_subnet.default) : subnet.id
    if(
      var.availability_zone != "" ?
      subnet.availability_zone == var.availability_zone :
      contains(data.aws_ec2_instance_type_offerings.available.locations, subnet.availability_zone)
    )
  ][0], "")
}

resource "aws_security_group" "smoke" {
  name_prefix = "${local.resource_name}-"
  description = "Smoke test access for novnc-desktop"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  dynamic "ingress" {
    for_each = local.http_ingress_ports
    content {
      description = "HTTP ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.http_cidr]
    }
  }

  dynamic "ingress" {
    for_each = local.https_ingress_ports
    content {
      description = "HTTPS ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.https_cidr]
    }
  }

  # tfsec:ignore:aws-ec2-no-public-egress-sgr This ephemeral smoke host must reach package mirrors and Let's Encrypt endpoints.
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = local.resource_name
    Purpose = "smoke-test"
    Stack   = local.stack_name
  }
}

resource "aws_instance" "smoke" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = local.selected_subnet_id
  vpc_security_group_ids      = [aws_security_group.smoke.id]
  key_name                    = aws_key_pair.smoke.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name    = local.resource_name
    Purpose = "smoke-test"
    Stack   = local.stack_name
  }

  lifecycle {
    precondition {
      condition     = local.selected_subnet_id != ""
      error_message = var.availability_zone != "" ? "No default subnet was found in availability zone ${var.availability_zone}." : "No default subnet was found in an availability zone that supports ${var.instance_type}."
    }
  }
}
