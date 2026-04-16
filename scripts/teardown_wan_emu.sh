#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-enx00051bcde7ed}"
UPSTREAM_IFACE="${2:-}"
WAN_IP_CIDR="${3:-100.127.0.1/24}"
GATEWAY_IP="${WAN_IP_CIDR%/*}"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0 [wan_iface] [upstream_iface]"
  exit 1
fi

if [[ -z "$UPSTREAM_IFACE" ]]; then
  UPSTREAM_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
fi

echo "Stopping gRPC mock server (WAN1)"
if [[ -f /run/starlink1-grpc.pid ]]; then
  kill "$(cat /run/starlink1-grpc.pid)" 2>/dev/null || true
  rm -f /run/starlink1-grpc.pid
fi

echo "Stopping dnsmasq instance used by emulator"
PID_FILE="/run/dnsmasq-starlinkwan.pid"
if [[ -f "$PID_FILE" ]]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

echo "Removing NAT/FORWARD rules (if present)"
iptables -t nat -D POSTROUTING -o "$UPSTREAM_IFACE" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "$UPSTREAM_IFACE" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$IFACE" -o "$UPSTREAM_IFACE" -j ACCEPT 2>/dev/null || true
iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY_IP":53 2>/dev/null || true
iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY_IP":53 2>/dev/null || true

echo "Clearing IP on $IFACE"
ip addr flush dev "$IFACE"

echo "Done"
