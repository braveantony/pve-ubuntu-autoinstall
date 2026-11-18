output "vms" {
  description = "Name, VMID, configured address and login user of each VM."
  value = {
    for name, vm in proxmox_virtual_environment_vm.vm : name => {
      vmid     = vm.vm_id
      address  = split("/", var.vms[name].ip_cidr)[0]
      username = var.vms[name].username
    }
  }
}
