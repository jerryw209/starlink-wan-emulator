#!/usr/bin/env python3
"""Mock Starlink dish gRPC server.

Implements SpaceX.API.Device.Device/Handle with realistic
DishGetStatusResponse so that routers (e.g. Peplink) recognise
this host as a Starlink user terminal.

Default listen address: 192.168.100.1:9200

Scenes:
  connected      - Normal connected state (default)
  no_account     - Disablement: no active account
  too_far        - Disablement: too far from service address
  in_ocean       - Disablement: in ocean
  blocked_country- Disablement: blocked country
  data_overage_sandbox - Disablement: data overage sandbox policy
  cell_disabled  - Disablement: cell is disabled
  roam_restricted- Disablement: roam restricted
  unknown_location - Disablement: unknown location
  account_disabled - Disablement: account disabled
  unsupported_version - Disablement: unsupported version
  moving_too_fast- Disablement: moving too fast for policy
  aviation_flyover - Disablement: under aviation flyover limits
  blocked_area   - Disablement: blocked area
  searching      - Dish searching for satellites
  stowed         - Dish stowed
  obstructed     - Dish obstructed
  overage        - Bandwidth restricted due to data overage
"""
import argparse
import sys
import time
from concurrent import futures

import grpc
from grpc_reflection.v1alpha import reflection

# Generated stubs — run compile_spacex_proto.sh first
from spacex.api.device import device_pb2 as device_pb2
from spacex.api.device import device_pb2_grpc as device_pb2_grpc
from spacex.api.device import common_pb2 as common_pb2
from spacex.api.device import dish_pb2 as dish_pb2
from spacex.api.common.status import status_pb2 as status_pb2

# Scene presets: (DishState, DisablementCode, throughput_down, throughput_up, latency, drop_rate)
SCENES = {
    "connected": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.DISABLEMENT_OKAY,
        "down_bps": 180000000.0,
        "up_bps": 22000000.0,
        "latency_ms": 42.0,
        "drop_rate": 0.0,
    },
    "no_account": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.NO_ACTIVE_ACCOUNT,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "too_far": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.TOO_FAR_FROM_SERVICE_ADDRESS,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "in_ocean": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.IN_OCEAN,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "blocked_country": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.BLOCKED_COUNTRY,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "data_overage_sandbox": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.DATA_OVERAGE_SANDBOX_POLICY,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "cell_disabled": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.CELL_IS_DISABLED,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "roam_restricted": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.ROAM_RESTRICTED,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "unknown_location": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.UNKNOWN_LOCATION,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "account_disabled": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.ACCOUNT_DISABLED,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "unsupported_version": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.UNSUPPORTED_VERSION,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "moving_too_fast": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.MOVING_TOO_FAST_FOR_POLICY,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "aviation_flyover": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.UNDER_AVIATION_FLYOVER_LIMITS,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "blocked_area": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.BLOCKED_AREA,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "searching": {
        "state": dish_pb2.SEARCHING,
        "disablement_code": dish_pb2.DISABLEMENT_OKAY,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "stowed": {
        "state": dish_pb2.STOWED,
        "disablement_code": dish_pb2.DISABLEMENT_OKAY,
        "down_bps": 0.0,
        "up_bps": 0.0,
        "latency_ms": 0.0,
        "drop_rate": 1.0,
    },
    "obstructed": {
        "state": dish_pb2.OBSTRUCTED,
        "disablement_code": dish_pb2.DISABLEMENT_OKAY,
        "down_bps": 5000000.0,
        "up_bps": 1000000.0,
        "latency_ms": 120.0,
        "drop_rate": 0.3,
    },
    "overage": {
        "state": dish_pb2.CONNECTED,
        "disablement_code": dish_pb2.DISABLEMENT_OKAY,
        "down_bps": 5000000.0,
        "up_bps": 1000000.0,
        "latency_ms": 55.0,
        "drop_rate": 0.01,
        "dl_bandwidth_restricted": dish_pb2.OVERAGE_LIMIT,
        "ul_bandwidth_restricted": dish_pb2.OVERAGE_LIMIT,
    },
}


class DeviceServicer(device_pb2_grpc.DeviceServicer):
    """Implements the SpaceX.API.Device.Device service."""

    def __init__(self, scene: str = "connected") -> None:
        self.start_time = time.time()
        self.scene = SCENES.get(scene, SCENES["connected"])
        self.scene_name = scene

    def Handle(self, request, context):
        """Dispatch incoming Request to the appropriate handler."""

        req_field = request.WhichOneof("request")
        peer = context.peer() or "unknown"
        print(f"[gRPC] {peer} -> Handle(req_type={req_field}, id={request.id})", flush=True)

        if req_field == "get_status":
            return self._get_status(request)
        elif req_field == "get_device_info":
            return self._get_device_info(request)
        elif req_field == "reboot":
            return device_pb2.Response(id=request.id, reboot=device_pb2.RebootResponse())
        elif req_field == "get_history":
            return self._get_history(request)
        elif req_field == "get_location":
            return self._get_location(request)
        elif req_field == "dish_get_obstruction_map":
            return self._get_obstruction_map(request)
        else:
            print(f"[gRPC] UNIMPLEMENTED: {req_field} from {peer}", flush=True)
            context.set_code(grpc.StatusCode.UNIMPLEMENTED)
            context.set_details(f"Request type '{req_field}' not implemented in mock")
            return device_pb2.Response()

    # -- handlers ----------------------------------------------------------

    def _get_status(self, request):
        uptime = int(time.time() - self.start_time)
        s = self.scene

        # Build DishGetStatusResponse
        dish_status = dish_pb2.DishGetStatusResponse(
            device_info=common_pb2.DeviceInfo(
                id="ut01000000-00000000-00000000",
                hardware_version="rev3_proto2",
                software_version="mock-2024.01.01",
                country_code="TW",
            ),
            device_state=common_pb2.DeviceState(
                uptime_s=uptime,
            ),
            state=s["state"],
            alerts=dish_pb2.DishAlerts(
                motors_stuck=False,
                thermal_throttle=False,
                thermal_shutdown=False,
                mast_not_near_vertical=False,
                unexpected_location=False,
                slow_ethernet_speeds=False,
            ),
            snr=9.0,
            seconds_to_first_nonempty_slot=0.0,
            pop_ping_drop_rate=s["drop_rate"],
            downlink_throughput_bps=s["down_bps"],
            uplink_throughput_bps=s["up_bps"],
            pop_ping_latency_ms=s["latency_ms"],
            obstruction_stats=dish_pb2.DishObstructionStats(
                currently_obstructed=(s["state"] == dish_pb2.OBSTRUCTED),
                fraction_obstructed=0.0,
                valid_s=43200.0,
            ),
            stow_requested=(s["state"] == dish_pb2.STOWED),
        )

        # Only set disablement_code for non-connected scenes
        # (connected = leave as default 0, matching real Starlink behavior)
        if s["disablement_code"] != dish_pb2.DISABLEMENT_OKAY:
            dish_status.disablement_code = s["disablement_code"]

        # Bandwidth restriction (overage scene)
        if "dl_bandwidth_restricted" in s:
            dish_status.dl_bandwidth_restricted_reason = s["dl_bandwidth_restricted"]
        if "ul_bandwidth_restricted" in s:
            dish_status.ul_bandwidth_restricted_reason = s["ul_bandwidth_restricted"]

        return device_pb2.Response(
            id=request.id,
            api_version=4,
            dish_get_status=dish_status,
        )

    def _get_device_info(self, request):
        return device_pb2.Response(
            id=request.id,
            get_device_info=device_pb2.GetDeviceInfoResponse(
                device_info=common_pb2.DeviceInfo(
                    id="ut01000000-00000000-00000000",
                    hardware_version="rev3_proto2",
                    software_version="mock-2024.01.01",
                    country_code="TW",
                ),
            ),
        )

    def _get_history(self, request):
        return device_pb2.Response(
            id=request.id,
            dish_get_history=dish_pb2.DishGetHistoryResponse(
                current=900,
                pop_ping_drop_rate=[0.0] * 900,
                pop_ping_latency_ms=[42.0] * 900,
                downlink_throughput_bps=[180000000.0] * 900,
                uplink_throughput_bps=[22000000.0] * 900,
            ),
        )

    def _get_location(self, request):
        return device_pb2.Response(
            id=request.id,
            get_location=device_pb2.GetLocationResponse(
                lla=common_pb2.LLAPosition(lat=25.0330, lon=121.5654, alt=10.0),
            ),
        )

    def _get_obstruction_map(self, request):
        size = 123
        return device_pb2.Response(
            id=request.id,
            dish_get_obstruction_map=dish_pb2.DishGetObstructionMapResponse(
                num_rows=size,
                num_cols=size,
                snr=[1.0] * (size * size),
            ),
        )

    def Stream(self, request_iterator, context):
        """Bidirectional stream — wrap Handle for each incoming message."""
        for to_device in request_iterator:
            req = to_device.request
            resp = self.Handle(req, context)
            yield device_pb2.FromDevice(response=resp)


def serve(listen: str, scene: str = "connected") -> None:
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    device_pb2_grpc.add_DeviceServicer_to_server(DeviceServicer(scene), server)

    # Enable gRPC reflection so clients can discover services dynamically
    service_names = (
        device_pb2.DESCRIPTOR.services_by_name["Device"].full_name,
        reflection.SERVICE_NAME,
    )
    reflection.enable_server_reflection(service_names, server)

    server.add_insecure_port(listen)
    server.start()
    print(f"Mock Starlink gRPC (SpaceX.API.Device.Device) listening at {listen}")
    print(f"  Scene: {scene}")
    if scene in SCENES:
        s = SCENES[scene]
        state_name = dish_pb2.DishState.Name(s["state"])
        disable_name = dish_pb2.DisablementCode.Name(s["disablement_code"])
        print(f"  State: {state_name}, DisablementCode: {disable_name}")
    server.wait_for_termination()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock Starlink dish gRPC service")
    parser.add_argument(
        "--listen",
        default="192.168.100.1:9200",
        help="Listen address, default 192.168.100.1:9200",
    )
    parser.add_argument(
        "--scene",
        default="connected",
        choices=list(SCENES.keys()),
        help="Dish scene to simulate, default: connected",
    )
    args = parser.parse_args()
    serve(args.listen, args.scene)
