# --- Proxmox connection (overlay env, passed in as TF_VAR_*) -----------------
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

variable "template_vmid" {
  type        = number
  description = "Template built by base/packer. TEMPLATE_VMID in the overlay env."
}

# --- Site (overlay site.hcl, shared with Packer) ---------------------------
variable "vm_storage" {
  type        = string
  description = "Storage for VM disks."
}

variable "iso_storage" {
  type        = string
  default     = ""
  description = "Only used by Packer; declared here so both tools can read the same site.hcl."
}

variable "bridge" {
  type = string
}

variable "gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "ssh_public_keys" {
  type        = list(string)
  default     = []
  description = "Public keys authorised for every VM's user. scripts/tofu.sh fills this from SSH_PUBLIC_KEY_FILE."
}

# --- The VMs (overlay vms.tfvars and secrets.tfvars) --------------------------
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

variable "vm_password_hashes" {
  description = "SHA-512 crypt hash of each VM's login password, keyed by VM name. Generate with scripts/hash-password.sh and keep in the overlay's secrets.tfvars (git-ignored). PVE passes a crypt hash to cloud-init unchanged, so no plaintext password is ever written to this repo, the state file or the PVE VM config."
  type        = map(string)
  sensitive   = true

  validation {
    condition     = alltrue([for h in values(var.vm_password_hashes) : can(regex("^\\$6\\$[^$]+\\$[./A-Za-z0-9]{86}$", h))])
    error_message = "Every value must be a SHA-512 crypt hash ($6$<salt>$<86 characters>), not a plaintext password. Generate one with scripts/hash-password.sh."
  }
}
