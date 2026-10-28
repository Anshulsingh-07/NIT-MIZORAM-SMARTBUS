#!/usr/bin/env python3
import argparse
import os
import json
import random
import time
from datetime import datetime, timezone
from urllib import error, request


def send_packet(url, api_key, payload, timeout):
    body = json.dumps(payload).encode("utf-8")
    req = request.Request(
        url=url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
        },
    )
    with request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8")


def main():
    parser = argparse.ArgumentParser(
        description="Send random ESP32-like GPS coordinates to telemetry endpoint."
    )
    parser.add_argument(
        "--target-host",
        default="127.0.0.1",
        help="Telemetry server host/IP (default is for local development)",
    )
    parser.add_argument("--port", type=int, default=8080, help="Local Node backend port")
    parser.add_argument(
        "--url",
        default=os.environ.get("SMARTBUS_TELEMETRY_URL"),
        help="Full telemetry endpoint URL; supports deployed HTTPS endpoints",
    )
    parser.add_argument("--interval", type=float, default=2.0, help="Seconds between sends")
    parser.add_argument("--bus-id", default="Bus 5", help="bus_id value")
    parser.add_argument("--device-id", default="ESP32-Device-1", help="device_id value")
    parser.add_argument("--api-key", default=os.environ.get("API_SECRET_KEY"), help="x-api-key header")
    parser.add_argument("--lat", type=float, default=23.7271, help="Start latitude")
    parser.add_argument("--lng", type=float, default=92.7176, help="Start longitude")
    parser.add_argument("--step", type=float, default=0.00035, help="Random movement step size")
    parser.add_argument("--speed-min", type=float, default=8.0, help="Minimum random speed")
    parser.add_argument("--speed-max", type=float, default=28.0, help="Maximum random speed")
    parser.add_argument("--count", type=int, default=0, help="Number of packets (0 = infinite)")
    parser.add_argument("--timeout", type=float, default=6.0, help="HTTP timeout seconds")
    args = parser.parse_args()
    if not args.api_key:
        parser.error("Set --api-key or API_SECRET_KEY")

    lat = args.lat
    lng = args.lng
    sent = 0

    url = args.url or f"http://{args.target_host}:{args.port}/api/update-location"
    print(f"Sending random telemetry to {url}")
    print("Press Ctrl+C to stop.\n")

    try:
        while True:
            lat += random.uniform(-args.step, args.step)
            lng += random.uniform(-args.step, args.step)
            speed = round(random.uniform(args.speed_min, args.speed_max), 1)

            payload = {
                "device_id": args.device_id,
                "bus_id": args.bus_id,
                "lat": round(lat, 6),
                "lng": round(lng, 6),
                "speed": speed,
                "accuracy": round(random.uniform(0.7, 1.5), 2),
                "ts": datetime.now(timezone.utc).isoformat(),
                "status": "moving" if speed > 1 else "idle",
            }

            try:
                status, body = send_packet(url, args.api_key, payload, args.timeout)
                print(f"[{datetime.now().strftime('%H:%M:%S')}] {status} lat={payload['lat']} lng={payload['lng']} speed={payload['speed']} -> {body}")
            except error.HTTPError as http_err:
                err_body = http_err.read().decode("utf-8", errors="ignore")
                print(f"HTTP {http_err.code}: {err_body}")
            except Exception as exc:
                print(f"Send failed: {exc}")

            sent += 1
            if args.count > 0 and sent >= args.count:
                break

            time.sleep(max(args.interval, 0.2))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
