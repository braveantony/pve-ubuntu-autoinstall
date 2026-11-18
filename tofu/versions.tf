terraform {
  required_version = ">= 1.13.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.123.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = "${var.pve_token_id}=${var.pve_token_secret}"
  insecure  = true # PVE uses its own self-signed CA
}
