import importlib.util
import re
import subprocess

import pytest
from conftest import ROOT


@pytest.fixture
def installer():
    spec = importlib.util.spec_from_file_location("installer_under_test", ROOT / "install.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def release_id(script):
    return re.search(r"RELEASE_ID='([0-9a-f]{20})'", script).group(1)


def test_every_runtime_file_is_staged(installer):
    template = (ROOT / "scripts/install.sh").read_text()
    staged = re.search(r"for file in (.+); do", template).group(1).split()
    assert set(staged) == set(installer.PAYLOAD)
    rendered = installer.build_remote_script()
    for filename, path in installer.PAYLOAD.items():
        assert filename in rendered
        assert path.read_text().rstrip() in rendered
    subprocess.run(["sh", "-n"], input=rendered, text=True, check=True)
    subprocess.run(["sh", "-n", str(ROOT / "scripts/service.sh")], check=True)


def test_release_hash_changes_with_payload(installer, tmp_path, monkeypatch):
    payload = tmp_path / "example.lua"
    payload.write_text("return 1\n")
    monkeypatch.setattr(installer, "PAYLOAD", {"example.lua": payload})
    original = installer.build_remote_script()
    assert release_id(original) == release_id(installer.build_remote_script())
    payload.write_text("return 2\n")
    assert release_id(original) != release_id(installer.build_remote_script())


def test_payload_rejects_missing_newline_and_delimiter_collision(installer, tmp_path, monkeypatch):
    payload = tmp_path / "example.lua"
    monkeypatch.setattr(installer, "PAYLOAD", {"example.lua": payload})
    for source in ("return 1", "HARMONY_IR_PAYLOAD_EXAMPLE_LUA\n"):
        payload.write_text(source)
        with pytest.raises(ValueError):
            installer.build_remote_script()


def test_dry_run_never_connects(installer, tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(installer.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(installer.shutil, "which", lambda program: "/usr/bin/ssh")
    monkeypatch.setattr(installer.sys, "argv", ["install.py", "--host", "192.0.2.10", "--dry-run"])
    monkeypatch.setattr(
        installer.subprocess, "run", lambda *args, **kwargs: pytest.fail("Unexpected SSH")
    )
    assert installer.main() == 0
    assert "no SSH connection or device changes" in capsys.readouterr().out


@pytest.mark.parametrize(
    "host", ["root@example.com", "example.com;id", "https://example.com", "bad\nhost"]
)
def test_host_injection_is_rejected(installer, host, monkeypatch):
    monkeypatch.setattr(installer.sys, "argv", ["install.py", "--host", host, "--dry-run"])
    with pytest.raises(SystemExit) as error:
        installer.main()
    assert error.value.code == 2


def test_no_source_depends_on_analysis_workspace():
    sources = [ROOT / "install.py", *(ROOT / "custom_components").rglob("*.py")]
    for path in sources:
        for analysis_path in ("lua-decompiled", "lua-normalized", "firmware/tools"):
            assert analysis_path not in path.read_text()
