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

variable "ami_name_prefix" {
  type        = string
  description = "Prefix for the output AMI names"
  default     = "novnc-desktop-ubuntu-24.04"
}

variable "use_certbot" {
  type        = bool
  description = "Whether to run certbot during provisioning. Set false for public AMIs that use user-data scripts for TLS."
  default     = false
}

variable "ami_public" {
  type        = bool
  description = "Whether to make the AMI publicly accessible. When true, sets launch permissions to allow all AWS accounts."
  default     = false
}

variable "ami_environment" {
  type        = string
  description = "Value for the Environment tag on built AMIs. Use 'test' (default) for smoke-discoverable AMIs; use 'production' for public release builds."
  default     = "test"
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

source "amazon-ebs" "openbox" {
  ami_name        = "${var.ami_name_prefix}-openbox-${local.timestamp}"
  ami_description = "noVNC Desktop (Openbox) over HTTPS with Ubuntu 24.04 LTS"
  instance_type   = var.instance_type
  region          = var.aws_region
  source_ami      = data.amazon-ami.ubuntu.id

  associate_public_ip_address = true
  ebs_optimized               = true

  ami_groups = var.ami_public ? ["all"] : []

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  snapshot_tags = {
    Name        = "${var.ami_name_prefix}-openbox"
    BuildTool   = "Packer"
    BuildDate   = local.timestamp
    Environment = var.ami_environment
    Project     = "novnc-desktop"
    Variant     = "openbox"
  }

  tags = {
    Name        = "${var.ami_name_prefix}-openbox"
    OS          = "Ubuntu 24.04 LTS"
    BuildTool   = "Packer"
    BuildDate   = local.timestamp
    Description = "noVNC Desktop (Openbox) over HTTPS with Ubuntu 24.04 LTS"
    Environment = var.ami_environment
    Project     = "novnc-desktop"
    Variant     = "openbox"
  }

  ssh_username = "ubuntu"
  ssh_timeout  = "10m"
}

source "amazon-ebs" "elementary" {
  ami_name        = "${var.ami_name_prefix}-elementary-${local.timestamp}"
  ami_description = "noVNC Desktop (Elementary) over HTTPS with Ubuntu 24.04 LTS"
  instance_type   = var.instance_type
  region          = var.aws_region
  source_ami      = data.amazon-ami.ubuntu.id

  associate_public_ip_address = true
  ebs_optimized               = true

  ami_groups = var.ami_public ? ["all"] : []

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  snapshot_tags = {
    Name        = "${var.ami_name_prefix}-elementary"
    BuildTool   = "Packer"
    BuildDate   = local.timestamp
    Environment = var.ami_environment
    Project     = "novnc-desktop"
    Variant     = "elementary"
  }

  tags = {
    Name        = "${var.ami_name_prefix}-elementary"
    OS          = "Ubuntu 24.04 LTS"
    BuildTool   = "Packer"
    BuildDate   = local.timestamp
    Description = "noVNC Desktop (Elementary) over HTTPS with Ubuntu 24.04 LTS"
    Environment = var.ami_environment
    Project     = "novnc-desktop"
    Variant     = "elementary"
  }

  ssh_username = "ubuntu"
  ssh_timeout  = "10m"
}

build {
  name = "novnc-desktop-ubuntu-24.04"

  sources = [
    "source.amazon-ebs.openbox",
    "source.amazon-ebs.elementary",
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
      "echo '=== Core dependencies installed ==='",
      "echo '=== Creating /etc/novnc directory ==='",
      "sudo mkdir -p /etc/novnc",
      "sudo chmod 0755 /etc/novnc",
      "echo '=== /etc/novnc ready ==='"
    ]
  }

  # Step 2a: Run Ansible for openbox variant.
  # ANSIBLE_ROLES_PATH points to the local checkout so the role used is always
  # the version in this branch, not a pinned Galaxy release.
  # ANSIBLE_COLLECTIONS_PATH is isolated per-variant to prevent concurrent
  # galaxy_force_install writes from corrupting a shared directory.
  provisioner "ansible" {
    only                 = ["amazon-ebs.openbox"]
    playbook_file        = "${path.root}/packer-playbook.yml"
    galaxy_file          = "${path.root}/packer-requirements.yml"
    galaxy_force_install = true
    extra_arguments = [
      "--extra-vars", "ansible_python_interpreter=/usr/bin/python3 desktop_type=openbox use_certbot=${var.use_certbot}",
    ]
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_ROLES_PATH=${path.root}/roles",
      "ANSIBLE_COLLECTIONS_PATH=/tmp/novnc-collections-openbox",
    ]
  }

  # Step 2b: Run Ansible for elementary variant.
  provisioner "ansible" {
    only                 = ["amazon-ebs.elementary"]
    playbook_file        = "${path.root}/packer-playbook.yml"
    galaxy_file          = "${path.root}/packer-requirements.yml"
    galaxy_force_install = true
    extra_arguments = [
      "--extra-vars", "ansible_python_interpreter=/usr/bin/python3 desktop_type=elementary use_certbot=${var.use_certbot}",
    ]
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_ROLES_PATH=${path.root}/roles",
      "ANSIBLE_COLLECTIONS_PATH=/tmp/novnc-collections-elementary",
    ]
  }

  # Step 3: Clean up and optimise the image.
  # For public AMIs, reset instance-specific identity so each launched instance
  # gets its own SSH host keys and machine-id on first boot.
  provisioner "shell" {
    inline = [
      "set -e",
      "echo '=== Cleaning up image ==='",
      "sudo apt-get clean",
      "sudo apt-get autoclean",
      "sudo apt-get autoremove -y",
      "sudo truncate -s 0 /var/log/*log",
      "sudo rm -rf /var/tmp/* /tmp/*",
      "echo '=== Resetting instance identity ==='",
      "sudo cloud-init clean --logs 2>/dev/null || true",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "history -c 2>/dev/null || true",
      "cat /dev/null > ~/.bash_history 2>/dev/null || true",
      "echo '=== Image cleanup complete ==='"
    ]
  }
}
