packer {
  required_version = ">= 1.16.0"
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = "= 1.2.4"
    }
  }
}

locals {
  # Autoinstall answers for subiquity, shipped to the installer on a small
  # NoCloud seed CD (volume label "cidata") that Packer builds and uploads.
  user_data = templatefile("${path.root}/files/user-data.pkrtpl.yaml", {
    hostname            = var.template_name
    build_username      = var.build_username
    build_password_hash = var.build_password_hash
    build_ip_cidr       = var.build_ip_cidr
    build_gateway       = var.build_gateway
    build_dns           = var.build_dns
    apt_mirror          = var.apt_mirror
  })

  # Run a provisioner script as root. The build account needs its password for
  # sudo; "env {{ .Vars }}" passes the provisioner's environment_vars through
  # (Ubuntu 26.04's sudo does not support -E).
  sudo_run = "echo '${var.build_password}' | sudo -S env {{ .Vars }} bash '{{ .Path }}'"
}

source "proxmox-iso" "ubuntu" {
  # --- Proxmox API ---------------------------------------------------------
  proxmox_url              = "${var.pve_endpoint}/api2/json"
  username                 = var.pve_token_id
  token                    = var.pve_token_secret
  insecure_skip_tls_verify = true # PVE uses its own self-signed CA
  node                     = var.pve_node
  task_timeout             = "10m"

  # --- VM hardware: mirrors the hand-built template (VMID 604) --------------
  vm_id           = var.template_vmid
  vm_name         = var.template_name
  os              = "l26"
  bios            = "seabios"
  cpu_type        = "host"
  sockets         = 1
  cores           = var.cores
  memory          = var.memory
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true

  disks {
    type         = "scsi"
    storage_pool = var.vm_storage
    disk_size    = var.disk_size
    format       = "raw"
    io_thread    = true
  }

  network_adapters {
    model    = "virtio"
    bridge   = var.bridge
    firewall = true
  }

  # --- Install media --------------------------------------------------------
  # The disk is first in the boot order. It is empty on the first boot, so the
  # BIOS falls through to the installer CD; after the install the VM reboots
  # straight into the installed system.
  boot = "order=scsi0;ide2;net0"

  boot_iso {
    type     = "ide"
    index    = "2"
    iso_file = var.iso_file
    unmount  = true
  }

  additional_iso_files {
    type             = "ide"
    index            = "3"
    iso_storage_pool = var.iso_storage
    cd_label         = "cidata"
    cd_content = {
      "meta-data" = "instance-id: ${var.template_name}-autoinstall\n"
      "user-data" = local.user_data
    }
    unmount = true
  }

  # Subiquity only skips its "Continue with autoinstall?" prompt when the word
  # "autoinstall" is on the kernel command line, so boot the installer kernel
  # by hand from the GRUB console. The paths and the trailing "---" are copied
  # from /boot/grub/grub.cfg on the ISO. "autoinstall" must stay BEFORE "---":
  # anything after it is copied into the installed system's GRUB config.
  boot_wait = var.boot_wait
  boot_command = [
    "c<wait3>",
    "linux /casper/vmlinuz autoinstall ---<enter><wait3>",
    "initrd /casper/initrd<enter><wait15>",
    "boot<enter>",
  ]

  # --- Communicator ---------------------------------------------------------
  # Packer keeps retrying SSH while the installer runs. The live installer
  # environment answers on the same address but rejects the build account, so
  # allow many failed handshakes before giving up.
  ssh_host               = split("/", var.build_ip_cidr)[0]
  ssh_username           = var.build_username
  ssh_password           = var.build_password
  ssh_timeout            = "45m"
  ssh_handshake_attempts = 1000

  # --- Template -------------------------------------------------------------
  template_name        = var.template_name
  template_description = "Ubuntu Server 26.04, ISO autoinstall, root on LVM, cloud-init ready. Built by Packer on ${formatdate("YYYY-MM-DD", timestamp())}."

  # Adds the (empty) PVE cloud-init drive that clones are configured through.
  cloud_init                          = true
  cloud_init_storage_pool             = var.vm_storage
  cloud_init_disk_type                = "ide"
  cloud_init_disable_upgrade_packages = true
}

build {
  sources = ["source.proxmox-iso.ubuntu"]

  provisioner "file" {
    sources = [
      "${path.root}/files/grow-root-lvm",
      "${path.root}/files/grow-root-lvm.service",
    ]
    destination = "/tmp/"
  }

  # 1. Check the install is what we asked for, add the disk-grow service.
  provisioner "shell" {
    execute_command = local.sudo_run
    script          = "${path.root}/scripts/provision.sh"
  }

  # 2. Seal the image. This deletes the build account that Packer is logged in
  #    as, so it must be the last provisioner and must not be cleaned up over
  #    a new SSH session (skip_clean); the script removes itself instead.
  provisioner "shell" {
    execute_command   = local.sudo_run
    script            = "${path.root}/scripts/seal.sh"
    environment_vars  = ["BUILD_USERNAME=${var.build_username}"]
    skip_clean        = true
    expect_disconnect = true
  }
}
