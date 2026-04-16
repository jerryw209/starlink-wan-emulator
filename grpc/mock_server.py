#!/usr/bin/env python3
import argparse
import time
from concurrent import futures

import grpc

import starlink_mock_pb2 as pb2
import starlink_mock_pb2_grpc as pb2_grpc


class DeviceService(pb2_grpc.DeviceServiceServicer):
    def __init__(self) -> None:
        self.start_time = time.time()

    def GetStatus(self, request: pb2.StatusRequest, context: grpc.ServicerContext) -> pb2.StatusReply:
        uptime = int(time.time() - self.start_time)
        return pb2.StatusReply(
            dish_id="DISH-MOCK-0001",
            state="ONLINE",
            down_mbps=180.5,
            up_mbps=22.3,
            latency_ms=42.0,
            uptime_sec=uptime,
        )

    def Reboot(self, request: pb2.RebootRequest, context: grpc.ServicerContext) -> pb2.RebootReply:
        return pb2.RebootReply(accepted=True)


def serve(listen: str) -> None:
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    pb2_grpc.add_DeviceServiceServicer_to_server(DeviceService(), server)
    server.add_insecure_port(listen)
    server.start()
    print(f"Mock Starlink gRPC listening at {listen}")
    server.wait_for_termination()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock Starlink-like gRPC service")
    parser.add_argument("--listen", default="0.0.0.0:50051", help="Listen address, default 0.0.0.0:50051")
    args = parser.parse_args()
    serve(args.listen)
