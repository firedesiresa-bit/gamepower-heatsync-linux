#!/usr/bin/env python3
"""Linux telemetry sender for the Gamepower HeatSync / USB35INCH display."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import serial

DEFAULT_PORT = "/dev/serial/by-id/usb-Turing_UsbMonitor_USB35INCHIPSV2-if00"
BAUD = 115200
PACKET_SIZE = 20
CMD_STATS = 0xA9


def clamp(value: float, low: int, high: int) -> int:
    return max(low, min(high, int(value)))


def read_cpu_temperature() -> int:
    """Return Ryzen Tctl in whole Celsius using lm-sensors JSON."""
    raw = subprocess.run(
        ["sensors", "-j"], check=True, capture_output=True, text=True, timeout=3
    ).stdout
    report = json.loads(raw)
    for chip, readings in report.items():
        if "k10temp" not in chip.lower():
            continue
        for wanted in ("Tctl", "Tdie"):
            entry = readings.get(wanted)
            if isinstance(entry, dict):
                for key, value in entry.items():
                    if key.endswith("_input") and key.startswith("temp"):
                        return clamp(float(value), 0, 99)
    raise RuntimeError("No k10temp Tctl/Tdie sensor found; check `sensors -j` output")


def read_gpu(index: int) -> tuple[int, int]:
    """Return GPU temperature (C) and utilization (%) from NVIDIA's CLI."""
    raw = subprocess.run(
        [
            "nvidia-smi", f"--id={index}",
            "--query-gpu=temperature.gpu,utilization.gpu",
            "--format=csv,noheader,nounits",
        ], check=True, capture_output=True, text=True, timeout=3
    ).stdout.strip().splitlines()
    if not raw:
        raise RuntimeError(f"nvidia-smi returned no GPU at index {index}")
    fields = [part.strip() for part in raw[0].split(",")]
    if len(fields) != 2:
        raise RuntimeError(f"Unexpected nvidia-smi output: {raw[0]!r}")
    return clamp(float(fields[0]), 0, 99), clamp(float(fields[1]), 0, 100)


def read_cpu_utilization(previous: tuple[int, int] | None) -> tuple[float, tuple[int, int]]:
    """Read CPU utilization from /proc/stat using the delta since the last poll."""
    fields = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
    ticks = [int(value) for value in fields]
    idle = ticks[3] + (ticks[4] if len(ticks) > 4 else 0)
    total = sum(ticks)
    current = (total, idle)
    if previous is None:
        return 0.0, current
    total_delta = total - previous[0]
    idle_delta = idle - previous[1]
    if total_delta <= 0:
        return 0.0, current
    return max(0.0, min(100.0, 100.0 * (total_delta - idle_delta) / total_delta)), current


def pack_command(command: int, x1: int, y1: int, x2: int, y2: int, body: bytes) -> bytes:
    """Pack Gamepower's five 10-bit header fields plus command byte and body."""
    values = [clamp(v, 0, 1023) for v in (x1, y1, x2, y2)]
    x1, y1, x2, y2 = values
    header = bytes((
        (x1 >> 2) & 0xFF,
        (((x1 & 0x03) << 6) | (y1 >> 4)) & 0xFF,
        (((y1 & 0x0F) << 4) | (x2 >> 6)) & 0xFF,
        (((x2 & 0x3F) << 2) | (y2 >> 8)) & 0xFF,
        y2 & 0xFF,
        command & 0xFF,
    ))
    packet = header + body
    if len(packet) != PACKET_SIZE:
        raise ValueError(f"expected {PACKET_SIZE}-byte stats packet, got {len(packet)}")
    return packet


def stats_packet(cpu_temp: int, gpu_temp: int, cpu_load: float, gpu_load: int) -> bytes:
    """Build observed 0xA9 dashboard packet for the holder's live stats panel."""
    body = bytearray(14)
    body[0] = cpu_temp // 10
    body[1] = cpu_temp % 10
    body[2] = gpu_temp // 10
    body[3] = gpu_temp % 10
    # The vendor animation increments these two slots 0..7. Map each usage meter
    # to those same eight observed steps so the blue bars reflect actual load.
    body[4] = clamp(round(cpu_load * 7 / 100), 0, 7)
    body[5] = clamp(round(gpu_load * 7 / 100), 0, 7)
    return pack_command(CMD_STATS, round(cpu_load), gpu_temp, round(cpu_load), 0, body)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--port", default=os.environ.get("HEATSYNC_PORT", DEFAULT_PORT),
        help="HeatSync serial device",
    )
    parser.add_argument("--gpu-index", type=int, default=0, help="nvidia-smi GPU index")
    parser.add_argument("--interval", type=float, default=1.0, help="update period in seconds")
    parser.add_argument("--once", action="store_true", help="send one live update and exit")
    args = parser.parse_args()
    if args.interval < 0.2:
        parser.error("--interval must be at least 0.2 seconds")
    if not os.path.exists(args.port):
        print(f"HeatSync serial port not found: {args.port}", file=sys.stderr)
        return 2

    try:
        with serial.Serial(
            args.port, baudrate=BAUD, bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
            timeout=0.2, xonxoff=False, rtscts=False, dsrdtr=False,
            exclusive=True,
        ) as device:
            device.dtr = True
            device.rts = True
            time.sleep(0.15)
            previous_cpu = None
            while True:
                cpu_load, previous_cpu = read_cpu_utilization(previous_cpu)
                cpu_temp = read_cpu_temperature()
                gpu_temp, gpu_load = read_gpu(args.gpu_index)
                packet = stats_packet(cpu_temp, gpu_temp, cpu_load, gpu_load)
                device.write(packet)
                device.flush()
                print(
                    f"{datetime.now().astimezone().strftime('%H:%M:%S')}  "
                    f"CPU {cpu_temp:02d}°C {cpu_load:4.0f}%  "
                    f"GPU {gpu_temp:02d}°C {gpu_load:3d}%  "
                    f"sent {packet.hex(' ')}",
                    flush=True,
                )
                if args.once:
                    return 0
                time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nHeatSync telemetry stopped.")
        return 0
    except (OSError, serial.SerialException, subprocess.SubprocessError, ValueError, RuntimeError) as exc:
        print(f"HeatSync update failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
