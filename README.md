# Harmony Infrared

![Harmony Infrared icon](custom_components/harmony_ir/brand/icon.png)

Use a rooted Logitech Harmony Hub's built-in IR transmitter and receiver from
Home Assistant. A Lua 5.1 HTTP bridge uses the Hub's existing HAL; the HA
integration provides standard emitter/receiver entities and a capture button.
Receiving is experimental and explicitly armed on demand.

**Version 0.1.0 — experimental. Trusted LAN only: no authentication or TLS.**
Never expose the bridge to the internet or port-forward it.

## Installation

Install the Hub service and HA integration separately. **HACS only installs the
HA component; it does not root the Hub or update its Lua service.**

### 1. Hub service

You need existing owner root SSH on firmware 4.15.600, plus Python **3.9+** and
OpenSSH on your computer. Rooting and SSH configuration are outside this project.
The Hub needs no new packages, compiler or firmware replacement.

From a checkout of this repository, keep Harmony controls idle and run on your
computer, replacing the example address/key:

```sh
python3 install.py --host 192.0.2.10 --key ~/.ssh/id_ed25519
```

The installer streams current sources over SSH, stages and validates them under
`/data/harmony-ir`, adds one owned block to `/etc/init.d/rcS.local`, and starts a
supervisor. It does not change SSH, restart stock HAL, reboot, or send IR.
New installs listen on **0.0.0.0:8089**. Use network isolation/firewall rules or
`--listen` to restrict access. Updates preserve existing listen settings.

Use `--dry-run` to preview without connecting, or `--help` for options. Stop any
unmanaged bridge before installing; unknown occupied listeners are not killed.
Do not interrupt installation or run multiple installers concurrently.

On the Hub, check service status without transmitting:

```sh
/data/harmony-ir/service status
/data/harmony-ir/service check
```

### 2. HA integration via HACS

Your HA build needs `InfraredEmitterEntity`, `InfraredReceiverEntity` and
`InfraredReceivedSignal` in its core `infrared` domain for both features. A
minimum released version has not yet been established. Older HA builds lacking
receiver APIs fall back to emitter-only operation; the receiver hardware is
built into the Hub. HACS does not add core APIs.

Once the repository is pushed and public, with [HACS installed](https://www.hacs.xyz/docs/use/):

1. Back up HA before changing custom integrations.
2. Open **HACS → ⋮ → Custom repositories**.
3. Add `https://github.com/samneirinck/harmony-ir`, type **Integration**.
4. Find **Harmony Infrared** and download/install it.
5. **Restart Home Assistant** to load the Python files.

Without releases, HACS downloads the default branch. Default-store listing is
not required. Public HACS validation still needs the owner's license decision
and GitHub metadata (description, topics and Issues).

For a private checkout or manual installation, copy the **entire**
`custom_components/harmony_ir/` folder into your HA configuration's
`custom_components/` directory, then restart HA. Include all Python files,
manifest, translations and brand assets; do not create an extra nested folder.

### 3. Connect HA

Open **Settings → Devices & services → Add integration → Harmony Infrared**.
Enter the Hub address, port **8089**, and a name. Setup only checks `/health`;
it never transmits. Select the emitter in a compatible consumer such as
**LG Infrared**. A DHCP reservation is recommended; use **Reconfigure** for
address changes rather than deleting integration/entity-registry entries.

Stock Harmony SSDP can offer discovery when the default-port bridge responds.
A custom port requires manual setup. Discovery does not track arbitrary IP
changes automatically.

For existing YAML users: back up configuration, remove only the
`platform: harmony_ir` item from `infrared`, restart HA, and add the UI entry
with the **same host and port**. Keep the existing entity registry and consumer
integrations. The original emitter unique ID is preserved; do not leave YAML
and UI active for the same endpoint. Legacy YAML operation remains supported.

### 4. Use the transmitter and receiver

A new entity can show `unknown` until its first signal, not necessarily offline.
First check HTTP without sending IR:

```sh
export HUB_HOST="192.0.2.10"
curl --max-time 5 "http://$HUB_HOST:8089/health"
```

With capture decoder v2 and compatible HA receiver APIs, the device also has a
receiver and **Capture IR (10 seconds)** button under Diagnostics. Press it,
then aim a handheld remote at the Hub's learning receiver and press once.
The handheld may operate the appliance. Quiet timeout is normal. Receiving is
never continuous and captured signals are never automatically replayed.

Only test a transmission when someone can observe a non-safety-critical
appliance. HAL acceptance is not proof of appliance reception. Never
automatically retry an uncertain command. See [API.md](API.md) for requests and
the [LG examples](examples/README.md) for reviewed power commands.

## Updates and service control

Re-run `install.py` from the updated checkout for the Hub. Update through HACS
or replace the entire component folder for HA, then restart HA; an entry reload
does not reliably reload Python code. Preserve integration and entity IDs.

The Hub controller accepts `status`, `check`, `start`, `stop`, `restart`,
`enable`, `disable` and `uninstall`:

```sh
/data/harmony-ir/service restart
```

Stop/restart only while idle. `stop` leaves next-boot startup enabled; `disable`
stops and disables it. Re-installation enables it again. `uninstall` stops it
and removes only its boot block, retaining files/settings and the original boot
backup for inspection. Current and previous releases are retained on updates;
detected activation failure attempts rollback, but power loss is not transactional.

Logs are in RAM at `/tmp/harmony-ir-service/bridge.log`, with one rotated copy.
The original boot backup stays under `/data/harmony-ir/backups/`; never commit it.
Persistence covers normal reboots, not factory reset or firmware replacement.

## Testing and troubleshooting

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
make test
```

Development needs Python **3.12+** and Lua **5.1** or LuaJIT. Tests never contact
a real Hub. See [TESTING.md](TESTING.md) for coverage, safe remote-HA testing,
recovery and the explicit diagnostic CLI.

## Scope and references

No RF/Bluetooth, stock activity management, code database, MQTT, web UI,
continuous learning or authentication. Use HA's existing Harmony integration
for stock activities. Appliance protocol decoding belongs in consumer integrations.

- [HTTP/CLI API](API.md)
- [Security, provenance and licensing](SECURITY.md)
- [HA infrared API](https://developers.home-assistant.io/docs/core/entity/infrared/)
- [HACS packaging requirements](https://www.hacs.xyz/docs/publish/integration/)

No project license has been selected. No proprietary firmware, keys, device
backups or private captures are distributed. This project is not affiliated
with Logitech, Home Assistant or HACS.
