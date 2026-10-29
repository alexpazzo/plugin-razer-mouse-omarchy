#!/usr/bin/python3
"""OpenRazer bridge for the Omarchy Razer mouse bar widget.

The OpenRazer daemon owns the device, so this is the only place the plugin
talks to hardware: everything goes through openrazer.client over the session
bus. No sysfs, no hidraw, no root.

Contract: exactly one JSON line on stdout, always.

    status                      -> {"ok": true, "count": N, "devices": [...]}
    set <key> <value>           -> {"ok": true, "key": ..., "value": "..."}

Failures:
    {"ok": false, "error": "<code>", "detail": "<text>"}

Exit codes: 0 ok, 2 daemon_unavailable, 3 no_device, 4 bad_usage,
5 write_failed (also used for the watchdog timeout).
"""

import json
import re
import signal
import sys
import traceback

EXIT_DAEMON_UNAVAILABLE = 2
EXIT_NO_DEVICE = 3
EXIT_BAD_USAGE = 4
EXIT_WRITE_FAILED = 5

TIMEOUT_SECONDS = 6

# 250 Hz is accepted by the daemon but the kernel driver maps it to 500 Hz, so
# it is never offered nor accepted here.
POLL_RATES = (125, 500, 1000)
EFFECTS = ("none", "spectrum", "wave")
DEFAULT_MAX_DPI = 30000
DPI_MIN = 100
IDLE_TIME_MIN, IDLE_TIME_MAX = 60, 900
LOW_BATTERY_MIN, LOW_BATTERY_MAX = 5, 25
BRIGHTNESS_MIN, BRIGHTNESS_MAX = 0, 100
COLOR_PATTERN = re.compile(r"^[0-9a-fA-F]{6}$")


def emit(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def fail(code, error, detail=""):
    emit({"ok": False, "error": error, "detail": detail})
    sys.exit(code)


def _on_alarm(signum, frame):
    fail(EXIT_WRITE_FAILED, "timeout",
         "openrazer did not answer within %d s" % TIMEOUT_SECONDS)


def collect(warnings, key, getter):
    """Run one field getter; a failure blanks the field and names the reason."""
    try:
        return getter()
    except Exception as exc:  # noqa: BLE001 - any daemon failure blanks a field
        warnings.append("%s: %s" % (key, type(exc).__name__))
        return None


def device_manager():
    from openrazer.client import DeviceManager
    from openrazer.client.device_manager import DaemonNotFound

    try:
        return DeviceManager()
    except DaemonNotFound as exc:
        fail(EXIT_DAEMON_UNAVAILABLE, "daemon_unavailable", str(exc))
    except Exception as exc:  # noqa: BLE001 - no client library, no daemon
        fail(EXIT_DAEMON_UNAVAILABLE, "daemon_unavailable",
             "%s: %s" % (type(exc).__name__, exc))


def pick_device(manager):
    mice = [d for d in manager.devices if d.type == "mouse"]
    if not mice:
        fail(EXIT_NO_DEVICE, "no_device",
             "openrazer exposes no mouse (daemon up, device asleep or absent)")

    def serial_key(dev):
        try:
            return str(dev.serial)
        except Exception:  # noqa: BLE001 - unreadable serial still sorts here
            return ""

    mice.sort(key=serial_key)
    return mice[0]


def status_dict(dev):
    warnings = []
    fields = {}

    fields["name"] = collect(warnings, "name", lambda: str(dev.name))
    fields["serial"] = collect(warnings, "serial", lambda: str(dev.serial))
    fields["firmware"] = collect(warnings, "firmware",
                                 lambda: str(dev.firmware_version))

    max_dpi = collect(warnings, "maxDpi", lambda: int(dev.max_dpi))
    fields["maxDpi"] = max_dpi if max_dpi else DEFAULT_MAX_DPI

    dpi = collect(warnings, "dpi", lambda: [int(v) for v in dev.dpi])
    fields["dpi"] = dpi if dpi and len(dpi) == 2 else None

    fields["pollRate"] = collect(warnings, "pollRate", lambda: int(dev.poll_rate))

    rates = collect(warnings, "pollRates", lambda: list(dev.supported_poll_rates))
    rates = [int(r) for r in rates if r in POLL_RATES] if rates else []
    fields["pollRates"] = rates if rates else list(POLL_RATES)

    fields["idleTime"] = collect(warnings, "idleTime",
                                 lambda: int(dev.get_idle_time()))
    fields["lowBatteryThreshold"] = collect(
        warnings, "lowBatteryThreshold", lambda: int(dev.get_low_battery_threshold()))
    fields["brightness"] = collect(warnings, "brightness",
                                   lambda: float(dev.brightness))
    fields["effect"] = collect(warnings, "effect", lambda: str(dev.fx.effect))

    battery = collect(warnings, "battery", lambda: int(round(dev.battery_level)))
    fields["battery"] = battery if battery is None else max(0, min(100, battery))
    charging = collect(warnings, "charging", lambda: bool(dev.is_charging))
    fields["charging"] = charging

    payload = {}
    for key in ("name", "serial", "firmware", "maxDpi", "dpi", "pollRate",
                "pollRates", "idleTime", "lowBatteryThreshold", "brightness",
                "effect", "battery", "charging"):
        payload[key] = fields[key]
    if warnings:
        payload["warnings"] = warnings

    # A sleeping wireless mouse keeps the driver bound but answers zeros to
    # every hardware read: DPI (0, 0), battery 0, not charging. Those are gaps,
    # not values — reporting them would paint "0 %" on the bar and drop the DPI
    # slider to the floor — so the live fields are reported as unknown and the
    # caller shows a "move the mouse" state instead.
    if payload["dpi"] == [0, 0] and payload["battery"] == 0 and payload["charging"] is not True:
        payload["asleep"] = True
        payload["battery"] = None
        payload["dpi"] = None
        payload["firmware"] = None
        payload["idleTime"] = None
        payload["lowBatteryThreshold"] = None
        payload["warnings"] = (payload.get("warnings") or []) + ["asleep: zeroed hardware report"]
    return payload


def is_asleep(dev):
    """True when the device answers zeros, i.e. the wireless link is idle."""
    try:
        return list(dev.dpi) == [0, 0]
    except Exception:  # noqa: BLE001 - unreadable DPI is not a sleep verdict
        return False


def parse_args(argv):
    """Validate the command line before touching the daemon."""
    if not argv or argv[0] == "status":
        if len(argv) > 1:
            fail(EXIT_BAD_USAGE, "bad_usage", "status takes no arguments")
        return ("status",)
    if argv[0] != "set":
        fail(EXIT_BAD_USAGE, "bad_usage", "unknown subcommand %r" % argv[0])
    if len(argv) != 3:
        fail(EXIT_BAD_USAGE, "bad_usage", "usage: set <key> <value>")

    key, raw = argv[1], argv[2]
    validate(key, raw)
    return ("set", key, raw)


def _as_int(key, raw):
    try:
        return int(raw)
    except (TypeError, ValueError):
        fail(EXIT_BAD_USAGE, "bad_usage",
             "%s expects an integer, got %r" % (key, raw))


def validate(key, raw):
    if key == "dpi":
        if _as_int(key, raw) < DPI_MIN:
            fail(EXIT_BAD_USAGE, "bad_usage", "dpi must be >= %d" % DPI_MIN)
    elif key == "poll_rate":
        if _as_int(key, raw) not in POLL_RATES:
            fail(EXIT_BAD_USAGE, "bad_usage",
                 "poll_rate must be one of 125, 500, 1000")
    elif key == "idle_time":
        value = _as_int(key, raw)
        if not IDLE_TIME_MIN <= value <= IDLE_TIME_MAX:
            fail(EXIT_BAD_USAGE, "bad_usage",
                 "idle_time must be %d..%d" % (IDLE_TIME_MIN, IDLE_TIME_MAX))
    elif key == "low_battery_threshold":
        value = _as_int(key, raw)
        if not LOW_BATTERY_MIN <= value <= LOW_BATTERY_MAX:
            fail(EXIT_BAD_USAGE, "bad_usage",
                 "low_battery_threshold must be %d..%d"
                 % (LOW_BATTERY_MIN, LOW_BATTERY_MAX))
    elif key == "brightness":
        value = _as_int(key, raw)
        if not BRIGHTNESS_MIN <= value <= BRIGHTNESS_MAX:
            fail(EXIT_BAD_USAGE, "bad_usage", "brightness must be 0..100")
    elif key == "effect":
        if raw not in EFFECTS:
            fail(EXIT_BAD_USAGE, "bad_usage",
                 "effect must be one of %s" % ", ".join(EFFECTS))
    elif key == "color":
        if not COLOR_PATTERN.match(raw):
            fail(EXIT_BAD_USAGE, "bad_usage", "color must be RRGGBB")
    else:
        fail(EXIT_BAD_USAGE, "bad_usage", "unknown key %r" % key)


def apply(dev, key, raw):
    if key == "dpi":
        limit = DEFAULT_MAX_DPI
        try:
            limit = int(dev.max_dpi)
        except Exception:  # noqa: BLE001 - fall back to the known ceiling
            pass
        value = max(DPI_MIN, min(limit, int(raw)))
        dev.dpi = (value, value)
    elif key == "poll_rate":
        dev.poll_rate = int(raw)
    elif key == "idle_time":
        dev.set_idle_time(int(raw))
    elif key == "low_battery_threshold":
        dev.set_low_battery_threshold(int(raw))
    elif key == "brightness":
        dev.brightness = int(raw)
    elif key == "effect":
        if raw == "none":
            dev.fx.none()
        elif raw == "spectrum":
            dev.fx.spectrum()
        else:
            dev.fx.wave(1)
    elif key == "color":
        dev.fx.static(int(raw[0:2], 16), int(raw[2:4], 16), int(raw[4:6], 16))


def main():
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(TIMEOUT_SECONDS)

    command = parse_args(sys.argv[1:])
    dev = pick_device(device_manager())

    if command[0] == "status":
        emit({"ok": True, "count": 1, "devices": [status_dict(dev)]})
        return

    _, key, raw = command
    # A sleeping mouse accepts writes and silently drops them, so a "set" that
    # looks successful would be a lie. Refuse instead of pretending.
    if is_asleep(dev):
        fail(EXIT_WRITE_FAILED, "write_failed",
             "mouse asleep: no DPI report, move it to wake")
    try:
        apply(dev, key, raw)
    except Exception as exc:  # noqa: BLE001 - report, never crash the caller
        traceback.print_exc(file=sys.stderr)
        fail(EXIT_WRITE_FAILED, "write_failed",
             "%s: %s" % (type(exc).__name__, exc))
    emit({"ok": True, "key": key, "value": str(raw)})


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - last line of defence for stdout
        traceback.print_exc(file=sys.stderr)
        fail(EXIT_WRITE_FAILED, "write_failed",
             "%s: %s" % (type(exc).__name__, exc))
