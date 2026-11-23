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

Packer 與 OpenTofu 不用安裝，腳本會用 podman 下載它們的容器映像檔來執行。

### 1.2 選定一把 SSH 金鑰

這把金鑰有兩個用途：登入 PVE 節點，以及之後登入每台 VM。先看工作機有沒有金鑰：

```bash
ls ~/.ssh/id_*.pub
```

沒有的話，建立一把：

```bash
ssh-keygen -t ed25519
```

**記下你要用的公鑰路徑**，例如 `~/.ssh/id_ed25519.pub`，步驟 4.2 要填。有多把金鑰時，選一把即可。

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

在 PVE 節點上執行以下指令，把結果記下來。和範例值相同的項目，之後不用修改。

| 要查的項目 | 在 PVE 節點上執行 |
|---|---|
| 節點名稱 | `hostname` |
| 有哪些 storage、各自能放什麼 | `pvesm status`，以及 `cat /etc/pve/storage.cfg` 裡每個 storage 的 `content` |
| 有哪些橋接器 | `ip -br link show type bridge \| grep -v '^fwbr'` |
| 哪些 VMID 已被使用 | `pvesh get /cluster/resources --type vm --noborder \| awk 'NR>1{print $1}'` |

選擇時的條件：

- **放 VM 磁碟的 storage**：`content` 要包含 `images`。
- **放 ISO 的 storage**：`content` 要包含 `iso`。
- **範本的 VMID**：選一個沒出現在清單裡的數字。清單涵蓋整個叢集的 VM 與容器。
- **建置範本時暫用的 IP**：建置期間 VM 會使用一個固定 IP，工作機靠它連進 VM。它必須和工作機互通，而且沒有其他裝置在用。預設是 `192.168.11.66`。
- **每台 VM 的 IP**：同樣不能和現有的機器重複。

確認 IP 可用時，請以你的 IP 分配紀錄或 DNS 紀錄為準。`ping` 只能知道當下有沒有裝置回應，關機中的機器、或不回應 ping 的裝置都查不出來。

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

回到工作機，把這個 repo 複製下來。`REPO_URL` 換成你存放這個 repo 的位址：

```bash
git clone "$REPO_URL" ubuntu-pve-vm-template
cd ubuntu-pve-vm-template
```

之後的指令都在這個目錄下執行。

## 3. 依你的環境修改設定

和範例值相同的項目可以跳過。下表的檔案都是 HCL 格式，每個變數修改的是 `default = ` 後面的值。

| 項目 | 要修改的地方 |
|---|---|
| 放 VM 磁碟的 storage | `packer/variables.pkr.hcl` 的 `vm_storage`、`tofu/variables.tf` 的 `vm_storage` |
| 安裝光碟 | `packer/variables.pkr.hcl` 的 `iso_file`，填步驟 1.5 查到的完整名稱 |
| 種子光碟上傳到哪個 storage | `packer/variables.pkr.hcl` 的 `iso_storage`，通常和安裝光碟同一個 |
| 橋接器 | `packer/variables.pkr.hcl` 的 `bridge`、`tofu/variables.tf` 的 `bridge` |
| 建置範本時暫用的 IP、閘道、DNS | `packer/variables.pkr.hcl` 的 `build_ip_cidr`、`build_gateway`、`build_dns` |
| 所有 VM 共用的閘道與 DNS | `tofu/variables.tf` 的 `gateway`、`dns_servers` |
| 範本的名稱與規格 | `packer/variables.pkr.hcl` 的 `template_name`、`cores`、`memory`、`disk_size` |
| Ubuntu 套件來源 | `packer/variables.pkr.hcl` 的 `apt_mirror` |

PVE 節點的位址、節點名稱與**範本的 VMID** 不在這張表裡，它們填在下一步建立的 `.env`。

範本的 `disk_size` 改成大於 50G 時，`tofu/variables.tf` 裡 `vms` 的 `disk_gb` 預設值（50）也要跟著調高，因為 VM 的磁碟不能小於範本。

## 4. 建立 API 權杖

Packer 與 OpenTofu 透過 PVE 的 API 操作，需要一組 API 權杖（token，用來代替帳號密碼的憑證）。

### 4.1 在 PVE 上建立專用帳號與權杖

```bash
ssh root@192.168.11.201 'bash -s' < scripts/pve-access.sh
```

你的節點名稱、storage 或橋接器和範例值不同時，在前面加上對應的變數：

```bash
ssh root@192.168.11.201 'NODE=pve1 VM_STORAGE=local-lvm ISO_STORAGE=local BRIDGE=vmbr0 bash -s' < scripts/pve-access.sh
```

用非 root 帳號時，引號裡的指令分別改成 `sudo bash -s` 與 `sudo env NODE=pve1 VM_STORAGE=local-lvm ISO_STORAGE=local BRIDGE=vmbr0 bash -s`。

輸出的最後是一段 JSON：

```json
{"full-tokenid":"automation@pve!iac","info":{"privsep":"0"},"value":"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
```

`value` 是權杖的密鑰，**只會顯示這一次**，請立刻複製。

這支腳本在 PVE 上建立了三樣東西：使用者 `automation@pve`、角色 `AutomationIso`、權杖 `automation@pve!iac`。權杖的權限範圍請看[運作原理的「API 權杖的權限」](how-it-works.md#api-權杖的權限)。

### 4.2 填寫連線資訊

```bash
cp env.example .env
chmod 600 .env
```

用編輯器打開 `.env`。這個檔案的格式是 `名稱=值`，填入：

| 變數 | 填什麼 |
|---|---|
| `PVE_ENDPOINT` | `https://<PVE 節點的 IP>:8006` |
| `PVE_NODE` | 節點名稱 |
| `PVE_TOKEN_ID` | 上一步輸出的 `full-tokenid` |
| `PVE_TOKEN_SECRET` | 上一步輸出的 `value` |
| `TEMPLATE_VMID` | 範本的 VMID。建立範本與複製 VM 都以這裡的值為準 |
| `PVE_SSH` | 步驟 1.3 用來登入 PVE 節點的帳號與位址，例如 `root@192.168.11.201` |
| `SSH_PUBLIC_KEY_FILE` | 步驟 1.2 選定的公鑰路徑。拿掉這一行開頭的 `#` 再填。不填時使用 `~/.ssh/id_rsa.pub` |

確認公鑰路徑正確，以及權杖能讀取節點狀態：

```bash
set -a; . ./.env; set +a
test -r "${SSH_PUBLIC_KEY_FILE/#\~/$HOME}" && echo "公鑰 OK"
curl -sk -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
  "${PVE_ENDPOINT}/api2/json/nodes/${PVE_NODE}/status"
```

```
公鑰 OK
200
```

出現 `401` 代表權杖的 ID 或密鑰填錯；出現 `403` 或其他數字，代表節點名稱不對或權限沒有建立成功。

Git 預設會忽略 `.env`，它不會出現在 `git status` 裡。

## 5. 建立範本

```bash
scripts/build-template.sh
```

第一次執行會下載 Packer 的容器映像檔與 Proxmox 外掛，所以工作機要能連到網際網路。接著 Packer 會自動完成所有步驟，中途不需要操作。正常的輸出依序會出現這幾行：

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

```
ide0: vmdata:vm-605-cloudinit,media=cdrom
name: ub2604-ci-temp
scsi0: vmdata:base-605-disk-0,cache=none,iothread=1,replicate=0,size=50G
template: 1
```

預設的磁碟配置是根目錄放在 LVM 上、用滿整顆磁碟。使用預設配置的話，直接進行下一步。想把 `/var` 這類目錄分到獨立的磁碟區，請看[進階：修改磁碟配置](#進階修改磁碟配置)。

## 6. 定義 VM

### 6.1 VM 清單

VM 列在 `tofu/vms.auto.tfvars`，每台一個區塊。區塊的名稱就是 VM 名稱，也是主機名稱：

```hcl
vms = {
  web-01 = {
    vmid      = 615
    ip_cidr   = "192.168.11.67/24"
    username  = "bigred"
    cores     = 2      # 選填，預設 4
    memory_mb = 4096   # 選填，預設 8192
    disk_gb   = 100    # 選填，預設 50，不能小於範本的磁碟
  }
}
```

每台 VM 各自指定的是 VMID、IP、帳號名稱與規格。閘道、DNS 與 SSH 公鑰是所有 VM 共用的。

repo 裡附的兩台 `ub2604-ci-test1`、`ub2604-ci-test2` 是驗證用的範例，請換成你要的 VM。`vmid` 和 `ip_cidr` 都不能和現有的機器重複。

### 6.2 每台 VM 的密碼雜湊

設定檔裡不放密碼本身，只放密碼的雜湊（hash，由密碼算出來、無法反推回密碼的字串）。先產生雜湊：

```bash
scripts/hash-password.sh
```

輸入密碼時螢幕不會顯示任何字元。輸入兩次之後，腳本會印出一行以 `$6$` 開頭、共 106 個字元的字串，這就是雜湊。請從終端機完整複製這一行。

接著建立密碼雜湊檔：

```bash
cp tofu/secrets.auto.tfvars.example tofu/secrets.auto.tfvars
chmod 600 tofu/secrets.auto.tfvars
```

打開它，每台 VM 填一筆，名稱要和 VM 清單一致，值是剛才複製的雜湊：

```hcl
vm_password_hashes = {
  web-01 = "這裡貼上 $6$ 開頭的完整雜湊"
}
```

填入的不是 `$6$` 開頭的雜湊時，下一步會直接報錯，不會把明文密碼送出去。

## 7. 建立 VM

```bash
scripts/tofu.sh init    # 初始化並下載 Proxmox 外掛，只有第一次需要
scripts/tofu.sh plan    # 預覽會建立、修改或刪除哪些 VM
scripts/tofu.sh apply   # 執行，確認後輸入 yes
```

在驗證用的環境裡，每台 VM 大約 1 分鐘。完成時會列出每台 VM 的設定：

```
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

vms = {
  "web-01" = {
    "address" = "192.168.11.67"
    "username" = "bigred"
    "vmid" = 615
  }
}
```

這裡顯示的是你設定的 IP。實際連得上才算成功，用金鑰登入確認：

```bash
ssh bigred@192.168.11.67
```

再[打開這台 VM 的 Console](#打開-vm-的-console)，用清單裡的 `username` 與步驟 6.2 輸入的原始密碼登入。

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

| 想做的事 | 做法 |
|---|---|
| 新增 VM | 在 `tofu/vms.auto.tfvars` 加一個區塊，在 `tofu/secrets.auto.tfvars` 加一筆雜湊，執行 `scripts/tofu.sh apply` |
| 調整 CPU 或記憶體 | 修改清單裡的數值後執行 `scripts/tofu.sh apply`。在驗證用的環境裡，OpenTofu 會把 VM 重開機讓設定生效 |
| 加大磁碟 | 修改 `disk_gb` 後執行 `scripts/tofu.sh apply`。在驗證用的環境裡，磁碟會立刻變大，VM 不會重開機。接著把 VM 重開機，或登入後執行 `sudo systemctl start grow-root-lvm`，根目錄就會擴充到新的大小。磁碟只能加大，不能縮小 |
| 刪除一台 VM | 從清單移除它的區塊，執行 `scripts/tofu.sh apply` |
| 刪除 OpenTofu 管理的全部 VM | `scripts/tofu.sh destroy`。執行前它會列出要刪除的 VM，請核對後再輸入 yes |
| 重建範本 | 見下方說明 |

**重建範本**

建置腳本不會覆蓋現有的範本，要先刪除舊的。在 PVE 節點上，先確認那個 VMID 確實是這個專案的範本：

```bash
qm config 605 | grep -E '^(name|template)'
```

```
name: ub2604-ci-temp
template: 1
```

名稱與 `template: 1` 都符合，才刪除：

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

以 `/var` 分出 15G 為例，在 `storage.config` 清單裡加三段。新的 LV 給固定大小，根目錄的 `ubuntu-lv` 維持 `size: -1`，也就是用掉剩下的全部空間。

第一段要放在 `id: lv-root` 那一段**之前**，因為 `size: -1` 的 LV 必須最後建立：

```yaml
      - id: lv-var
        type: lvm_partition
        volgroup: vg0
        name: var-lv
        size: 15G
```

另外兩段加在清單的最後：

```yaml
      - id: fs-var
        type: format
        volume: lv-var
        fstype: ext4
      - id: mount-var
        type: mount
        device: fs-var
        path: /var
```

改完後要重建範本才會生效。

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
| 停在安裝光碟的開機選單，或已經進入一般的安裝畫面 | Packer 輸入開機指令的時機不對 | 調整 `packer/variables.pkr.hcl` 的 `boot_wait`。開機選單會停留 30 秒，數值設在選單出現之後、30 秒之內即可 |
| 出現 `Continue with autoinstall? (yes\|no)` | 核心開機參數缺少 `autoinstall` | 同上 |
| 安裝程式顯示錯誤 | autoinstall 設定有誤，常見於修改 `storage` 區塊之後 | 檢查 `packer/files/user-data.pkrtpl.yaml` 的縮排，以及各段的 `id` 是否互相對應 |
| 安裝完成並出現登入提示，Packer 仍在等 SSH | 工作機連不到建置用的 IP | 檢查 `build_ip_cidr`、`build_gateway` 與橋接器設定 |

需要 Packer 的詳細紀錄時：

```bash
PACKER_LOG=1 scripts/build-template.sh
```

建置失敗時，Packer 會嘗試刪除建到一半的 VM。重新執行前，先在 PVE 節點上用 `qm config 605` 確認它已經不存在。

**`VMID 605 already exists`**

這個 VMID 已經被使用。請看「日常操作」的「重建範本」，或在 `.env` 把 `TEMPLATE_VMID` 改成沒有被使用的數字。

**`public key file not found`**

`.env` 的 `SSH_PUBLIC_KEY_FILE` 指向的檔案不存在，請回到步驟 4.2 檢查。

**`scripts/tofu.sh apply` 停很久**

VM 開機失敗，或 cloud-init 沒有套用網路設定時，OpenTofu 會一直等到逾時。打開該 VM 的 Console 查看開機畫面。

## 不會進 git 的檔案

以下檔案含有機密或本機狀態，Git 預設會忽略它們：

| 檔案 | 內容 |
|---|---|
| `.env` | PVE 位址與 API 權杖 |
| `tofu/secrets.auto.tfvars` | 每台 VM 的密碼雜湊 |
| `tofu/terraform.tfstate` | OpenTofu 的狀態檔，記錄它管理的每台 VM，裡面也有密碼雜湊 |
| `.cache/` | Packer 與 OpenTofu 下載的外掛 |

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
