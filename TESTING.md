# Testing and troubleshooting

## Offline regression tests

Use Python 3.12+ and Lua 5.1 or LuaJIT:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
make test
```

Override `PYTHON` or `LUA` if needed, for example `make test LUA=luajit`.
No Hub address, SSH key or HA token is needed. Tests do not contact hardware.

The tests focus on failures that matter:

- Raw IR encoding, LTCP framing and native socket readiness.
- Capture's first mark, mark-to-mark conversion and malformed data.
- Request bounds, cleanup, uncertain transmission and no automatic retries.
- HA form serialization, identity preservation, capture/send exclusion and unload.
- Installer stream construction, shell syntax, input validation and dry runs.

HA interfaces and HTTP responses are doubled, but form serialization uses real
schema libraries. The full Python suite runs with Probatio; the config-flow
regressions also run with legacy Voluptuous to check form serialization.
These are not substitutes for testing startup and entity behavior in real HA.

## A remote production HA

Do not use the live installation as the development test runner. Ideally check
the component in a separate HA instance with a fresh configuration and the same
version/infrared APIs first. Do not copy production `.storage`, secrets or tokens
into tests. A fake HTTP endpoint can exercise forms/lifecycle without sending
IR; a separate HA instance pointed at a real Hub can still operate appliances.

For deployment:

1. Back up HA and its existing component folder. Keep SSH/VPN recovery access
   independent of the frontend, and choose a maintenance window.
2. Install the complete component and restart HA. Keep existing registry entries.
3. Check Hub `service status`, `service check`, LAN `/health`, HA setup/reload and
   logs before any transmission.
4. Arrange an onsite helper or reliable observation before testing one reviewed
   command on a non-safety-critical appliance. A HAL acknowledgment does not
   prove reception. Do not retry automatically.

Never expose the unauthenticated bridge publicly. If a test HA runs remotely,
use a VPN or SSH tunnel for its UI rather than publishing it to the internet.

## Common problems

- **Setup form fails:** inspect HA logs for `harmony_ir` and `infrared`. Replace
  the entire component, restart HA, and share only a redacted traceback.
- **Receiver missing:** HA needs `InfraredReceiverEntity`/`InfraredReceivedSignal`
  and the Hub must advertise `capture_decoder_version:2`. Emitter support remains
  available without receiver support.
- **Capture times out:** normal without a remote signal during the window. Aim
  at the learning receiver and press once; do not hold or run stock learning.
- **Busy/send rejected:** wait for capture to finish. Connection errors or
  cancellation impose an additional 11-second safety holdoff. This coordinates
  only this integration, not external clients or stock Harmony controllers.
- **Health stalls:** capture occupies the single HTTP worker for up to 30 seconds.
  Health proves HTTP/API availability, not physical IR operation.
- **HA fails after an update:** restore the previous component via independent
  recovery access and restart. Do not delete registry data or factory-reset the Hub.
- **Interrupted Hub install:** inspect the service and installer lock/processes
  before retrying. Never remove an active lock. Keep previous source and owner
  SSH available for recovery.

## Explicit transmit-and-capture diagnostic

`diagnose.lua` is an experimental exception to normal send/capture exclusion.
It starts native capture, waits 250 ms, submits one send request, attempts
cancellation and collects capture within eight seconds. **It can operate the
appliance.** There is no automatic retry or HTTP diagnostic route.

The learning receiver may not see the Hub's own emitters; this is not guaranteed
internal loopback. Concurrent driver configuration may affect results. A missing
capture or mismatch is inconclusive; a match does not prove appliance reception.

Prepare a reviewed `/transmit` JSON request in `/tmp/ir-request.json` on the Hub.
It contains `carrier_hz`, `timings_us` and optional `duty_percent`, within normal
transmitter limits and a 32 KiB input bound. From the current release directory,
`lua diagnose.lua --dry-run < /tmp/ir-request.json` opens no sockets or sends.

Only when ready, keep all other controllers, stock learning and handhelds idle:

```sh
/data/harmony-ir/service stop
read -r release < /data/harmony-ir/active
/usr/bin/lua "/data/harmony-ir/releases/$release/diagnose.lua" \
  --send-and-capture < /tmp/ir-request.json > /tmp/ir-diagnostic.json
/data/harmony-ir/service start
```

**Always run the final start command, even if the diagnostic fails.** The CLI
checks managed PIDs but cannot detect every unmanaged/stock IR client. Do not
interrupt it: that can prevent transmit cancellation.

The JSON report includes acceptance/cancellation, capture or timeout/error, and
an approximate timing/carrier comparison. Final trailing silence is ignored;
timing tolerance is 100 µs or 20%, whichever is larger, and carrier tolerance
is 5%. Estimates are uncalibrated. `appliance_reception_verified` remains false.
Nonzero exit status can mean mismatch or an incomplete diagnostic; inspect the
report before considering another transmission. Keep private captures out of Git.
