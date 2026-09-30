# Wi-Fi discovery probe

This read-only probe reports the count of attached USB product labels recognizable as iPhone, iPad, or iPod, plus active Bonjour advertisements for Apple's `_apple-mobdev2._tcp` service. It parses `ioreg -p IOUSB -a` plist product-name fields and ignores generic Apple peripherals. It never prints device names, identifiers, addresses, or raw system command output. Service discovery only establishes that something advertises the service; it does not grant media-library access.

## Setup and run

1. Use an iPhone that has already been paired and trusted with this Mac over USB. Keep both devices on the same local Wi-Fi network.
2. In Finder, select the iPhone and enable **Show this iPhone when on Wi-Fi** if that option is available. This is a manual Finder setting; the probe does not alter pairing or sync settings.
3. From the repository root, run:

   ```sh
   python3 scripts/diagnose-environment.py --browse-seconds 5
   ```

The command prints one JSON object with tool availability, macOS version, recognizable USB iOS product count, and the number of currently advertised mobile-device Bonjour services observed during the bounded browse. A malformed ioreg plist returns a null count and error status; a normal browse window ends with status `window_complete` and can report events received before the deadline. An unexpected nonzero `dns-sd` exit returns a null count and error status. No packages or phone apps are required.

A positive Bonjour count is only a feasibility signal. Finder presence alone is insufficient, and real paired iPhone Wi-Fi reading of the photo library remains unproven until the app can enumerate and transfer media over that path. The USB count recognizes product labels containing iPhone, iPad, or iPod; unrecognized/localized product labels are not counted.

Run parser-only tests without probing devices:

```sh
python3 -m unittest discover -s Tests/EnvironmentDiagnostics -v
```
