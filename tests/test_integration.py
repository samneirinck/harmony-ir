import asyncio
from types import SimpleNamespace

import aiohttp
import pytest
from conftest import Response, Session


def create_client(ha, session, configuration):
    return ha.client.HarmonyClient(session, configuration["host"], configuration["port"])


def test_entry_setup_and_unload_only_check_health(ha, configuration, entry, health):
    async def scenario():
        forwarded, unloaded = [], []

        async def forward(config_entry, platforms):
            forwarded.extend(platforms)

        async def unload(config_entry, platforms):
            unloaded.extend(platforms)
            return True

        ha.hass.session = Session(Response(200, health))
        ha.hass.config_entries = SimpleNamespace(
            async_forward_entry_setups=forward,
            async_unload_platforms=unload,
        )
        assert await ha.package.async_setup_entry(ha.hass, entry)
        entities = entry.runtime_data
        assert entities.emitter.unique_id == "original-emitter-id"
        assert entities.receiver.unique_id == "original-emitter-id_receiver"
        assert entities.emitter.device_info == entities.receiver.device_info
        added = []
        await ha.button.async_setup_entry(ha.hass, entry, added.extend)
        assert added[0].device_info == entities.emitter.device_info
        assert forwarded == ["infrared", "button"]
        assert await ha.package.async_unload_entry(ha.hass, entry)
        assert unloaded == forwarded
        assert all(
            method == "GET" and url.endswith("/health") for method, url, _ in ha.hass.session.calls
        )

    asyncio.run(scenario())


def test_capture_button_publishes_without_transmitting(ha, configuration, entry, health, capture):
    async def scenario():
        session = Session(Response(200, health), Response(200, capture))
        client = create_client(ha, session, configuration)
        await client.async_check_connection()
        entities = ha.infrared.create_entities(client, configuration, entry)
        receiver = entities.receiver
        receiver.hass = ha.hass
        button = ha.button.HarmonyCaptureButton(receiver)
        await button.async_press()
        assert receiver.signals[0].timings == capture["timings_us"]
        assert receiver.signals[0].modulation is None
        assert receiver.extra_state_attributes == {
            "listening": False,
            "last_capture_status": "received",
            "carrier_hz_estimate": 38025,
            "last_timing_count": 6,
        }
        assert session.calls[-1][1].endswith("/capture")
        assert session.calls[-1][2]["timeout"].total == 15
        assert session.calls[-1][2]["allow_redirects"] is False
        assert not any(url.endswith("/transmit") for _, url, _ in session.calls)

    asyncio.run(scenario())


def test_quiet_capture_is_normal(ha, configuration, health):
    async def scenario():
        session = Session(Response(200, health), Response(504, {"capture_timeout": True}))
        client = create_client(ha, session, configuration)
        await client.async_check_connection()
        receiver = ha.infrared.create_entities(client, configuration).receiver
        receiver.hass = ha.hass
        await receiver.async_capture()
        assert receiver.extra_state_attributes["last_capture_status"] == "timeout"
        assert not getattr(receiver, "signals", [])
        assert not client.capture_active

    asyncio.run(scenario())


def test_queued_send_rechecks_uncertain_capture_before_http(ha, configuration):
    async def scenario():
        session = Session()
        client = create_client(ha, session, configuration)
        await client._operation_lock.acquire()
        pending = asyncio.create_task(client.async_transmit(38000, [420, -420]))
        await asyncio.sleep(0)
        assert not pending.done()
        client._capture_holdoff_until = asyncio.get_running_loop().time() + 11
        client._operation_lock.release()
        with pytest.raises(ha.error, match="capture may still be active"):
            await pending
        assert not session.calls

    asyncio.run(scenario())


def test_capture_blocks_sends_and_duplicate_capture(ha, configuration, capture):
    async def scenario():
        future = asyncio.get_running_loop().create_future()
        session = Session(Response(200, future))
        client = create_client(ha, session, configuration)
        client.supports_capture = True
        receiver = ha.infrared.create_entities(client, configuration).receiver
        receiver.hass = ha.hass
        pending = asyncio.create_task(receiver.async_capture())
        await asyncio.sleep(0)
        with pytest.raises(ha.error):
            await client.async_transmit(38000, [420, -420])
        with pytest.raises(ha.error):
            await receiver.async_capture()
        assert receiver.extra_state_attributes["listening"]
        assert len(session.calls) == 1
        future.set_result(capture)
        await pending
        assert not client.capture_active

    asyncio.run(scenario())


def test_capture_cancellation_holds_off_new_operations(ha, configuration):
    async def scenario():
        future = asyncio.get_running_loop().create_future()
        client = create_client(ha, Session(Response(200, future)), configuration)
        client.supports_capture = True
        pending = asyncio.create_task(client.async_capture())
        await asyncio.sleep(0)
        pending.cancel()
        with pytest.raises(asyncio.CancelledError):
            await pending
        assert client.capture_active
        with pytest.raises(ha.error):
            await client.async_transmit(38000, [420, -420])
        with pytest.raises(ha.error):
            await client.async_capture()

    asyncio.run(scenario())


def test_late_capture_is_not_published_after_unload(ha, configuration, capture):
    async def scenario():
        future = asyncio.get_running_loop().create_future()
        client = create_client(ha, Session(Response(200, future)), configuration)
        client.supports_capture = True
        receiver = ha.infrared.create_entities(client, configuration).receiver
        receiver.hass = ha.hass
        pending = asyncio.create_task(receiver.async_capture())
        await asyncio.sleep(0)
        await receiver.async_will_remove_from_hass()
        writes = receiver.state_writes
        future.set_result(capture)
        await pending
        assert not getattr(receiver, "signals", [])
        assert receiver.state_writes == writes

    asyncio.run(scenario())


def test_old_receiver_api_keeps_emitter(ha, configuration, entry, monkeypatch):
    monkeypatch.delattr(ha.components.infrared, "InfraredReceiverEntity")
    module = ha.load("_harmony_test.older_infrared", "infrared.py")
    client = create_client(ha, Session(), configuration)
    client.supports_capture = True
    entities = module.create_entities(client, configuration, entry)
    assert entities.emitter.unique_id == "original-emitter-id"
    assert entities.receiver is None


@pytest.mark.parametrize("capability", ["capture_supported", "capture_experimental"])
@pytest.mark.parametrize("enabled", [True, False])
def test_capture_capability_supports_current_and_legacy_bridges(
    ha, configuration, health, capability, enabled
):
    async def scenario():
        bridge_health = {key: value for key, value in health.items() if key != "capture_supported"}
        bridge_health[capability] = enabled
        client = create_client(ha, Session(Response(200, bridge_health)), configuration)
        await client.async_check_connection()
        assert client.supports_capture is enabled

    asyncio.run(scenario())


def test_old_bridge_keeps_emitter(ha, configuration, entry):
    client = create_client(ha, Session(), configuration)
    entities = ha.infrared.create_entities(client, configuration, entry)
    assert entities.emitter.unique_id == "original-emitter-id"
    assert entities.receiver is None


def test_transmission_is_not_retried(ha, configuration):
    async def scenario():
        session = Session(aiohttp.ClientConnectionError("connection lost"))
        client = create_client(ha, session, configuration)
        with pytest.raises(ha.error, match="do not automatically retry"):
            await client.async_transmit(38000, [420, -420])
        assert len(session.calls) == 1

    asyncio.run(scenario())


@pytest.mark.parametrize("timings", [[], [False], [-420], [420, 0], [1.5], [420, -1000000]])
def test_invalid_transmissions_never_reach_http(ha, configuration, timings):
    async def scenario():
        session = Session()
        client = create_client(ha, session, configuration)
        with pytest.raises(ha.error):
            await client.async_transmit(38000, timings)
        assert not session.calls

    asyncio.run(scenario())
