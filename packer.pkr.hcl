variable "aws_region" {
  type        = string
  description = "AWS region to build the AMI in"
  default     = "us-east-1"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type to use for the build"
  default     = "t3.medium"
}

variable "root_volume_size" {
  type        = number
  description = "Root volume size in GB"
  default     = 20
}

variable "ami_name" {
  type        = string
  description = "Name of the output AMI"
  default     = "novnc-desktop-ubuntu-24.04"
}

variable "ami_description" {
  type        = string
  description = "Description of the output AMI"
  default     = "noVNC Desktop over HTTPS with Ubuntu 24.04 LTS"
}

locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
}

data "amazon-ami" "ubuntu" {
  filters = {
    name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }

  owners      = ["099720109477"] # Canonical
  most_recent = true

  region = var.aws_region
}

source "amazon-ebs" "ubuntu" {
  ami_name                    = "${var.ami_name}-${local.timestamp}"
  ami_description             = var.ami_description
  instance_type               = var.instance_type
  region                      = var.aws_region
  source_ami                  = data.amazon-ami.ubuntu.id
  associate_public_ip_address = true

  # Enable EBS optimization for faster builds
  ebs_optimized = true

  # Root volume configuration using launch_block_device_mappings
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Add tags to the snapshot
  snapshot_tags = {
    Name      = var.ami_name
    BuildTool = "Packer"
    BuildDate = local.timestamp
  }

  # Add tags to the AMI
  tags = {
    Name        = var.ami_name
    OS          = "Ubuntu 24.04 LTS"
    BuildTool   = "Packer"
    BuildDate   = local.timestamp
    Description = var.ami_description
  }

  # SSH configuration
  ssh_username = "ubuntu"
  ssh_timeout  = "10m"
}

build {
  name = "novnc-desktop-ubuntu-24.04"

  sources = [
    "source.amazon-ebs.ubuntu"
  ]

  # Step 1: Fix any broken dpkg/apt state and update system
  provisioner "shell" {
    inline = [
      "set -e",
      "echo '=== Fixing potential dpkg/apt state issues ==='",
      "sudo dpkg --configure -a || true",
      "sudo apt-get update --fix-missing || true",
      "sudo apt-get clean",
      "sudo apt-get autoclean",
      "echo '=== System cleanup complete ==='",
      "echo '=== Installing Python and core dependencies ==='",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip git curl",
      "echo '=== Core dependencies installed ===' "
    ]
  }

  # Step 3: Run Ansible provisioner using Packer's built-in provisioner
  provisioner "ansible" {
    playbook_file        = "${path.root}/packer-playbook.yml"
    galaxy_file          = "${path.root}/packer-requirements.yml"
    galaxy_force_install = true
    extra_arguments = [
      "--extra-vars", "ansible_python_interpreter=/usr/bin/python3",
    ]
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
    ]
  }

  # Step 4: Clean up and optimize the image
  provisioner "shell" {
    inline = [
      "set -e",
      "echo '=== Cleaning up image ==='",
      "sudo apt-get clean",
      "sudo apt-get autoclean",
      "sudo apt-get autoremove -y",
      "sudo truncate -s 0 /var/log/*log",
      "sudo rm -rf /var/tmp/* /tmp/*",
      "history -c 2>/dev/null || true",
      "cat /dev/null > ~/.bash_history 2>/dev/null || true",
      "echo '=== Image cleanup complete ===' "
    ]
  }
}
