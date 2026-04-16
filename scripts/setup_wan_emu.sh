#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-enx00051bcde7ed}"
WAN_IP_CIDR="${2:-100.127.0.1/24}"
UPSTREAM_IFACE="${3:-}"
DNSMASQ_CONF="${4:-$(dirname "$0")/../configs/dnsmasq-wan.conf}"
GATEWAY_IP="${WAN_IP_CIDR%/*}"
# Starlink dish management IP — router expects to reach 192.168.100.1:9200
DISH_IP="192.168.100.1"
DISH_CIDR="${DISH_IP}/24"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0 [wan_iface] [wan_ip_cidr] [upstream_iface] [dnsmasq_conf]"
  exit 1
fi

if ! command -v dnsmasq >/dev/null 2>&1; then
  echo "dnsmasq not found. Install it first (e.g. apt install dnsmasq)."
  exit 1
fi

if [[ -z "$UPSTREAM_IFACE" ]]; then
  UPSTREAM_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
fi

if [[ -z "$UPSTREAM_IFACE" ]]; then
  echo "Could not detect upstream interface. Pass it as 3rd arg."
  exit 1
fi

echo "[1/6] Configure interface $IFACE"
# Prevent NetworkManager from overriding manual IP assignment
if command -v nmcli >/dev/null 2>&1; then
  nmcli device set "$IFACE" managed no 2>/dev/null || true
fi
ip link set "$IFACE" up
ip addr flush dev "$IFACE"
ip addr add "$WAN_IP_CIDR" dev "$IFACE"
# Add Starlink dish management IP as secondary address
ip addr add "$DISH_CIDR" dev "$IFACE" 2>/dev/null || true

echo "[2/6] Enable IPv4 forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "[3/6] Configure NAT from $IFACE to $UPSTREAM_IFACE"
echo "[4/6] Starlink dish IP $DISH_IP added to $IFACE"
iptables -t nat -C POSTROUTING -o "$UPSTREAM_IFACE" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$UPSTREAM_IFACE" -j MASQUERADE

iptables -C FORWARD -i "$UPSTREAM_IFACE" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$UPSTREAM_IFACE" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

iptables -C FORWARD -i "$IFACE" -o "$UPSTREAM_IFACE" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$IFACE" -o "$UPSTREAM_IFACE" -j ACCEPT

# Force all DNS from router WAN side to local dnsmasq, even if router tries 8.8.8.8 directly.
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY_IP":53 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY_IP":53

iptables -t nat -C PREROUTING -i "$IFACE" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY_IP":53 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY_IP":53

echo "[5/6] Start dnsmasq"
# If system dnsmasq is running globally, this dedicated instance still works with bind-interfaces.
# Kill previous instance started by this script if pid file exists.
PID_FILE="/run/dnsmasq-starlinkwan.pid"
if [[ -f "$PID_FILE" ]]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

dnsmasq \
  --conf-file="$DNSMASQ_CONF" \
  --listen-address="$GATEWAY_IP" \
  --pid-file="$PID_FILE" \
  --dhcp-leasefile=/run/dnsmasq-starlinkwan.leases

echo "[6/6] Done"
echo "WAN emulator is up."
echo "  Router WAN iface target: $IFACE"
echo "  Emulated gateway: ${WAN_IP_CIDR%/*}"
echo "  Starlink dish IP: $DISH_IP (gRPC on port 9200)"
echo "  Upstream iface: $UPSTREAM_IFACE"
echo ""
echo "Next: start the gRPC mock server:"
echo "  cd grpc && python3 spacex_mock_server.py"
