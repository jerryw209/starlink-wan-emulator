#!/usr/bin/env bash
set -euo pipefail

# ── Starlink WAN Emulator 統一控制腳本 ──
# 用法:
#   sudo ./starlink.sh start              # 啟動全部（WAN1 + WAN2）
#   sudo ./starlink.sh start wan1         # 只啟動 WAN1
#   sudo ./starlink.sh start wan2         # 只啟動 WAN2
#   sudo ./starlink.sh stop               # 停止全部
#   sudo ./starlink.sh stop wan1          # 只停 WAN1
#   sudo ./starlink.sh stop wan2          # 只停 WAN2
#   sudo ./starlink.sh status             # 查看狀態
#   sudo ./starlink.sh restart            # 重啟全部

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRPC_DIR="$SCRIPT_DIR/grpc"

# ── 設定 ──
WAN1_IFACE="enx00051bcde7ed"
WAN2_IFACE="enxd03745fef729"

usage() {
  echo "Starlink WAN Emulator"
  echo ""
  echo "用法: sudo $0 {start|stop|restart|status|impair|clear|scene} [wan1|wan2]"
  echo ""
  echo "  start   [wan1|wan2]  啟動模擬（預設全部）"
  echo "  stop    [wan1|wan2]  停止模擬（預設全部）"
  echo "  restart [wan1|wan2]  重啟模擬（預設全部）"
  echo "  status               顯示目前狀態"
  echo "  impair  [wan1|wan2] [DELAY_MS] [JITTER_MS] [LOSS%]"
  echo "                       加入延遲/抖動/掉包（預設: 40ms 15ms 0.5%）"
  echo "  clear   [wan1|wan2]  移除延遲/抖動/掉包"
  echo "  scene   [wan1|wan2] <SCENE_NAME>"
  echo "                       切換 Starlink 場景（重啟 gRPC）"
  echo "                       場景: connected, no_account, too_far,"
  echo "                              in_ocean, blocked_country,"
  echo "                              data_overage_sandbox, cell_disabled,"
  echo "                              roam_restricted, unknown_location,"
  echo "                              account_disabled, unsupported_version,"
  echo "                              moving_too_fast, aviation_flyover,"
  echo "                              blocked_area, searching, stowed,"
  echo "                              obstructed, overage"
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  echo "請用 root 執行: sudo $0 $*"
  exit 1
fi

start_wan1() {
  echo "━━━ 啟動 WAN1 ($WAN1_IFACE) ━━━"
  "$SCRIPT_DIR/scripts/setup_wan_emu.sh" "$WAN1_IFACE"

  # 啟動 gRPC mock server
  if ss -lntp 2>/dev/null | grep -q "192.168.100.1.*:9200"; then
    echo "WAN1 gRPC 已在執行中，跳過"
  else
    cd "$GRPC_DIR"
    nohup setsid python3 spacex_mock_server.py --listen 192.168.100.1:9200 \
      </dev/null >/var/log/starlink1-grpc.log 2>&1 &
    GRPC_PID=$!
    echo "$GRPC_PID" > /run/starlink1-grpc.pid
    echo "WAN1 gRPC mock 已啟動 (PID $GRPC_PID)"
  fi
  echo ""
}

stop_wan1() {
  echo "━━━ 停止 WAN1 ($WAN1_IFACE) ━━━"
  iptables -D FORWARD -i "$WAN1_IFACE" -j DROP 2>/dev/null || true
  rm -f /run/starlink1-scene
  "$SCRIPT_DIR/scripts/teardown_wan_emu.sh" "$WAN1_IFACE"
  echo ""
}

start_wan2() {
  echo "━━━ 啟動 WAN2 ($WAN2_IFACE, namespace) ━━━"
  "$SCRIPT_DIR/scripts/setup_wan2_emu.sh" "$WAN2_IFACE"
  echo ""
}

stop_wan2() {
  echo "━━━ 停止 WAN2 ($WAN2_IFACE, namespace) ━━━"
  ip netns exec starlink2 iptables -D FORWARD -i "$WAN2_IFACE" -j DROP 2>/dev/null || true
  rm -f /run/starlink2-scene
  "$SCRIPT_DIR/scripts/teardown_wan2_emu.sh" "$WAN2_IFACE"
  echo ""
}

show_status() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Starlink WAN Emulator 狀態"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # WAN1
  echo "【WAN1】$WAN1_IFACE"
  if ip link show "$WAN1_IFACE" &>/dev/null; then
    WAN1_IPS=$(ip -4 addr show "$WAN1_IFACE" 2>/dev/null | grep -oP 'inet \K[^ ]+' | tr '\n' ', ' | sed 's/,$//')
    if [[ -n "$WAN1_IPS" ]]; then
      echo "  IP: $WAN1_IPS"
    else
      echo "  IP: (無)"
    fi
  else
    echo "  介面: 不存在或在 namespace 中"
  fi

  if ss -lntp 2>/dev/null | grep -q "192.168.100.1.*:9200"; then
    echo "  gRPC: ✓ 運行中 (192.168.100.1:9200)"
  else
    echo "  gRPC: ✗ 未啟動"
  fi

  if [[ -f /run/dnsmasq-starlinkwan.pid ]] && kill -0 "$(cat /run/dnsmasq-starlinkwan.pid)" 2>/dev/null; then
    echo "  DHCP: ✓ 運行中"
    LEASES=$(cat /run/dnsmasq-starlinkwan.leases 2>/dev/null | wc -l)
    echo "  租約: $LEASES 筆"
  else
    echo "  DHCP: ✗ 未啟動"
  fi
  echo ""

  # WAN2
  echo "【WAN2】$WAN2_IFACE (netns: starlink2)"
  if ip netns list 2>/dev/null | grep -q starlink2; then
    WAN2_IPS=$(ip netns exec starlink2 ip -4 addr show "$WAN2_IFACE" 2>/dev/null | grep -oP 'inet \K[^ ]+' | tr '\n' ', ' | sed 's/,$//')
    if [[ -n "$WAN2_IPS" ]]; then
      echo "  IP: $WAN2_IPS"
    else
      echo "  IP: (無)"
    fi

    if ip netns exec starlink2 ss -lntp 2>/dev/null | grep -q ":9200"; then
      echo "  gRPC: ✓ 運行中 (192.168.100.1:9200)"
    else
      echo "  gRPC: ✗ 未啟動"
    fi

    if [[ -f /run/dnsmasq-starlinkwan2.pid ]] && kill -0 "$(cat /run/dnsmasq-starlinkwan2.pid)" 2>/dev/null; then
      echo "  DHCP: ✓ 運行中"
      LEASES=$(ip netns exec starlink2 cat /run/dnsmasq-starlinkwan2.leases 2>/dev/null | wc -l)
      echo "  租約: $LEASES 筆"
    else
      echo "  DHCP: ✗ 未啟動"
    fi
  else
    echo "  Namespace: 不存在（WAN2 未啟動）"
  fi
  echo ""
}

# ── 網路損傷（延遲/抖動/掉包）──
impair_iface() {
  local iface="$1" delay="$2" jitter="$3" loss="$4" ns="${5:-}"
  local cmd_prefix=""
  [[ -n "$ns" ]] && cmd_prefix="ip netns exec $ns"

  # 移除舊規則
  $cmd_prefix tc qdisc del dev "$iface" root 2>/dev/null || true
  # 加入 netem
  $cmd_prefix tc qdisc add dev "$iface" root netem \
    delay "${delay}ms" "${jitter}ms" distribution normal \
    loss "${loss}%"
  echo "  $iface: delay=${delay}ms jitter=${jitter}ms loss=${loss}%"
}

clear_iface() {
  local iface="$1" ns="${2:-}"
  local cmd_prefix=""
  [[ -n "$ns" ]] && cmd_prefix="ip netns exec $ns"
  $cmd_prefix tc qdisc del dev "$iface" root 2>/dev/null || true
  echo "  $iface: 已清除"
}

show_impair() {
  local iface="$1" ns="${2:-}"
  local cmd_prefix=""
  [[ -n "$ns" ]] && cmd_prefix="ip netns exec $ns"
  local info=$($cmd_prefix tc qdisc show dev "$iface" 2>/dev/null | grep netem)
  if [[ -n "$info" ]]; then
    echo "  $iface: $info"
  else
    echo "  $iface: (無損傷)"
  fi
}

impair_wan1() {
  echo "━━━ WAN1 加入網路損傷 ━━━"
  impair_iface "$WAN1_IFACE" "$DELAY" "$JITTER" "$LOSS"
}

impair_wan2() {
  echo "━━━ WAN2 加入網路損傷 ━━━"
  impair_iface "$WAN2_IFACE" "$DELAY" "$JITTER" "$LOSS" "starlink2"
}

clear_wan1() {
  echo "━━━ WAN1 清除網路損傷 ━━━"
  clear_iface "$WAN1_IFACE"
}

clear_wan2() {
  echo "━━━ WAN2 清除網路損傷 ━━━"
  clear_iface "$WAN2_IFACE" "starlink2"
}

# ── 場景流量控制 ──
# DISABLED 場景封鎖轉發流量（DHCP + gRPC 不受影響，因為走 INPUT 鏈）
apply_scene_traffic() {
  local iface="$1" scene="$2" ns="${3:-}"
  local cmd_prefix=""
  [[ -n "$ns" ]] && cmd_prefix="ip netns exec $ns"

  case "$scene" in
    no_account|too_far|in_ocean|blocked_country|data_overage_sandbox|cell_disabled|roam_restricted|unknown_location|account_disabled|unsupported_version|moving_too_fast|aviation_flyover|blocked_area|stowed|searching)
      # 清除 netem
      $cmd_prefix tc qdisc del dev "$iface" root 2>/dev/null || true
      # 封鎖轉發
      $cmd_prefix iptables -D FORWARD -i "$iface" -j DROP 2>/dev/null || true
      $cmd_prefix iptables -I FORWARD -i "$iface" -j DROP
      echo "  流量: ✗ 已封鎖（$scene — 無法上網）"
      ;;
    obstructed)
      # 移除封鎖
      $cmd_prefix iptables -D FORWARD -i "$iface" -j DROP 2>/dev/null || true
      # 高掉包模擬遮擋
      $cmd_prefix tc qdisc del dev "$iface" root 2>/dev/null || true
      $cmd_prefix tc qdisc add dev "$iface" root netem delay 80ms 40ms distribution normal loss 75%
      echo "  流量: ⚠ 嚴重損傷（delay=80ms jitter=40ms loss=75%）"
      ;;
    overage)
      # 移除封鎖
      $cmd_prefix iptables -D FORWARD -i "$iface" -j DROP 2>/dev/null || true
      # 限速模擬 overage：低帶寬 + 延遲
      $cmd_prefix tc qdisc del dev "$iface" root 2>/dev/null || true
      $cmd_prefix tc qdisc add dev "$iface" root netem delay 55ms 10ms distribution normal rate 5mbit
      echo "  流量: ⚠ 限速（overage — rate=5mbit delay=55ms）"
      ;;
    connected|*)
      # 移除封鎖
      $cmd_prefix iptables -D FORWARD -i "$iface" -j DROP 2>/dev/null || true
      # 清除 netem
      $cmd_prefix tc qdisc del dev "$iface" root 2>/dev/null || true
      echo "  流量: ✓ 正常"
      ;;
  esac
}

# ── 切換場景（重啟 gRPC server + 流量控制）──
scene_wan1() {
  local scene="$1"
  echo "━━━ WAN1 切換場景: $scene ━━━"
  # Kill old gRPC
  if [[ -f /run/starlink1-grpc.pid ]]; then
    kill "$(cat /run/starlink1-grpc.pid)" 2>/dev/null || true
    rm -f /run/starlink1-grpc.pid
  fi
  sleep 1
  cd "$GRPC_DIR"
  nohup setsid python3 spacex_mock_server.py --listen 192.168.100.1:9200 --scene "$scene" \
    </dev/null >/var/log/starlink1-grpc.log 2>&1 &
  GRPC_PID=$!
  echo "$GRPC_PID" > /run/starlink1-grpc.pid
  echo "  gRPC 已重啟 (PID $GRPC_PID, scene=$scene)"
  apply_scene_traffic "$WAN1_IFACE" "$scene"
  echo "$scene" > /run/starlink1-scene
}

scene_wan2() {
  local scene="$1"
  echo "━━━ WAN2 切換場景: $scene ━━━"
  # Kill old gRPC
  if [[ -f /run/starlink2-grpc.pid ]]; then
    kill "$(cat /run/starlink2-grpc.pid)" 2>/dev/null || true
    rm -f /run/starlink2-grpc.pid
  fi
  sleep 1
  GRPC_ABS="$(realpath "$GRPC_DIR")"
  nohup ip netns exec starlink2 bash -c "cd '$GRPC_ABS' && setsid python3 spacex_mock_server.py --listen 192.168.100.1:9200 --scene '$scene'" \
    </dev/null >/var/log/starlink2-grpc.log 2>&1 &
  GRPC_PID=$!
  echo "$GRPC_PID" > /run/starlink2-grpc.pid
  echo "  gRPC 已重啟 (PID $GRPC_PID, scene=$scene)"
  apply_scene_traffic "$WAN2_IFACE" "$scene" "starlink2"
  echo "$scene" > /run/starlink2-scene
}

ACTION="${1:-}"
TARGET="${2:-all}"
DELAY="${3:-40}"
JITTER="${4:-15}"
LOSS="${5:-0.5}"

case "$ACTION" in
  start)
    case "$TARGET" in
      wan1) start_wan1 ;;
      wan2) start_wan2 ;;
      all)  start_wan1; start_wan2 ;;
      *)    usage ;;
    esac
    show_status
    ;;
  stop)
    case "$TARGET" in
      wan1) stop_wan1 ;;
      wan2) stop_wan2 ;;
      all)  stop_wan1; stop_wan2 ;;
      *)    usage ;;
    esac
    ;;
  restart)
    case "$TARGET" in
      wan1) stop_wan1; start_wan1 ;;
      wan2) stop_wan2; start_wan2 ;;
      all)  stop_wan1; stop_wan2; start_wan1; start_wan2 ;;
      *)    usage ;;
    esac
    show_status
    ;;
  status)
    show_status
    echo "【網路損傷】"
    show_impair "$WAN1_IFACE"
    if ip netns list 2>/dev/null | grep -q starlink2; then
      show_impair "$WAN2_IFACE" "starlink2"
    fi
    echo ""
    echo "【場景】"
    S1=$(cat /run/starlink1-scene 2>/dev/null || echo "connected")
    echo -n "  WAN1: $S1"
    if iptables -C FORWARD -i "$WAN1_IFACE" -j DROP 2>/dev/null; then
      echo " (流量已封鎖)"
    else
      echo ""
    fi
    if ip netns list 2>/dev/null | grep -q starlink2; then
      S2=$(cat /run/starlink2-scene 2>/dev/null || echo "connected")
      echo -n "  WAN2: $S2"
      if ip netns exec starlink2 iptables -C FORWARD -i "$WAN2_IFACE" -j DROP 2>/dev/null; then
        echo " (流量已封鎖)"
      else
        echo ""
      fi
    fi
    echo ""
    ;;
  impair)
    case "$TARGET" in
      wan1) impair_wan1 ;;
      wan2) impair_wan2 ;;
      all)  impair_wan1; impair_wan2 ;;
      *)    usage ;;
    esac
    ;;
  clear)
    case "$TARGET" in
      wan1) clear_wan1 ;;
      wan2) clear_wan2 ;;
      all)  clear_wan1; clear_wan2 ;;
      *)    usage ;;
    esac
    ;;
  scene)
    SCENE_NAME="${3:-}"
    if [[ -z "$SCENE_NAME" ]]; then
      echo "請指定場景名稱:"
      echo "  Disablement: no_account, too_far, in_ocean, blocked_country,"
      echo "               data_overage_sandbox, cell_disabled, roam_restricted,"
      echo "               unknown_location, account_disabled, unsupported_version,"
      echo "               moving_too_fast, aviation_flyover, blocked_area"
      echo "  其他: connected, searching, stowed, obstructed, overage"
      exit 1
    fi
    case "$TARGET" in
      wan1) scene_wan1 "$SCENE_NAME" ;;
      wan2) scene_wan2 "$SCENE_NAME" ;;
      all)  scene_wan1 "$SCENE_NAME"; scene_wan2 "$SCENE_NAME" ;;
      *)    usage ;;
    esac
    ;;
  *)
    usage
    ;;
esac
