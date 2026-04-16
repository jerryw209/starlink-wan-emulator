#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PROTO_ROOT="$SCRIPT_DIR"

python3 -m grpc_tools.protoc \
  -I"$PROTO_ROOT" \
  --python_out="$PROTO_ROOT" \
  --grpc_python_out="$PROTO_ROOT" \
  spacex/api/common/status/status.proto \
  spacex/api/device/command.proto \
  spacex/api/device/common.proto \
  spacex/api/device/dish.proto \
  spacex/api/device/transceiver.proto \
  spacex/api/device/wifi_config.proto \
  spacex/api/device/wifi.proto \
  spacex/api/device/device.proto

echo "Generated SpaceX gRPC stubs under spacex/"
