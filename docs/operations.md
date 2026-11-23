# 日常操作

範本與 VM 建好之後的操作。第一次建置請看[建置手冊](getting-started.md)。

VM 的新增、調整與刪除都是同一個流程：修改 `tofu/vms.auto.tfvars`，執行 `scripts/tofu.sh plan` 看它打算做什麼，確認無誤後執行 `scripts/tofu.sh apply`。

`plan` 最後一行的數字和你預期的不同時，**先不要執行 `apply`**。尤其是出現你沒打算刪除的 `to destroy`，或某台 VM 標示為 `must be replaced`（先刪除再重建，資料會消失）。

## 新增 VM

`plan` 應該顯示 `1 to add, 0 to change, 0 to destroy`。

1. 在 `tofu/vms.auto.tfvars` 的 `vms = { ... }` 裡加一個區塊，寫法和[建置手冊的步驟 6.1](getting-started.md#61-填寫-vm-清單) 相同。
2. 執行 `scripts/hash-password.sh` 產生雜湊，在 `tofu/secrets.auto.tfvars` 加一行同名的項目。
3. 執行 `scripts/tofu.sh plan`，確認後執行 `scripts/tofu.sh apply`。

## 調整 CPU 或記憶體

`plan` 應該顯示 `0 to add, 1 to change, 0 to destroy`。

修改那台 VM 的 `cores` 或 `memory_mb`，再執行 `plan` 與 `apply`。在驗證用的環境裡，OpenTofu 會把 VM 重開機讓設定生效。

## 加大磁碟

`plan` 應該顯示 `0 to add, 1 to change, 0 to destroy`。磁碟只能加大，不能縮小。

1. 在那台 VM 的區塊裡加上或修改 `disk_gb`，例如從 50 加大到 100：

   ```hcl
     web-01 = {
       vmid     = 615
       ip_cidr  = "192.168.11.67/24"
       username = "bigred"
       disk_gb  = 100
     }
   ```

2. 執行 `scripts/tofu.sh plan`，確認後執行 `scripts/tofu.sh apply`。在驗證用的環境裡，磁碟會立刻變大，VM 不會重開機，但這時 VM 裡的根目錄還是原本的大小。

3. 登入 VM，讓根目錄擴充到新的大小。把 VM 重開機也有同樣的效果：

   ```bash
   sudo systemctl start grow-root-lvm
   df -h /
   ```

   `df` 顯示的 `Size` 接近新的磁碟大小就完成了。

## 刪除 VM

刪除一台時，`plan` 應該顯示 `0 to add, 0 to change, 1 to destroy`。

從 `tofu/vms.auto.tfvars` 刪掉那台 VM 的整個區塊，並刪掉 `tofu/secrets.auto.tfvars` 裡它的那一行，再執行 `plan` 與 `apply`。

要刪除 OpenTofu 管理的全部 VM，執行 `scripts/tofu.sh destroy`，核對它列出的 VM 後再輸入 `yes`。

## 重建範本

建置腳本不會覆蓋現有的範本，要先刪除舊的。已經建立的 VM 是完整複製，有自己的磁碟，不受影響。

1. 確認那個 VMID 確實是這個專案的範本。把 `605` 換成你的範本 VMID：

   ```bash
   ssh root@192.168.11.201 qm config 605 | grep -E '^(name|template)'
   ```

   名稱要是你設定的 `template_name`（預設是 `ub2604-ci-temp`），而且有 `template: 1`。

2. 兩項都符合，才刪除：

   ```bash
   ssh root@192.168.11.201 qm destroy 605
   ```

3. 執行 `scripts/build-template.sh`。

## 不會進 git 的檔案

以下檔案含有機密或本機狀態，Git 預設會忽略它們：

| 檔案 | 內容 |
|---|---|
| `.env` | PVE 位址與 API 權杖 |
| `tofu/secrets.auto.tfvars` | 每台 VM 的密碼雜湊 |
| `tofu/terraform.tfstate` | OpenTofu 的狀態檔，記錄它管理的每台 VM，裡面也有密碼雜湊 |
| `.cache/` | Packer 的暫存檔 |

狀態檔只存在工作機上，沒有遠端備份。遺失後，OpenTofu 就不知道哪些 VM 歸它管理，請自行備份。

## 使用自己建置的映像檔

腳本預設使用發布在 GHCR 的容器映像檔。想自己建置的話，在 repo 根目錄執行：

```bash
podman build -t localhost/pve-ubuntu-autoinstall:dev .
```

再把 `.env` 裡 `TOOLS_IMAGE` 那一行開頭的 `#` 刪掉，值改成 `localhost/pve-ubuntu-autoinstall:dev`。

## 全部移除

依序執行，可以移除這個專案在 PVE 上建立的東西。

1. 刪除 OpenTofu 管理的 VM。它會先列出要刪除的對象，核對後再輸入 `yes`：

   ```bash
   scripts/tofu.sh destroy
   ```

   狀態檔遺失時，這個指令找不到要刪除的 VM，要到 PVE 上逐台確認後手動刪除。

2. 刪除範本。先照[重建範本](#重建範本)的第 1 步確認 VMID，再執行：

   ```bash
   ssh root@192.168.11.201 qm destroy 605
   ```

3. 刪除 API 帳號與角色。使用者的權杖與權限設定會一併移除：

   ```bash
   ssh root@192.168.11.201 'pveum user delete automation@pve; pveum role delete AutomationIso'
   ```
