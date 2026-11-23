#!/usr/bin/env bash
# Debug aid: save what a VM's VGA console currently shows as a PNG.
# Useful when the installer hangs and you want to see why without opening
# the PVE web console.
#
#   scripts/vm-screenshot.sh <overlay> <vmid> <out.png>
#
# Needs SSH to the PVE node (PVE_SSH in the overlay env, root or a user with passwordless
# sudo) and python3 locally (standard library only).
set -euo pipefail

usage="usage: $0 <overlay> <vmid> <out.png>"
. "$(dirname "$0")/lib.sh"
load_overlay "${1:-}"
vmid="${2:?$usage}"
out="${3:?$usage}"
node_ssh="${PVE_SSH:?set PVE_SSH in overlays/$overlay/env, for example root@192.168.11.201}"
node="${PVE_NODE:?set PVE_NODE in overlays/$overlay/env}"
remote="/tmp/vm-${vmid}-screen.$$.ppm"

ssh -o BatchMode=yes "$node_ssh" \
  "S=; [ \"\$(id -u)\" -eq 0 ] || S='sudo -n'; \$S pvesh create /nodes/${node}/qemu/${vmid}/monitor --command 'screendump ${remote}' >/dev/null && sleep 1 && \$S cat ${remote} && \$S rm -f ${remote}" |
python3 -c '
import sys, zlib, struct
data = sys.stdin.buffer.read()
if not data.startswith(b"P6"):
    sys.exit("no screen dump received: is the VM running, and can PVE_SSH run pvesh?")
# Binary PPM (P6): magic, width, height, maxval, then raw RGB.
fields, pos = [], 0
while len(fields) < 4:
    while data[pos:pos+1].isspace(): pos += 1
    if data[pos:pos+1] == b"#":
        pos = data.index(b"\n", pos); continue
    end = pos
    while not data[end:end+1].isspace(): end += 1
    fields.append(data[pos:end]); pos = end
pos += 1
assert fields[0] == b"P6", fields
w, h = int(fields[1]), int(fields[2])
rgb = data[pos:pos + w*h*3]
raw = b"".join(b"\x00" + rgb[y*w*3:(y+1)*w*3] for y in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
print(f"{sys.argv[1]}: {w}x{h}")
' "$out"
