# --- Proxmox connection (from .env, passed in as TF_VAR_*) --------------------
variable "pve_endpoint" {
  type        = string
  description = "PVE API base URL, for example https://192.168.11.201:8006"
}

variable "pve_node" {
  type = string
}

variable "pve_token_id" {
  type        = string
  description = "user@realm!tokenid"
}

variable "pve_token_secret" {
  type      = string
  sensitive = true
}

# --- Site defaults ------------------------------------------------------------
variable "template_vmid" {
  type        = number
  default     = 605
  description = "Template built by packer/ (scripts/build-template.sh)."
}

variable "vm_storage" {
  type    = string
  default = "vmdata"
}

variable "bridge" {
  type    = string
  default = "vmbr1"
}

variable "gateway" {
  type    = string
  default = "192.168.11.254"
}

variable "dns_servers" {
  type    = list(string)
  default = ["192.168.11.2"]
}

variable "ssh_public_keys" {
  type        = list(string)
  default     = []
  description = "Public keys authorised for every VM's user. scripts/tofu.sh fills this from SSH_PUBLIC_KEY_FILE."
}

# --- The VMs ------------------------------------------------------------------
variable "vms" {
  description = "VMs to clone from the template, keyed by VM name (which is also the hostname)."
  type = map(object({
    vmid      = number
    ip_cidr   = string # for example 192.168.11.67/24
    username  = string # created by cloud-init on first boot
    cores     = optional(number, 4)
    memory_mb = optional(number, 8192)
    disk_gb   = optional(number, 50) # must be >= the template's disk
  }))
}

variable "vm_passwords" {
  description = "Login password per VM, keyed by VM name. Keep in secrets.auto.tfvars (git-ignored)."
  type        = map(string)
  sensitive   = true
}
