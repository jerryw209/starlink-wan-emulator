#!/usr/bin/env bash
set -euo pipefail

# ── Second Starlink WAN emulator using a network namespace ──
# This allows a second NIC to also present 192.168.100.1:9200
# (Starlink dish IP) without conflicting with the first WAN instance.

IFACE="${1:-enxd03745fef729}"
WAN_IP_CIDR="${2:-100.127.1.1/24}"
UPSTREAM_IFACE="${3:-}"
DNSMASQ_CONF="${4:-$(dirname "$0")/../configs/dnsmasq-wan2.conf}"
GRPC_DIR="$(dirname "$0")/../grpc"
GATEWAY_IP="${WAN_IP_CIDR%/*}"
DISH_IP="192.168.100.1"
DISH_CIDR="${DISH_IP}/24"
NETNS="starlink2"
VETH_HOST="veth-sl2-host"
VETH_NS="veth-sl2-ns"
VETH_HOST_IP="10.200.1.1/30"
VETH_NS_IP="10.200.1.2/30"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0 [wan_iface] [wan_ip_cidr] [upstream_iface] [dnsmasq_conf]"
  exit 1
fi

if ! command -v dnsmasq >/dev/null 2>&1; then
  echo "dnsmasq not found. Install it first."
  exit 1
fi

if [[ -z "$UPSTREAM_IFACE" ]]; then
  UPSTREAM_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
fi

if [[ -z "$UPSTREAM_IFACE" ]]; then
  echo "Could not detect upstream interface. Pass it as 3rd arg."
  exit 1
fi

echo "[1/7] Create network namespace '$NETNS'"
ip netns del "$NETNS" 2>/dev/null || true
ip netns add "$NETNS"

echo "[2/7] Move $IFACE into namespace and configure"
# Prevent NetworkManager interference
if command -v nmcli >/dev/null 2>&1; then
  nmcli device set "$IFACE" managed no 2>/dev/null || true
fi
ip link set "$IFACE" netns "$NETNS"

# Configure inside namespace
ip netns exec "$NETNS" ip link set lo up
ip netns exec "$NETNS" ip link set "$IFACE" up
ip netns exec "$NETNS" ip addr add "$WAN_IP_CIDR" dev "$IFACE"
ip netns exec "$NETNS" ip addr add "$DISH_CIDR" dev "$IFACE"

echo "[3/7] Create veth pair for upstream connectivity"
ip link del "$VETH_HOST" 2>/dev/null || true
ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
ip link set "$VETH_NS" netns "$NETNS"

ip addr add "$VETH_HOST_IP" dev "$VETH_HOST"
ip link set "$VETH_HOST" up

ip netns exec "$NETNS" ip addr add "$VETH_NS_IP" dev "$VETH_NS"
ip netns exec "$NETNS" ip link set "$VETH_NS" up
ip netns exec "$NETNS" ip route add default via "${VETH_HOST_IP%/*}"

echo "[4/7] Enable forwarding and NAT"
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Host side: NAT namespace traffic to upstream
iptables -t nat -C POSTROUTING -s "${VETH_HOST_IP%/*}/30" -o "$UPSTREAM_IFACE" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "${VETH_HOST_IP%/*}/30" -o "$UPSTREAM_IFACE" -j MASQUERADE

iptables -C FORWARD -i "$VETH_HOST" -o "$UPSTREAM_IFACE" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$VETH_HOST" -o "$UPSTREAM_IFACE" -j ACCEPT

iptables -C FORWARD -i "$UPSTREAM_IFACE" -o "$VETH_HOST" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$UPSTREAM_IFACE" -o "$VETH_HOST" -m state --state RELATED,ESTABLISHED -j ACCEPT

# Inside namespace: NAT router traffic to veth (for internet breakout)
ip netns exec "$NETNS" sysctl -w net.ipv4.ip_forward=1 >/dev/null
ip netns exec "$NETNS" iptables -t nat -A POSTROUTING -o "$VETH_NS" -j MASQUERADE
ip netns exec "$NETNS" iptables -A FORWARD -i "$VETH_NS" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
ip netns exec "$NETNS" iptables -A FORWARD -i "$IFACE" -o "$VETH_NS" -j ACCEPT

echo "[5/7] DNS interception inside namespace"
ip netns exec "$NETNS" iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY_IP":53
ip netns exec "$NETNS" iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY_IP":53

echo "[6/7] Start dnsmasq inside namespace"
PID_FILE="/run/dnsmasq-starlinkwan2.pid"
if [[ -f "$PID_FILE" ]]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

ip netns exec "$NETNS" dnsmasq \
  --conf-file="$(realpath "$DNSMASQ_CONF")" \
  --listen-address="$GATEWAY_IP" \
  --pid-file="$PID_FILE" \
  --dhcp-leasefile=/run/dnsmasq-starlinkwan2.leases

echo "[7/7] Start gRPC mock server inside namespace"
# Kill old instance if running
pkill -f "spacex_mock_server.*starlink2" 2>/dev/null || true

GRPC_ABS="$(realpath "$GRPC_DIR")"
nohup ip netns exec "$NETNS" bash -c "cd '$GRPC_ABS' && setsid python3 spacex_mock_server.py --listen ${DISH_IP}:9200" \
  </dev/null >/var/log/starlink2-grpc.log 2>&1 &
GRPC_PID=$!
echo "$GRPC_PID" > /run/starlink2-grpc.pid

echo ""
echo "WAN2 emulator is up (namespace: $NETNS)."
echo "  Router WAN iface target: $IFACE"
echo "  Emulated gateway: $GATEWAY_IP"
echo "  Starlink dish IP: $DISH_IP (gRPC on port 9200)"
echo "  Upstream via: $VETH_HOST <-> $VETH_NS -> $UPSTREAM_IFACE"
echo ""
echo "Check leases: sudo ip netns exec $NETNS cat /run/dnsmasq-starlinkwan2.leases"
