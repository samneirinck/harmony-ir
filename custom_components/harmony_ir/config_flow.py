from urllib.parse import urlparse

from homeassistant import config_entries
from homeassistant.const import CONF_HOST, CONF_NAME, CONF_PORT
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .client import HarmonyClient
from .const import DEFAULT_PORT, DOMAIN
from .validation import schema


def endpoint_id(data):
    return f"harmony_ir_{data[CONF_HOST]}_{data[CONF_PORT]}"


def form_schema(data):
    # Keep UI fields serializable; trim and validate only after submission.
    return schema.Schema(
        {
            schema.Required(CONF_HOST, default=data.get(CONF_HOST, "")): str,
            schema.Required(CONF_PORT, default=data.get(CONF_PORT, DEFAULT_PORT)): int,
            schema.Required(CONF_NAME, default=data.get(CONF_NAME, "Harmony IR")): str,
        }
    )


def normalize_input(data):
    return schema.Schema(
        {
            schema.Required(CONF_HOST): schema.All(
                str,
                str.strip,
                schema.Length(min=1, max=253),
                schema.Match(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"),
            ),
            schema.Required(CONF_PORT): schema.All(
                schema.Any(int, schema.All(str, schema.Match(r"^[0-9]+$"), schema.Coerce(int))),
                schema.Range(min=1024, max=65535),
            ),
            schema.Required(CONF_NAME): schema.All(str, str.strip, schema.Length(min=1, max=64)),
        }
    )(data)


class HarmonyIRConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    VERSION = 1

    def __init__(self):
        super().__init__()
        self._discovered = {}

    async def _validate(self, data):
        client = HarmonyClient(async_get_clientsession(self.hass), data[CONF_HOST], data[CONF_PORT])
        await client.async_check_connection()

    async def async_step_user(self, user_input=None):
        errors = {}
        data = user_input or self._discovered
        if user_input is not None:
            try:
                user_input = normalize_input(user_input)
                await self._validate(user_input)
            except schema.Invalid:
                errors["base"] = "invalid_input"
            except HomeAssistantError:
                errors["base"] = "cannot_connect"
            else:
                await self.async_set_unique_id(endpoint_id(user_input))
                self._abort_if_unique_id_configured()
                return self.async_create_entry(title=user_input[CONF_NAME], data=user_input)
        return self.async_show_form(step_id="user", data_schema=form_schema(data), errors=errors)

    async def async_step_ssdp(self, discovery_info):
        try:
            host = urlparse(discovery_info.ssdp_location).hostname
        except ValueError:
            return self.async_abort(reason="not_bridge")
        if not host or ":" in host:
            return self.async_abort(reason="not_bridge")
        self._discovered = {
            CONF_HOST: host,
            CONF_PORT: DEFAULT_PORT,
            CONF_NAME: discovery_info.upnp.get("friendlyName") or "Harmony IR",
        }
        self._async_abort_entries_match({CONF_HOST: host, CONF_PORT: DEFAULT_PORT})
        await self.async_set_unique_id(endpoint_id(self._discovered))
        self._abort_if_unique_id_configured()
        try:
            await self._validate(self._discovered)
        except HomeAssistantError:
            return self.async_abort(reason="not_bridge")
        self.context["title_placeholders"] = {"name": self._discovered[CONF_NAME]}
        return await self.async_step_user()

    async def async_step_reconfigure(self, user_input=None):
        entry = self._get_reconfigure_entry()
        errors = {}
        if user_input is not None:
            try:
                user_input = normalize_input(user_input)
            except schema.Invalid:
                return self.async_show_form(
                    step_id="reconfigure",
                    data_schema=form_schema(user_input),
                    errors={"base": "invalid_input"},
                )
            for other in self._async_current_entries():
                if other.entry_id != entry.entry_id and all(
                    other.data.get(key) == user_input[key] for key in (CONF_HOST, CONF_PORT)
                ):
                    errors["base"] = "already_configured"
                    break
            if not errors:
                try:
                    await self._validate(user_input)
                except HomeAssistantError:
                    errors["base"] = "cannot_connect"
                else:
                    return self.async_update_reload_and_abort(
                        entry, data_updates=user_input, title=user_input[CONF_NAME]
                    )
        return self.async_show_form(
            step_id="reconfigure",
            data_schema=form_schema(user_input or entry.data),
            errors=errors,
        )
