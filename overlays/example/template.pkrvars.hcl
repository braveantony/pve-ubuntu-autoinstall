# The template Packer builds. Its VMID is TEMPLATE_VMID in env.

# Installer ISO as PVE names it (pvesm list <iso storage> --content iso).
iso_file = "local:iso/ubuntu-26.04-live-server-amd64.iso"

# Address the VM uses during the build only. It must be free and reachable
# from this machine.
build_ip_cidr = "192.168.11.66/24"

# Optional: remove the leading "#" to change a default.
# template_name = "ub2604-ci-temp"
# cores         = 4
# memory        = 8192    # MB
# disk_size     = "50G"   # VMs cloned from the template cannot be smaller

# Ubuntu package mirror used during the install. Pick one near you.
apt_mirror = "http://tw.archive.ubuntu.com/ubuntu/"
