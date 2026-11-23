#!/usr/bin/env bash
# Check that the VMs OpenTofu cloned from the template meet the goals of this
# repo: per-VM network and account from cloud-init, root on LVM grown to the
# disk size, and a console/kernel setup identical to a manual ISO install.
#
#   scripts/verify.sh <overlay>
#
# Needs: the VMs applied (scripts/tofu.sh <overlay> apply), SSH key login to them from
# this machine, and SSH to the PVE node (PVE_SSH in the overlay env, root or a user with
# passwordless sudo) for the hardware comparison.
set -uo pipefail

. "$(dirname "$0")/lib.sh"
load_overlay "${1:-}" || exit 1
node_ssh="${PVE_SSH:?set PVE_SSH in overlays/$overlay/env, for example root@192.168.11.201}"
reference_vmid="${REFERENCE_VMID:-604}" # hand-built template to compare hardware with
build_username="${BUILD_USERNAME:-packer}"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
check() { # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1: $2"; else bad "$1: got '$2', expected '$3'"; fi
}

vms_json=$("$repo/scripts/tofu.sh" "$overlay" output -json vms) || { echo "cannot read tofu output" >&2; exit 1; }

# Hardware keys a hand-built VM has; values that are per-VM by nature are
# not compared (name, sizes, MAC, UUIDs).
# Works whether PVE_SSH logs in as root or as a user with passwordless sudo.
qm_config() {
  ssh "${ssh_opts[@]}" "$node_ssh" "if [ \"\$(id -u)\" -eq 0 ]; then qm config $1; else sudo -n qm config $1; fi"
}
hw_keys() {
  qm_config "$1" |
    sed -E 's/^([a-z0-9]+): .*/\1/' | grep -vE '^(template|description|tags)$' | sort
}
hw_value() { qm_config "$1" | sed -n "s/^$2: //p"; }

ref_keys=$(hw_keys "$reference_vmid")

for name in $(jq -r 'keys[]' <<<"$vms_json"); do
  vmid=$(jq -r --arg n "$name" '.[$n].vmid' <<<"$vms_json")
  addr=$(jq -r --arg n "$name" '.[$n].address' <<<"$vms_json")
  user=$(jq -r --arg n "$name" '.[$n].username' <<<"$vms_json")
  echo "== $name (VMID $vmid, $user@$addr)"

  guest() { ssh "${ssh_opts[@]}" "$user@$addr" "$@"; }

  # 1. Network and hostname from cloud-init
  if ! guest true 2>/dev/null; then
    bad "SSH key login as $user@$addr"
    continue
  fi
  ok "SSH key login as $user@$addr"
  check "hostname" "$(guest hostname)" "$name"
  if guest "ip -4 -o addr show scope global" | grep -q " $addr/"; then ok "address $addr is configured"; else bad "address $addr is not configured"; fi
  check "cloud-init status" "$(guest "cloud-init status" | sed -n 's/^status: //p')" "done"
  check "cloud-init datasource" "$(guest "cloud-id")" "nocloud"

  # 2. Account from cloud-init, build account gone
  check "uid of $user" "$(guest "id -u")" "1000"
  if guest "sudo -n true" 2>/dev/null; then ok "$user has sudo"; else bad "$user has no passwordless sudo"; fi
  if guest "getent passwd $build_username" >/dev/null; then bad "build account $build_username still exists"; else ok "build account $build_username is absent"; fi
  if guest "test -e /home/$build_username"; then bad "/home/$build_username still exists"; else ok "/home/$build_username is absent"; fi

  # 3. Root on LVM, grown to the disk
  check "root device" "$(guest "findmnt -n -o SOURCE /")" "/dev/mapper/ubuntu--vg-ubuntu--lv"
  disk_gb=$(hw_value "$vmid" scsi0 | sed -n 's/.*size=\([0-9]*\)G.*/\1/p')
  root_gb=$(guest "lsblk -b -n -o SIZE /dev/mapper/ubuntu--vg-ubuntu--lv" | awk '{printf "%d", $1 / 1024 / 1024 / 1024}')
  fs_gb=$(guest "df -B1 --output=size / | tail -1" | awk '{printf "%d", $1 / 1024 / 1024 / 1024}')
  # Expected: disk minus 1 MiB BIOS partition and 2 GiB /boot, rounded down.
  want_gb=$((disk_gb - 3))
  if [ "$root_gb" -ge "$want_gb" ]; then ok "root LV is ${root_gb}G on a ${disk_gb}G disk"; else bad "root LV is ${root_gb}G on a ${disk_gb}G disk (expected >= ${want_gb}G)"; fi
  if [ "$fs_gb" -ge $((want_gb - 3)) ]; then ok "root filesystem is ${fs_gb}G"; else bad "root filesystem is only ${fs_gb}G"; fi
  check "free extents left in ubuntu-vg" "$(guest "sudo -n vgs --noheadings -o vg_free_count ubuntu-vg" | tr -d ' ')" "0"

  # 4. Same console/kernel setup as a manual ISO install
  cmdline=$(guest "cat /proc/cmdline")
  if grep -q 'console=' <<<"$cmdline"; then bad "kernel cmdline has console=: $cmdline"; else ok "kernel cmdline has no console= override"; fi
  if grep -qw 'autoinstall' <<<"$cmdline"; then bad "kernel cmdline contains autoinstall"; else ok "kernel cmdline has no installer leftovers"; fi
  check "GRUB_CMDLINE_LINUX" "$(guest "sed -n 's/^GRUB_CMDLINE_LINUX=//p' /etc/default/grub")" '""'
  check "GRUB_CMDLINE_LINUX_DEFAULT" "$(guest "sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT=//p' /etc/default/grub")" '""'
  if guest "dpkg -s linux-generic" >/dev/null 2>&1; then ok "linux-generic kernel ($(guest "uname -r"))"; else bad "linux-generic is not installed"; fi
  if guest "systemctl is-active --quiet getty@tty1"; then ok "login prompt (getty) is running on tty1"; else bad "no getty on tty1"; fi
  if guest "systemctl is-active --quiet 'serial-getty@*'" 2>/dev/null; then bad "a serial getty is running"; else ok "no serial getty"; fi

  # Hardware: the only keys a clone may have beyond the hand-built reference
  # are the cloud-init drive and PVE's cloud-init fields.
  vm_keys=$(hw_keys "$vmid")
  extra=$(comm -13 <(echo "$ref_keys") <(echo "$vm_keys") | tr '\n' ' ')
  missing=$(comm -23 <(echo "$ref_keys") <(echo "$vm_keys") | tr '\n' ' ')
  # bios/kvm/onboot/tablet: Packer and the provider write these out even when
  # they equal the PVE default, so they are checked by value below instead.
  unexpected=$(tr ' ' '\n' <<<"$extra" | grep -vE '^(ide[0-3]|ciuser|cipassword|ciupgrade|ipconfig0|nameserver|searchdomain|sshkeys|bios|kvm|onboot|tablet|balloon|)$' | tr '\n' ' ')
  echo "        config keys beyond VMID $reference_vmid: ${extra:-none}"
  if [ -z "${unexpected// /}" ]; then ok "extra hardware keys are cloud-init only"; else bad "unexpected hardware keys: $unexpected"; fi
  if [ -z "${missing// /}" ]; then ok "no hardware key of VMID $reference_vmid is missing"; else bad "missing hardware keys: $missing"; fi
  if hw_keys "$vmid" | grep -q '^serial'; then bad "VM has a serial port"; else ok "no serial port"; fi
  if hw_keys "$vmid" | grep -q '^vga'; then bad "VM overrides the display adapter"; else ok "default VGA display"; fi
  # Explicitly written defaults must really be the default.
  for kv in bios=seabios kvm=1 onboot=0 tablet=1; do
    actual=$(hw_value "$vmid" "${kv%%=*}")
    if [ -z "$actual" ] || [ "$actual" = "${kv#*=}" ]; then ok "${kv%%=*} is the PVE default (${kv#*=})"; else bad "${kv%%=*} is '$actual', PVE default is '${kv#*=}'"; fi
  done
  # balloon equal to memory is what an unset balloon means: device present,
  # no memory taken back. "balloon: 0" would mean the device is removed.
  balloon=$(hw_value "$vmid" balloon)
  if [ -z "$balloon" ] || [ "$balloon" = "$(hw_value "$vmid" memory)" ]; then ok "balloon device present (PVE default)"; else bad "balloon is '$balloon', expected unset or equal to memory"; fi
  for key in scsihw cpu ostype boot; do
    check "$key" "$(hw_value "$vmid" "$key")" "$(hw_value "$reference_vmid" "$key")"
  done
  # "agent: 1" and "agent: enabled=1,<defaults spelled out>" are the same setting.
  agent_norm() { hw_value "$1" agent | sed -E 's/^enabled=//; s/,fstrim_cloned_disks=0//; s/,type=virtio//'; }
  check "agent" "$(agent_norm "$vmid")" "$(agent_norm "$reference_vmid")"
  if hw_value "$vmid" "$(hw_keys "$vmid" | grep -E '^ide[0-3]$' | head -1)" | grep -q cloudinit; then ok "cloud-init drive is attached"; else bad "no cloud-init drive"; fi
done

echo
echo "Result: $pass passed, $fail failed"
echo "Still to check by hand in the PVE web console (noVNC) of each VM:"
echo "  - the login prompt is shown on the graphical console (tty1)"
echo "  - logging in there with the password you hashed for secrets.tfvars works"
[ "$fail" -eq 0 ]
