resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.vms

  node_name = var.pve_node
  vm_id     = each.value.vmid
  name      = each.key

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  # Hardware is restated (not just inherited) so the provider does not replace
  # the template's settings with its own defaults.
  scsi_hardware = "virtio-scsi-single"
  on_boot       = false # provider default is true; the hand-built VMs do not autostart

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true # qemu-guest-agent is baked into the template
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
    # Keep the balloon device, as on a VM made in the web UI. The provider's
    # default (0) would write "balloon: 0" and remove the device.
    floating = each.value.memory_mb
  }

  # Same slot as the template's disk: a larger size grows it in place, and
  # grow-root-lvm inside the guest extends partition, PV, LV and filesystem.
  disk {
    interface    = "scsi0"
    datastore_id = var.vm_storage
    size         = each.value.disk_gb
    iothread     = true
  }

  network_device {
    model    = "virtio"
    bridge   = var.bridge
    firewall = true
  }

  # PVE's built-in cloud-init fields: no snippets, visible in the web UI.
  initialization {
    datastore_id = var.vm_storage

    ip_config {
      ipv4 {
        address = each.value.ip_cidr
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = each.value.username
      password = var.vm_passwords[each.key]
      keys     = var.ssh_public_keys
    }
  }
}
