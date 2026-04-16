#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-enxd03745fef729}"
UPSTREAM_IFACE="${2:-}"
NETNS="starlink2"
VETH_HOST="veth-sl2-host"
VETH_HOST_IP="10.200.1.1"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0 [wan_iface] [upstream_iface]"
  exit 1
fi

if [[ -z "$UPSTREAM_IFACE" ]]; then
  UPSTREAM_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
fi

echo "Stopping gRPC mock server (WAN2)"
if [[ -f /run/starlink2-grpc.pid ]]; then
  kill "$(cat /run/starlink2-grpc.pid)" 2>/dev/null || true
  rm -f /run/starlink2-grpc.pid
fi

echo "Stopping dnsmasq (WAN2)"
PID_FILE="/run/dnsmasq-starlinkwan2.pid"
if [[ -f "$PID_FILE" ]]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

echo "Removing host-side NAT/FORWARD rules"
iptables -t nat -D POSTROUTING -s "${VETH_HOST_IP}/30" -o "$UPSTREAM_IFACE" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "$VETH_HOST" -o "$UPSTREAM_IFACE" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$UPSTREAM_IFACE" -o "$VETH_HOST" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

echo "Deleting veth pair"
ip link del "$VETH_HOST" 2>/dev/null || true

echo "Moving $IFACE back from namespace and deleting namespace"
ip netns exec "$NETNS" ip link set "$IFACE" netns 1 2>/dev/null || true
ip netns del "$NETNS" 2>/dev/null || true

echo "Clearing IP on $IFACE"
ip addr flush dev "$IFACE" 2>/dev/null || true

echo "Done"
