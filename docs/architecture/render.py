"""Render the architecture diagrams with Python's standard library."""
from pathlib import Path
from unicodedata import east_asian_width
from xml.etree import ElementTree as ET

BLUE = "#335e9a"
TEAL = "#167064"
INK = "#26374a"
EDGE = "#657589"
FONT = '"Noto Sans CJK TC", "Noto Sans TC", "PingFang TC", "Microsoft JhengHei", sans-serif'


def element(parent, tag, **attrs):
    return ET.SubElement(parent, tag, {k.replace("_", "-"): str(v) for k, v in attrs.items()})


def rect(s, x, y, w, h, fill="white", stroke=EDGE, **attrs):
    return element(s, "rect", x=x, y=y, width=w, height=h, fill=fill,
                   stroke=stroke, stroke_width=2, **attrs)


def label(s, x, y, value, size=20, anchor="middle", weight=500, color=INK):
    element(s, "text", x=x, y=y, text_anchor=anchor, fill=color,
            font_size=size, font_weight=weight).text = value


def text_width(value, size):
    return size * sum(1 if east_asian_width(c) in "WF" else 0.6 for c in value)


def fitted(s, bounds, x, y, value, size=20, anchor="middle", weight=500):
    # Coordinates describe the baseline. Allow for ascenders, descenders,
    # and half of the two-pixel outline in addition to the clear padding.
    bx, by, w, h = bounds
    width = text_width(value, size)
    left = x - width * {"middle": 0.5, "end": 1, "start": 0}[anchor]
    assert min(left-bx, bx+w-left-width, y-size*0.85-by,
               by+h-y-size*0.25) >= 15, f"{value!r} exceeds padding in {bounds}"
    label(s, x, y, value, size, anchor, weight)


def canvas(title, w, h):
    s = ET.Element("svg", xmlns="http://www.w3.org/2000/svg", width=str(w),
                   height=str(h), viewBox=f"0 0 {w} {h}", attrib={"font-family": FONT})
    element(s, "title").text = title
    defs = element(s, "defs")
    for color in (BLUE, TEAL):
        m = element(defs, "marker", id="tip"+color[1:], viewBox="0 0 10 10",
                    refX=10, refY=5, markerWidth=12, markerHeight=12,
                    markerUnits="userSpaceOnUse", orient="auto")
        element(m, "path", d="M0 0 L10 5 L0 10 Z", fill=color)
    rect(s, 0, 0, w, h, stroke="none")
    return s


def group(s, x, y, w, h, name):
    rect(s, x, y, w, h, "#f7f9fb", "#b2bfcb", rx=10)
    fitted(s, (x, y, w, h), x+20, y+40, name, 26, "start", 700)


def shape(s, x, y, w, h, kind):
    if kind == "cd":
        element(s, "path", d=f"M{x+12} {y} h{w-12} v{h} h{-w} v{12-h} Z",
                fill="#fff6dd", stroke="#94763a", stroke_width=2)
    elif kind == "disk":
        rect(s, x+6, y+6, w-6, h-6, "#c7d8e8")
        rect(s, x+3, y+3, w-6, h-6, "#dce8f3")
        rect(s, x, y, w-6, h-6, "#edf3f9")
    elif kind == "template":
        rect(s, x, y, w, h, "#e7effc", BLUE, rx=5)
        rect(s, x+5, y+5, w-10, h-10, "none", BLUE, rx=2)
    else:
        attrs = {"stroke_dasharray": "7 5"} if kind == "container" else {}
        rect(s, x, y, w, h, rx=5, **attrs)


def box(s, x, y, w, h, name, kind="vm"):
    shape(s, x, y, w, h, kind)
    inset = 5 if kind == "template" else 0
    fitted(s, (x+inset, y+inset, w-2*inset, h-2*inset),
           x+w/2, y+h/2+6, name)


def arrow(s, path, color, width=3):
    element(s, "path", d=path, fill="none", stroke=color, stroke_width=width,
            stroke_linejoin="round", marker_end=f"url(#tip{color[1:]})")


def badge(s, x, y, n, color):
    element(s, "circle", cx=x, cy=y, r=15, fill="white")
    label(s, x, y+9, chr(0x2460+n-1), 28, color=color)


def legend(s, y, *, disk=True, segmented=False):
    for x, kind, name in [(28, "container", "容器"), (168, "vm", "VM"),
                          (290, "template", "範本"), (425, "cd", "光碟"),
                          (565, "disk", "磁碟 / LVM")]:
        if kind == "disk" and not disk:
            continue
        if kind == "disk" and segmented:
            rect(s, x, y, 7, 25, "#f5f8fb")
            rect(s, x+7, y, 10, 25, "#f5f8fb")
            rect(s, x+17, y, 19, 25, "#deebf5")
        else:
            shape(s, x, y, 36, 25, kind)
        label(s, x+52, y+20, name, 18, "start")


def overview():
    s = canvas("兩階段架構", 1090, 580)
    group(s, 20, 20, 208, 480, "工作機")
    group(s, 260, 20, 810, 480, "PVE 節點")
    group(s, 477, 38, 490, 115, "ISO storage")
    box(s, 491, 89, 200, 54, "Ubuntu 安裝光碟", "cd")
    box(s, 705, 89, 244, 54, "種子光碟 (cidata)", "cd")
    box(s, 43, 180, 154, 72, "Packer", "container")
    box(s, 43, 377, 154, 65, "OpenTofu", "container")
    box(s, 308, 267, 127, 81, "PVE API")
    box(s, 480, 181, 188, 64, "VM 605 → 範本", "template")
    arrow(s, "M197 237 H349 V267", BLUE, 5)
    badge(s, 278, 237, 1, BLUE)
    arrow(s, "M685 153 V213 H668", BLUE, 5)
    badge(s, 685, 182, 2, BLUE)
    arrow(s, "M197 199 H480", BLUE)
    badge(s, 390, 199, 3, BLUE)
    arrow(s, "M197 408 H373 V348", TEAL, 5)
    badge(s, 286, 408, 4, TEAL)
    for y in (274, 415):
        box(s, 683, y-27, 86, 54, "VM")
        box(s, 822, y-27, 226, 54, "cloud-init 光碟機", "cd")
        arrow(s, f"M822 {y} H769", TEAL)
        badge(s, 797, y, 6, TEAL)
        arrow(s, f"M574 {y} H683", TEAL, 5)
    element(s, "path", d="M574 245 V415", fill="none", stroke=TEAL, stroke_width=5)
    badge(s, 623, 274, 5, TEAL)
    badge(s, 623, 415, 5, TEAL)
    legend(s, 530, disk=False)
    return s


def disk_bar(s, x, y, w, *, clone=False, tail=0):
    """Only the last partition and its contents change width between clones."""
    if clone:
        label(s, x+10, y+29, "scsi0", 18, "start")
    else:
        shape(s, x, y, w, 270, "disk")
        fitted(s, (x, y, w-6, 264), x+20, y+33, "scsi0", 18, "start")
    px, py = x+10, y+48
    for name, width in (("1M", 58), ("/boot", 90)):
        rect(s, px, py, width, 207, "#f5f8fb")
        fitted(s, (px, py, width, 207), px+width/2, py+105, name, 18)
        px += width
    width = x+w-16-px-tail
    if tail:
        rect(s, px+width, py, tail, 207, "none", stroke_dasharray="7 5")
    for name, height, fill in (("PV", 207, "#deebf5"),
                               ("ubuntu-vg", 156, "#d1e4ec"),
                               ("ubuntu-lv", 105, "#c4dddf")):
        rect(s, px, py, width, height, fill)
        fitted(s, (px, py, width, height), px+16, py+32, name, 18, "start")
        px, py, width = px+8, py+47, width-16
    rect(s, px, py, width, 51, "#f2faf8")
    fitted(s, (px, py, width, 51), px+width/2, py+31, "/", 18)


def stage1():
    s = canvas("建立範本", 1040, 1150)
    group(s, 18, 18, 205, 1070, "工作機")
    group(s, 254, 18, 768, 1070, "PVE 節點")
    shape(s, 43, 88, 153, 836, "container")
    fitted(s, (43, 88, 153, 836), 119, 130, "Packer", 24)
    group(s, 508, 42, 490, 127, "ISO storage")
    box(s, 588, 98, 230, 54, "cidata", "cd")
    arrow(s, "M196 125 H588", BLUE)
    badge(s, 394, 125, 1, BLUE)
    box(s, 286, 193, 135, 54, "PVE API")
    arrow(s, "M196 220 H286", BLUE)
    arrow(s, "M421 220 H477", BLUE, 5)
    badge(s, 448, 220, 2, BLUE)
    install = (477, 188, 521, 502)
    shape(s, *install, "vm")
    fitted(s, install, 501, 230, "安裝環境", 26, "start", 700)
    fitted(s, install, 972, 229, "VM 605", 20, "end")
    box(s, 496, 252, 248, 54, "ide2 · Ubuntu ISO", "cd")
    box(s, 760, 252, 214, 54, "ide3 · cidata", "cd")
    box(s, 496, 330, 130, 54, "GRUB")
    arrow(s, "M196 357 H496", BLUE)
    badge(s, 320, 357, 3, BLUE)
    label(s, 386, 340, "鍵盤")
    arrow(s, "M867 306 V404", BLUE)
    badge(s, 867, 354, 4, BLUE)
    disk_bar(s, 496, 404, 478)
    arrow(s, "M738 690 V750", BLUE, 5)
    badge(s, 738, 720, 5, BLUE)
    label(s, 773, 727, "scsi0", 18, "start")
    installed = (477, 750, 521, 200)
    shape(s, *installed, "vm")
    fitted(s, installed, 501, 792, "已安裝的系統", 26, "start", 700)
    for n, y, name in [(6, 839, "provision.sh"), (7, 909, "seal.sh")]:
        box(s, 501, y-27, 196, 54, name)
        arrow(s, f"M196 {y} H501", BLUE)
        badge(s, 318, y, n, BLUE)
        label(s, 381, y-17, "SSH", 18)
    arrow(s, "M738 950 V994", BLUE, 5)
    badge(s, 766, 973, 8, BLUE)
    template = (477, 994, 521, 80)
    shape(s, *template, "template")
    fitted(s, (482, 999, 511, 70), 510, 1041, "範本 605", 22, "start", 700)
    box(s, 732, 1007, 251, 54, "ide0 · cloud-init", "cd")
    legend(s, 1101)
    return s


def stage2():
    s = canvas("複製 VM", 1100, 1280)
    group(s, 18, 18, 174, 1182, "工作機")
    group(s, 247, 18, 835, 1182, "PVE 節點")
    tofu = (36, 112, 146, 1055)
    api = (263, 112, 132, 1055)
    shape(s, *tofu, "container")
    fitted(s, tofu, 109, 156, "OpenTofu", 24)
    shape(s, *api, "vm")
    fitted(s, api, 329, 155, "PVE API", 22)
    arrow(s, "M182 185 H263", TEAL)
    box(s, 643, 61, 176, 66, "範本 605", "template")
    arrow(s, "M329 112 V91 H643", TEAL)
    arrow(s, "M731 127 V193", TEAL, 5)
    badge(s, 731, 158, 1, TEAL)
    vm = (465, 193, 595, 985)
    shape(s, *vm, "vm")
    fitted(s, vm, 492, 236, "VM", 26, "start", 700)
    box(s, 810, 238, 220, 54, "CPU · 記憶體")
    arrow(s, "M395 320 H973 V560", TEAL)
    badge(s, 430, 320, 2, TEAL)
    arrow(s, "M920 320 V292", TEAL)
    box(s, 500, 340, 300, 54, "cloud-init 光碟機", "cd")
    arrow(s, "M395 367 H500", TEAL)
    badge(s, 430, 367, 3, TEAL)
    arrow(s, "M395 427 H465", TEAL, 5)
    badge(s, 430, 427, 4, TEAL)
    fitted(s, vm, 492, 434, "啟動", 20, "start")
    arrow(s, "M665 394 V445", TEAL, 4)
    badge(s, 665, 419, 5, TEAL)
    box(s, 573, 445, 184, 54, "cloud-init")
    disk_bar(s, 489, 512, 560, clone=True, tail=120)
    disk_bar(s, 489, 815, 560, clone=True)
    arrow(s, "M745 767 V863", TEAL, 4)
    badge(s, 745, 815, 6, TEAL)
    fitted(s, vm, 777, 822, "grow-root-lvm", 20, "start")
    box(s, 504, 1109, 246, 54, "qemu-guest-agent")
    for path in ("M504 1136 H395", "M263 1136 H182"):
        arrow(s, path, TEAL)
    badge(s, 430, 1136, 7, TEAL)
    label(s, 220, 1119, "IP", 18)
    legend(s, 1232, segmented=True)
    rect(s, 753, 1232, 36, 25, "none", stroke_dasharray="7 5")
    label(s, 805, 1252, "未配置", 18, "start")
    return s


if __name__ == "__main__":
    for filename, draw in (("overview.svg", overview),
                           ("stage1-build-template.svg", stage1),
                           ("stage2-clone-vm.svg", stage2)):
        root = draw()
        ET.indent(root)
        Path(__file__).with_name(filename).write_text(
            ET.tostring(root, encoding="unicode") + "\n", encoding="utf-8")
