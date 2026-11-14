import asyncio
from types import SimpleNamespace

import pytest
from conftest import Response, Session


def test_discovery_is_confirmed_and_checks_only_default_port(ha, health):
    async def scenario():
        flow = ha.flow.HarmonyIRConfigFlow()
        flow.hass = ha.hass
        ha.hass.session = Session(Response(200, health))
        discovered = SimpleNamespace(
            ssdp_location="http://192.0.2.20:8088/description",
            upnp={"friendlyName": "Living room Hub"},
        )
        result = await flow.async_step_ssdp(discovered)
        assert result["type"] == "form"
        assert result["step_id"] == "user"
        assert flow.context["title_placeholders"] == {"name": "Living room Hub"}
        assert ha.hass.session.calls[0][:2] == ("GET", "http://192.0.2.20:8089/health")

    asyncio.run(scenario())


@pytest.mark.parametrize("location", ["not a URL", "http://[invalid", "http://[::1]/"])
def test_invalid_discovery_never_connects(ha, location):
    async def scenario():
        flow = ha.flow.HarmonyIRConfigFlow()
        flow.hass = ha.hass
        result = await flow.async_step_ssdp(SimpleNamespace(ssdp_location=location))
        assert result["reason"] == "not_bridge"
        assert not ha.hass.session.calls

    asyncio.run(scenario())


def test_stock_hub_without_bridge_is_not_offered(ha):
    async def scenario():
        flow = ha.flow.HarmonyIRConfigFlow()
        flow.hass = ha.hass
        ha.hass.session = Session(Response(404, {"error": "not found"}))
        result = await flow.async_step_ssdp(
            SimpleNamespace(
                ssdp_location="http://192.0.2.20:8088/description",
                upnp={},
            )
        )
        assert result["reason"] == "not_bridge"
        assert len(ha.hass.session.calls) == 1

    asyncio.run(scenario())


def test_duplicate_reconfiguration_never_connects(ha, configuration, entry):
    async def scenario():
        flow = ha.flow.HarmonyIRConfigFlow()
        flow.hass = ha.hass
        flow.entry = entry
        flow.entries = [SimpleNamespace(entry_id="other-entry", data=configuration)]
        result = await flow.async_step_reconfigure(configuration)
        assert result["errors"] == {"base": "already_configured"}
        assert not ha.hass.session.calls

    asyncio.run(scenario())
