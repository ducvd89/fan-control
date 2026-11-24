# Fan Control

A menu bar app for Apple Silicon (and Intel) MacBooks that drives the fans from custom temperature curves.

- **Menu bar:** shows the hottest temperature and the average fan speed, e.g. `67° 2450`. The fan icon is filled while a custom curve is in control and outlined under System Auto.
- **Profiles:** System Auto, Silent, Balanced, Performance and Full Blast come built in. You can add, duplicate, rename, reorder and delete profiles.
- **Fast switching:** click a profile in the menu, or use **⌃⌥⌘1–9** to pick a profile and **⌃⌥⌘0** to move to the next one.
- **Curve editor:** drag points, double-click to add one, and press Delete or right-click to remove one. There is also a table for exact values. While you edit, the live temperature and the current fan level appear on the graph.
- **Temperature source:** the curve follows the hottest sensor in the groups you pick (CPU and GPU by default). You can add memory, storage, battery, ambient and other groups.
- **Smooth behaviour:** fans speed up immediately and slow down at a rate you set, so they don't keep hunting up and down.

## Build

You need Xcode installed. The Command Line Tools on their own can't build it, because they don't include SwiftUI's macro plugins.

```bash
./scripts/build-app.sh
```

```bash
open build/FanControl.app
```

## Helper (needed to set fan speeds)

Any user can read sensors, but only root can write fan speeds. Open the menu and click **Install Helper…**, or go to Settings → Privileged helper. macOS asks for your admin password once. This installs:

- `/Library/PrivilegedHelperTools/local.fancontrol.helper`
- `/Library/LaunchDaemons/local.fancontrol.helper.plist`. It listens on `/var/run/fancontrol.sock` and logs to `/var/log/fancontrol-helper.log`.

The helper only applies the speeds the app sends, clamped to each fan's own min/max. It returns every fan to automatic control when:
- the app quits or disconnects,
- the app sends nothing for 20 s (for example after a hang or crash),
- the helper itself is stopped.

To remove it, use **Uninstall Helper…** in Settings, or run:

```bash
sudo ./Resources/helper.sh uninstall
```

## Curve levels

- `0%` means "fans off". MacBook fans normally rest at 0 rpm.
- `1–100%` maps linearly onto the fan's min…max speed (2317–7826 rpm on an M5 Pro).

## Debugging

```bash
.build/release/FanControlHelper --list
```

This prints every temperature sensor and fan reading, and works without root.

## Layout

| Path | What |
|---|---|
| `Sources/SMCKit` | AppleSMC access: key read/write, sensor enumeration, fan mode control (incl. `Ftst` unlock on newer chips) |
| `Sources/FanControlHelper` | Root daemon, Unix-socket protocol, watchdog |
| `Sources/FanControl` | SwiftUI menu bar app: profiles, curve editor, controller loop, hot keys |
| `Resources/helper.sh` | LaunchDaemon install/uninstall |
