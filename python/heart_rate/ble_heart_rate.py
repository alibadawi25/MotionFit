"""BLE heart-rate ingestion for MotionFit (optional).

Reads live heart rate from a Bluetooth Low Energy chest strap or watch and makes
it available to `pose_server.py`, which forwards it in the packet's `hr` field.
Godot then fuses it with the player's profile (weight/age/sex) for a far more
accurate calorie estimate than motion alone -- but the boundary is unchanged:
this is data ingestion, not AI, and it still flows Python -> UDP -> Godot (see
CONTEXT.md §9). When no wearable is connected, `hr` stays 0 and Godot falls back
to the motion-based MET estimate automatically.

Targets the **standard Bluetooth Heart Rate Service** (GATT 0x180D, measurement
characteristic 0x2A37), which virtually every modern HR monitor exposes -- Polar
H9/H10, Wahoo Tickr, Garmin straps, Apple Watch (via broadcasters), CooSpo, etc.
No vendor SDK needed, so it is genuinely device-agnostic.

Requires `bleak` (`pip install -r python/requirements-hr.txt`). It is imported
lazily so the pose service runs fine without it.

Run standalone to scan/connect and print live BPM:
    python python/heart_rate/ble_heart_rate.py            # auto-pick first HR device
    python python/heart_rate/ble_heart_rate.py --address <MAC/UUID>
    python python/heart_rate/ble_heart_rate.py --scan     # just list nearby devices
"""
from __future__ import annotations

import asyncio
import threading
import time
from typing import Optional

# Standard GATT Heart Rate Service / Measurement characteristic UUIDs.
HR_SERVICE_UUID = "0000180d-0000-1000-8000-00805f9b34fb"
HR_MEASUREMENT_UUID = "00002a37-0000-1000-8000-00805f9b34fb"


def parse_hr_measurement(data: bytes) -> Optional[int]:
    """Decode a Heart Rate Measurement packet (GATT 0x2A37) to BPM.

    Byte 0 is a flags field; bit 0 selects the value format: 0 = the BPM is a
    single uint8 in byte 1, 1 = a little-endian uint16 in bytes 1-2. The rest of
    the packet (energy expended, RR intervals) is ignored here.
    """
    if not data:
        return None
    flags = data[0]
    if flags & 0x01:  # 16-bit heart rate value
        if len(data) < 3:
            return None
        return int.from_bytes(data[1:3], "little")
    if len(data) < 2:  # 8-bit heart rate value
        return None
    return data[1]


class HeartRateMonitor:
    """Background BLE heart-rate reader; exposes the latest BPM.

    Runs its own asyncio event loop on a daemon thread so the synchronous pose
    capture loop can just poll `.bpm` each frame. All failures are non-fatal:
    if `bleak` is missing, no device is found, or the link drops, `.bpm` simply
    stays 0.0 and `.error` explains why, so the pose service keeps running on
    the motion fallback.
    """

    def __init__(self, address: Optional[str] = None, stale_after: float = 5.0) -> None:
        self.address = address
        self.stale_after = stale_after  # treat readings older than this as gone
        self.bpm: float = 0.0
        self.connected: bool = False
        self.error: Optional[str] = None
        self._last_update: float = 0.0
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()

    def start(self) -> None:
        """Begin connecting/reading on a background thread (returns at once)."""
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="ble-hr", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def current_bpm(self) -> float:
        """Latest BPM, or 0.0 if never received or gone stale."""
        if self.bpm <= 0.0:
            return 0.0
        if time.time() - self._last_update > self.stale_after:
            return 0.0
        return self.bpm

    # --- internals -----------------------------------------------------------
    def _run(self) -> None:
        try:
            asyncio.run(self._loop())
        except Exception as exc:  # noqa: BLE001 - surface any failure, keep serving
            self.error = str(exc)
            self.connected = False

    async def _loop(self) -> None:
        try:
            from bleak import BleakClient, BleakScanner
        except ImportError:
            self.error = (
                "bleak not installed -- run 'pip install -r python/requirements-hr.txt' "
                "for heart-rate support"
            )
            return

        while not self._stop.is_set():
            address = self.address
            if address is None:
                device = await BleakScanner.find_device_by_filter(
                    lambda d, ad: HR_SERVICE_UUID in (ad.service_uuids or []),
                    timeout=10.0,
                )
                if device is None:
                    self.error = "no BLE heart-rate device found"
                    await asyncio.sleep(3.0)
                    continue
                address = device.address

            def _on_measurement(_char, data: bytearray) -> None:
                bpm = parse_hr_measurement(bytes(data))
                if bpm and bpm > 0:
                    self.bpm = float(bpm)
                    self._last_update = time.time()

            try:
                async with BleakClient(address) as client:
                    self.connected = True
                    self.error = None
                    await client.start_notify(HR_MEASUREMENT_UUID, _on_measurement)
                    while not self._stop.is_set() and client.is_connected:
                        await asyncio.sleep(0.2)
                    await client.stop_notify(HR_MEASUREMENT_UUID)
            except Exception as exc:  # noqa: BLE001 - reconnect on any drop
                self.error = str(exc)
            finally:
                self.connected = False
                self.bpm = 0.0
            if not self._stop.is_set():
                await asyncio.sleep(2.0)  # brief backoff, then try to reconnect


async def _scan_and_list() -> None:
    from bleak import BleakScanner

    print("Scanning 8s for BLE devices advertising the Heart Rate Service...")
    devices = await BleakScanner.discover(timeout=8.0, return_adv=True)
    found = False
    for dev, adv in devices.values():
        if HR_SERVICE_UUID in (adv.service_uuids or []):
            found = True
            print(f"  HR  {dev.address}  {dev.name or '(unnamed)'}  rssi={adv.rssi}")
    if not found:
        print("  none found -- make sure the strap is worn/awake and not paired elsewhere")


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="BLE heart-rate reader (standard GATT HRS).")
    parser.add_argument("--address", help="BLE MAC/UUID to connect to (else auto-pick).")
    parser.add_argument("--scan", action="store_true", help="Only list nearby HR devices.")
    args = parser.parse_args()

    if args.scan:
        asyncio.run(_scan_and_list())
        return

    mon = HeartRateMonitor(address=args.address)
    mon.start()
    print("Connecting to a heart-rate monitor... Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1.0)
            if mon.error:
                print(f"[hr] {mon.error}")
            else:
                print(f"[hr] {mon.current_bpm():.0f} bpm  (connected={mon.connected})")
    except KeyboardInterrupt:
        pass
    finally:
        mon.stop()


if __name__ == "__main__":
    main()
