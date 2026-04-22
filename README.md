# Starlink WAN Emulator

用一台 Linux 電腦 + USB 網卡模擬 Starlink WAN，讓 Peplink 路由器的 WAN 口辨識為「Starlink」連線。

## 功能

- DHCP 發 IP 給路由器 WAN 口（CGNAT 100.127.x.x 子網）
- NAT 讓路由器透過 Linux 主機上網
- DNS 攔截（即使路由器指定外部 DNS 也能正常 health check）
- **SpaceX gRPC mock**（`192.168.100.1:9200`），實作 `SpaceX.API.Device.Device/Handle`，路由器可辨識為 Starlink WAN
- 支援單 WAN 或雙 WAN（第二條用 Linux network namespace 隔離）

## 檔案結構

```
configs/
  dnsmasq-wan.conf          # WAN1 DHCP 設定
  dnsmasq-wan2.conf         # WAN2 DHCP 設定
scripts/
  setup_wan_emu.sh          # 啟動 WAN1
  teardown_wan_emu.sh       # 停止 WAN1
  setup_wan2_emu.sh         # 啟動 WAN2（network namespace）
  teardown_wan2_emu.sh      # 停止 WAN2
grpc/
  spacex_mock_server.py     # SpaceX gRPC mock server
  compile_spacex_proto.sh   # 編譯 SpaceX proto
  spacex/api/device/*.proto # SpaceX protobuf 定義（來自真實 Starlink）
  mock_server.py            # 舊版簡易 mock（可選）
```

---

## 快速啟動

### Step 0：安裝依賴

```bash
sudo apt update && sudo apt install -y dnsmasq iptables python3 python3-pip
pip3 install -r requirements.txt
sudo pip3 install grpcio grpcio-tools grpcio-reflection
```

### Step 1：編譯 SpaceX proto

```bash
cd grpc
chmod +x compile_spacex_proto.sh
./compile_spacex_proto.sh
cd ..
```

### Step 2：啟動

```bash
# 啟動全部（WAN1 + WAN2）
sudo ./starlink.sh start

# 只啟動 WAN1
sudo ./starlink.sh start wan1

# 只啟動 WAN2
sudo ./starlink.sh start wan2
```

### 查看狀態

```bash
sudo ./starlink.sh status
```

### 停止

```bash
# 停止全部
sudo ./starlink.sh stop

# 只停 WAN1 / WAN2
sudo ./starlink.sh stop wan1
sudo ./starlink.sh stop wan2
```

### 重啟

```bash
sudo ./starlink.sh restart
```

---

## 驗證

### WAN1

```bash
# DHCP 租約
sudo cat /run/dnsmasq-starlinkwan.leases

# gRPC 是否在監聽
ss -lntp | grep 9200

# NAT 規則
sudo iptables -t nat -S | grep MASQUERADE
```

### WAN2

```bash
# DHCP 租約
sudo ip netns exec starlink2 cat /run/dnsmasq-starlinkwan2.leases

# gRPC 是否在監聽
sudo ip netns exec starlink2 ss -lntp | grep 9200

# namespace 裡的 IP
sudo ip netns exec starlink2 ip -4 addr show
```

---

## 網路架構圖

```
                    ┌──────────────────────────────┐
                    │        Linux 主機             │
                    │                              │
  WAN1:            │  enx00051bcde7ed              │
  USB NIC ─────────┤    100.127.0.1/24             │
  → Router WAN1    │    192.168.100.1/24           │    enp0s31f6
                    │    dnsmasq (port 53)          ├──── (上網)
                    │    gRPC mock (port 9200)      │
                    │                              │
  WAN2:            │  [netns: starlink2]           │
  USB NIC ─────────┤    enxd03745fef729            │
  → Router WAN2    │      100.127.1.1/24           │
                    │      192.168.100.1/24         │
                    │      dnsmasq (port 53)        │
                    │      gRPC mock (port 9200)    │
                    │    veth-sl2-ns ↔ veth-sl2-host│
                    └──────────────────────────────┘
```

## 網路損傷（延遲/抖動/掉包）

模擬 Starlink 的網路特性（高延遲、抖動、偶爾掉包）：

```bash
# 加入損傷（預設: 40ms 延遲, 15ms 抖動, 0.5% 掉包）
sudo ./starlink.sh impair

# 自訂參數: impair [wan1|wan2|all] [延遲ms] [抖動ms] [掉包%]
sudo ./starlink.sh impair all 80 25 2
sudo ./starlink.sh impair wan1 50 20 1

# 清除損傷
sudo ./starlink.sh clear
sudo ./starlink.sh clear wan1

# status 會顯示目前損傷設定
sudo ./starlink.sh status
```

Starlink 典型參數參考：
| 場景 | 延遲 | 抖動 | 掉包 |
|------|------|------|------|
| 正常 | 40ms | 15ms | 0.5% |
| 擁塞 | 80ms | 30ms | 2% |
| 惡劣天氣 | 120ms | 50ms | 5% |

## 場景模擬（DisablementCode）

切換 Starlink dish 的 gRPC 回應狀態，測試路由器對各種 Starlink 異常的處理：

```bash
# 切換場景（會重啟 gRPC server）
sudo ./starlink.sh scene wan1 blocked_area
sudo ./starlink.sh scene wan2 no_account
sudo ./starlink.sh scene all searching

# 恢復正常
sudo ./starlink.sh scene all connected
```

可用場景：

| 場景名稱 | DishState | DisablementCode | 流量效果 | 說明 |
|----------|-----------|-----------------|----------|------|
| `connected` | CONNECTED | DISABLEMENT_OKAY | ✓ 正常 | 正常連線（預設） |
| `no_account` | CONNECTED | NO_ACTIVE_ACCOUNT (2) | ✗ 封鎖 | 無有效帳號 |
| `too_far` | CONNECTED | TOO_FAR_FROM_SERVICE_ADDRESS (3) | ✗ 封鎖 | 距離服務地址太遠 |
| `in_ocean` | CONNECTED | IN_OCEAN (4) | ✗ 封鎖 | 在海洋中 |
| `blocked_country` | CONNECTED | BLOCKED_COUNTRY (6) | ✗ 封鎖 | 被封鎖國家 |
| `data_overage_sandbox` | CONNECTED | DATA_OVERAGE_SANDBOX_POLICY (7) | ✗ 封鎖 | 數據超量沙盒策略 |
| `cell_disabled` | CONNECTED | CELL_IS_DISABLED (8) | ✗ 封鎖 | Cell 已停用 |
| `roam_restricted` | CONNECTED | ROAM_RESTRICTED (10) | ✗ 封鎖 | 漫遊受限 |
| `unknown_location` | CONNECTED | UNKNOWN_LOCATION (11) | ✗ 封鎖 | 未知位置 |
| `account_disabled` | CONNECTED | ACCOUNT_DISABLED (12) | ✗ 封鎖 | 帳號已停用 |
| `unsupported_version` | CONNECTED | UNSUPPORTED_VERSION (13) | ✗ 封鎖 | 不支援的版本 |
| `moving_too_fast` | CONNECTED | MOVING_TOO_FAST_FOR_POLICY (14) | ✗ 封鎖 | 移動太快 |
| `aviation_flyover` | CONNECTED | UNDER_AVIATION_FLYOVER_LIMITS (15) | ✗ 封鎖 | 航空飛越限制 |
| `blocked_area` | CONNECTED | BLOCKED_AREA (16) | ✗ 封鎖 | 禁止區域 |
| `searching` | SEARCHING | DISABLEMENT_OKAY | ✗ 封鎖 | 搜尋衛星中 |
| `stowed` | STOWED | DISABLEMENT_OKAY | ✗ 封鎖 | 天線收起 |
| `obstructed` | OBSTRUCTED | DISABLEMENT_OKAY | ⚠ 75% 掉包 | 遮擋（間歇連線） |
| `overage` | CONNECTED | DISABLEMENT_OKAY | ⚠ 限速 5Mbit | 流量超額限速 |

> **注意：** 切換場景時會同時控制實際網路流量。DISABLED/搜尋/收起場景會封鎖 WAN 轉發流量（iptables FORWARD DROP），路由器無法上網但仍可查詢 gRPC。切回 `connected` 恢復正常。
