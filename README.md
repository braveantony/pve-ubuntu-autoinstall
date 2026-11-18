# ubuntu-pve-vm-template

在 Proxmox VE（PVE）上全自動建立 Ubuntu Server 26.04 的 VM 範本，再從範本複製出 VM，並在複製時設定每台 VM 的網路、主機名稱與帳號密碼。

做出來的 VM 和手動掛光碟安裝的結果相同：根目錄在 LVM 上、使用 `linux-generic` 核心、登入畫面在 PVE 網頁的 Console（noVNC）上，沒有序列埠。

## 流程

```
階段一：建立範本（scripts/build-template.sh，約 8 分鐘）

  Packer ──▶ 建立 VM 605，掛上 Ubuntu 安裝光碟與種子光碟
         ──▶ 在開機選單輸入 autoinstall 參數
         ──▶ 安裝程式依 user-data 分割磁碟（LVM）並安裝系統
         ──▶ 重開機後以 SSH 連入：檢查、安裝磁碟擴充服務、清理
         ──▶ 關機，轉成範本，加上 cloud-init 光碟機

階段二：建立 VM（scripts/tofu.sh apply，每台約 1 分鐘）

  OpenTofu ──▶ 從範本 605 複製出 VM，調整 CPU、記憶體、磁碟大小
           ──▶ 把 IP、DNS、帳號、密碼、SSH 公鑰寫進 PVE 的 cloud-init 欄位
           ──▶ VM 開機，cloud-init 套用設定，磁碟擴充服務把根目錄擴到滿
```

- **Packer**：HashiCorp 的映像檔建置工具，負責階段一。
- **OpenTofu**：開源的基礎設施管理工具（Terraform 的分支），負責階段二。
- **autoinstall**：Ubuntu 安裝程式的無人值守模式，依一份 YAML 設定檔自動回答所有安裝問題。
- **cloud-init**：VM 第一次開機時讀取外部設定並套用的程式。PVE 會把設定放在一台虛擬光碟機裡交給它。

兩個工具都用 podman 從容器映像檔執行，執行指令的電腦和 PVE 節點都不需要安裝套件。

## 事前準備

以下指令都在你的工作機上執行，不是在 PVE 節點上。

工作機需要：

- `podman`、`curl`、`jq`、`ssh`、`openssl`、`python3`。
- 和 PVE 節點、VM 所在網段互通。Packer 要用 SSH 連進建置中的 VM。
- 能用 SSH 金鑰登入 PVE 節點，而且該帳號可以免密碼 `sudo`。只有建立 API 權杖和驗證時會用到。

PVE 節點需要：

- Ubuntu 26.04 的安裝光碟已經放在 ISO storage，預設路徑是 `local:iso/ubuntu-26.04-live-server-amd64.iso`。

### 1. 建立 API 權杖

`scripts/pve-access.sh` 會在 PVE 上建立使用者 `automation@pve`、自訂角色 `AutomationIso` 和一組 API 權杖，並印出權杖內容。密鑰只會顯示這一次。

```bash
ssh <帳號>@<PVE 節點 IP> 'sudo bash -s' < scripts/pve-access.sh
```

這組權杖可以管理所有 VM、在 `vmdata` 配置磁碟、使用 `vmbr1`，以及在 `local` 上傳和刪除檔案。PVE 的刪除權限以整個 storage 為單位，所以這組權杖能刪除 `local` 上的任何 ISO 與備份，請妥善保管。

### 2. 填寫連線資訊

```bash
cp env.example .env && chmod 600 .env
```

把上一步輸出的 `full-tokenid` 填入 `PVE_TOKEN_ID`，`value` 填入 `PVE_TOKEN_SECRET`。

## 階段一：建立範本

```bash
scripts/build-template.sh
```

範本的規格在 `packer/variables.pkr.hcl`，預設是 VMID 605、名稱 `ub2604-ci-temp`、4 核、8192 MB、50G 磁碟。

建置期間 VM 會暫時使用 `192.168.11.66`（變數 `build_ip_cidr`）。請先確認這個位址沒有其他裝置在用。

VMID 已經存在時，腳本會直接停止，不會覆蓋或刪除現有的 VM。

### 修改磁碟配置

磁碟配置寫在 `packer/files/user-data.pkrtpl.yaml` 的 `storage` 區塊，預設是：

| 分割區 | 大小 | 用途 |
|---|---|---|
| 1 | 1M | BIOS 開機分割區 |
| 2 | 2G | `/boot`（ext4） |
| 3 | 其餘空間 | LVM 的 PV，`ubuntu-vg/ubuntu-lv` 用滿並掛在 `/`（ext4） |

要把 `/var`、`/home` 分成獨立的 LV 時，在這個區塊增加對應的項目。同時要修改 `packer/files/grow-root-lvm`，因為它目前會把所有新增的空間都給根目錄。

## 階段二：建立 VM

VM 清單在 `tofu/vms.auto.tfvars`，每台 VM 一個區塊，名稱同時是主機名稱：

```hcl
vms = {
  my-vm = {
    vmid      = 617
    ip_cidr   = "192.168.11.70/24"
    username  = "bigred"
    cores     = 2      # 選填，預設 4
    memory_mb = 4096   # 選填，預設 8192
    disk_gb   = 100    # 選填，預設 50，不能小於範本的磁碟
  }
}
```

密碼放在另一個不進 git 的檔案，每台 VM 一筆：

```bash
cp tofu/secrets.auto.tfvars.example tofu/secrets.auto.tfvars
chmod 600 tofu/secrets.auto.tfvars
```

接著執行：

```bash
scripts/tofu.sh init    # 第一次使用時
scripts/tofu.sh plan    # 預覽會做哪些變更
scripts/tofu.sh apply   # 建立或更新 VM
```

閘道、DNS、storage、橋接器的預設值在 `tofu/variables.tf`。工作機的 `~/.ssh/id_rsa.pub` 會自動加到每台 VM 的帳號；要換成別把公鑰時，在 `.env` 設定 `SSH_PUBLIC_KEY_FILE`。

刪除 VM：從 `tofu/vms.auto.tfvars` 移除該區塊後執行 `scripts/tofu.sh apply`，或用 `scripts/tofu.sh destroy` 刪除清單裡的全部 VM。

## 驗證

```bash
scripts/verify.sh
```

腳本會登入 `tofu/vms.auto.tfvars` 裡的每台 VM，檢查：

- 主機名稱、IP、帳號和設定一致，建置用的臨時帳號 `packer` 不存在。
- 根目錄在 `ubuntu-vg/ubuntu-lv` 上，而且已經擴充到磁碟大小。
- 核心是 `linux-generic`，開機參數沒有 `console=`，`tty1` 有登入提示，沒有序列埠終端。
- PVE 上的硬體設定和手動建立的對照範本（預設 VMID 604，可用 `REFERENCE_VMID` 指定）相比，只多了 cloud-init 光碟機和 cloud-init 欄位。

用密碼從 PVE 網頁的 Console 登入這一項，要自己動手確認。

## 和手動安裝的差異

- 多安裝了 `qemu-guest-agent`，PVE 和 OpenTofu 靠它取得 VM 的 IP。
- 多了 `grow-root-lvm` 服務。每次開機時，它會依序擴充分割區、PV、LV 和檔案系統；沒有新空間時不做任何事。之後在 PVE 上加大磁碟，重開機就會生效。
- 帳號由 cloud-init 建立，所以 `sudo` 不需要輸入密碼。手動安裝建立的帳號則需要。
- cloud-init 保持啟用。手動安裝的系統在第一次開機後會停用它。

## 除錯

- 建置卡住時，用 `scripts/vm-screenshot.sh 605 screen.png` 擷取 VM 目前的畫面，或直接開 PVE 網頁的 Console。
- 需要 Packer 的詳細紀錄時，執行 `PACKER_LOG=1 scripts/build-template.sh`。
- Packer 輸入開機指令的時機太早或太晚時，調整 `packer/variables.pkr.hcl` 的 `boot_wait`。安裝光碟的開機選單會停留 30 秒。

## 不會進 git 的檔案

| 檔案 | 內容 |
|---|---|
| `.env` | PVE 位址與 API 權杖 |
| `tofu/secrets.auto.tfvars` | 每台 VM 的密碼 |
| `tofu/terraform.tfstate` | OpenTofu 的狀態檔，裡面有明文密碼 |
| `.cache/` | Packer 與 OpenTofu 下載的外掛 |

狀態檔遺失後，OpenTofu 就不知道哪些 VM 歸它管理，請自行備份。
