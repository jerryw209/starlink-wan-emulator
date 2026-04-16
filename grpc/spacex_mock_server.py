#!/usr/bin/env python3
"""Mock Starlink dish gRPC server.

Implements SpaceX.API.Device.Device/Handle with realistic
DishGetStatusResponse so that routers (e.g. Peplink) recognise
this host as a Starlink user terminal.

Default listen address: 192.168.100.1:9200
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


class DeviceServicer(device_pb2_grpc.DeviceServicer):
    """Implements the SpaceX.API.Device.Device service."""

    def __init__(self) -> None:
        self.start_time = time.time()

    def Handle(self, request, context):
        """Dispatch incoming Request to the appropriate handler."""

        req_field = request.WhichOneof("request")

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
            context.set_code(grpc.StatusCode.UNIMPLEMENTED)
            context.set_details(f"Request type '{req_field}' not implemented in mock")
            return device_pb2.Response()

    # -- handlers ----------------------------------------------------------

    def _get_status(self, request):
        uptime = int(time.time() - self.start_time)
        return device_pb2.Response(
            id=request.id,
            api_version=4,
            dish_get_status=dish_pb2.DishGetStatusResponse(
                device_info=common_pb2.DeviceInfo(
                    id="ut01000000-00000000-00000000",
                    hardware_version="rev3_proto2",
                    software_version="mock-2024.01.01",
                    country_code="TW",
                ),
                device_state=common_pb2.DeviceState(
                    uptime_s=uptime,
                ),
                state=dish_pb2.CONNECTED,
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
                pop_ping_drop_rate=0.0,
                downlink_throughput_bps=180000000.0,
                uplink_throughput_bps=22000000.0,
                pop_ping_latency_ms=42.0,
                obstruction_stats=dish_pb2.DishObstructionStats(
                    currently_obstructed=False,
                    fraction_obstructed=0.0,
                    valid_s=43200.0,
                ),
                stow_requested=False,
            ),
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


def serve(listen: str) -> None:
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    device_pb2_grpc.add_DeviceServicer_to_server(DeviceServicer(), server)

    # Enable gRPC reflection so clients can discover services dynamically
    service_names = (
        device_pb2.DESCRIPTOR.services_by_name["Device"].full_name,
        reflection.SERVICE_NAME,
    )
    reflection.enable_server_reflection(service_names, server)

    server.add_insecure_port(listen)
    server.start()
    print(f"Mock Starlink gRPC (SpaceX.API.Device.Device) listening at {listen}")
    server.wait_for_termination()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock Starlink dish gRPC service")
    parser.add_argument(
        "--listen",
        default="192.168.100.1:9200",
        help="Listen address, default 192.168.100.1:9200",
    )
    args = parser.parse_args()
    serve(args.listen)
