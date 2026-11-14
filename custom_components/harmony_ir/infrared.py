import asyncio
import logging
from dataclasses import dataclass

from homeassistant.components import infrared as infrared_domain
from homeassistant.components.infrared import InfraredEmitterEntity
from homeassistant.const import CONF_HOST, CONF_NAME, CONF_PORT, Platform
from homeassistant.exceptions import HomeAssistantError, PlatformNotReady
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers import discovery
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .client import HarmonyClient
from .const import DEFAULT_PORT, DOMAIN
from .validation import schema

_LOGGER = logging.getLogger(__name__)
InfraredReceiverBase = getattr(infrared_domain, "InfraredReceiverEntity", object)
InfraredReceivedSignal = getattr(infrared_domain, "InfraredReceivedSignal", None)

PLATFORM_SCHEMA = cv.PLATFORM_SCHEMA.extend(
    {
        schema.Required(CONF_HOST): cv.string,
        schema.Optional(CONF_PORT, default=DEFAULT_PORT): cv.port,
        schema.Optional(CONF_NAME, default="Harmony IR"): cv.string,
    }
)


@dataclass
class HarmonyEntities:
    emitter: "HarmonyEmitter"
    receiver: "HarmonyReceiver | None"

    @property
    def infrared_entities(self):
        if self.receiver is None:
            return [self.emitter]
        return [self.emitter, self.receiver]


def create_entities(client, config, entry=None):
    emitter = HarmonyEmitter(client, config, entry)
    if not client.supports_capture:
        _LOGGER.warning("Receiver unavailable: update the Hub bridge for capture decoder v2")
        return HarmonyEntities(emitter, None)
    if (
        InfraredReceiverBase is object
        or InfraredReceivedSignal is None
        or not callable(getattr(InfraredReceiverBase, "_handle_received_signal", None))
    ):
        _LOGGER.warning("This HA infrared API lacks receiver support; emitter remains enabled")
        return HarmonyEntities(emitter, None)
    receiver = HarmonyReceiver(client, emitter, config[CONF_NAME])
    return HarmonyEntities(emitter, receiver)


async def async_setup_platform(hass, config, async_add_entities, discovery_info=None):
    client = HarmonyClient(async_get_clientsession(hass), config[CONF_HOST], config[CONF_PORT])
    try:
        await client.async_check_connection()
    except HomeAssistantError as error:
        raise PlatformNotReady(str(error)) from error
    entities = create_entities(client, config)
    async_add_entities(entities.infrared_entities)
    if entities.receiver is not None:
        hass.async_create_task(
            discovery.async_load_platform(
                hass,
                Platform.BUTTON,
                DOMAIN,
                {"receiver": entities.receiver},
                hass.data[DOMAIN]["yaml_config"],
            )
        )


async def async_setup_entry(hass, entry, async_add_entities):
    async_add_entities(entry.runtime_data.infrared_entities)


class HarmonyEmitter(InfraredEmitterEntity):
    _attr_should_poll = False

    def __init__(self, client, config, entry=None):
        self._client = client
        self._attr_has_entity_name = entry is not None
        self._attr_name = None if entry is not None else config[CONF_NAME]
        self._attr_unique_id = (
            entry.unique_id
            if entry is not None
            else f"harmony_ir_{config[CONF_HOST]}_{config[CONF_PORT]}"
        )
        if entry is not None:
            self._attr_device_info = {
                "identifiers": {(DOMAIN, entry.entry_id)},
                "name": config[CONF_NAME],
                "manufacturer": "Logitech",
                "model": "Harmony Hub (IR bridge)",
            }

    async def async_send_command(self, command):
        try:
            frequency = command.modulation
            timings = list(command.get_raw_timings())
        except (TypeError, ValueError) as error:
            raise HomeAssistantError("Cannot obtain raw IR timings") from error
        await self._client.async_transmit(frequency, timings)


class HarmonyReceiver(InfraredReceiverBase):
    _attr_should_poll = False

    def __init__(self, client, emitter, hub_name):
        self._client = client
        self.hub_name = hub_name
        self._attr_unique_id = f"{emitter.unique_id}_receiver"
        self._attr_device_info = emitter.device_info
        self._attr_has_entity_name = bool(emitter.device_info)
        self._attr_name = None if emitter.device_info else f"{hub_name} Receiver"
        self._listening = False
        self._removed = False
        self._last_capture_status = "idle"
        self._estimated_carrier_hz = None
        self._last_timing_count = 0

    @property
    def extra_state_attributes(self):
        return {
            "listening": self._listening,
            "last_capture_status": self._last_capture_status,
            "carrier_hz_estimate": self._estimated_carrier_hz,
            "last_timing_count": self._last_timing_count,
        }

    async def async_capture(self):
        if self._removed or getattr(self, "hass", None) is None:
            raise HomeAssistantError("Enable the Harmony IR receiver entity before capturing")
        if self._listening:
            raise HomeAssistantError("Harmony IR capture is already active")
        self._listening = True
        self._last_capture_status = "listening"
        self.async_write_ha_state()
        try:
            captured = await self._client.async_capture()
            if captured is None:
                self._last_capture_status = "timeout"
                return
            self._last_capture_status = "received"
            self._last_timing_count = len(captured["timings_us"])
            frequency = captured.get("carrier_hz_estimate")
            self._estimated_carrier_hz = (
                frequency if type(frequency) is int and frequency > 0 else None
            )
            if not self._removed:
                self._handle_received_signal(
                    InfraredReceivedSignal(timings=list(captured["timings_us"]))
                )
        except asyncio.CancelledError:
            self._last_capture_status = "cancelled"
            raise
        except HomeAssistantError:
            self._last_capture_status = "error"
            raise
        finally:
            self._listening = False
            if not self._removed:
                self.async_write_ha_state()

    async def async_will_remove_from_hass(self):
        self._removed = True
        await super().async_will_remove_from_hass()
