variable "aws_region" {
  description = "AWS region for the smoke test instance."
  type        = string
}

variable "stack_name" {
  description = "Logical stack name for the smoke test workspace."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for AWS resource names."
  type        = string
  default     = "novnc-smoke"
}

variable "project_name" {
  description = "Project tag value applied to smoke test resources."
  type        = string
  default     = "novnc-desktop"
}

variable "environment" {
  description = "Environment tag value applied to smoke test resources."
  type        = string
  default     = "smoke"
}

variable "availability_zone" {
  description = "Availability zone to use for the smoke test instance and subnet selection."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for the smoke test host."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
}

variable "ssh_cidr" {
  description = "CIDR allowed to reach SSH on the smoke test instance. Provide an explicit trusted CIDR such as your current public IP in /32 form."
  type        = string
}

variable "http_cidr" {
  description = "CIDR allowed to reach HTTP on the smoke test instance. For Certbot validation you may need 0.0.0.0/0."
  type        = string
}

variable "https_cidr" {
  description = "CIDR allowed to reach HTTPS on the smoke test instance. For public browser checks you may need a broader range than /32."
  type        = string
}

variable "novnc_http_port" {
  description = "Public HTTP port exposed by the smoke test security group for noVNC."
  type        = number
  default     = 80
}

variable "novnc_https_port" {
  description = "Public HTTPS port exposed by the smoke test security group for noVNC."
  type        = number
  default     = 443
}

variable "ami_id" {
  description = "Optional AMI ID to launch from. If not provided, uses the latest Ubuntu 24.04 AMI."
  type        = string
  default     = ""
}

variable "tls_zone" {
  description = "Route53 hosted zone for Let's Encrypt. When set, a random subdomain A record is created. Example: smoke.markcallen.dev"
  type        = string
  default     = ""
}
