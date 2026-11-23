# 設計紀錄：用設定檔定義磁碟擴充規則

這是一份設計紀錄，內容**還沒有實作**，目前建立 `disk-growth.yaml` 不會有任何效果。

**現況**：磁碟與 LVM 的配置可以在 `user-data.pkrtpl.yaml` 裡調整，但 `grow-root-lvm` 的規則是寫死的，VG 裡空閒的空間固定全部加給根目錄的 LV。範本改成多個 LV 之後，其他 LV 不會跟著磁碟變大。

**已定案的設定格式**：新增 `base/packer/files/disk-growth.yaml`，列出新空間依什麼比例分給哪些 LV。

```yaml
# share 是百分比，總和不可超過 100；不足 100 的部分留在 VG 裡不配置。
volume_group: ubuntu-vg
grow:
  - lv: ubuntu-lv   # /
    share: 30
  - lv: var-lv      # /var
    share: 50
```

**已定案的行為規則**：

- 每次開機時先擴充分割區與 PV，再依 `share` 把新增的空間分給各 LV，並同步擴大檔案系統。
- 沒列到的 LV 不會變動。
- `grow` 是空清單時，只擴充分割區與 PV，新空間全部留在 VG 裡。
- 設定有錯時不動磁碟，例如 `share` 總和超過 100，或列了不存在的 LV。腳本記錄錯誤後結束，不影響開機。

**實作時要注意**：

- 規則是「分配新增的空間」，不是「分配當下的空閒空間」。否則刻意保留不配置的部分，下次開機時又會被分掉。腳本需要在 VM 內用一個狀態檔記住上次處理到的磁碟大小。
- 選用比例而不是固定大小，是因為固定大小無法回答「磁碟再次加大時怎麼分」。
- 手動安裝的 Ubuntu Server 26.04 已經有 Python 與 YAML 模組（cloud-init 與 netplan 依賴它們），所以 VM 內的腳本應該可以直接讀 YAML，不必加裝套件。實作時要再確認。

**尚未決定**：規則在哪一層生效。

| 選項 | 做法 | 代價 |
|---|---|---|
| 綁在範本上 | 建置範本時把 `disk-growth.yaml` 複製到 VM 的 `/etc/disk-growth.yaml`，同一個範本複製出來的 VM 共用一份規則。個別 VM 要不同規則時，登入後修改這個檔案再重開機 | 無法在 OpenTofu 的 VM 清單裡為個別 VM 指定規則 |
| 每台 VM 在清單裡指定 | 在 overlay 的 `vms.tfvars` 為每台 VM 寫規則，複製時傳進 VM | PVE 內建的 cloud-init 欄位傳不了這種設定，要改用自訂的 cloud-init 設定檔：ISO storage 要啟用 snippets、OpenTofu 要能 SSH 到 PVE 節點，而且 PVE 網頁上的 cloud-init 欄位會失效 |

規則必須和 LV 的配置對得上，而 LV 的配置是在建置範本時決定的，所以目前傾向第一個選項。
