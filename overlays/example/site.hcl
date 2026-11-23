# Values that describe your PVE site. Read by both Packer and OpenTofu.
vm_storage  = "vmdata"         # storage for VM disks
iso_storage = "local"          # storage that holds ISO files
bridge      = "vmbr1"          # bridge the VMs attach to
gateway     = "192.168.11.254"
dns_servers = ["192.168.11.2"]
