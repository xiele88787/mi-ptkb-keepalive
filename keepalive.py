#!/usr/bin/env python3
"""
Mi PTKB (Xiaomi Portable Dual-Mode Keyboard, VID=0x2717, PID=0x507C)
Smart Sweet-Spot Sleep & Mouse-Linked Pre-Wake Daemon for macOS.

Root-Cause Findings from macOS bluetoothd & IOKit Telemetry:
  1. Factory Deep Sleep (STATUS 719): Mi PTKB terminates its BLE connection after ~150s (2m38s)
     of zero traffic. Once disconnected, macOS bluetoothd only runs LeConnectionScanHigh
     (100% duty cycle, 30ms/30ms) for 6.0 seconds before FastConnectionScanTimer expires.
  2. Factory Shallow Sleep (Peripheral Latency = 22): Within 1~3s of no keystrokes,
     BLE RTT jumps from ~29ms to 215ms~585ms.
  3. Over-the-Air GATT Reset: Synchronous IOHIDDeviceGetReport(Output, ID=1) +
     IOHIDDeviceSetReport(Output, ID=1) toggles bit 4 (Kana LED, which has no physical LED
     on the 85-key Mi PTKB) and restores the exact CapsLock state, forcing an over-the-air
     ATT_READ_REQ/RSP + ATT_WRITE_REQ/RSP transaction that resets both the 150s deep-sleep
     timer and the shallow-sleep slave latency.

Three-Tier Power-Budgeted State Machine (within 2x Battery Budget):
  - Tier 1 [HOT / PRE-WAKE] (key_idle < 15s OR mouse_idle < 3s):
      Pulses every 3.5s (and immediately within 0.25s when the mouse moves after a pause),
      keeping keyboard RTT at ~29ms so switching from mouse to keyboard has zero lag.
  - Tier 2 [SWEET-SPOT KEEP-ALIVE] (any_idle < sweet_spot_minutes [default 20m] AND display awake):
      Pulses every 35s (well under the 150s factory disconnect timer) to prevent deep-sleep
      disconnection while reading, watching videos, or thinking at the desk.
  - Tier 3 [DEEP-SLEEP RELEASE] (any_idle >= sweet_spot_minutes OR display asleep):
      Stops all pulses immediately so the keyboard naturally enters factory deep sleep (STATUS 719)
      after 2.5 minutes, consuming zero extra battery overnight or when away from the Mac.
"""

import argparse
import ctypes
from ctypes import c_void_p, c_int, c_int32, c_uint32, c_long, c_double, c_char_p, c_uint8, POINTER, byref
import sys
import time

VENDOR_ID = 0x2717   # Xiaomi Inc.
PRODUCT_ID = 0x507C  # Mi PTKB (XMBXJP01YM)
KIOHID_REPORT_TYPE_OUTPUT = 1
REPORT_ID_KEYBOARD = 1
KANA_BIT_MASK = 0x10  # UsagePage 0x08, Usage 0x05 (Kana - no physical LED on Mi PTKB)

cf = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
iokit = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/IOKit.framework/IOKit")
cg = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")

cf.CFStringCreateWithCString.restype = c_void_p
cf.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint32]
cf.CFNumberCreate.restype = c_void_p
cf.CFNumberCreate.argtypes = [c_void_p, c_long, c_void_p]
cf.CFDictionaryCreate.restype = c_void_p
cf.CFDictionaryCreate.argtypes = [c_void_p, POINTER(c_void_p), POINTER(c_void_p), c_long, c_void_p, c_void_p]
cf.CFSetGetCount.restype = c_long
cf.CFSetGetCount.argtypes = [c_void_p]
cf.CFSetGetValues.restype = None
cf.CFSetGetValues.argtypes = [c_void_p, POINTER(c_void_p)]
cf.CFRelease.restype = None
cf.CFRelease.argtypes = [c_void_p]

iokit.IOHIDManagerCreate.restype = c_void_p
iokit.IOHIDManagerCreate.argtypes = [c_void_p, c_uint32]
iokit.IOHIDManagerSetDeviceMatching.argtypes = [c_void_p, c_void_p]
iokit.IOHIDManagerCopyDevices.restype = c_void_p
iokit.IOHIDManagerCopyDevices.argtypes = [c_void_p]
iokit.IOHIDDeviceOpen.restype = c_int
iokit.IOHIDDeviceOpen.argtypes = [c_void_p, c_uint32]
iokit.IOHIDDeviceClose.restype = c_int
iokit.IOHIDDeviceClose.argtypes = [c_void_p, c_uint32]
iokit.IOHIDDeviceGetReport.restype = c_int
iokit.IOHIDDeviceGetReport.argtypes = [c_void_p, c_int, c_long, c_void_p, POINTER(c_long)]
iokit.IOHIDDeviceSetReport.restype = c_int
iokit.IOHIDDeviceSetReport.argtypes = [c_void_p, c_int, c_long, c_void_p, c_long]

cg.CGEventSourceSecondsSinceLastEventType.restype = c_double
cg.CGEventSourceSecondsSinceLastEventType.argtypes = [c_int32, c_uint32]
cg.CGMainDisplayID.restype = c_uint32
cg.CGDisplayIsAsleep.restype = c_uint32
cg.CGDisplayIsAsleep.argtypes = [c_uint32]


def cfstr(s: str) -> c_void_p:
    return cf.CFStringCreateWithCString(None, s.encode("utf-8"), 0x08000100)


def cfnum(n: int) -> c_void_p:
    val = c_int(n)
    return cf.CFNumberCreate(None, 9, byref(val))


def get_system_activity() -> tuple[float, float, float, bool]:
    """Return (any_idle_sec, key_idle_sec, mouse_idle_sec, display_asleep)."""
    any_idle = float(cg.CGEventSourceSecondsSinceLastEventType(1, 0xFFFFFFFF))
    key_idle = float(min(
        cg.CGEventSourceSecondsSinceLastEventType(1, 10),  # KeyDown
        cg.CGEventSourceSecondsSinceLastEventType(1, 11),  # KeyUp
        cg.CGEventSourceSecondsSinceLastEventType(1, 12),  # FlagsChanged
    ))
    mouse_idle = float(min(
        cg.CGEventSourceSecondsSinceLastEventType(1, 5),   # MouseMoved
        cg.CGEventSourceSecondsSinceLastEventType(1, 1),   # LeftMouseDown
        cg.CGEventSourceSecondsSinceLastEventType(1, 3),   # RightMouseDown
        cg.CGEventSourceSecondsSinceLastEventType(1, 22),  # ScrollWheel
    ))
    display_asleep = bool(cg.CGDisplayIsAsleep(cg.CGMainDisplayID()))
    return any_idle, key_idle, mouse_idle, display_asleep


def pulse_keyboard() -> tuple[bool, float, float]:
    """
    Perform an over-the-air BLE GATT Output Report read + write pulse.
    Returns (success, first_rtt_ms, second_rtt_ms).
    """
    mgr = iokit.IOHIDManagerCreate(None, 0)
    if not mgr:
        return False, 0.0, 0.0
    try:
        k_vid = cfstr("VendorID")
        k_pid = cfstr("ProductID")
        v_vid = cfnum(VENDOR_ID)
        v_pid = cfnum(PRODUCT_ID)
        keys = (c_void_p * 2)(k_vid, k_pid)
        vals = (c_void_p * 2)(v_vid, v_pid)
        match_dict = cf.CFDictionaryCreate(None, keys, vals, 2, None, None)
        iokit.IOHIDManagerSetDeviceMatching(mgr, match_dict)
        cf.CFRelease(match_dict)
        cf.CFRelease(k_vid)
        cf.CFRelease(k_pid)
        cf.CFRelease(v_vid)
        cf.CFRelease(v_pid)

        dev_set = iokit.IOHIDManagerCopyDevices(mgr)
        if not dev_set:
            return False, 0.0, 0.0
        try:
            cnt = cf.CFSetGetCount(dev_set)
            if cnt <= 0:
                return False, 0.0, 0.0
            devs = (c_void_p * cnt)()
            cf.CFSetGetValues(dev_set, devs)
            dev = devs[0]
            if iokit.IOHIDDeviceOpen(dev, 0) != 0:
                return False, 0.0, 0.0
            try:
                buf = (c_uint8 * 8)()
                length = c_long(8)
                t0 = time.perf_counter()
                gret = iokit.IOHIDDeviceGetReport(dev, KIOHID_REPORT_TYPE_OUTPUT, REPORT_ID_KEYBOARD, buf, byref(length))
                rtt1 = (time.perf_counter() - t0) * 1000.0
                cur_leds = buf[1] if (gret == 0 and length.value >= 2) else 0x00

                p1 = (c_uint8 * 2)(REPORT_ID_KEYBOARD, cur_leds ^ KANA_BIT_MASK)
                iokit.IOHIDDeviceSetReport(dev, KIOHID_REPORT_TYPE_OUTPUT, REPORT_ID_KEYBOARD, p1, 2)

                p0 = (c_uint8 * 2)(REPORT_ID_KEYBOARD, cur_leds)
                t1 = time.perf_counter()
                sret = iokit.IOHIDDeviceSetReport(dev, KIOHID_REPORT_TYPE_OUTPUT, REPORT_ID_KEYBOARD, p0, 2)
                rtt2 = (time.perf_counter() - t1) * 1000.0

                return (gret == 0 and sret == 0), rtt1, rtt2
            finally:
                iokit.IOHIDDeviceClose(dev, 0)
        finally:
            cf.CFRelease(dev_set)
    finally:
        cf.CFRelease(mgr)


def main():
    parser = argparse.ArgumentParser(description="Mi PTKB Smart Sweet-Spot & Mouse Pre-Wake Daemon")
    parser.add_argument("--sweet-spot-minutes", type=float, default=20.0,
                        help="Keep keyboard connected for N minutes after last user input (default: 20.0)")
    parser.add_argument("--hot-interval", type=float, default=3.5,
                        help="Heartbeat interval in seconds during active mouse/keyboard use (default: 3.5)")
    parser.add_argument("--warm-interval", type=float, default=35.0,
                        help="Heartbeat interval in seconds during passive reading within sweet-spot window (default: 35.0)")
    parser.add_argument("--once", action="store_true", help="Send a single heartbeat pulse and exit")
    args = parser.parse_args()

    if args.once:
        any_idle, key_idle, mouse_idle, disp_asleep = get_system_activity()
        ok, rtt1, rtt2 = pulse_keyboard()
        print(
            f"[mi-ptkb-keepalive] pulse={'OK' if ok else 'DISCONNECTED'} "
            f"wake_rtt={rtt1:.1f}ms active_rtt={rtt2:.1f}ms | "
            f"key_idle={key_idle:.1f}s mouse_idle={mouse_idle:.1f}s display_asleep={disp_asleep}"
        )
        sys.exit(0 if ok else 1)

    sweet_spot_sec = args.sweet_spot_minutes * 60.0
    print(
        f"[mi-ptkb-keepalive] smart daemon started: sweet_spot={args.sweet_spot_minutes:.0f}m, "
        f"hot_interval={args.hot_interval}s, warm_interval={args.warm_interval}s",
        flush=True,
    )

    last_pulse_ts = 0.0
    last_tier = ""
    was_connected = True

    while True:
        try:
            now = time.monotonic()
            any_idle, key_idle, mouse_idle, disp_asleep = get_system_activity()

            if disp_asleep or any_idle >= sweet_spot_sec:
                # Tier 3: User walked away or screen is asleep -> allow keyboard to enter factory deep sleep
                if last_tier != "DEEP_SLEEP_ALLOWED":
                    reason = "display_asleep" if disp_asleep else f"idle={any_idle/60.0:.1f}m>={args.sweet_spot_minutes:.0f}m"
                    print(f"[mi-ptkb-keepalive] -> Tier 3 (DEEP_SLEEP_ALLOWED: {reason}), pausing heartbeats", flush=True)
                    last_tier = "DEEP_SLEEP_ALLOWED"
                time.sleep(1.0)
                continue

            # Determine if user is actively interacting (mouse moving/clicking or recently typed)
            is_hot = (mouse_idle < 3.0) or (key_idle < 15.0)
            target_interval = args.hot_interval if is_hot else args.warm_interval
            new_tier = "TIER1_HOT" if is_hot else "TIER2_SWEET_SPOT"

            # Pre-wake immediately if mouse just moved after a warm pause or if keyboard just reconnected
            elapsed_since_pulse = now - last_pulse_ts
            should_pulse = (elapsed_since_pulse >= target_interval) or (not was_connected and any_idle < 5.0)

            if should_pulse:
                # Only send GATT pulse if user isn't mid-keystroke (<0.4s) to avoid colliding with typing burst
                if key_idle >= 0.4 or not was_connected:
                    ok, rtt1, rtt2 = pulse_keyboard()
                    last_pulse_ts = time.monotonic()
                    if ok and not was_connected:
                        print(f"[mi-ptkb-keepalive] keyboard reconnected & pre-warmed (rtt={rtt1:.1f}ms->{rtt2:.1f}ms)", flush=True)
                    was_connected = ok
                    if new_tier != last_tier:
                        print(
                            f"[mi-ptkb-keepalive] -> {new_tier} (interval={target_interval}s, "
                            f"key_idle={key_idle:.1f}s, mouse_idle={mouse_idle:.1f}s, rtt={rtt1:.1f}ms->{rtt2:.1f}ms)",
                            flush=True,
                        )
                        last_tier = new_tier
        except Exception as e:
            print(f"[mi-ptkb-keepalive] error: {e}", flush=True)

        time.sleep(0.25)


if __name__ == "__main__":
    main()
