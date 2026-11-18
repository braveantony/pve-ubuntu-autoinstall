# The VMs OpenTofu manages. Add a block to get another VM, then run
# scripts/tofu.sh apply. Each name also needs a password in
# secrets.auto.tfvars.
vms = {
  # Same size as the template.
  ub2604-ci-test1 = {
    vmid     = 615
    ip_cidr  = "192.168.11.67/24"
    username = "bigred"
  }

  # Different user, smaller CPU/RAM, and a bigger disk to prove that root
  # grows automatically.
  ub2604-ci-test2 = {
    vmid      = 616
    ip_cidr   = "192.168.11.68/24"
    username  = "tester"
    cores     = 2
    memory_mb = 4096
    disk_gb   = 100
  }
}
