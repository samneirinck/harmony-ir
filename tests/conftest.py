import asyncio
import importlib.util
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

if os.environ.get("SCHEMA_BACKEND", "probatio") == "probatio":
    from probatio.compat import install_as_voluptuous

    install_as_voluptuous()

import voluptuous as vol

ROOT = Path(__file__).resolve().parents[1]
COMPONENT = ROOT / "custom_components" / "harmony_ir"


class HomeAssistantError(Exception):
    pass


class Entity:
    hass = None

    @property
    def unique_id(self):
        return self._attr_unique_id

    @property
    def name(self):
        return getattr(self, "_attr_name", None)

    @property
    def device_info(self):
        return getattr(self, "_attr_device_info", None)

    def async_write_ha_state(self):
        self.state_writes = getattr(self, "state_writes", 0) + 1

    async def async_will_remove_from_hass(self):
        pass


class ReceiverEntity(Entity):
    def _handle_received_signal(self, signal):
        self.signals = getattr(self, "signals", []) + [signal]


@dataclass
class ReceivedSignal:
    timings: list[int]
    modulation: int | None = None


class ConfigFlow:
    def __init_subclass__(cls, domain=None):
        pass

    async def async_set_unique_id(self, unique_id):
        self.unique_id = unique_id

    def _abort_if_unique_id_configured(self):
        pass

    def __init__(self):
        self.context = {}

    def async_create_entry(self, **values):
        return {"type": "create_entry", **values}

    def async_show_form(self, **values):
        return {"type": "form", **values}

    def async_abort(self, **values):
        return {"type": "abort", **values}

    def _get_reconfigure_entry(self):
        return self.entry

    def _async_current_entries(self):
        return getattr(self, "entries", [])

    def _async_abort_entries_match(self, values):
        pass

    def async_update_reload_and_abort(self, entry, **values):
        return {"type": "reconfigure", "entry": entry, **values}


class Response:
    def __init__(self, status, payload):
        self.status = status
        self.payload = payload

    async def __aenter__(self):
        return self

    async def __aexit__(self, *arguments):
        return False

    async def json(self):
        if asyncio.isfuture(self.payload):
            return await self.payload
        if isinstance(self.payload, Exception):
            raise self.payload
        return self.payload


class Session:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def request(self, method, url, **options):
        self.calls.append((method, url, options))
        if not self.responses:
            raise AssertionError("Unexpected HTTP request")
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


@pytest.fixture
def ha(monkeypatch):
    def register(name, **attributes):
        module = ModuleType(name)
        module.__path__ = []
        module.__dict__.update(attributes)
        monkeypatch.setitem(sys.modules, name, module)
        return module

    register("homeassistant")
    components = register("homeassistant.components")
    components.infrared = register(
        "homeassistant.components.infrared",
        InfraredEmitterEntity=Entity,
        InfraredReceiverEntity=ReceiverEntity,
        InfraredReceivedSignal=ReceivedSignal,
    )
    register("homeassistant.components.button", ButtonEntity=Entity)
    register("homeassistant.config_entries", ConfigFlow=ConfigFlow)
    register(
        "homeassistant.const",
        CONF_HOST="host",
        CONF_NAME="name",
        CONF_PORT="port",
        Platform=SimpleNamespace(INFRARED="infrared", BUTTON="button"),
        EntityCategory=SimpleNamespace(DIAGNOSTIC="diagnostic"),
    )
    register(
        "homeassistant.exceptions",
        HomeAssistantError=HomeAssistantError,
        PlatformNotReady=HomeAssistantError,
        ConfigEntryNotReady=HomeAssistantError,
    )
    helpers = register("homeassistant.helpers")
    helpers.config_validation = register(
        "homeassistant.helpers.config_validation",
        PLATFORM_SCHEMA=vol.Schema({}),
        string=str,
        port=int,
    )
    discoveries = []

    async def load_platform(*arguments):
        discoveries.append(arguments)

    helpers.discovery = register(
        "homeassistant.helpers.discovery", async_load_platform=load_platform
    )
    register(
        "homeassistant.helpers.aiohttp_client",
        async_get_clientsession=lambda hass: hass.session,
    )

    def load(name, file):
        spec = importlib.util.spec_from_file_location(
            name,
            COMPONENT / file,
            submodule_search_locations=[str(COMPONENT)] if file == "__init__.py" else None,
        )
        module = importlib.util.module_from_spec(spec)
        monkeypatch.setitem(sys.modules, name, module)
        spec.loader.exec_module(module)
        return module

    if os.environ.get("SCHEMA_BACKEND") == "voluptuous":
        monkeypatch.setitem(sys.modules, "probatio", None)
    register("_harmony_test").__path__ = [str(COMPONENT)]
    load("_harmony_test.const", "const.py")
    client = load("_harmony_test.client", "client.py")
    load("_harmony_test.validation", "validation.py")
    package = load("_harmony_test", "__init__.py")
    infrared = load("_harmony_test.infrared", "infrared.py")
    flow = load("_harmony_test.config_flow", "config_flow.py")
    button = load("_harmony_test.button", "button.py")
    tasks = []
    hass = SimpleNamespace(
        data={}, session=Session(), async_create_task=lambda task: tasks.append(task)
    )
    return SimpleNamespace(
        package=package,
        client=client,
        infrared=infrared,
        flow=flow,
        button=button,
        hass=hass,
        discoveries=discoveries,
        tasks=tasks,
        components=components,
        load=load,
        error=HomeAssistantError,
    )


@pytest.fixture
def configuration():
    return {"host": "192.0.2.10", "port": 8089, "name": "Harmony IR"}


@pytest.fixture
def entry(configuration):
    return SimpleNamespace(unique_id="original-emitter-id", entry_id="entry-id", data=configuration)


@pytest.fixture
def health():
    return {
        "api_version": 1,
        "transmitter": "harmony-hal",
        "capture_supported": True,
        "capture_decoder_version": 2,
    }


@pytest.fixture
def capture():
    return {
        "decoder_version": 2,
        "timings_us": [3300, -1600, 420, -420, 420, -200000],
        "carrier_hz_estimate": 38025,
    }
