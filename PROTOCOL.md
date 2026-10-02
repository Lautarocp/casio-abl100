# Casio ABL-100WE BLE protocol

Reference for the protocol as this app uses it. The main source is the code of
[GShockAPI](https://github.com/izivkov/GShockAPI) by Ivo Zivkov, which supports the ABL-100WE (`WatchModel.ABL_100`, module 3565).
Each item says whether it is **verified** on the real watch with our app or comes **from GShockAPI only**.

## GATT

Service: `26eb000d-b012-49a8-b1f8-394fb2032b0f`. The watch does not include it in its advertising.

| UUID | Name (GShockAPI) | Actual properties | Use |
|---|---|---|---|
| `26eb002c` | Read Request | writeNoResp | **GET**: write the code to request |
| `26eb002d` | All Features | write, notify | **SET**: write the full payload (with response). All responses arrive here as notifications |
| `26eb0023` | Data Request | write, notify | Lifelog (steps): start and end of the transaction, length announcement |
| `26eb0024` | Convoy | notify, writeNoResp | Lifelog (steps): the data arrives here in chunks |
| `26eb002e` | SP Request | writeNoResp | Unused. **Not for the time** (we used it by mistake at first) |
| `26eb002f` | SP Data | write, notify | Unused |

iOS can also return the standard `1804` service (Tx Power, characteristic `2A07`), even when discovering with the Casio UUID as filter.

## Format

- Each packet: `byte[0] = code` + data. No checksum or encryption.
- **GET**: write the code to `0x2C` (plus the index, if any), e.g. `1d 00`. The response arrives on `0x2D`.
- **SET**: write the full packet to `0x2D`, *with response*, in the same format as the GET response.
- **Error**: `ff <error code> <command>`, e.g. `ff 81 1e` = command `0x1e` rejected.

## Connection sequence (verified)

1. Long press of a button → the watch advertises and iOS connects (pending connect).
2. Enable notifications on `0x2D`.
3. Write the header `19 f8 fa f1` to `0x2C`, then request `10` (BLE_FEATURES). The header was found empirically: it is not in GShockAPI, but it works.
4. The watch answers `0x10` (which button started the connection). We answer every `0x10` with the header, `11` (SETTING_FOR_BLE) and `22` (APP_INFORMATION).
5. **Time sync** (see below). Without it, CNCT keeps blinking for about 3 minutes and the watch drops the connection on timeout.

## Button (`0x10`, byte 8)

Example: `10 34 d8 16 d9 6b da 7f 01 03 0f ff ff ff ff 18 00 00 00`

The codes come from `ButtonPressedIO.kt` in GShockAPI.

| Byte 8 | Button | Status |
|---|---|---|
| `0x01` | Lower left | ✅ verified |
| `0x04` | Lower right | ✅ verified |
| `0x02` | Lower right, long press (2+ s) | ✅ verified (GShockAPI calls it FIND_PHONE) |
| `0x00` | Reset | GShockAPI only |
| `0x03` | No button (auto time adjustment) | GShockAPI only |
| `0x0A/0B/0D/0E` | Always connected | GShockAPI only |

The watch can send `0x10` several times per connection: only the first one counts as a button press.

## Time sync (verified)

A port of GShockAPI's `TimeIO.set()` for the ABL-100 (dstCount = 1, worldCitiesCount = 2, no world cities or home time):

1. GET `1d 00` → response, e.g. `1d 00 01 03 00 e9 76 fe ff ff ff ff ff ff ff` → SET the same packet.
2. GET `1e 00` → `1e 00 e9 76 04 04 02` → SET the same packet.
3. GET `1e 01` → `1e 01 fe ff 00 00 00` → SET the same packet.
4. SET `09` + the time:

| Byte | Content |
|---|---|
| 1–2 | Year, **little-endian** (`ea 07` = 2026) |
| 3–7 | Month, day, hour, minute, second |
| 8 | **ISO** day of the week: Monday = 1 … Sunday = 7 |
| 9 | Fraction of a second × 256 |
| 10 | `01` |

Example: `09 ea 07 09 1c 10 30 26 01 7e 01` = Monday 28/09/2026, 16:48:38.

Writing `1D`/`1E` back unchanged keeps the time zone the watch already has. GShockAPI instead changes them to match the phone's time zone (`DstWatchStateIO.setDST`, `DstForWorldCitiesIO.setDST`); that is still to do, in case it is needed to change zones.

Several syncs in the same session work. If requests overlap, the watch answers `ff 81 1e`.

## Steps / lifelog (verified on the watch on 2026-09-29)

A separate transaction that does not use `0x2C`/`0x2D`:

1. Write `00 11 00 00 00` to `0x23` (Data Request), with response. `0x11` = "exercise" category.
2. The watch notifies on `0x23` `00 11 L0 L1 L2`: total length, little-endian (~400 bytes).
3. The data arrives in chunks on **`0x24`** (convoy). Accumulate until the announced length. Continuation chunks have no code, so they can't go through the first-byte dispatcher.
4. Close the transaction by writing `04 11 00 00 00` to `0x23`.

Payload format (`StepCounterIOFunctional.parse`), little-endian integers, with `0xFFFF`/`0xFFFFFFFE` meaning "no data":
- `[0..5]`: date and time in BCD (`26` = year 2026, then month, day, h, m, s).
- `[6..]`: 10-byte records, 5 u16 buckets each = steps per hour, from the most recent backwards.
- `[246..318]`: u16 distances. `[318..374]`: 7 days × (steps u32, distance u32).
- `[374]`: today's steps (u32). `[378]`: today's distance in meters (u32). `[382]`: 3 buckets of the current hour. `[392]`: pending distance. `[396]`: total in BCD.

Verified with 57 steps: the watch announces `00 11 90 01 00 00 00` (400 bytes) and sends it on `0x24` in chunks of 182 + 182 + 36. End of the record:
`39 00 00 00` (today = 57) `1d 00 00 00` (29 m) `05 00 13 00 21 00` (current hour buckets, adding up to 57) `00 00 00 00` (not interpreted) `1d 00 00 00` (pending distance) `57 00 00 00` (BCD total = 57).
- Closing with `04 11` doesn't erase anything: the watch keeps counting afterwards.
- With a freshly reset counter, the hourly records arrive as `00`; later, as `fe ff` (no data).
- Still to verify: the order of the 7 days (whether the first one is yesterday). This can only be checked after the watch closes a day.
- Verified on 2026-09-29 (read at 15:01): record 0 (`[6..16]`) is the **previous** hour (14 h = 53 steps, spread over its 5 buckets) and `[382]` is the current hour (15 h = 14). Total `[374]` = 265 = 198 (hours already delivered before) + 53 + 14; BCD `[396]` = `65 02` = 265.
- **Hourly records are delivered only once** (seen on 2026-09-29): another app read the lifelog (with records `3d 00 50 00…`) and closed with `04 11`; our read 3 s later got them as `fe ff`, although the day total (198) was still there. That's why the app keeps and merges its own history (`StepHistory`) and doesn't rely on the watch's records or daily summaries.

The 112-byte packets we saw on `0x24` with the official app connected were most likely these chunks.

## Alarms (reading and writing verified on 2026-09-29)

- GET `15` → `15 FLAG B HH MM` (alarm 1). GET `16` → `16` + 4 × `FLAG B HH MM` (alarms 2 to 5). Total: 5 alarms.
- FLAG (GShockAPI): `0x40` = enabled, `0x80` = hourly chime.
- With a freshly reset watch everything arrives as `00` (`15 00 00 00 00`, `16 00…`), byte B included. GShockAPI always writes B = `40`.
- SET: the same packets, to `0x2D`. Verified: after a SET of alarm 2 = 07:30 enabled and hourly chime on, on reconnect the watch returns `15 80 00 00 00` and `16 40 00 07 1e …`.
- Byte B always comes back as `00` even if `40` was written: the watch ignores it.

## Settings `0x13` (verified on 2026-09-29)

- GET `13` → 12 bytes, e.g. `13 16 01 00 00 00 00 00 00 00 00 00`. SET: the same packet, to `0x2D`.
- Byte 1: bit 0 = 24 h ✅ verified; bit 1 = button tone **off** ✅ verified; bit 4 = power saving **off** ✅ verified.
- Byte 2: bit 0 = long light ✅ verified.
- GShockAPI builds the packet from scratch; we start from the packet we read and change only those bits.

## Auto time adjustment `0x11` (reading verified, writing not verified)

- It's the same SETTING_FOR_BLE response as in the handshake: `11 24 48 24 06 04 50 00 04 00 01 00 00 1e 03`.
- Byte 12: `00` = enabled, `80` = disabled. Byte 13: the minute (`1e` = 30) at which the watch connects on its own to adjust the time (a `0x10` arrives with button `0x03`).
- SET: the packet we read, with bytes 12 and 13 changed.

## Timer `0x18` (verified on 2026-09-29)

- GET `18` → **15 bytes**: `18 HH MM SS` + 11 bytes of `00` (GShockAPI expects 7 in the standard protocol). SET: the same packet, to `0x2D`.
- Verified: `18 00 0a 00 …` = 10:00; SET `18 00 08 00 …` and reading again returns 08:00.

## Find phone `0x0A` (verified on 2026-09-29)

- Long press of the lower right button: the watch connects and sends `0a 02` (start searching) **before** the `0x10` with button `0x02`.
- When the search is stopped on the watch (or times out), it sends `0a 00` and drops the connection right away.
- The watch only signals: the app makes the sound. Verified in the background: the app rings on `0a 02` and stops on `0a 00` (16 s later in the test).

## End of session (verified on 2026-09-29)

With the full flow (handshake + time), the watch drops the connection by itself about 55 s later ("The specified device has disconnected from us"). Without the time sync, CNCT blinked for ~3 min until the timeout.

## Other codes

| Code | What it is | Status |
|---|---|---|
| `0x22` | APP_INFORMATION, `22 bb c3 ce f3 a2 f0 8a 4c e2 2b 01` | received. GShockAPI rewrites it with `22 95 00…` if it doesn't see the magic byte `0x95`; we leave it alone |
| `0x26` | ACTIVITY_RECORD | only seen requested by the official app; not decoded. Steps come from the lifelog (see above), not from here |
| `0x28` | WATCH_CONDITION | according to GShockAPI, the ABL-100 has neither battery level nor temperature |
| `0x20` | unknown | seen with the official app connected |
| `0x09` as GET | current time | the watch answers `0xFF`: the time can't be read |

## Things to keep in mind when testing

- **Another app connected at the same time** (the official Casio app, or an older build of ours with another bundle ID): packets arrive twice, responses we didn't ask for show up and, when requests overlap, the watch answers `ff 81 1e` and CNCT keeps blinking. The time sync is retried once and the other reads run even if it fails.
- **Official Casio app**: if it's connected at the same time, iOS delivers the `0x2D` notifications to both apps and its requests (`0x26`, `0x28`, `0x1d`, `0x1e`, repeated `0x10`…) show up in our logs. Close it before drawing conclusions.
- **Disconnections in CoreBluetooth**: `didDisconnect` with a nil error means our app asked for it. "The specified device has disconnected from us" means the watch dropped it.
- **Linux/bluez**: it connects and discovers the GATT, but reads return "NotPermitted" and there have been `le-connection-abort-by-local` drops. The iPhone is the reliable test platform.
