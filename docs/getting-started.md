# 建置手冊

這份手冊從一台剛裝好的 Linux 工作機開始，帶你建立 Ubuntu Server 26.04 的範本，再從範本建立 VM。照著做完大約需要 30 分鐘，其中約 10 分鐘是等待安裝。

想先了解每個步驟背後做了什麼，請看[運作原理](how-it-works.md)。

## 開始之前

**你需要兩台機器：**

- **PVE 節點**：一台運作中的 Proxmox VE 主機，VM 就執行在它上面。這份手冊在 PVE 9.2 上驗證過。
- **工作機**：一台 Linux，用來執行這個 repo 的腳本。它要和 PVE 節點、VM 所在的網段互通。

除非特別註明「在 PVE 節點上執行」，手冊裡的指令都在工作機上執行。

**會用到的名詞：**

| 名詞 | 意思 |
|---|---|
| 範本 | 一台設定成唯讀的 VM，專門用來複製出其他 VM |
| VMID | PVE 用來識別 VM 或容器的數字，同一個叢集內不能重複。它和主機名稱是兩回事 |
| storage | PVE 存放資料的位置，介面上稱為 Storage。每個 storage 會設定可以放哪些類型的內容，例如 VM 磁碟或 ISO |
| 橋接器 | PVE 節點上的虛擬交換器，例如 `vmbr0`。VM 的網卡接到哪個橋接器，就連到哪個網路 |
| Packer | 建置範本的工具 |
| OpenTofu | 依設定檔建立並管理 VM 的工具 |
| cloud-init | VM 第一次開機時，讀取外部設定並套用網路與帳號的程式 |

**手冊使用的範例環境：**

指令和輸出範例都用下表的數值，它們也是 repo 設定檔的預設值。[步驟 1.4](#14-記下你的環境) 會帶你查出自己的數值。

| 項目 | 範例值 |
|---|---|
| PVE 節點的 IP | `192.168.11.201` |
| PVE 節點名稱 | `node5` |
| 放 VM 磁碟的 storage | `vmdata` |
| 放 ISO 的 storage | `local` |
| VM 使用的橋接器 | `vmbr1` |
| 網段、閘道、DNS | `192.168.11.0/24`、`192.168.11.254`、`192.168.11.2` |
| 範本的 VMID | 605 |

`/24` 是網路遮罩的長度，等同 `255.255.255.0`。

## 1. 事前檢查

### 1.1 工作機的工具

```bash
for t in git podman curl jq ssh ssh-keygen openssl python3; do
  command -v "$t" >/dev/null && echo "OK    $t" || echo "缺少  $t"
done
```

有缺少的項目時，在 Ubuntu 或 Debian 上這樣安裝：

```bash
sudo apt update
sudo apt install -y git podman curl jq openssh-client openssl python3
```

Packer 與 OpenTofu 不用安裝。它們和各自的 Proxmox 外掛都包在同一個容器映像檔 `ghcr.io/braveantony/pve-ubuntu-autoinstall` 裡，腳本第一次執行時會用 podman 下載它。這個映像檔只提供 x86-64 版本。想自己建置映像檔的話，在 repo 根目錄執行 `podman build -t <名稱> .`，再把 `.env` 的 `TOOLS_IMAGE` 設成那個名稱。

### 1.2 選定一把 SSH 金鑰

這把金鑰有兩個用途：登入 PVE 節點，以及之後登入每台 VM。先看工作機有沒有金鑰：

```bash
ls ~/.ssh/id_*.pub
```

已經有金鑰時，會列出公鑰的路徑：

```
/home/bigred/.ssh/id_ed25519.pub
```

出現 `No such file or directory` 代表還沒有金鑰，建立一把：

```bash
ssh-keygen -t ed25519
```

它會問三個問題。第一個是存放位置，直接按 Enter 使用預設的 `~/.ssh/id_ed25519`。後兩個是金鑰的保護密碼，不設定的話連按兩次 Enter。

**記下公鑰的路徑**，也就是結尾是 `.pub` 的那個檔案，例如 `~/.ssh/id_ed25519.pub`，步驟 4.2 要填。有多把金鑰時，選一把即可。

### 1.3 能用 SSH 登入 PVE 節點

把公鑰裝到 PVE 節點，會問一次 root 的密碼：

```bash
ssh-copy-id root@192.168.11.201
```

確認不用密碼就能登入：

```bash
ssh root@192.168.11.201 pveversion
```

```
pve-manager/9.2.28/310cfbc506c4490f (running kernel: 7.0.12-1-pve)
```

**不用 root 的話**，可以改用其他帳號，條件是它在 PVE 節點上能免密碼執行 `sudo`。這時手冊裡的指令要調整兩處：

- `root@192.168.11.201` 換成那個帳號。
- 在 PVE 節點上執行的管理指令（`qm`、`pvesm`、`pvesh`、`pveum`）前面加上 `sudo`。

### 1.4 記下你的環境

這一步要查出六個值，後面的章節會用到。先登入 PVE 節點：

```bash
ssh root@192.168.11.201
```

以下四個指令都在 PVE 節點上執行。

**節點名稱**

```bash
hostname
```

```
node5
```

輸出的這一行就是節點名稱。

**storage**

```bash
pvesm status
```

```
Name             Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %
local             dir     active       205839152        84356420       112189396   40.98%
vmdata        lvmthin     active      1919827968       910190439      1009637528   47.41%
```

`Name` 欄是 storage 的名稱，只有 `Status` 是 `active` 的才能用。接著看每個 storage 可以放什麼：

```bash
cat /etc/pve/storage.cfg
```

```
dir: local
	path /var/lib/vz
	content import,backup,vztmpl,iso,images

lvmthin: vmdata
	thinpool vmdata
	vgname vmdata
	content images,rootdir
```

每一段的第一行冒號後面是 storage 名稱，`content` 那一行是它能放的內容。要選出兩個 storage：

- **放 VM 磁碟的 storage**：`content` 裡有 `images` 的。範例選 `vmdata`。
- **放 ISO 的 storage**：`content` 裡有 `iso` 的。範例選 `local`。

**橋接器**

```bash
ip -br link show type bridge | grep -v '^fwbr'
```

```
vmbr0            UP             00:e0:4c:68:1a:f4 <BROADCAST,MULTICAST,UP,LOWER_UP>
vmbr1            UP             74:56:3c:ff:03:e8 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

第一欄是橋接器的名稱。選 VM 要連的那個網路所在的橋接器；不確定的話，到 PVE 網頁點選一台已經在那個網路上的 VM，看「Hardware」頁面裡網卡的 `bridge=` 是哪一個。範例選 `vmbr1`。

**已被使用的 VMID**

```bash
pvesh get /cluster/resources --type vm --noborder | awk 'NR>1{print $1}'
```

```
qemu/601
qemu/602
qemu/604
lxc/700
```

斜線後面的數字就是已被使用的 VMID，清單涵蓋整個叢集的 VM 與容器。選一個沒出現在清單裡的數字當範本的 VMID，範例選 605。之後每台 VM 也各需要一個沒被使用的 VMID。

**IP、閘道與 DNS**

這三項沒有指令可以查，要依你的網路規劃決定：

- **建置範本時暫用的 IP**：建置期間 VM 會使用一個固定 IP，工作機靠它連進 VM。它必須和工作機互通，而且沒有其他裝置在用。範例是 `192.168.11.66`。
- **每台 VM 的 IP**：同樣不能和現有的機器重複。
- **閘道與 DNS**：和同一個網段上其他機器使用的相同。

確認 IP 可用時，請以你的 IP 分配紀錄或 DNS 紀錄為準。`ping` 只能知道當下有沒有裝置回應，關機中的機器、或不回應 ping 的裝置都查不出來。

**把查到的值記下來**

| 項目 | 範例值 | 之後用在哪裡 |
|---|---|---|
| 節點名稱 | `node5` | 步驟 4.1、4.2 |
| 放 VM 磁碟的 storage | `vmdata` | 第 3 章、步驟 4.1 |
| 放 ISO 的 storage | `local` | 步驟 1.5、第 3 章、步驟 4.1 |
| 橋接器 | `vmbr1` | 第 3 章、步驟 4.1 |
| 範本的 VMID | `605` | 步驟 4.2 |
| 建置時暫用的 IP、閘道、DNS | `192.168.11.66/24`、`192.168.11.254`、`192.168.11.2` | 第 3 章 |

先不要登出，下一步也在 PVE 節點上執行。

### 1.5 安裝光碟在 PVE 上

在 PVE 節點上執行，確認安裝光碟已經在放 ISO 的 storage 裡。把 `local` 換成你的 storage 名稱：

```bash
pvesm list local --content iso | grep ubuntu-26.04
```

```
local:iso/ubuntu-26.04-live-server-amd64.iso   iso   iso   2918598656
```

第一欄 `local:iso/ubuntu-26.04-live-server-amd64.iso` 是這張光碟在 PVE 裡的完整名稱，步驟 3 會用到。

沒有光碟的話，到 PVE 網頁選擇放 ISO 的 storage，在「ISO Images」頁面按「Download from URL」，貼上這個網址：

```
https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso
```

下載完成後，在同一頁核對檢查碼，或在 PVE 節點上計算。官方的檢查碼列在 <https://releases.ubuntu.com/26.04/SHA256SUMS>，這張光碟的是：

```
dec49008a71f6098d0bcfc822021f4d042d5f2db279e4d75bdd981304f1ca5d9
```

這個專案只用 26.04 這張光碟驗證過，之後的小改版（例如 26.04.1）沒有測過。

## 2. 取得 repo

在 PVE 節點上輸入 `exit` 回到工作機，把這個 repo 複製下來：

```bash
git clone https://github.com/braveantony/pve-ubuntu-autoinstall.git
cd pve-ubuntu-autoinstall
```

之後的指令都在這個目錄下執行。

## 3. 依你的環境修改設定

設定檔裡預先填好的是範例環境的值。這一章要把它們換成你在[步驟 1.4](#14-記下你的環境) 記下的值。你的環境和範例值完全相同的話，可以直接跳到第 4 章。

要改的檔案只有兩個：

| 檔案 | 用途 |
|---|---|
| `packer/variables.pkr.hcl` | 建立範本時用的設定 |
| `tofu/variables.tf` | 建立 VM 時用的設定 |

### 3.1 修改的方法

兩個檔案的寫法相同。每一項設定是一個 `variable` 區塊，要改的是區塊裡 `default =` 後面的值，其他地方不要動。

以「放 VM 磁碟的 storage」為例。用編輯器打開 `packer/variables.pkr.hcl`，找到這一段：

```hcl
variable "vm_storage" {
  type    = string
  default = "vmdata"
}
```

假設你的 storage 叫 `local-lvm`，就改成：

```hcl
variable "vm_storage" {
  type    = string
  default = "local-lvm"
}
```

值的寫法有三種，照原本的樣子改就不會錯：

- **文字**：前後要有雙引號，例如 `"local-lvm"`。
- **數字**：不加引號，例如 `4`。
- **清單**：用中括號包住，例如 `["192.168.11.2"]`；有兩筆時寫成 `["192.168.11.2", "8.8.8.8"]`。

### 3.2 修改 `packer/variables.pkr.hcl`

打開檔案，依下表逐項檢查。「範例值」是檔案裡現在的值，和你的環境不同才需要改。

| 變數 | 範例值 | 填什麼 |
|---|---|---|
| `vm_storage` | `"vmdata"` | 放 VM 磁碟的 storage 名稱 |
| `bridge` | `"vmbr1"` | VM 要接的橋接器名稱 |
| `iso_file` | `"local:iso/ubuntu-26.04-live-server-amd64.iso"` | 安裝光碟，填步驟 1.5 查到的完整名稱 |
| `iso_storage` | `"local"` | 放 ISO 的 storage 名稱，也就是 `iso_file` 冒號前面那一段 |
| `build_ip_cidr` | `"192.168.11.66/24"` | 建置範本時暫用的 IP，後面要加上網路遮罩的長度 |
| `build_gateway` | `"192.168.11.254"` | 這個網段的閘道 |
| `build_dns` | `"192.168.11.2"` | DNS 伺服器 |

以下四項是範本本身的名稱與規格，想調整再改：

| 變數 | 範例值 | 說明 |
|---|---|---|
| `template_name` | `"ub2604-ci-temp"` | 範本在 PVE 上顯示的名稱 |
| `cores` | `4` | CPU 核心數 |
| `memory` | `8192` | 記憶體，單位是 MB |
| `disk_size` | `"50G"` | 磁碟大小。之後建立的 VM 磁碟只能和它一樣大或更大 |

`apt_mirror` 是 Ubuntu 套件的下載來源，預設是台灣的鏡像站，不在台灣時可以換成離你較近的站。

檔案裡其他的變數不要改，包含 `pve_` 開頭的四個、`template_vmid`、`boot_wait`，以及 `build_username`、`build_password`、`build_password_hash`。它們由腳本或 `.env` 提供。

### 3.3 修改 `tofu/variables.tf`

這個檔案只有四項要檢查：

| 變數 | 範例值 | 填什麼 |
|---|---|---|
| `vm_storage` | `"vmdata"` | 和 3.2 的 `vm_storage` 填一樣的值 |
| `bridge` | `"vmbr1"` | 和 3.2 的 `bridge` 填一樣的值 |
| `gateway` | `"192.168.11.254"` | 所有 VM 共用的閘道 |
| `dns_servers` | `["192.168.11.2"]` | 所有 VM 共用的 DNS 伺服器，這一項是清單 |

範本的 `disk_size` 改成大於 50G 的話，這個檔案裡還要改一個地方：找到 `variable "vms"` 區塊裡的 `disk_gb = optional(number, 50)`，把 `50` 改成和範本一樣的數字。VM 的磁碟不能小於範本。

其他的變數不要改。每台 VM 的名稱、IP 與帳號不在這裡設定，第 6 章會說明。

### 3.4 檢查改了什麼

```bash
git diff packer/variables.pkr.hcl tofu/variables.tf
```

輸出裡 `-` 開頭的是原本的行，`+` 開頭的是你改後的行。確認每一處都只改到 `default =` 後面的值。沒有任何輸出代表兩個檔案都沒有變動。

PVE 節點的位址、節點名稱與**範本的 VMID** 不在這兩個檔案裡，它們填在下一章建立的 `.env`。

## 4. 建立 API 權杖

Packer 與 OpenTofu 透過 PVE 的 API 操作，需要一組 API 權杖（token，用來代替帳號密碼的憑證）。

### 4.1 在 PVE 上建立專用帳號與權杖

`scripts/pve-access.sh` 會在 PVE 上建立一個專用帳號，並只開放這個專案需要的權限。它要知道步驟 1.4 記下的四個值，才能把權限設在正確的對象上：

| 變數 | 範例值 | 填什麼 |
|---|---|---|
| `NODE` | `node5` | 節點名稱 |
| `VM_STORAGE` | `vmdata` | 放 VM 磁碟的 storage |
| `ISO_STORAGE` | `local` | 放 ISO 的 storage |
| `BRIDGE` | `vmbr1` | 橋接器 |

在工作機上執行以下指令，把四個等號後面的值和 `root@192.168.11.201` 換成你的：

```bash
ssh root@192.168.11.201 'NODE=node5 VM_STORAGE=vmdata ISO_STORAGE=local BRIDGE=vmbr1 bash -s' < scripts/pve-access.sh
```

用非 root 帳號登入 PVE 時，引號裡的開頭多加 `sudo env`：

```bash
ssh bigred@192.168.11.201 'sudo env NODE=node5 VM_STORAGE=vmdata ISO_STORAGE=local BRIDGE=vmbr1 bash -s' < scripts/pve-access.sh
```

輸出的最後一行是一段 JSON：

```json
{"full-tokenid":"automation@pve!iac","info":{"privsep":"0"},"value":"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
```

下一步會用到其中兩個值：

- `full-tokenid` 後面的 `automation@pve!iac` 是權杖的 ID。
- `value` 後面那串是權杖的密鑰，**只會顯示這一次**。先不要關掉這個終端機視窗，下一步要把它貼進 `.env`。

這支腳本在 PVE 上建立了三樣東西：使用者 `automation@pve`、角色 `AutomationIso`、權杖 `automation@pve!iac`。權杖的權限範圍請看[運作原理的「API 權杖的權限」](how-it-works.md#api-權杖的權限)。

出現 `user automation@pve already exists` 代表這支腳本已經執行過。密鑰沒有留下來的話，照[全部移除](#全部移除)的最後一個指令刪除帳號與角色，再重新執行。

### 4.2 填寫連線資訊

從範例檔複製一份 `.env`，並設成只有自己能讀取：

```bash
cp env.example .env
chmod 600 .env
```

用編輯器打開 `.env`。每一行的格式是 `名稱=值`，等號兩邊不能有空格；`#` 開頭的行是說明，不會生效。依下表修改每一行等號後面的值：

| 變數 | 填什麼 |
|---|---|
| `PVE_ENDPOINT` | `https://`、PVE 節點的 IP、`:8006` 接在一起 |
| `PVE_NODE` | 節點名稱 |
| `PVE_TOKEN_ID` | 上一步輸出的 `full-tokenid`。保留前後的單引號，因為內容有 `!` |
| `PVE_TOKEN_SECRET` | 上一步輸出的 `value`，貼在兩個單引號中間 |
| `TEMPLATE_VMID` | 步驟 1.4 選定的範本 VMID |
| `PVE_SSH` | 步驟 1.3 用來登入 PVE 節點的帳號與位址 |
| `SSH_PUBLIC_KEY_FILE` | 步驟 1.2 記下的公鑰路徑。這一行開頭有 `#`，要先刪掉 `#` 再改 |

`TOOLS_IMAGE` 那一行維持 `#` 開頭，不用改。

填好之後，有效的幾行會長這樣：

```bash
PVE_ENDPOINT=https://192.168.11.201:8006
PVE_NODE=node5
PVE_TOKEN_ID='automation@pve!iac'
PVE_TOKEN_SECRET='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
TEMPLATE_VMID=605
PVE_SSH=root@192.168.11.201
SSH_PUBLIC_KEY_FILE=~/.ssh/id_ed25519.pub
```

存檔後，確認公鑰路徑正確，以及權杖能讀取節點狀態：

```bash
set -a; . ./.env; set +a
test -r "${SSH_PUBLIC_KEY_FILE/#\~/$HOME}" && echo "公鑰 OK"
curl -sk -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
  "${PVE_ENDPOINT}/api2/json/nodes/${PVE_NODE}/status"
```

正確的結果是這兩行：

```
公鑰 OK
200
```

結果不同時，對照下表修正 `.env` 後再執行一次：

| 結果 | 原因 | 要檢查的變數 |
|---|---|---|
| 沒有出現 `公鑰 OK` | 公鑰檔不存在 | `SSH_PUBLIC_KEY_FILE` |
| `401` | 權杖的 ID 或密鑰不對 | `PVE_TOKEN_ID`、`PVE_TOKEN_SECRET` |
| `403` 或其他數字 | 節點名稱不對，或步驟 4.1 的權限沒有建立成功 | `PVE_NODE` |
| `000` | 連不到 PVE | `PVE_ENDPOINT` |

Git 預設會忽略 `.env`，它不會出現在 `git status` 裡。

## 5. 建立範本

```bash
scripts/build-template.sh
```

第一次執行會下載容器映像檔（約 300 MB），所以工作機要能連到網際網路。接著 Packer 會自動完成所有步驟，中途不需要操作。正常的輸出依序會出現這幾行：

```
==> proxmox-iso.ubuntu: Creating VM
==> proxmox-iso.ubuntu: Starting VM
==> proxmox-iso.ubuntu: Typing the boot command
==> proxmox-iso.ubuntu: Waiting for SSH to become available...
==> proxmox-iso.ubuntu: Connected to SSH!
==> proxmox-iso.ubuntu: ==> provision checks passed
==> proxmox-iso.ubuntu: ==> sealed
==> proxmox-iso.ubuntu: Stopping VM
==> proxmox-iso.ubuntu: Converting VM to template
```

`Waiting for SSH` 這一行會停留一段時間，安裝程式正在 VM 裡安裝系統。在驗證用的環境裡，整個建置大約 8 分鐘。想看安裝畫面的話，[打開這台 VM 的 Console](#打開-vm-的-console)。

完成後，在 PVE 節點上確認範本存在：

```bash
qm config 605 | grep -E '^(name|template|scsi0|ide0)'
```

把 `605` 換成你的範本 VMID。輸出要有 `template: 1`，名稱與磁碟大小要和第 3 章的設定相同：

```
ide0: vmdata:vm-605-cloudinit,media=cdrom
name: ub2604-ci-temp
scsi0: vmdata:base-605-disk-0,cache=none,iothread=1,replicate=0,size=50G
template: 1
```

沒有出現 `Converting VM to template`，或指令以錯誤結束時，請看[除錯](#除錯)。

預設的磁碟配置是根目錄放在 LVM 上、用滿整顆磁碟。使用預設配置的話，直接進行下一步。想把 `/var` 這類目錄分到獨立的磁碟區，請看[進階：修改磁碟配置](#進階修改磁碟配置)。

## 6. 定義 VM

要建立哪些 VM，寫在兩個檔案裡：

| 檔案 | 內容 |
|---|---|
| `tofu/vms.auto.tfvars` | VM 清單：每台的名稱、VMID、IP、帳號與規格 |
| `tofu/secrets.auto.tfvars` | 每台 VM 帳號的密碼雜湊 |

### 6.1 VM 清單

用編輯器打開 `tofu/vms.auto.tfvars`。裡面有 `ub2604-ci-test1`、`ub2604-ci-test2` 兩個區塊，它們是驗證用的範例。把這兩個區塊刪掉，換成你要的 VM，每台一個區塊。

以建立 `web-01`、`db-01` 兩台為例，整個檔案改成這樣：

```hcl
vms = {
  web-01 = {
    vmid     = 615
    ip_cidr  = "192.168.11.67/24"
    username = "bigred"
  }

  db-01 = {
    vmid      = 616
    ip_cidr   = "192.168.11.68/24"
    username  = "bigred"
    cores     = 2
    memory_mb = 4096
    disk_gb   = 100
  }
}
```

區塊的名稱（`web-01`、`db-01`）就是 VM 在 PVE 上的名稱，也是它的主機名稱。只能使用英文字母、數字與 `-`。

每個區塊裡可以寫的欄位：

| 欄位 | 必填 | 填什麼 |
|---|---|---|
| `vmid` | 是 | 沒被使用的 VMID，數字不加引號 |
| `ip_cidr` | 是 | 這台 VM 的 IP 加上網路遮罩的長度，前後要有雙引號 |
| `username` | 是 | 登入用的帳號名稱，前後要有雙引號 |
| `cores` | 否 | CPU 核心數，不寫時是 4 |
| `memory_mb` | 否 | 記憶體，單位是 MB，不寫時是 8192 |
| `disk_gb` | 否 | 磁碟大小，單位是 GB，不寫時是 50。不能小於範本的磁碟 |

`vmid` 和 `ip_cidr` 都不能和現有的機器重複，也不能和清單裡其他台重複。閘道、DNS 與 SSH 公鑰是所有 VM 共用的，已經在第 3 章與步驟 4.2 設定好，這裡不用寫。

### 6.2 每台 VM 的密碼雜湊

設定檔裡不放密碼本身，只放密碼的雜湊（hash，由密碼算出來、無法反推回密碼的字串）。

**產生雜湊**

```bash
scripts/hash-password.sh
```

它會要你輸入兩次密碼，輸入時螢幕不會顯示任何字元：

```
Password:
Again:
$6$fPZ6p1gbnaRA0u3.$uUSoEOTJy6oenMCd0McqahD.mPJE.YCWAwZG35TFbIiH57HIFLKf.u1zDVAeRYl0XmLmM03sFbpaBMyOVj8nW1
```

最後一行就是雜湊：以 `$6$` 開頭、共 106 個字元。請從終端機完整複製這一行，不要漏掉頭尾的字元。

清單裡有幾台 VM 就執行幾次，每台各產生一個雜湊。想讓多台用同一組密碼的話，也可以把同一個雜湊填給多台。

**填進設定檔**

從範例檔複製一份，並設成只有自己能讀取：

```bash
cp tofu/secrets.auto.tfvars.example tofu/secrets.auto.tfvars
chmod 600 tofu/secrets.auto.tfvars
```

用編輯器打開 `tofu/secrets.auto.tfvars`。裡面是範例的兩台 VM，值是空的：

```hcl
vm_password_hashes = {
  ub2604-ci-test1 = ""
  ub2604-ci-test2 = ""
}
```

把等號左邊的名稱改成 VM 清單裡的名稱，把雜湊貼進雙引號中間。清單裡的每一台都要有一行：

```hcl
vm_password_hashes = {
  web-01 = "$6$fPZ6p1gbnaRA0u3.$uUSoEOTJy6oenMCd0McqahD.mPJE.YCWAwZG35TFbIiH57HIFLKf.u1zDVAeRYl0XmLmM03sFbpaBMyOVj8nW1"
  db-01  = "$6$MQ5nXc/x9UP2JzYt$q32cHWrtPbJUezR9KYikwLAWAJSWvNe9B2GPjwgTh/LFdhMXjMJmYx2xdsRc7cbeDVWtIqqzf5ijHPz1YCH67."
}
```

填入的不是 `$6$` 開頭的完整雜湊時，下一章的指令會直接報錯，不會把明文密碼送出去。

## 7. 建立 VM

建立 VM 分三個指令，依序執行。

### 7.1 初始化

```bash
scripts/tofu.sh init
```

只有第一次需要執行。看到這一行代表成功：

```
OpenTofu has been successfully initialized!
```

### 7.2 預覽

```bash
scripts/tofu.sh plan
```

這個指令只會列出打算做的事，不會動到 PVE。輸出裡每台要建立的 VM 是一段 `+` 開頭的內容，最後一行是總數：

```
Plan: 2 to add, 0 to change, 0 to destroy.
```

確認 `to add` 的數字等於清單裡的 VM 數量，`to destroy` 是 0。出現錯誤時，常見的原因：

| 錯誤訊息裡的文字 | 原因 | 處理方式 |
|---|---|---|
| `Every value must be a SHA-512 crypt hash` | `tofu/secrets.auto.tfvars` 裡有值不是完整的雜湊 | 回到步驟 6.2 重新複製雜湊 |
| `Invalid index`，並提到 `vm_password_hashes` | 清單裡有 VM 在 `tofu/secrets.auto.tfvars` 找不到同名的一行 | 檢查兩個檔案裡的名稱是否完全相同 |
| `public key file not found` | 公鑰檔不存在 | 回到步驟 4.2 檢查 `SSH_PUBLIC_KEY_FILE` |

### 7.3 執行

```bash
scripts/tofu.sh apply
```

它會再列一次同樣的計畫，然後停在這裡等你確認：

```
Do you want to perform these actions?
  OpenTofu will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value:
```

輸入 `yes` 後按 Enter。在驗證用的環境裡，每台 VM 大約 1 分鐘。完成時會列出每台 VM 的設定：

```
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:

vms = {
  "db-01" = {
    "address" = "192.168.11.68"
    "username" = "bigred"
    "vmid" = 616
  }
  "web-01" = {
    "address" = "192.168.11.67"
    "username" = "bigred"
    "vmid" = 615
  }
}
```

### 7.4 確認能登入

上面顯示的是你設定的 IP，實際連得上才算成功。用清單裡的 `username` 和 IP 登入：

```bash
ssh bigred@192.168.11.67
```

第一次連線會問是否信任這台主機，輸入 `yes`。不用輸入密碼就進入 VM，代表網路、帳號與 SSH 公鑰都設定成功。

再[打開這台 VM 的 Console](#打開-vm-的-console)，用同一個帳號和步驟 6.2 輸入的原始密碼登入，確認密碼也生效。

## 8. 驗證

登入 VM 後，先用這四個指令確認主要的設定都生效了：

```bash
hostname                 # 應該是 VM 名稱
ip -br addr              # 應該有你設定的 IP
cloud-init status        # 應該是 status: done
findmnt -n -o SOURCE /   # 應該是 /dev/mapper/ubuntu--vg-ubuntu--lv
```

repo 另外附了一支驗證腳本，檢查項目更完整：

```bash
scripts/verify.sh
```

**執行前要先知道：** 腳本有一部分是比對硬體設定，需要一台**手動建立**的 VM 或範本當對照組，預設是 VMID 604。對照組的 CPU 類型、SCSI 控制器、開機順序和 guest agent 設定要與這個專案相同（`cpu: host`、`virtio-scsi-single`、`boot: order=scsi0;net0`、`agent: 1`），否則硬體比對的項目會顯示 FAIL，但這不代表建置有問題。用其他 VMID 當對照組時：

```bash
REFERENCE_VMID=100 scripts/verify.sh
```

沒有合適的對照組時，看前面幾組檢查即可。

腳本檢查的對象是上一次 `scripts/tofu.sh apply` 建立的 VM，項目包括：

- 主機名稱、IP、帳號和設定一致，建置用的臨時帳號 `packer` 不存在。
- 根目錄在 `ubuntu-vg/ubuntu-lv` 上，而且已經擴充到磁碟大小。
- 核心是 `linux-generic`，開機參數沒有 `console=`，`tty1` 的登入服務正在執行。
- 硬體設定和對照組相比，只多了 cloud-init 光碟機與 cloud-init 欄位。

最後一行是結果。每台 VM 有 35 項檢查：

```
Result: 35 passed, 0 failed
```

Console 上看不看得到登入提示、密碼能不能登入，腳本無法代勞，請照步驟 7 的方式自己確認。

## 日常操作

VM 的新增、調整與刪除都是同一個流程：修改 `tofu/vms.auto.tfvars`，執行 `scripts/tofu.sh plan` 看它打算做什麼，確認無誤後執行 `scripts/tofu.sh apply`。

| 想做的事 | 做法 | `plan` 最後一行應該是 |
|---|---|---|
| 新增 VM | 見下方說明 | `1 to add, 0 to change, 0 to destroy` |
| 調整 CPU 或記憶體 | 修改那台 VM 的 `cores` 或 `memory_mb` | `0 to add, 1 to change, 0 to destroy` |
| 加大磁碟 | 見下方說明 | `0 to add, 1 to change, 0 to destroy` |
| 刪除一台 VM | 從清單刪掉它的整個區塊，並刪掉 `tofu/secrets.auto.tfvars` 裡它的那一行 | `0 to add, 0 to change, 1 to destroy` |
| 刪除 OpenTofu 管理的全部 VM | 執行 `scripts/tofu.sh destroy`，核對它列出的 VM 後再輸入 `yes` | |
| 重建範本 | 見下方說明 | |

`plan` 顯示的數字和你預期的不同時，先不要執行 `apply`。尤其是出現你沒打算刪除的 `to destroy`，或某台 VM 標示為 `must be replaced`（先刪除再重建，資料會消失）。

在驗證用的環境裡，調整 CPU 或記憶體時 OpenTofu 會把 VM 重開機讓設定生效。

**新增 VM**

1. 在 `tofu/vms.auto.tfvars` 的 `vms = { ... }` 裡加一個區塊，寫法和步驟 6.1 相同。
2. 執行 `scripts/hash-password.sh` 產生雜湊，在 `tofu/secrets.auto.tfvars` 加一行同名的項目。
3. 執行 `scripts/tofu.sh plan`，確認後執行 `scripts/tofu.sh apply`。

**加大磁碟**

以 `web-01` 從 50G 加大到 100G 為例。在它的區塊裡加上或修改 `disk_gb`：

```hcl
  web-01 = {
    vmid     = 615
    ip_cidr  = "192.168.11.67/24"
    username = "bigred"
    disk_gb  = 100
  }
```

執行 `scripts/tofu.sh apply`。在驗證用的環境裡，磁碟會立刻變大，VM 不會重開機，但這時 VM 裡的根目錄還是原本的大小。登入 VM 執行：

```bash
sudo systemctl start grow-root-lvm
df -h /
```

`df` 顯示的 `Size` 接近新的磁碟大小就完成了。不想登入的話，把 VM 重開機也有同樣的效果。磁碟只能加大，不能縮小。

**重建範本**

建置腳本不會覆蓋現有的範本，要先刪除舊的。登入 PVE 節點，先確認那個 VMID 確實是這個專案的範本。把 `605` 換成你的範本 VMID：

```bash
qm config 605 | grep -E '^(name|template)'
```

```
name: ub2604-ci-temp
template: 1
```

名稱和你在第 3 章設定的 `template_name` 相同，而且有 `template: 1`，才刪除：

```bash
qm destroy 605
```

接著回到工作機的 repo 目錄執行 `scripts/build-template.sh`。已經建立的 VM 是完整複製，有自己的磁碟，不受影響。

## 打開 VM 的 Console

1. 用瀏覽器開啟 `.env` 裡的 `PVE_ENDPOINT`，例如 `https://192.168.11.201:8006`，用 PVE 的帳號登入。
2. 在左側展開節點，點選要看的 VM（顯示為「VMID（名稱）」）。
3. 點選右側的「Console」。

這裡看到的是 VM 的螢幕畫面。登入 VM 用的是 VM 自己的帳號與密碼，和登入 PVE 網頁的帳號無關。

## 進階：修改磁碟配置

磁碟配置寫在 `packer/files/user-data.pkrtpl.yaml` 的 `storage` 區塊。這裡用到 LVM 的三個名詞：

- **PV**（physical volume）：交給 LVM 管理的分割區。
- **VG**（volume group）：由 PV 組成的儲存空間集合。
- **LV**（logical volume）：從 VG 劃出來的邏輯磁碟區，上面可以建立檔案系統。

預設的配置：

| 分割區 | 大小 | 用途 |
|---|---|---|
| 1 | 1M | BIOS 開機分割區 |
| 2 | 2G | `/boot`（ext4） |
| 3 | 其餘空間 | PV，屬於 VG `ubuntu-vg`；LV `ubuntu-lv` 用滿整個 VG 並掛在 `/`（ext4） |

**把某個目錄分成獨立的 LV**

以 `/var` 分出 15G 為例。新的 LV 給固定大小，根目錄的 `ubuntu-lv` 維持 `size: -1`，也就是用掉剩下的全部空間。

用編輯器打開 `packer/files/user-data.pkrtpl.yaml`，找到 `storage:` 底下的 `config:` 清單。清單的後半段原本是這樣：

```yaml
      - id: vg0
        type: lvm_volgroup
        name: ubuntu-vg
        devices:
          - part-pv
      - id: lv-root
        type: lvm_partition
        volgroup: vg0
        name: ubuntu-lv
        size: -1
      - id: fs-root
        type: format
        volume: lv-root
        fstype: ext4
      - id: mount-root
        type: mount
        device: fs-root
        path: /
      - id: mount-boot
        type: mount
        device: fs-boot
        path: /boot
```

要加入三段，改完後是這樣。標示「新增」的註解只是用來指出位置，不用照抄：

```yaml
      - id: vg0
        type: lvm_volgroup
        name: ubuntu-vg
        devices:
          - part-pv
      - id: lv-var              # 新增：建立 15G 的 LV
        type: lvm_partition
        volgroup: vg0
        name: var-lv
        size: 15G
      - id: lv-root
        type: lvm_partition
        volgroup: vg0
        name: ubuntu-lv
        size: -1
      - id: fs-root
        type: format
        volume: lv-root
        fstype: ext4
      - id: mount-root
        type: mount
        device: fs-root
        path: /
      - id: mount-boot
        type: mount
        device: fs-boot
        path: /boot
      - id: fs-var              # 新增：在這個 LV 上建立 ext4
        type: format
        volume: lv-var
        fstype: ext4
      - id: mount-var           # 新增：掛載到 /var
        type: mount
        device: fs-var
        path: /var
```

三個要注意的地方：

- **`lv-var` 要放在 `lv-root` 之前**。`size: -1` 的 LV 會用掉剩下的全部空間，所以必須最後建立。
- **縮排要和其他段完全對齊**，而且只能用空白，不能用 Tab。
- **三段靠 `id` 互相指向**：`fs-var` 的 `volume` 填 `lv-var`，`mount-var` 的 `device` 填 `fs-var`。要分出其他目錄時，把三個 `id`、`name` 與 `path` 換成新的名稱，大小改成你要的值。

改完後要[重建範本](#日常操作)才會生效。建好之後，從新範本建立一台 VM，登入後確認：

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
```

```
NAME                       SIZE TYPE MOUNTPOINTS
sda                         50G disk
├─sda1                       1M part
├─sda2                       2G part /boot
└─sda3                      48G part
  ├─ubuntu--vg-var--lv      15G lvm  /var
  └─ubuntu--vg-ubuntu--lv   33G lvm  /
```

**修改配置時的限制**

建置過程與驗證腳本都以預設配置為基準，修改時要留意：

- **VG 不能留下未配置的空間**。建置時會檢查這一點，有剩餘空間就會失敗。所以根目錄的 LV 要維持 `size: -1`。
- **VG 與根目錄 LV 的名稱要維持 `ubuntu-vg` 與 `ubuntu-lv`**，`/boot` 要維持獨立的分割區。建置時的檢查寫死了這些名稱。
- **加大磁碟後，新增的空間全部加給根目錄的 LV**，其他 LV 不會跟著變大。
- **`scripts/verify.sh` 會回報根目錄大小不符**。它預期根目錄接近整顆磁碟的大小，分出其他 LV 之後這一項會顯示 FAIL，可以忽略。

## 除錯

**建置範本時卡住**

擷取 VM 目前的畫面：

```bash
scripts/vm-screenshot.sh 605 screen.png
```

或直接[打開 VM 的 Console](#打開-vm-的-console)。常見的情況：

| 畫面 | 原因 | 處理方式 |
|---|---|---|
| 停在安裝光碟的開機選單，或已經進入一般的安裝畫面 | Packer 輸入開機指令的時機不對 | 把 `packer/variables.pkr.hcl` 裡 `boot_wait` 的 `"8s"` 改成 `"15s"` 再重新建置。這個值是 VM 開機後等幾秒才開始輸入；開機選單會停留 30 秒，所以要在選單出現之後、30 秒之內 |
| 出現 `Continue with autoinstall? (yes\|no)` | 核心開機參數缺少 `autoinstall` | 同上 |
| 安裝程式顯示錯誤 | autoinstall 設定有誤，常見於修改 `storage` 區塊之後 | 檢查 `packer/files/user-data.pkrtpl.yaml` 的縮排，以及各段的 `id` 是否互相對應 |
| 安裝完成並出現登入提示，Packer 仍在等 SSH | 工作機連不到建置用的 IP | 在工作機上 `ping` 建置用的 IP。不通的話，檢查 `packer/variables.pkr.hcl` 的 `build_ip_cidr`、`build_gateway` 與 `bridge` |

上面的情況處理完後，先按 Ctrl+C 中止還在等待的 `scripts/build-template.sh`，再重新執行。

需要 Packer 的詳細紀錄時：

```bash
PACKER_LOG=1 scripts/build-template.sh
```

建置失敗或被中止時，Packer 會嘗試刪除建到一半的 VM。重新執行前，先在 PVE 節點上執行 `qm config 605`，出現 `does not exist` 代表它已經不存在。

**`VMID 605 already exists`**

這個 VMID 已經被使用。請看「日常操作」的「重建範本」，或在 `.env` 把 `TEMPLATE_VMID` 改成沒有被使用的數字。

**`public key file not found`**

`.env` 的 `SSH_PUBLIC_KEY_FILE` 指向的檔案不存在，請回到步驟 4.2 檢查。

**`scripts/tofu.sh apply` 停很久**

VM 開機失敗，或 cloud-init 沒有套用網路設定時，OpenTofu 會一直等到逾時。[打開該 VM 的 Console](#打開-vm-的-console) 查看：

- 畫面停在開機過程或錯誤訊息：範本本身有問題，重建範本。
- 已經出現登入提示：登入後執行 `ip -br addr`，看 IP 是否和清單裡的 `ip_cidr` 相同。不同的話，檢查 `ip_cidr`、`tofu/variables.tf` 的 `gateway` 與 `bridge`。

## 不會進 git 的檔案

以下檔案含有機密或本機狀態，Git 預設會忽略它們：

| 檔案 | 內容 |
|---|---|
| `.env` | PVE 位址與 API 權杖 |
| `tofu/secrets.auto.tfvars` | 每台 VM 的密碼雜湊 |
| `tofu/terraform.tfstate` | OpenTofu 的狀態檔，記錄它管理的每台 VM，裡面也有密碼雜湊 |
| `.cache/` | Packer 的暫存檔 |

狀態檔只存在工作機上，沒有遠端備份。遺失後，OpenTofu 就不知道哪些 VM 歸它管理，請自行備份。

## 全部移除

依序執行，可以移除這個專案在 PVE 上建立的東西。

刪除 OpenTofu 管理的 VM。它會先列出要刪除的對象，核對後再輸入 yes：

```bash
scripts/tofu.sh destroy
```

刪除範本。先照「重建範本」的方式確認 VMID 是這個專案的範本，再執行：

```bash
ssh root@192.168.11.201 'qm destroy 605'
```

刪除 API 帳號與角色。使用者的權杖與權限設定會一併移除：

```bash
ssh root@192.168.11.201 'pveum user delete automation@pve; pveum role delete AutomationIso'
```

狀態檔遺失時，`scripts/tofu.sh destroy` 找不到要刪除的 VM，這時要到 PVE 上逐台確認後手動刪除。
