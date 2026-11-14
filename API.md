# Trusted-LAN IR bridge API

**No authentication or encryption.** Anyone who can reach the port can transmit
or capture IR. Use a trusted LAN/firewall only. Never port-forward it. The default listener
binds to loopback when run manually; the persistent installer defaults to
0.0.0.0:8089.

For installation and HA instructions, see [README.md](README.md).
Commands below run from this repository's root. Set `HUB_HOST` to your Hub's IP.

## GET /health

```sh
curl --max-time 5 "http://$HUB_HOST:8089/health"
```

Returns API version, transmitter limits, output mask, `authenticated:false`,
`capture_experimental:true`, `capture_decoder_version:2` and
`max_capture_timeout_s:30`.
No HAL connection is made: this proves HTTP availability, not physical IR health.

## POST /transmit

Content-Type must be `application/json`. Request schema:

```json
{
  "carrier_hz": 38000,
  "timings_us": [8990, -4490, 568, -552],
  "duty_percent": 33
}
```

These abbreviated timings illustrate the schema, not an appliance command.
Positive microseconds are marks; negative values are spaces. Duty is optional
(default 33%). The output mask is fixed to all three outputs (`7`).

Limits:

- Carrier: integer 10000..60000 Hz; duty: integer 1..50%.
- 1..2048 nonzero integer timings; first must be positive.
- At most one second of total mark/space duration per request.
- Body: 32768 bytes; headers: 8192 bytes and at most 32 fields.
- Single HTTP request per connection; no chunked bodies or Expect/continue.

Unknown fields, sparse/object timings, and duplicate headers are rejected.
Browser form content types are rejected and no CORS permission is granted.
These restrictions are not authentication.

Successful response (200):

```json
{
  "accepted": true,
  "cancellation_acknowledged": true,
  "duration_us": 215735,
  "appliance_reception_verified": false
}
```

The response follows HAL acceptance, a wait for the nominal duration plus 50 ms,
and acknowledged cancellation. It does not verify appliance state.
Validation failures return 400/415; unsupported methods return 405; unknown paths
return 404. HAL failures return 502 with `transmission_uncertain:true` and
`retry_safe:false`. Diagnostic errors may contain local paths or reply bytes.

**Never automatically retry a POST**, including after an HTTP/network timeout:
the appliance may already have received it. A client disconnect does not abort
the send/wait/cancel operation already in progress. Cancellation is best-effort
if the process is interrupted or the HAL fails.

## POST /capture (experimental)

Listen for one raw IR capture through HAL's native `ir.cap` command. This does
not transmit, automatically replay, decode an appliance protocol, or store codes.
Content-Type must be `application/json`; only `timeout_s` is accepted:

```sh
curl --max-time 15 --fail-with-body \
  -H 'Content-Type: application/json' \
  --data '{"timeout_s":10}' \
  "http://$HUB_HOST:8089/capture" > /tmp/ir-capture.json
```

While it waits, aim the original remote at the Hub's learning receiver and press
once, without holding. Keep other Harmony controllers and stock learning idle.
The handheld itself may operate the appliance. The timeout is an integer 1–30
seconds, default 10; set curl's timeout several seconds longer.

A successful response (200) contains:

- `experimental:true`, `decoder_version:2` and lossless `native_capture_hex`.
- `first_pulse_us`, `first_mark_us`, `first_mark_pulses`: native metadata.
- `carrier_hz_estimate`, when the metadata permits an estimate. This is not an
  exact carrier measurement; use the known protocol frequency when available.
- `timings_us` and `duration_us`, when waveform decoding succeeds. Timings use the
  same signed convention as `/transmit`, restoring the first mark from metadata
  and subtracting each preceding mark from its native mark-to-mark period. The
  capture's trailing silence is retained; initial presilence is not available.
  Check transmitter limits before
  attempting any separate replay; a capture need not fit them.
- Otherwise `decoding_error`, with native hex retained for inspection. Native
  long-mark escapes are not yet decoded; no plausible waveform is invented.

No complete capture within the deadline returns **504** with `capture_timeout:true`.
Malformed input returns 400/415; HAL/transport or malformed native replies return
502. Every HAL connection is closed after success or error. On a deadline,
closing it requests native capture abortion via EOF; there is no separate
cancellation acknowledgment. This uses the same close path if parsing fails.

The service serializes capture with its own transmissions. All requests,
including health checks, may wait behind capture for up to 30 seconds. A client
HTTP disconnect does not stop a pending capture immediately; its HAL deadline
still applies. Avoid parallel requests. This implementation does not coordinate
with stock controllers or separate CLI processes. It cannot capture this service's
own transmission simultaneously. Use capture decoder v2 or newer; older timing
arrays may omit the first mark or represent periods instead of spaces.

For standalone Lua, with the bridge stopped, run from the deployed directory:

```sh
lua capture.lua --timeout 10 > /tmp/ir-capture.json
```

## Controlled LG power check

With the bridge running, create a request from the reviewed example. This first
command does not transmit:

```sh
python3 -c 'import json,pathlib; p=pathlib.Path("examples/lg-power-off.txt"); print(json.dumps({"carrier_hz":38000,"timings_us":[int(v) for v in p.read_text().split()]}))' > /tmp/lg-power-off.json
```

Only when ready to **turn the TV off**, with other Harmony controls idle:

```sh
curl --max-time 10 --fail-with-body \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/lg-power-off.json \
  "http://$HUB_HOST:8089/transmit"
```

Python is used only on the computer to prepare JSON, not on the Hub. For Power
On, prepare a separate request using `examples/lg-power-on.txt`. Do not chain
both commands as one test. Check the TV's state before any retry.

## CLI

On the Hub, with the three CLI files deployed:

```sh
lua /tmp/harmony-ir/transmit.lua --probe
lua /tmp/harmony-ir/transmit.lua --dry-run 38000 /tmp/known-command.txt
```

Only when ready to transmit:

```sh
lua /tmp/harmony-ir/transmit.lua --send 38000 /tmp/known-command.txt
```

To cancel without submitting an IR waveform:

```sh
lua /tmp/harmony-ir/transmit.lua --stop
```

Cancellation can interrupt another controller's active transmission. Never run
the CLI concurrently with the HTTP service, Harmony activities or a handheld.

## Lifecycle and timeouts

The service has one worker and listening backlog one. It serializes only its
own clients, not other software using the HAL. Headers/body and response writes
each have three-second deadlines. Transmit HAL exchanges each have two-second
deadlines; acceptance and cancellation use separate connections. Capture uses
its requested 1–30 second HAL deadline.

HA allows ten seconds per request. Applications should avoid parallel sends and
should never add automatic retries to `/transmit`. Stop the foreground service
with Ctrl-C while idle. For managed reboot persistence, see [README.md](README.md).
There is no TLS or graceful-drain manager.
