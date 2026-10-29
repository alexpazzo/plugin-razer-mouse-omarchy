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
omarchy plugin add git@github.com:alexpazzo/plugin-razer-mouse-omarchy.git --enable
```

Manual install: clone this repository into `~/.config/omarchy/plugins/alexpazzo.razer-mouse`,
make `razer-bridge.py` executable, then:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/alexpazzo.razer-mouse
omarchy plugin enable alexpazzo.razer-mouse --section right
```

## Usage

The bar shows `87%` while discharging and `87%+` while charging; `--` means the
daemon or the device did not answer. Left click opens the panel, middle click
forces a fresh reading.

In the panel:

- **DPI** — 100 to the mouse's maximum, applied on release
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
