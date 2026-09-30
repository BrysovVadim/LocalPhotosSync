# Wi-Fi discovery probe

This read-only probe reports the count of attached USB product labels recognizable as iPhone, iPad, or iPod, active Bonjour advertisements for Apple's `_apple-mobdev2._tcp` service, and aggregate USB/Network/unknown transport counts from the local usbmuxd `ListDevices` request. It parses `ioreg -p IOUSB -a -l` product-name fields and ignores generic Apple peripherals. The `-l` option is required to include registry properties; archive output alone does not include product labels. The usbmuxd probe uses only the local AF_UNIX socket and the `ListDevices` message; it does not connect to a device or read pairing records. It never prints device names, identifiers, addresses, pairing data, or raw system command output. Bonjour advertisements indicate discovery only; the local usbmuxd count is a separate signal of transport availability.

## Setup and run

1. Use an iPhone that has already been paired and trusted with this Mac over USB. Keep both devices on the same local Wi-Fi network.
2. In Finder, select the iPhone and enable **Show this iPhone when on Wi-Fi** if that option is available. This is a manual Finder setting; the probe does not alter pairing or sync settings.
3. From the repository root, run:

   ```sh
   python3 scripts/diagnose-environment.py --browse-seconds 5
   ```

The command prints one JSON object with tool availability, macOS version, recognizable USB iOS product count, advertised Bonjour services, and `usbmuxd_devices.counts` (`usb`, `network`, and `unknown`). The usbmuxd request has one three-second deadline covering connection, send, and fragmented reads; it validates the v1/message-8 response header and a payload limit of 1 MiB. Missing socket, timeout, and malformed replies are reported as status values without including response data. A malformed ioreg plist returns a null count and error status; a normal browse window ends with status `window_complete` and can report events received before the deadline. An unexpected nonzero `dns-sd` exit returns a null count and error status. No packages or phone apps are required.

In the recorded check for this setup, Bonjour discovery returned 2 advertisements while usbmuxd `ListDevices` returned 0 devices. That means the advertisements did not correspond to a locally listed usable transport at that moment; it does not establish that Wi-Fi media access works.

A positive Bonjour count is only a feasibility signal. Finder presence alone is insufficient, and real paired iPhone Wi-Fi reading of the photo library remains unproven until the app can enumerate and transfer media over that path. The USB count recognizes product labels containing iPhone, iPad, or iPod; unrecognized/localized product labels are not counted.

Run parser-only tests without probing devices:

```sh
python3 -m unittest discover -s Tests/EnvironmentDiagnostics -v
```
