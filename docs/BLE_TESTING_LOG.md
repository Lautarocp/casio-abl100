# Casio ABL-100WE BLE Testing Log

> **Historical (2026-09-26).** First attempts from Linux, before the connection worked. The current protocol is in [../PROTOCOL.md](../PROTOCOL.md).

**Date:** 2026-09-26  
**Hardware:** ThinkCentre M625q (Debian 12), Realtek Bluetooth adapter  
**Objective:** Validate BLE protocol UUIDs and connection feasibility

## Setup

- ✅ Installed `bluez`, `bluez-hcidump`, `bluez-tools`
- ✅ Bluetooth service running (systemctl: active)
- ✅ Adapter powered on: `XX:XX:XX:XX:XX:XX`

## Scanning Results

### BLE Scan (find mode active)
After activating "find mode" on Casio ABL-100WE, one device appeared:

```
Device: XX:XX:XX:XX:XX:XX (public)
Type: Public address
Paired: no
Manufacturer Data Key: 0x0014 (Apple?)
```

**Note:** Device appears in scan, but identity unknown — could be Casio or other device in range.

## Connection Attempts

### bluetoothctl
- Status: **Failed** — `org.bluez.Error.Failed le-connection-abort-by-local`
- Possible causes:
  - Device may not accept bluetoothctl connections
  - Device may require specific pairing flow
  - Device may be in advertising-only mode (not GATT server mode)

### gatttool
- Status: **No response** (timeout 10s)
- Attempted: `--primary`, `--characteristics` discovery
- Possible causes: Same as above

## Session 2: Aggressive Testing (2026-09-26)

### Findings
1. ✅ Watch found once: **CASIO ABL-100WE**
2. ❌ **PERSISTENT BLOCKER:** `le-connection-abort-by-local` on all connection attempts
3. ❌ No GATT services visible in advertising data
4. ⚠️ Watch only advertises for ~10 seconds (maybe less) after "search" button press
5. ❌ Find Phone trigger also does not trigger connection window

### Tools Attempted
- `bluetoothctl` (standard connection) ❌
- `gatttool` (direct GATT) ❌
- `gatttool -I` (interactive mode) ❌
- `dbus-send` (DBus Layer) ❌
- Parallel connection attempts ❌
- Pre-loaded scanning ❌

### Conclusion
**Linux/bluez cannot connect to Casio ABL-100WE using standard BLE protocol.**

This is NOT:
- A timing issue (tried aggressive 10-second blitz)
- A scanning issue (device detected multiple times)
- A configuration issue (all standard methods attempted)

This IS likely:
- Proprietary connection flow required (Casio-specific)
- App-level pairing prerequisite
- bluez incompatibility with this model

## Next Steps

### Recommended: GShockAPI (Android)
GShockAPI proves ABL-100WE is connectable on Android. Strategy:
1. Download APK: https://github.com/izivkov/GShockAPI/releases
2. Install on Android device
3. Pair watch
4. Read their Kotlin source code for connection flow
5. Port `CasioConnectionFlow` to Swift directly

### Alternative: Verify from iPhone/macOS
1. Try Bluetooth pairing from iPhone Settings
2. If it connects there, issue is bluez-specific
3. If it doesn't, watch may need app-level setup first

### Alternative: Official Casio App
1. Download Casio G-Shock app (iOS/Android)
2. Pair watch through app
3. Capture BLE traffic (Wireshark/tcpdump)
4. Extract protocol from capture

## Unverified (pending connection)
- Service UUID: `26eb000d-b012-49a8-b1f8-394fb2032b0f`
- Button characteristic (0x10): byte[8]
- No checksum/encryption assumption

**BLOCKED by connection failure.**
