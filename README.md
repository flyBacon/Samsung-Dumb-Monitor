# Samsung Dumb Monitor

[中文](README.zh.md)

`Apparently, DDC/CI is too much to ask from these thousand-dollar smart monitors.`

A small native macOS menu bar utility for Samsung smart monitors, with a local Swift API and CLI.
Input switching, power, volume, mute and brightness.

Everything goes directly over the **local LAN**. No Samsung account login, SmartThings app, paid cloud API, or expiring PAT to babysit. Pair once on the monitor; the local token and certificate pin live in macOS Keychain. A compatible monitor with IP Remote enabled is required; this was created for the ViewFinity S9 and hasn't been tested on other Samsung smart monitors.

## Build & use

Download the DMG for your Mac from [Releases](../../releases), open it and drag `Dumb Monitor.app` to Applications (macOS 14+). If macOS blocks:

```sh
xattr -dr com.apple.quarantine "/Applications/Dumb Monitor.app"
```

Or build from source with Swift 6 / Xcode 16 or newer. No package dependencies.

```sh
./build.sh
swift test -c release
```

Local builds use your Apple Development identity automatically if exactly one is available. Otherwise, set `CODE_SIGN_IDENTITY` to the same Apple code-signing identity on each build so macOS can recognize updates and retain Accessibility permission.

Open `Dumb Monitor.app` (`build/` for a source build), enter your monitor's LAN address and approve pairing on the monitor.

Keyboard control needs Accessibility permission.
Volume keys follow the selected audio output. An optional setting also routes them to the connected monitor while it shows another input, such as DisplayPort. Brightness keys follow the active display.

Assign shortcuts to inputs, Power On and Standby. Input switching sends `powerOn` first by default (optional); it waits only for the command response, with no extra wake polling or delay.

Media shortcuts let you switch inputs and control power from the lock screen.

Login launch, hidden icon, volume limit and integer steps are configurable.

The CLI shares the app's pairing. Or pair from the terminal (`monitor.local` is a placeholder):

```sh
./build/s9-input pair monitor.local
./build/s9-input status
./build/s9-input power-status
./build/s9-input power-on
./build/s9-input power-off
./build/s9-input usb-c
./build/s9-input displayport
./build/s9-input input HDMI1  # example for a compatible HDMI device
./build/s9-input volume 20
./build/s9-input mute
./build/s9-input unmute
./build/s9-input brightness 25
./build/s9-input --help
```

## What it sends

JSON-RPC via HTTPS to port **1516**, with a pinned monitor certificate:

```json
{"jsonrpc":"2.0","id":"1","method":"inputSourceControl","params":{"AccessToken":"<local-token>","inputSource":"USB-C"}}
```

| Method | Setter parameter |
| --- | --- |
| `powerControl` | `power`: `powerOn` or `powerOff` |
| `inputSourceControl` | `inputSource`: `USB-C`, `Display Port`, or a configured exact value |
| `directVolumeControl` | `volume`: 0–100 |
| `muteControl` | `mute`: `muteOn` or `muteOff` |
| `backlightControl` | `backlight`: 0–50 |

CLI input commands stay direct; run `power-on` first when needed.

Omit the setter parameter to read. Pairing uses `getTVStates` then `createAccessToken`.
No remote-menu navigation. Firmware updates may change this unofficial interface.

## Remove

To remove the app, use **Settings → Clear Local Data and Quit…**, then drag it to the Trash.
This disables login launch and deletes settings, caches and the pairing shared with the CLI.
Remove Accessibility/firewall entries and separate CLI copies or credential backups yourself.
Monitor-side authorization is not revoked.

## License

[MPL-2.0](LICENSE). Commercial integration is welcome; please keep these monitor controls available without a paid unlock. No affiliation with Samsung.
