# SmartFitnessGlasses BLE Protocol (v1)

This document defines the BLE link between the SmartFitnessGlasses board and the
companion app. It is the contract the app must implement. It is written so the
app developer can build against it without reading the firmware.

ASCII only. All numbers on the wire are decimal text. No floats are sent; values
that need a fraction use fixed-point integers (documented per field).

## 0. Decisions made for v1

These are the choices made when writing this spec. They are easy to change, but
the app should be built against them as written:

- The wire format is **line-based ASCII**, not the 20-byte binary frames from the
  older `docs/communication_protocol.md`. That older doc does **not** apply to
  this project. This scheme is chosen because it is simple to parse in Dart,
  human-readable in a serial sniffer, and the data rates here are low.
- Live raw IR is streamed **decimated to 30 Hz**, batched several samples per
  line, to stay inside the RN4871 transparent-UART throughput.
- The live vitals summary (HR, SpO2, steps, temp) is sent **every 15 s**.
- History records are sent in **ascending timestamp order**; the app de-duplicates
  by timestamp.
- Extra commands beyond your `L` / `H` are defined: `T` (set time) and `C` (clear
  flash). These are needed for real timestamps and for the app's "clear" button.
- BLE device name is assumed to be `SmartGlasses` (see section 1). The current
  firmware actually advertises `BLE_SW_AG`; this will be renamed. Use whatever
  name section 1 finally states.

## 1. Transport

The board uses the Microchip RN4871 BLE module in **Transparent UART** mode. To
the app this looks like a Nordic-UART-style byte pipe.

| Item | Value |
| --- | --- |
| Advertised device name | `SmartGlasses` (planned; firmware currently `BLE_SW_AG`) |
| Transparent UART service | `49535343-FE7D-4AE5-8FA9-9FAFD205E455` |
| Board -> App (notify, app subscribes) | `49535343-1E4D-4BD9-BA61-23C647249616` |
| App -> Board (write) | `49535343-8841-43F4-A8D4-ECBE34729BB3` |

App link procedure:

1. Scan, find the device by name, connect.
2. Subscribe to the notify characteristic (board -> app).
3. Write commands to the write characteristic (app -> board).

The board only talks to the app while it is in **app mode** (red LED on, see the
firmware mode spec). It does not advertise in low-power or running mode.

## 2. Framing rules

- Every message in **both** directions is one **line** of ASCII text terminated
  by a single `\n` (0x0A). Any `\r` (0x0D) is ignored.
- Inside a line, fields are separated by commas `,`.
- The **first field is a one-letter tag** that identifies the message.
- BLE notifications can be merged or split. The app MUST keep a receive buffer,
  append every incoming chunk, and cut complete lines on each `\n`. Never assume
  one notification equals one line.
- Lines are short by design (worst case about 60 bytes for a long IR batch).

## 3. Field encodings

| Field | Meaning | Encoding |
| --- | --- | --- |
| `ts` | timestamp | uint32 decimal. RTC seconds. Unix epoch after `T` (set time); seconds-since-boot before. See section 7. |
| `temp_c100` | temperature | signed int, Celsius times 100. Example `3650` = 36.50 C. |
| `hr` | heart rate | uint8 bpm. `0` means no valid reading. |
| `spo2_x10` | blood oxygen | uint16, percent times 10. Example `975` = 97.5 percent. `0` means no valid reading. |
| `steps` | steps | uint16. In history records this is the steps taken **during that record's interval** (a delta). In the live vitals frame it is the **session cumulative** total. |
| `ir` | raw PPG IR | uint32, raw MAX30101 IR count, range 0..262143. |

## 4. Commands (App -> Board)

Send each command as a line ending in `\n`. Single-letter commands may also be
sent as just the letter; the firmware acts on the first known letter it sees, so
`L` and `L\n` both work. `T` needs the newline because it carries an argument.

| Command | Line | When the app sends it | Board reaction |
| --- | --- | --- | --- |
| Live | `L\n` | App opens the Live page | Board sends one `I` line, then begins the live stream (`P` + `V`). |
| History | `H\n` | App opens Storico, or Refresh pressed | Board stops the live stream, then sends `HBEGIN`, all `R` records, `HEND`. |
| Clear | `C\n` | Storico "Clear data" button | Board erases the stored history in flash and replies `C,OK\n`. |
| Set time | `T,<epoch>\n` | Right after connecting | Board sets its clock so future timestamps are real Unix time; replies `T,OK\n`. `<epoch>` is current Unix time in seconds, decimal. |

Notes:

- `L` and `H` are mutually exclusive states. `H` always stops live first.
- While streaming live or dumping history, the board keeps logging to flash on its
  own 30 s schedule. The app does not need to manage that.
- Unknown command letters are ignored (optionally answered with `E`, section 5).

## 5. Messages (Board -> App)

### I - info / hello

Sent once as the first line after an `L` command, so the app knows the time base
of the IR stream.

```
I,<proto_ver>,<ir_hz>,<vitals_period_s>
```

Example: `I,1,30,15` = protocol v1, IR streamed at 30 Hz nominal, vitals every 15 s.

### P - live raw IR batch

A batch of consecutive raw IR samples, oldest first. Up to 10 samples per line.

```
P,<ir1>,<ir2>,...,<irN>
```

Example: `P,118245,118260,118251,118233,118270`

The app appends these to its IR ring buffer and plots the smoothed waveform. The
sample spacing is `1 / ir_hz` seconds (30 Hz nominal from the `I` line).

### V - live vitals summary

Sent every 15 s while live streaming is active.

```
V,<ts>,<hr>,<spo2_x10>,<steps>,<temp_c100>
```

Here `steps` is the **session cumulative** total (for the live "tot passi"
display). Example: `V,1717593600,72,975,1840,3648`.

### History envelope and records

In response to `H`:

```
HBEGIN,<count>
R,<ts>,<temp_c100>,<hr>,<spo2_x10>,<steps>
R,<ts>,<temp_c100>,<hr>,<spo2_x10>,<steps>
...
HEND
```

- `HBEGIN` carries the number of `R` records that will follow (`0` is valid).
- Each `R` is one stored record, in **ascending `ts` order**.
- In `R`, `steps` is the **delta** for that interval (steps in that ~10 min or 30 s
  window), not a running total.
- `HEND` marks the end of the dump.

Example:

```
HBEGIN,3
R,1717593600,3648,71,974,12
R,1717594200,3650,0,0,5
R,1717594800,3661,68,981,40
HEND
```

(`hr=0, spo2=0` in the middle record means no valid PPG reading that interval, for
example the glasses were not being worn.)

### E - error (optional)

```
E,<text>
```

Free text reason, e.g. `E,busy`. The app may log and ignore it.

## 6. Typical flows

### Connect and set time

```
app:   (connect, subscribe)
app -> T,1717593600
board -> T,OK
```

The app should set time immediately on every connection so newly logged records
get real wall-clock timestamps.

### Live page

```
app -> L
board -> I,1,30,15
board -> P,118245,118260,...        (continuous, ~5 lines/sec)
board -> V,1717593605,72,975,1840,3648   (every 15 s)
board -> P,...
board -> V,...
```

When the app leaves the Live page it can send `H` (which stops live) or just stop
reading. To resume, send `L` again.

### Storico page (history)

```
app -> H
board -> HBEGIN,128
board -> R,...        (128 lines, ascending ts)
board -> HEND
```

- **Refresh**: send `H` again to re-pull. The app merges by timestamp (see dedup).
- **Clear data**: see section 8 for what "clear" should target.

### De-duplication and saving to the phone

- The de-dup key is the record **timestamp `ts`**. Records arrive in ascending
  order, so the app keeps the highest `ts` it has stored and ignores any `R` with
  `ts <=` that value on the next refresh.
- The app persists all unique records locally (file or DB) so the Storico graphs
  (HR, SpO2, cumulative steps per half hour, temperature) survive across sessions.

## 7. Timestamps and time sync (read this)

The board has no battery-backed clock. Its RTC is a free-running seconds counter:

- **Before** the app sends `T`, `ts` is **seconds since the board powered on** (a
  small number, e.g. `0..something`).
- **After** `T,<epoch>`, the firmware offsets the counter so new records and live
  frames carry real Unix epoch seconds.
- `T` only affects timestamps produced **after** it is received. Records that were
  already stored in flash keep their boot-relative `ts`.

Practical guidance for the app:

- Send `T` on connect, before it matters.
- When reading history you may see a mix: small boot-relative values (logged before
  any sync, or after a power cycle that was never synced) and large epoch values.
  Treat `ts < 1000000000` (before year 2001) as "unsynced / relative" and either
  hide those points or label them as such.

This is a known prototype limitation, acceptable for the demo, and called out here
so the app side is not surprised.

## 8. Open questions for the app developer

1. **"Clear data" target.** Does the Storico clear button erase the board's flash
   (`C` command, as specified here), only the phone's local copy, or both?
   Current assumption: `C` erases the board flash; the app should also clear its
   local copy if that is the intended UX.
2. **Device name.** Final advertised name to scan for. Proposed `SmartGlasses`.
3. **IR batch size / rate.** 30 Hz, up to 10 samples per `P` line is the starting
   point. If the link drops samples, we lower the rate; the app reads the real rate
   from the `I` line so it should not hard-code 30.
4. **Reconnect behavior.** On reconnect the app should re-send `T`, then `L` or `H`
   depending on the active page.

## 9. Quick reference

App -> Board:

```
L\n                 start live
H\n                 dump history (stops live)
C\n                 clear flash history
T,<epoch>\n         set wall-clock time
```

Board -> App:

```
I,<ver>,<ir_hz>,<vitals_s>                      hello (after L)
P,<ir>,<ir>,...                                 live IR batch (30 Hz)
V,<ts>,<hr>,<spo2_x10>,<steps_total>,<temp_c100> live vitals (15 s)
HBEGIN,<count>                                  history start
R,<ts>,<temp_c100>,<hr>,<spo2_x10>,<steps_delta> history record
HEND                                            history end
C,OK                                            clear done
T,OK                                            time set
E,<text>                                        error (optional)
```
