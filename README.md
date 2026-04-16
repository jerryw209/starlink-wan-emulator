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
