#!/usr/bin/python3 -I
"""在临时 HOME 里测试 approval-hooks.py：保留原配置、可重复安装、卸载后还原。"""
import json, os, pathlib, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
home = pathlib.Path(tempfile.mkdtemp(prefix="nh-home"))
(home / ".claude").mkdir()
(home / ".claude/settings.json").write_text(json.dumps({"env": {"A": "1"}, "hooks": {"PermissionRequest": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "mine"}]}], "Stop": []}}))
(home / ".dsh/profiles/desktop").mkdir(parents=True)
(home / ".dsh/profiles/desktop/cordis.patch.yml").write_text("- id: x\n  name: y\n")


def run(*args):
    done = subprocess.run(["/usr/bin/python3", "-I", "-c",
        "import os,pathlib,runpy,sys; pathlib.Path.home=lambda *_: pathlib.Path(os.environ['TEST_HOME']); sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='__main__')",
        str(ROOT / "tools/approval-hooks.py"), *args], env={**os.environ, "TEST_HOME": str(home)}, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    return done.stdout


claude = home / ".claude/settings.json"
original = json.loads(claude.read_text())
output = run("install")
assert output.count("已接入") >= 5, output
data = json.loads(claude.read_text())
assert data["env"] == {"A": "1"} and "Stop" in data["hooks"] and len(data["hooks"]["PermissionRequest"]) == 2
print("通过 安装保留原有配置")
run("install")
assert len(json.loads(claude.read_text())["hooks"]["PermissionRequest"]) == 2
assert (home / ".dsh/profiles/desktop/cordis.patch.yml").read_text().count("id: agent-hud-approval") == 1
print("通过 重复安装不叠加")
assert list(home.joinpath(".claude").glob("settings.json.bak.*")), "应有备份"
print("通过 改动前备份")
output = run("uninstall")
assert output.count("未接入") >= 5, output
assert json.loads(claude.read_text()) == original
assert (home / ".dsh/profiles/desktop/cordis.patch.yml").read_text() == "- id: x\n  name: y\n"
print("通过 卸载还原")
