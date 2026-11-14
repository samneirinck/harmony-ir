from homeassistant.const import CONF_HOST, CONF_PORT, Platform
from homeassistant.exceptions import ConfigEntryNotReady, HomeAssistantError
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .client import HarmonyClient
from .const import DOMAIN

PLATFORMS = [Platform.INFRARED, Platform.BUTTON]


async def async_setup(hass, config):
    hass.data.setdefault(DOMAIN, {})["yaml_config"] = config
    return True


async def async_setup_entry(hass, entry):
    from .infrared import create_entities

    client = HarmonyClient(
        async_get_clientsession(hass), entry.data[CONF_HOST], entry.data[CONF_PORT]
    )
    try:
        await client.async_check_connection()
    except HomeAssistantError as error:
        raise ConfigEntryNotReady(str(error)) from error
    entry.runtime_data = create_entities(client, entry.data, entry)
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass, entry):
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
