#!/usr/bin/env bash
# One-time prerequisite. Run ON the PVE node as root (or through sudo).
#
# Creates a dedicated API identity for Packer and OpenTofu with the minimum
# privileges this repo needs, then prints the new token as JSON on stdout.
# The token secret is shown only once: capture stdout.
#
# To undo everything this script did:
#   pveum user delete automation@pve     # also removes its token and ACLs
#   pveum role delete AutomationIso
set -euo pipefail

NODE="${NODE:-node5}"
VM_STORAGE="${VM_STORAGE:-vmdata}"
ISO_STORAGE="${ISO_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr1}"
PVE_USER="automation@pve"
TOKEN_ID="iac"

if pveum user list --output-format json | grep -q "\"userid\":\"${PVE_USER}\""; then
  echo "user ${PVE_USER} already exists; refusing to continue" >&2
  exit 1
fi

# Read the installer ISO, upload the small autoinstall seed ISO, and delete it
# again when the build ends. Deleting needs Datastore.Allocate, which PVE only
# grants per storage: this token can therefore delete ANY file on ISO_STORAGE
# (other ISOs, backups, container templates), not just its own uploads.
pveum role add AutomationIso \
  -privs "Datastore.Audit,Datastore.AllocateTemplate,Datastore.AllocateSpace,Datastore.Allocate" >&2

pveum user add "${PVE_USER}" \
  --comment "Packer/OpenTofu automation for ubuntu-pve-vm-template" >&2

# Create, configure, clone, start/stop and template VMs.
pveum acl modify /vms -user "${PVE_USER}" -role PVEVMAdmin >&2
# Allocate VM disks and cloud-init drives.
pveum acl modify "/storage/${VM_STORAGE}" -user "${PVE_USER}" -role PVEDatastoreUser >&2
pveum acl modify "/storage/${ISO_STORAGE}" -user "${PVE_USER}" -role AutomationIso >&2
# Attach NICs to the VM bridge.
pveum acl modify "/sdn/zones/localnetwork/${BRIDGE}" -user "${PVE_USER}" -role PVESDNUser >&2
# Read node status and task logs.
pveum acl modify "/nodes/${NODE}" -user "${PVE_USER}" -role PVEAuditor >&2

# privsep=0: the token has exactly the privileges of automation@pve.
pveum user token add "${PVE_USER}" "${TOKEN_ID}" --privsep 0 --output-format json
