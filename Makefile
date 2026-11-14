PYTHON ?= python3
LUA ?= lua5.1

.PHONY: test test-python test-lua lint

test: test-lua test-python lint

test-python:
	SCHEMA_BACKEND=probatio PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m pytest -q
	SCHEMA_BACKEND=voluptuous PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m pytest -q tests/test_config_flow.py

test-lua:
	$(LUA) -e 'assert(_VERSION == "Lua 5.1", "Lua 5.1 or LuaJIT is required")'
	$(LUA) test.lua
	$(LUA) test_bridge.lua
	$(LUA) test_capture.lua

lint:
	$(PYTHON) -m ruff check --no-cache .
	$(PYTHON) -m ruff format --check --no-cache .
	sh -n install
	sh -n scripts/install.sh
	sh -n scripts/service.sh
