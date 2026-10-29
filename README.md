# Razer Mouse for Omarchy

Battery percentage for a Razer mouse in the Omarchy bar, with a panel for DPI,
poll rate, idle time, low-battery threshold and lighting — all through the
OpenRazer daemon.

## Requirements

- `omarchy` 4.0.x with the Quickshell-based `omarchy-shell`
- `openrazer-daemon`, `openrazer-driver-dkms` and `python-openrazer`
- Your user in the `openrazer` group (log out and back in after adding yourself)
- A Razer mouse supported by OpenRazer, awake on its dongle or cable

The plugin talks to the daemon over the session bus only. It never touches
hidraw or sysfs, so it does not fight the driver for the device.

## Install

```bash
omarchy plugin add https://github.com/alexpazzo/plugin-razer-mouse-omarchy.git --enable
```

Manual install: clone this repository into `~/.config/omarchy/plugins/alexpazzo.razer-mouse`,
make `razer-bridge.py` executable, then:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/alexpazzo.razer-mouse
omarchy plugin enable alexpazzo.razer-mouse --section right
```

## Usage

The bar shows the Razer mark (the Nerd Font mouse glyph) before the reading:
`87%` while discharging and `87%+` while charging; `--` means the daemon or the
device did not answer. Left click opens the panel — whose hero repeats the mark
beside the full device name — and middle click forces a fresh reading.

A sleeping wireless mouse keeps the driver bound but reports zeros for every
hardware field. The plugin treats that as "unknown" rather than 0 %: the bar
shows `--`, the panel explains that the mouse is asleep, and writes are refused
instead of being silently dropped. Move the mouse to wake it and values return
on the next poll.

In the panel:

- **DPI** — logarithmic slider from 100 to the mouse's maximum, with the value
  updating while you drag and one write per release; the chips (400, 800, 1600,
  3200, 6400 — filtered by the sensor ceiling) jump straight to the usual
  stops, and a drag that ends near one snaps onto it
- **Poll rate** — 125, 500 or 1000 Hz
- **Idle prima dello sleep** — when the mouse goes to sleep, 60–900 s
- **Soglia batteria scarica** — 5–25 % (see Limits)
- **Luminosità** — the last value written, not an hardware read-back
- **Effetto** — `none`, `spectrum`, `wave` or `static` (static writes red)

## Limits

- Brightness is read from the daemon's cache, so the panel labels it as the last
  value set rather than the current hardware state.
- Poll rate 125/500/1000 only. The daemon accepts 250 Hz, but the kernel driver
  maps it to 500 Hz, so the plugin refuses it.
- The low-battery threshold is writable only in the 5–25 % range: the kernel
  clamps the raw value (12–63) and the live 30 % cannot be rewritten from here.
- No DPI stages, LED zones or scroll-mode settings: this model does not expose
  them through OpenRazer.
- With several Razer mice the plugin controls the first one (sorted by serial)
  and the panel reports how many were found.

## License

MIT — see [LICENSE](LICENSE).
