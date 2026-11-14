PYTHON ?= python3
LUA ?= lua5.1

.PHONY: test test-python test-lua lint

test: test-lua test-python lint

test-python:
	SCHEMA_BACKEND=probatio PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m pytest -q
	SCHEMA_BACKEND=voluptuous PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m pytest -q tests/home_assistant/test_config_flow.py

test-lua:
	$(LUA) -e 'assert(_VERSION == "Lua 5.1", "Lua 5.1 or LuaJIT is required")'
	$(LUA) tests/hub/test_ir.lua
	$(LUA) tests/hub/test_bridge.lua
	$(LUA) tests/hub/test_capture.lua

lint:
	$(PYTHON) -m ruff check --no-cache .
	$(PYTHON) -m ruff format --check --no-cache .
	sh -n install
	sh -n hub/scripts/install.sh
	sh -n hub/scripts/service.sh
