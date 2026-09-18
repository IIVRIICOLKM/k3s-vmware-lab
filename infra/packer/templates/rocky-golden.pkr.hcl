packer {
  required_version = "= 1.16.0"
  required_plugins {
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = "= 2.1.6"
    }
  }
}

locals {
  vm_name    = "${var.image_name}-${var.image_version}"
  output_dir = "${var.image_root}/${local.vm_name}"
}

source "vmware-iso" "rocky" {
  vm_name          = local.vm_name
  display_name     = local.vm_name
  output_directory = local.output_dir
  version          = 21
  guest_os_type    = "rockyLinux-64"
  firmware         = "efi"
  cpus             = var.build_cpus
  memory           = var.build_memory_mb

  disk_size          = var.disk_size_mb
  disk_adapter_type  = "pvscsi"
  cdrom_adapter_type = "sata"

  # elsudano/vmworkstation 2.0.1 re-creates each clone's NIC with the parent's type/vmnet. vmrest 1.3.1 rejects
  # that request for type "nat", but accepts type "custom" on vmnet8 (the same NAT network), and creates e1000.
  network              = "vmnet8"
  network_adapter_type = "e1000"

  iso_url      = "file://${var.iso_path}"
  iso_checksum = "sha256:${var.iso_sha256}"

  # Anaconda reads ks.cfg from a second CD labelled OEMDRV. No build-time HTTP listener is exposed to the LAN.
  cd_label = "OEMDRV"
  cd_content = {
    "ks.cfg" = templatefile(abspath("${path.root}/../http/kickstart.pkrtpl.cfg"), {
      hostname            = var.hostname
      admin_user          = var.admin_user
      admin_password_hash = var.admin_password_hash
      ssh_public_key      = var.ssh_public_key
      timezone            = var.timezone
      build_ip            = var.build_ip
      build_gateway       = var.build_gateway
    })
  }

  # Ports 5900 (krfb) and 5939 (TeamViewer) are in use on this host; keep Packer's VNC on loopback, elsewhere.
  headless         = true
  vnc_bind_address = "127.0.0.1"
  vnc_port_min     = 5980
  vnc_port_max     = 5989

  boot_wait = "10s"
  boot_command = [
    "c<wait3s>",
    "linuxefi /images/pxeboot/vmlinuz inst.text inst.ks=hd:LABEL=OEMDRV:/ks.cfg inst.stage2=hd:LABEL=Rocky-9-8-x86_64-dvd<enter><wait3s>",
    "initrdefi /images/pxeboot/initrd.img<enter><wait3s>",
    "boot<enter>",
  ]

  communicator           = "ssh"
  ssh_host               = var.build_ip
  ssh_username           = var.admin_user
  ssh_private_key_file   = var.ssh_private_key_file
  ssh_timeout            = "60m"
  ssh_handshake_attempts = 1000
  shutdown_command       = "sudo systemctl poweroff"
  shutdown_timeout       = "10m"

  vmx_data = {
    "annotation"     = "k3s-vmware-lab Rocky Linux 9.8 Server golden image ${local.vm_name}. Read-only parent for Terraform clones: never power on or edit."
    "uuid.action"    = "create"
    "msg.autoAnswer" = "TRUE"
    "tools.syncTime" = "TRUE"
  }
}

build {
  sources = ["source.vmware-iso.rocky"]

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    script          = abspath("${path.root}/../scripts/finalize.sh")
  }

  post-processor "manifest" {
    output     = "${local.output_dir}/packer-manifest.json"
    strip_path = true
  }
}
