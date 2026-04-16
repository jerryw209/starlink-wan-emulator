# Starlink WAN Emulator (DHCP + gRPC mock)

This workspace provides a minimal test setup for:

- Emulating an ISP/Starlink-like WAN over Linux NIC `enx00051bcde7ed`
- Giving DHCP to a router WAN port
- Providing a mock gRPC service for router-side API integration testing

## What this can and cannot emulate

Can emulate:

- WAN DHCP IP assignment
- Gateway + DNS
- Basic internet breakout via NAT
- A mock gRPC service with fixed telemetry values
- DNS health-check friendly behavior (local DNS forwarder + DNS interception)

Cannot fully emulate:

- Real Starlink satellite behavior
- Official cloud auth and private backend behavior
- Exact proprietary protobuf/service definitions expected by every vendor router

## Files

- `configs/dnsmasq-wan.conf`: DHCP server settings
- `scripts/setup_wan_emu.sh`: bring up WAN emulation (IP/NAT/DHCP)
- `scripts/teardown_wan_emu.sh`: clean up rules and stop dnsmasq instance
- `grpc/starlink_mock.proto`: example proto schema
- `grpc/mock_server.py`: example gRPC mock server
- `grpc/compile_proto.sh`: generate Python gRPC stubs

## 1) Install dependencies (Ubuntu/Debian example)

```bash
sudo apt update
sudo apt install -y dnsmasq iptables python3 python3-pip
pip3 install -r requirements.txt
```

## 2) Bring up WAN emulation on your NIC

```bash
chmod +x scripts/setup_wan_emu.sh scripts/teardown_wan_emu.sh grpc/compile_proto.sh
sudo ./scripts/setup_wan_emu.sh enx00051bcde7ed
```

Notes:

- Emulated gateway IP: `100.127.0.1`
- DHCP pool: `100.127.0.10-100.127.0.200`
- Upstream interface auto-detected from default route (or pass as 3rd arg)
- DHCP advertises DNS as `100.127.0.1` (this Linux host)
- Script also DNATs WAN-side TCP/UDP 53 to local dnsmasq, so router DNS health checks still pass even if it hardcodes external DNS

Router WAN should receive DHCP from this host.

## 3) Compile and run gRPC mock

```bash
cd grpc
./compile_proto.sh
python3 mock_server.py --listen 0.0.0.0:50051
```

## 4) Validation checks on Linux host

Check DHCP leases:

```bash
sudo cat /run/dnsmasq-starlinkwan.leases
```

Check NAT rule:

```bash
sudo iptables -t nat -S | grep MASQUERADE
```

Check DNS interception rules:

```bash
sudo iptables -t nat -S PREROUTING | grep -- '--dport 53'
```

Check gRPC port:

```bash
ss -lntp | grep 50051
```

## 5) Optional network impairment (latency/loss)

To mimic unstable WAN, add traffic control on the WAN-facing NIC:

```bash
sudo tc qdisc add dev enx00051bcde7ed root netem delay 45ms 10ms loss 1%
```

Remove impairment:

```bash
sudo tc qdisc del dev enx00051bcde7ed root
```

## 6) Teardown

```bash
sudo ./scripts/teardown_wan_emu.sh enx00051bcde7ed
```

## Important for real router integration

Many routers do not just look for "any gRPC" endpoint. They often expect:

- Specific service names
- Specific method names
- Exact protobuf message fields
- Sometimes TLS or vendor-specific endpoint discovery

If your router already has packet captures or logs showing expected gRPC services/methods, replace `grpc/starlink_mock.proto` with those exact definitions and re-generate stubs.
