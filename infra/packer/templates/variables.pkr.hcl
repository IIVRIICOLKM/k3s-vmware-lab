variable "image_name" {
  type    = string
  default = "k3slab-golden-rocky98"
}

variable "image_version" {
  type        = string
  description = "Immutable build id, e.g. 20260918-1. A new version gets a new output directory."
}

variable "image_root" {
  type        = string
  description = "Directory that holds golden images (the lab's XDG data dir /images)."
}

variable "iso_path" {
  type        = string
  description = "Absolute path of the cached Rocky Linux 9.8 DVD ISO."
}

variable "iso_sha256" {
  type    = string
  default = "d2bcbb64c2d67511adf80d40cd9543391a33aea5860a355b1d26d7f55236d01f" # Rocky-9.8-x86_64-dvd.iso
}

variable "admin_user" {
  type    = string
  default = "k3sadmin"
}

variable "admin_password_hash" {
  type        = string
  sensitive   = true
  description = "SHA-512 crypt hash for console login only; SSH password login is disabled."
}

variable "ssh_public_key" {
  type        = string
  description = "Public key authorised for admin_user (the Ansible key)."
}

variable "ssh_private_key_file" {
  type        = string
  description = "Private key Packer uses to reach the VM during the build."
}

variable "hostname" {
  type    = string
  default = "k3slab-golden"
}

variable "timezone" {
  type    = string
  default = "Asia/Seoul"
}

variable "build_cpus" {
  type    = number
  default = 2
}

variable "build_memory_mb" {
  type    = number
  default = 2048
}

variable "disk_size_mb" {
  type    = number
  default = 40960
}

# The build VM uses a static address on vmnet8 so Packer never has to guess the address Anaconda is using.
# scripts/golden-build.sh derives these values from the host's vmnet8 subnet; finalize.sh switches the image back to
# a MAC-keyed NetworkManager DHCP profile for the clones.
variable "build_ip" {
  type        = string
  description = "Static IPv4 for the build VM, outside the vmnet8 DHCP pool."
}

variable "build_gateway" {
  type        = string
  description = "vmnet8 NAT gateway (x.x.x.2 on VMware desktop hypervisors)."
}
