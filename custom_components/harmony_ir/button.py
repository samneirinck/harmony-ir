from homeassistant.components.button import ButtonEntity
from homeassistant.const import EntityCategory


async def async_setup_entry(hass, entry, async_add_entities):

    if (receiver := entry.runtime_data.receiver) is not None:
        async_add_entities([HarmonyCaptureButton(receiver)])


async def async_setup_platform(hass, config, async_add_entities, discovery_info=None):

    if discovery_info and (receiver := discovery_info.get("receiver")) is not None:
        async_add_entities([HarmonyCaptureButton(receiver)])


class HarmonyCaptureButton(ButtonEntity):
    _attr_entity_category = EntityCategory.DIAGNOSTIC
    _attr_translation_key = "capture_ir"
    _attr_icon = "mdi:remote"

    def __init__(self, receiver):
        self._receiver = receiver
        self._attr_unique_id = f"{receiver.unique_id}_capture"
        self._attr_device_info = receiver.device_info
        self._attr_has_entity_name = bool(receiver.device_info)
        self._attr_name = None
        if not receiver.device_info:
            self._attr_translation_key = None
            self._attr_name = f"{receiver.hub_name} Capture IR (10 seconds)"

    async def async_press(self):

        await self._receiver.async_capture()
