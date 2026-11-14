import asyncio
import os

import pytest
import voluptuous as vol
from conftest import Response, Session


def serialize(schema):
    if os.environ.get("SCHEMA_BACKEND", "probatio") == "probatio":
        from probatio.codecs.fields import to_field_list

        return to_field_list(schema)
    from voluptuous_serialize import convert

    return convert(schema)


def test_setup_and_reconfigure_forms_serialize(ha, configuration):
    for defaults in ({}, configuration):
        fields = serialize(ha.flow.form_schema(defaults))
        assert [field["type"] for field in fields] == ["string", "integer", "string"]
        assert [field["name"] for field in fields] == ["host", "port", "name"]


def test_normalization_preserves_strict_validation(ha, configuration):
    submitted = {**configuration, "host": " hub.example ", "name": " Living room "}
    normalized = ha.flow.normalize_input(submitted)
    assert normalized == {**configuration, "host": "hub.example", "name": "Living room"}
    assert submitted["host"] == " hub.example "
    assert ha.flow.normalize_input({**configuration, "port": "8089"})["port"] == 8089


@pytest.mark.parametrize(
    "field,value",
    [
        ("host", "http://example.com"),
        ("host", "example.com/path"),
        ("host", "user@example.com"),
        ("host", ""),
        ("host", "-bad"),
        ("name", "   "),
        ("name", "x" * 65),
        ("port", 1023),
        ("port", 65536),
        ("port", 8089.5),
        ("port", "8089.5"),
    ],
)
def test_invalid_inputs_are_rejected(ha, configuration, field, value):
    with pytest.raises(vol.Invalid):
        ha.flow.normalize_input({**configuration, field: value})


def test_setup_validates_only_health_and_preserves_identity(ha, configuration, health):
    async def scenario():
        flow = ha.flow.HarmonyIRConfigFlow()
        flow.hass = ha.hass
        ha.hass.session = Session(Response(200, health))
        result = await flow.async_step_user({**configuration, "name": " Living room "})
        assert result["type"] == "create_entry"
        assert result["title"] == "Living room"
        assert flow.unique_id == "harmony_ir_192.0.2.10_8089"
        assert [(method, url) for method, url, _ in ha.hass.session.calls] == [
            ("GET", "http://192.0.2.10:8089/health")
        ]

    asyncio.run(scenario())


def test_invalid_input_and_failed_health_return_serializable_forms(ha, configuration):
    async def scenario():
        flow = ha.flow.HarmonyIRConfigFlow()
        flow.hass = ha.hass
        result = await flow.async_step_user({**configuration, "name": " "})
        assert result["errors"] == {"base": "invalid_input"}
        serialize(result["data_schema"])
        assert not ha.hass.session.calls
        ha.hass.session = Session(Response(503, {"error": "offline"}))
        result = await flow.async_step_user(configuration)
        assert result["errors"] == {"base": "cannot_connect"}
        serialize(result["data_schema"])

    asyncio.run(scenario())


def test_reconfigure_keeps_existing_unique_id(ha, configuration, entry, health):
    async def scenario():
        flow = ha.flow.HarmonyIRConfigFlow()
        flow.hass = ha.hass
        flow.entry = entry
        ha.hass.session = Session(Response(200, health))
        result = await flow.async_step_reconfigure({**configuration, "host": "192.0.2.11"})
        assert result["type"] == "reconfigure"
        assert result["entry"].unique_id == "original-emitter-id"
        invalid = await flow.async_step_reconfigure({**configuration, "port": 1})
        assert invalid["errors"] == {"base": "invalid_input"}
        serialize(invalid["data_schema"])

    asyncio.run(scenario())
