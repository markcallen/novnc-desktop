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
  tls_zone_normalized = trimsuffix(trimspace(var.tls_zone), ".")
  generated_tls_hostname = var.tls_zone != "" ? "${random_pet.tls_host[0].id}.${local.tls_zone_normalized}" : ""
  effective_novnc_hostname = local.generated_tls_hostname != "" ? local.generated_tls_hostname : (trimspace(var.novnc_hostname) != "" ? var.novnc_hostname : null)
  user_data_json = jsonencode({
    novnc_http_port   = var.novnc_http_port
    novnc_https_port  = var.novnc_https_port
    novnc_hostname    = local.effective_novnc_hostname
    novnc_use_certbot = var.novnc_use_certbot
    novnc_certbot_email = trimspace(var.novnc_certbot_email) != "" ? var.novnc_certbot_email : null
  })
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
  ami                         = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = local.selected_subnet_id
  vpc_security_group_ids      = [aws_security_group.smoke.id]
  key_name                    = aws_key_pair.smoke.key_name
  iam_instance_profile        = trimspace(var.iam_instance_profile) != "" ? var.iam_instance_profile : null
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

  user_data = local.user_data_json

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

# ---------------------------------------------------------------------------
# Optional TLS: random subdomain + Route53 A record
# Created only when var.tls_zone is non-empty (e.g. "smoke.markcallen.dev").
# The random_pet prefix ensures no hostname conflicts across concurrent runs.
# terraform destroy removes both the A record and the random resource.
# ---------------------------------------------------------------------------
resource "random_pet" "tls_host" {
  count     = var.tls_zone != "" ? 1 : 0
  length    = 2
  separator = "-"
}

data "aws_route53_zone" "tls" {
  count = var.tls_zone != "" ? 1 : 0
  name  = local.tls_zone_normalized
}

resource "aws_route53_record" "tls" {
  count   = var.tls_zone != "" ? 1 : 0
  zone_id = data.aws_route53_zone.tls[0].zone_id
  name    = "${random_pet.tls_host[0].id}.${local.tls_zone_normalized}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.smoke.public_ip]
}
