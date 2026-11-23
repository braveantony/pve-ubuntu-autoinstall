# 建置手冊

這份手冊從一台剛裝好的 Linux 工作機開始，帶你建立 Ubuntu Server 26.04 的範本，再從範本建立 VM。照著做完大約需要 30 分鐘，其中約 10 分鐘是等待安裝。

想先了解每個步驟背後做了什麼，請看[運作原理](how-it-works.md)。

**建置步驟**

1. [準備工作機](#1-準備工作機)
2. [檢查 PVE 並記下環境](#2-檢查-pve-並記下環境)
3. [建立你的 overlay](#3-建立你的-overlay)
4. [設定 PVE 連線](#4-設定-pve-連線)
5. [建立範本](#5-建立範本)
6. [定義 VM](#6-定義-vm)
7. [建立 VM](#7-建立-vm)
8. [確認 VM 可用](#8-確認-vm-可用)

**遇到問題時**

- [打開 VM 的 Console](#打開-vm-的-console)
- [除錯](#除錯)

**建好之後**

- [日常操作](operations.md)：新增、調整、刪除 VM，重建範本，全部移除。
- [修改磁碟配置](disk-layout.md)：把 `/var` 這類目錄分到獨立的磁碟區。

## 開始之前

你需要兩台機器：

- PVE 節點：一台運作中的 Proxmox VE 主機，VM 就執行在它上面。這份手冊在 PVE 9.2 上驗證過。
- 工作機：一台 Linux，用來執行這個 repo 的腳本。它要和 PVE 節點、VM 所在的網段互通。

手冊裡所有的指令都在工作機上執行。需要在 PVE 節點上執行的指令，都寫成 `ssh root@192.168.11.201 <指令>` 的形式，從工作機送過去。

指令和輸出範例用的是 repo 裡範例環境的值，例如 PVE 節點的 IP 是 `192.168.11.201`。[步驟 2.2](#22-查出環境值) 會帶你查出自己的值。

## 1. 準備工作機

### 1.1 檢查工具

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

Packer（建置範本的工具）與 OpenTofu（依設定檔建立並管理 VM 的工具）不用安裝。腳本第一次執行時，會用 podman 下載已經包好這兩個工具的容器映像檔。這個映像檔只提供 x86-64 版本。

### 1.2 準備 SSH 金鑰

這把金鑰有兩個用途：登入 PVE 節點，以及之後登入每台 VM。先看工作機有沒有金鑰：

```bash
ls ~/.ssh/id_*.pub
```

有列出檔案就代表已經有金鑰。出現 `No such file or directory` 的話，建立一把，三個問題都直接按 Enter：

```bash
ssh-keygen -t ed25519
```

記下公鑰的路徑，也就是結尾是 `.pub` 的那個檔案，例如 `~/.ssh/id_ed25519.pub`。步驟 4.2 要填。

### 1.3 取得 repo

```bash
git clone https://github.com/braveantony/pve-ubuntu-autoinstall.git
cd pve-ubuntu-autoinstall
```

之後的指令都在這個目錄下執行。

## 2. 檢查 PVE 並記下環境

### 2.1 設定免密碼登入 PVE

把公鑰裝到 PVE 節點，會問一次 root 的密碼：

```bash
ssh-copy-id root@192.168.11.201
```

確認不用密碼就能執行指令：

```bash
ssh root@192.168.11.201 pveversion
```

印出 `pve-manager/` 開頭的一行就是成功。

<details>
<summary>用非 root 帳號登入 PVE</summary>

可以改用其他帳號，條件是它在 PVE 節點上能免密碼執行 `sudo`。這時手冊裡的指令要調整兩處：

- `root@192.168.11.201` 換成那個帳號，例如 `bigred@192.168.11.201`。
- PVE 的管理指令（`qm`、`pvesm`、`pvesh`、`pveum`）前面加上 `sudo`，例如 `ssh bigred@192.168.11.201 sudo pvesm status`。

步驟 4.1 的指令寫法不同，那裡會另外說明。

</details>

### 2.2 查出環境值

這一步要查出六個值，後面的章節會用到。

#### 節點名稱

```bash
ssh root@192.168.11.201 hostname
```

輸出就是節點名稱，範例是 `node5`。

#### storage

storage 是 PVE 存放資料的位置，每個 storage 會設定可以放哪些類型的內容。要選出兩個：一個放 VM 磁碟，一個放 ISO。

列出可以放 VM 磁碟的 storage：

```bash
ssh root@192.168.11.201 pvesm status --content images
```

```
Name             Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %
local             dir     active       205839152        84356420       112189396   40.98%
vmdata        lvmthin     active      1919827968       910190439      1009637528   47.41%
```

從 `Status` 是 `active` 的當中選一個，記下 `Name` 欄的名稱。範例選 `vmdata`。

列出可以放 ISO 的 storage，同樣選一個：

```bash
ssh root@192.168.11.201 pvesm status --content iso
```

範例選 `local`。

#### 橋接器

橋接器是 PVE 節點上的虛擬交換器，VM 的網卡接到哪個橋接器，就連到哪個網路。

```bash
ssh root@192.168.11.201 ip -br link show type bridge | grep -v '^fwbr'
```

```
vmbr0            UP             00:e0:4c:68:1a:f4 <BROADCAST,MULTICAST,UP,LOWER_UP>
vmbr1            UP             74:56:3c:ff:03:e8 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

第一欄是橋接器的名稱，選 VM 要連的那個網路所在的橋接器。範例選 `vmbr1`。

不確定是哪一個的話，到 PVE 網頁點選一台已經在那個網路上的 VM，看「Hardware」頁面裡網卡的 `bridge=`。

#### 範本的 VMID

VMID 是 PVE 用來識別 VM 或容器的數字，同一個叢集內不能重複。列出已被使用的：

```bash
ssh root@192.168.11.201 pvesh get /cluster/resources --type vm --noborder | awk 'NR>1{print $1}'
```

```
qemu/601
qemu/602
qemu/604
lxc/700
```

斜線後面的數字是已被使用的 VMID。選一個沒出現在清單裡的數字當範本的 VMID，範例選 605。之後每台 VM 也各需要一個。

#### IP、閘道與 DNS

這三項要依你的網路規劃決定：

- 建置範本時暫用的 IP：建置期間 VM 會使用一個固定 IP，工作機靠它連進 VM。它必須和工作機互通，而且沒有其他裝置在用。
- 每台 VM 的 IP：同樣不能和現有的機器重複。
- 閘道與 DNS：和同一個網段上其他機器使用的相同。

確認 IP 可用時，請以你的 IP 分配紀錄或 DNS 紀錄為準。`ping` 只能知道當下有沒有裝置回應，關機中的機器、或不回應 ping 的裝置都查不出來。

#### 記下查到的值

| 項目 | 範例值 | 你的值 |
|---|---|---|
| 節點名稱 | `node5` | |
| 放 VM 磁碟的 storage | `vmdata` | |
| 放 ISO 的 storage | `local` | |
| 橋接器 | `vmbr1` | |
| 範本的 VMID | `605` | |
| 建置時暫用的 IP | `192.168.11.66/24` | |
| 閘道 | `192.168.11.254` | |
| DNS | `192.168.11.2` | |

IP 後面的 `/24` 是網路遮罩的長度，等同 `255.255.255.0`。

### 2.3 準備安裝光碟

確認安裝光碟已經在放 ISO 的 storage 裡。把 `local` 換成你的 storage 名稱：

```bash
ssh root@192.168.11.201 pvesm list local --content iso | grep ubuntu-26.04
```

```
local:iso/ubuntu-26.04-live-server-amd64.iso   iso   iso   2918598656
```

第一欄是這張光碟在 PVE 裡的完整名稱，步驟 3.3 會用到。

沒有輸出代表光碟不在裡面。到 PVE 網頁選擇放 ISO 的 storage，在「ISO Images」頁面按「Download from URL」，貼上這個網址：

```
https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso
```

下載完成後，在同一頁核對檢查碼。官方的檢查碼列在 <https://releases.ubuntu.com/26.04/SHA256SUMS>，這張光碟的是：

```
dec49008a71f6098d0bcfc822021f4d042d5f2db279e4d75bdd981304f1ca5d9
```

這個專案只用 26.04 這張光碟驗證過，之後的小改版（例如 26.04.1）沒有測過。

## 3. 建立你的 overlay

repo 分成兩個部分：

- `base/`：範本與 VM 的定義，所有環境共用，不用修改。
- `overlays/`：每個子目錄是一個環境（一座 PVE）的設定值，稱為 overlay。`overlays/example` 是範例。

你的環境值全部填在自己的 overlay 裡。這份手冊把它命名為 `lab`，你可以換成其他名稱，之後指令裡的 `lab` 也要跟著換。

### 3.1 複製範例

```bash
cp -r overlays/example overlays/lab
```

`overlays/lab` 裡有五個檔案，接下來會依序填寫：

| 檔案 | 內容 | 在哪裡填 |
|---|---|---|
| `site.hcl` | storage、橋接器、閘道、DNS | 步驟 3.2 |
| `template.pkrvars.hcl` | 安裝光碟、建置用的 IP、範本規格 | 步驟 3.3 |
| `env.example` | PVE 連線資訊與 API 權杖 | 步驟 4.2 |
| `vms.tfvars` | VM 清單 | 步驟 6.1 |
| `secrets.tfvars.example` | 每台 VM 的密碼雜湊 | 步驟 6.2 |

這些檔案裡，值的寫法有三種，照原本的樣子改就不會錯：

- 文字：前後要有雙引號，例如 `"local-lvm"`。
- 數字：不加引號，例如 `4`。
- 清單：用中括號包住，例如 `["192.168.11.2"]`；有兩筆時寫成 `["192.168.11.2", "8.8.8.8"]`。

### 3.2 填寫 `site.hcl`

打開 `overlays/lab/site.hcl`，把等號後面的值換成步驟 2.2 記下的值：

```hcl
vm_storage  = "vmdata"         # 放 VM 磁碟的 storage
iso_storage = "local"          # 放 ISO 的 storage
bridge      = "vmbr1"          # 橋接器
gateway     = "192.168.11.254" # 閘道
dns_servers = ["192.168.11.2"] # DNS，這一項是清單
```

### 3.3 填寫 `template.pkrvars.hcl`

打開 `overlays/lab/template.pkrvars.hcl`，有兩項一定要確認：

| 變數 | 填什麼 |
|---|---|
| `iso_file` | 步驟 2.3 查到的光碟完整名稱 |
| `build_ip_cidr` | 建置時暫用的 IP，後面要有 `/24` 這類遮罩長度 |

`apt_mirror` 是安裝時下載 Ubuntu 套件的來源，範例是台灣的鏡像站，不在台灣時換成離你較近的站。

其餘是範本的名稱與規格，行首有 `#` 代表使用預設值。想調整時，刪掉那一行開頭的 `#` 再改值：

| 變數 | 預設值 | 說明 |
|---|---|---|
| `template_name` | `"ub2604-ci-temp"` | 範本在 PVE 上顯示的名稱 |
| `cores` | `4` | CPU 核心數 |
| `memory` | `8192` | 記憶體，單位是 MB |
| `disk_size` | `"50G"` | 磁碟大小。之後建立的 VM 磁碟不能比它小 |

## 4. 設定 PVE 連線

Packer 與 OpenTofu 透過 PVE 的 API 操作，需要一組 API 權杖（token，用來代替帳號密碼的憑證）。

### 4.1 建立 API 權杖

`scripts/pve-access.sh` 會在 PVE 上建立一個專用帳號，並只開放這個專案需要的權限。執行以下指令，把 `NODE`、`VM_STORAGE`、`ISO_STORAGE`、`BRIDGE` 換成步驟 2.2 記下的節點名稱、兩個 storage 與橋接器：

```bash
ssh root@192.168.11.201 'NODE=node5 VM_STORAGE=vmdata ISO_STORAGE=local BRIDGE=vmbr1 bash -s' < scripts/pve-access.sh
```

用非 root 帳號時，引號裡的開頭改成 `sudo env NODE=node5 ...`，其餘相同。

輸出的最後一行是一段 JSON：

```json
{"full-tokenid":"automation@pve!iac","info":{"privsep":"0"},"value":"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
```

`value` 後面那串是權杖的密鑰，**只會顯示這一次**。先不要關掉這個終端機視窗，下一步要把它貼進 `env`。

權杖的權限範圍請看[運作原理的「API 權杖的權限」](how-it-works.md#api-權杖的權限)。

<details>
<summary>出現 <code>user automation@pve already exists</code></summary>

這支腳本已經執行過。密鑰沒有留下來的話，先刪除權杖、帳號與角色，再重新執行：

```bash
ssh root@192.168.11.201 'pveum user token remove automation@pve iac; pveum user delete automation@pve; pveum role delete AutomationIso'
```

</details>

### 4.2 填寫 `env`

1. 把範例檔改名成 `env`，並設成只有自己能讀取：

   ```bash
   mv overlays/lab/env.example overlays/lab/env
   chmod 600 overlays/lab/env
   ```

2. 用編輯器打開 `overlays/lab/env`，修改每一行等號後面的值。等號兩邊不能有空格；`#` 開頭的行是說明，不會生效。

   | 變數 | 填什麼 |
   |---|---|
   | `PVE_ENDPOINT` | `https://`、PVE 節點的 IP、`:8006` 接在一起 |
   | `PVE_NODE` | 節點名稱 |
   | `PVE_TOKEN_ID` | 上一步輸出的 `full-tokenid`，保留前後的單引號 |
   | `PVE_TOKEN_SECRET` | 上一步輸出的 `value`，貼在兩個單引號中間 |
   | `TEMPLATE_VMID` | 範本的 VMID |
   | `PVE_SSH` | 登入 PVE 節點的帳號與位址 |
   | `SSH_PUBLIC_KEY_FILE` | 步驟 1.2 記下的公鑰路徑。先刪掉這一行開頭的 `#` 再改 |

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

3. 存檔後檢查公鑰路徑與權杖：

   ```bash
   set -a; . overlays/lab/env; set +a
   test -r "${SSH_PUBLIC_KEY_FILE/#\~/$HOME}" && echo "公鑰 OK"
   curl -sk -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
     "${PVE_ENDPOINT}/api2/json/nodes/${PVE_NODE}/status"
   ```

   正確的結果是 `公鑰 OK` 與 `200` 兩行。結果不同時，對照下表修正 `env` 再執行一次：

   | 結果 | 要檢查的變數 |
   |---|---|
   | 沒有出現 `公鑰 OK` | `SSH_PUBLIC_KEY_FILE` |
   | `401` | `PVE_TOKEN_ID`、`PVE_TOKEN_SECRET` |
   | `403` 或其他數字 | `PVE_NODE`；或步驟 4.1 的權限沒有建立成功 |
   | `000` | `PVE_ENDPOINT` |

4. 檢查第 3 章填的兩個檔案格式正確：

   ```bash
   scripts/build-template.sh lab validate
   ```

   出現 `The configuration is valid.` 就可以進行下一步。

`env` 含有權杖，Git 預設會忽略它。

## 5. 建立範本

預設的磁碟配置是根目錄放在 LVM 上、用滿整顆磁碟。想把 `/var` 這類目錄分到獨立的磁碟區，要在建立範本之前改，請先看[修改磁碟配置](disk-layout.md)。

```bash
scripts/build-template.sh lab
```

第一次執行會下載容器映像檔（約 300 MB），工作機要能連到網際網路。接著 Packer 會自動完成所有步驟，中途不需要操作。正常的輸出依序會出現這幾行：

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

`Waiting for SSH` 這一行會停留好幾分鐘，安裝程式正在 VM 裡安裝系統。在驗證用的環境裡，整個建置大約 8 分鐘。

沒有出現 `Converting VM to template`，或指令以錯誤結束時，請看[除錯](#除錯)。

完成後確認範本存在。把 `605` 換成你的範本 VMID：

```bash
ssh root@192.168.11.201 qm config 605 | grep -E '^(name|template|scsi0)'
```

```
name: ub2604-ci-temp
scsi0: vmdata:base-605-disk-0,cache=none,iothread=1,replicate=0,size=50G
template: 1
```

有 `template: 1` 就是成功。

## 6. 定義 VM

要建立哪些 VM，寫在 overlay 的兩個檔案裡：

| 檔案 | 內容 |
|---|---|
| `vms.tfvars` | VM 清單：每台的名稱、VMID、IP、帳號與規格 |
| `secrets.tfvars` | 每台 VM 帳號的密碼雜湊 |

### 6.1 填寫 VM 清單

打開 `overlays/lab/vms.tfvars`。裡面的 `ub2604-ci-test1`、`ub2604-ci-test2` 是驗證用的範例，把這兩個區塊刪掉，換成你要的 VM，每台一個區塊。

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

區塊的名稱（`web-01`、`db-01`）是 VM 在 PVE 上的名稱，也是它的主機名稱，只能使用英文字母、數字與 `-`。

| 欄位 | 必填 | 填什麼 |
|---|---|---|
| `vmid` | 是 | 沒被使用的 VMID |
| `ip_cidr` | 是 | 這台 VM 的 IP，後面要有 `/24` 這類遮罩長度 |
| `username` | 是 | 登入用的帳號名稱 |
| `cores` | 否 | CPU 核心數，不寫時是 4 |
| `memory_mb` | 否 | 記憶體，單位是 MB，不寫時是 8192 |
| `disk_gb` | 否 | 磁碟大小，單位是 GB，不寫時是 50。不能小於範本的磁碟，所以範本的 `disk_size` 大於 50G 時每台都要寫 |

`vmid` 和 `ip_cidr` 不能和現有的機器重複，也不能和清單裡其他台重複。

### 6.2 填寫密碼雜湊

設定檔裡不放密碼本身，只放密碼的雜湊（hash，由密碼算出來、無法反推回密碼的字串）。

1. 產生雜湊。腳本會要你輸入兩次密碼，輸入時螢幕不會顯示任何字元：

   ```bash
   scripts/hash-password.sh
   ```

   它印出的那一行就是雜湊，以 `$6$` 開頭、共 106 個字元。清單裡每台 VM 各產生一個；想讓多台用同一組密碼，也可以共用同一個雜湊。

2. 把範例檔改名成 `secrets.tfvars`，並設成只有自己能讀取：

   ```bash
   mv overlays/lab/secrets.tfvars.example overlays/lab/secrets.tfvars
   chmod 600 overlays/lab/secrets.tfvars
   ```

3. 打開 `overlays/lab/secrets.tfvars`，把範例的兩個名稱換成你的 VM 名稱，把雜湊完整貼進雙引號中間。清單裡的每一台都要有一行：

   ```hcl
   vm_password_hashes = {
     web-01 = "$6$p9v7Qzl0/rx70C81$M0E2.SyXFzGJKl6WGJINnRGm7BMOoUDuK4W.TvsX6WNWDpjphR3bfD2tzw3bRive/Ye1W5lisRgyhlgQKw0tc/"
     db-01  = "$6$ebpg6lQrHg6rAPvt$8yZeDMnId03Dz9zKD6Vi1sm6JiLQJ1YS3tbKb4Xj87m09qhBC5C6MpjoLe1MYi3MS2okqoTV.5ngH983/blwt/"
   }
   ```

## 7. 建立 VM

### 7.1 初始化

```bash
scripts/tofu.sh lab init
```

只有第一次需要執行。看到 `OpenTofu has been successfully initialized!` 代表成功。

### 7.2 預覽

```bash
scripts/tofu.sh lab plan
```

這個指令只會列出打算做的事，不會動到 PVE。看最後一行：

```
Plan: 2 to add, 0 to change, 0 to destroy.
```

`to add` 的數字要等於清單裡的 VM 數量，`to destroy` 要是 0。出現錯誤時，對照下表：

| 錯誤訊息裡的文字 | 處理方式 |
|---|---|
| `Every value must be a SHA-512 crypt hash` | 有值不是完整的雜湊，回到步驟 6.2 重新複製 |
| `Invalid index`，並提到 `vm_password_hashes` | 有 VM 找不到同名的雜湊，檢查第 6 章兩個檔案裡的名稱是否完全相同 |
| `public key file not found` | 公鑰檔不存在，回到步驟 4.2 檢查 `SSH_PUBLIC_KEY_FILE` |

### 7.3 執行

```bash
scripts/tofu.sh lab apply
```

它會再列一次計畫並詢問是否執行，輸入 `yes` 後按 Enter。在驗證用的環境裡，每台 VM 大約 1 分鐘。完成時會出現這一行，後面接著每台 VM 的 IP、帳號與 VMID：

```
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

## 8. 確認 VM 可用

1. 用清單裡的 `username` 和 IP 登入。第一次連線會問是否信任這台主機，輸入 `yes`：

   ```bash
   ssh bigred@192.168.11.67
   ```

   不用輸入密碼就進入 VM，代表網路、帳號與 SSH 公鑰都設定成功。

2. 在 VM 裡確認主要的設定：

   ```bash
   hostname                 # 應該是 VM 名稱
   ip -br addr              # 應該有你設定的 IP
   cloud-init status        # 應該是 status: done
   findmnt -n -o SOURCE /   # 應該是 /dev/mapper/ubuntu--vg-ubuntu--lv
   ```

3. [打開這台 VM 的 Console](#打開-vm-的-console)，用同一個帳號和步驟 6.2 輸入的原始密碼登入，確認密碼也生效。

到這裡就完成了。之後要新增、調整或刪除 VM，請看[日常操作](operations.md)。

<details>
<summary>用驗證腳本做更完整的檢查</summary>

```bash
scripts/verify.sh lab
```

腳本檢查的對象是這個 overlay 的 VM，每台 35 項，最後一行是結果：

```
Result: 35 passed, 0 failed
```

其中一部分是比對硬體設定，執行前要先知道：

- 需要一台手動建立的 VM 或範本當對照組，預設是 VMID 604。用其他 VMID 時執行 `REFERENCE_VMID=100 scripts/verify.sh lab`。
- 對照組的設定要是 `cpu: host`、`virtio-scsi-single`、`boot: order=scsi0;net0`、`agent: 1`。
- 沒有符合條件的對照組時，硬體比對的項目會顯示 FAIL。這不代表建置有問題，看其他項目即可。

</details>

## 打開 VM 的 Console

1. 用瀏覽器開啟 `env` 裡的 `PVE_ENDPOINT`，例如 `https://192.168.11.201:8006`，用 PVE 的帳號登入。
2. 在左側展開節點，點選要看的 VM（顯示為「VMID（名稱）」）。
3. 點選右側的「Console」。

這裡看到的是 VM 的螢幕畫面。登入 VM 用的是 VM 自己的帳號與密碼，和登入 PVE 網頁的帳號無關。

## 除錯

### 建置範本時卡住

先看 VM 目前的畫面：[打開 VM 的 Console](#打開-vm-的-console)，或擷取成圖片：

```bash
scripts/vm-screenshot.sh lab 605 screen.png
```

依畫面判斷。處理完後，按 Ctrl+C 中止還在等待的建置指令，再重新執行。

#### 停在開機選單、進入手動安裝畫面，或出現 `Continue with autoinstall?`

Packer 輸入開機指令的時機不對。在 `overlays/lab/template.pkrvars.hcl` 加一行 `boot_wait = "15s"`，預設是 8 秒。

這個值是 VM 開機後等幾秒才開始輸入。開機選單會停留 30 秒，所以要設在選單出現之後、30 秒之內。

#### 安裝程式顯示錯誤

autoinstall 設定有誤，常見於修改磁碟配置之後。檢查你的 `user-data.pkrtpl.yaml` 的縮排，以及各段的 `id` 是否互相對應。

#### 已經出現登入提示，Packer 仍在等 SSH

工作機連不到建置用的 IP。在工作機上 `ping` 那個 IP，不通的話檢查 `template.pkrvars.hcl` 的 `build_ip_cidr`，以及 `site.hcl` 的 `gateway` 與 `bridge`。

#### 需要更多資訊

```bash
PACKER_LOG=1 scripts/build-template.sh lab
```

建置失敗或被中止時，Packer 會嘗試刪除建到一半的 VM。重新執行前，先執行 `ssh root@192.168.11.201 qm config 605`，出現 `does not exist` 代表它已經不存在。

### `VMID 605 already exists`

這個 VMID 已經被使用。要重建範本的話，請看[重建範本](operations.md#重建範本)；否則在 `overlays/lab/env` 把 `TEMPLATE_VMID` 改成沒被使用的數字。

### `scripts/tofu.sh lab apply` 停很久

VM 開機失敗，或 cloud-init（VM 第一次開機時套用網路與帳號設定的程式）沒有套用網路設定時，OpenTofu 會一直等到逾時。[打開該 VM 的 Console](#打開-vm-的-console) 查看：

- 畫面停在開機過程或錯誤訊息：範本本身有問題，[重建範本](operations.md#重建範本)。
- 已經出現登入提示：登入後執行 `ip -br addr`，看 IP 是否和清單裡的 `ip_cidr` 相同。不同的話，檢查 `vms.tfvars` 的 `ip_cidr`，以及 `site.hcl` 的 `gateway` 與 `bridge`。
