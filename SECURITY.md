# Security, provenance and licensing

## Trusted LAN only

The bridge has **no authentication or TLS**. Anyone who can reach it can transmit
IR or start a capture, which can observe nearby remotes and occupy the worker.
A private source repository does not make the deployed endpoint private.

- Never expose or port-forward the HTTP bridge or native HAL listener.
- Restrict access to trusted clients, ideally HA, through network/firewall rules.
- New persistent installations bind to `0.0.0.0:8089`; use `--listen` to narrow it.
  The manual server defaults to loopback.
- Body limits, content-type checks and CORS restrictions are not authentication.
  A slow/busy client can monopolize the single worker until its deadline.

The bridge normally runs as root. HTTP routes make bounded HAL transmit/capture
requests, not shell commands, file uploads or arbitrary HAL calls. A defect can
still affect the Hub. This project does not secure its old stock Linux/libraries.

## Hardware and failure safety

Never automatically retry transmission: an appliance may receive a command
before a timeout. HAL acceptance/cancellation is not proof of delivery or state.
Stopping the process during transmission can prevent cancellation. This is not
suitable for safety-critical equipment.

Keep stock learning, Harmony activities and external IR clients idle during
capture/diagnostics. Only this integration's operations are serialized; native
cancellation can affect other controllers. Capture cleanup closes the HAL socket
without a separate stop acknowledgment. Capture can block health/other HTTP
requests for up to 30 seconds.

The Hub's receiver is built in. Software capture is experimental, explicitly
armed, never continuous and never automatically replayed. HA stores only small
capture metadata in state; raw timings go to subscribers, which may log them.
The simultaneous diagnostic has additional caveats in [TESTING.md](TESTING.md).

The installer preserves the original boot hook and edits only its own marked
block. Do not commit that backup.

## Sensitive data

Never commit keys, credentials, firmware backups, account/device identifiers,
private HA configuration or raw captures. Diagnostic errors may include paths
and reply bytes: redact logs before sharing. Report security issues privately
to the repository owner; no support SLA has been established.

## Provenance

This independent interoperability project is not affiliated with Logitech,
Home Assistant or HACS. Product names belong to their respective owners.

- The implementation loads the Hub's existing `/opt/lib/luaworks.so` at runtime.
  Firmware, native libraries, disassembly and decompiled source are not distributed.
- [harmony-hub-control](https://github.com/Ripthulhu/harmony-hub-control) is a
  reference for standalone LTCP framing conventions. Review applicable
  permissions before reusing upstream source.
- HA's infrared APIs informed the adapter contract. The generic brand icon is
  an original project asset, not a Logitech logo.
- LG examples contain illustrative power commands, not Hub/account identifiers
  or credentials.

**No project license has been selected.** There is intentionally no LICENSE
file or implied MIT/Apache/GPL grant. Public HACS license validation remains
pending that owner decision. A project license would not grant rights to
excluded proprietary firmware or third-party source.
