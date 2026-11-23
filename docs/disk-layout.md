# 修改磁碟配置

預設的配置是根目錄放在 LVM 上、用滿整顆磁碟。這份文件說明怎麼把 `/var` 這類目錄分到獨立的磁碟區。修改要在建立範本之前進行；範本已經建好的話，改完後要[重建範本](operations.md#重建範本)。

磁碟配置寫在 `packer/files/user-data.pkrtpl.yaml` 的 `storage` 區塊。這裡用到 LVM 的三個名詞：

- PV（physical volume）：交給 LVM 管理的分割區。
- VG（volume group）：由 PV 組成的儲存空間集合。
- LV（logical volume）：從 VG 劃出來的邏輯磁碟區，上面可以建立檔案系統。

## 預設的配置

| 分割區 | 大小 | 用途 |
|---|---|---|
| 1 | 1M | BIOS 開機分割區 |
| 2 | 2G | `/boot`（ext4） |
| 3 | 其餘空間 | PV，屬於 VG `ubuntu-vg`；LV `ubuntu-lv` 用滿整個 VG 並掛在 `/`（ext4） |

## 把某個目錄分成獨立的 LV

以 `/var` 分出 15G 為例。新的 LV 給固定大小，根目錄的 `ubuntu-lv` 維持 `size: -1`，也就是用掉剩下的全部空間。

打開 `packer/files/user-data.pkrtpl.yaml`，在 `storage:` 底下的 `config:` 清單裡，加入標示「新增」的三段。清單的後半段改完後是這樣，註解只是用來指出位置，不用照抄：

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

- `lv-var` 要放在 `lv-root` 之前。`size: -1` 的 LV 會用掉剩下的全部空間，所以必須最後建立。
- 縮排要和其他段完全對齊，而且只能用空白，不能用 Tab。
- 三段靠 `id` 互相指向：`fs-var` 的 `volume` 填 `lv-var`，`mount-var` 的 `device` 填 `fs-var`。要分出其他目錄時，把三個 `id`、`name` 與 `path` 換成新的名稱，大小改成你要的值。

## 確認結果

建立範本後，從它建立一台 VM，登入後執行：

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

## 限制

建置過程與驗證腳本都以預設配置為基準，修改時要留意：

- VG 不能留下未配置的空間。建置時會檢查這一點，有剩餘空間就會失敗，所以根目錄的 LV 要維持 `size: -1`。
- VG 與根目錄 LV 的名稱要維持 `ubuntu-vg` 與 `ubuntu-lv`，`/boot` 要維持獨立的分割區。建置時的檢查寫死了這些名稱。
- 加大磁碟後，新增的空間全部加給根目錄的 LV，其他 LV 不會跟著變大。
- `scripts/verify.sh` 會回報根目錄大小不符。它預期根目錄接近整顆磁碟的大小，分出其他 LV 之後這一項會顯示 FAIL，可以忽略。
