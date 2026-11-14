PYTHON ?= python3

.PHONY: test test-python lint

test: test-python lint

test-python:
	SCHEMA_BACKEND=probatio PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m pytest -q
	SCHEMA_BACKEND=voluptuous PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m pytest -q tests/test_config_flow.py

lint:
	$(PYTHON) -m ruff check --no-cache .
	$(PYTHON) -m ruff format --check --no-cache .
	sh -n hub/scripts/install.sh
	sh -n hub/scripts/service.sh
