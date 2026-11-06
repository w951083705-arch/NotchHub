#!/usr/bin/python3 -I
"""把各智能体的审批接到 NotchHub。可重复执行，改动前会备份配置。

  tools/approval-hooks.py status
  tools/approval-hooks.py install [claude codex workbuddy gemini dsh]
  tools/approval-hooks.py uninstall [同上]
"""
import json, os, pathlib, shutil, sys, time

HOME = pathlib.Path.home()
ROOT = pathlib.Path(__file__).resolve().parent.parent
HOOK = HOME / ".local/bin/notchhub-approval-hook"
MARK = "notchhub-approval-hook"
JSON_TARGETS = {
    "claude": (HOME / ".claude/settings.json", "Claude"),
    "codex": (HOME / ".codex/hooks.json", "Codex"),
    "workbuddy": (HOME / ".workbuddy/settings.json", "WorkBuddy"),
}
GEMINI = HOME / ".gemini/config/hooks.json"
DSH_PATCH = HOME / ".dsh/profiles/desktop/cordis.patch.yml"
DSH_PLUGIN = HOME / ".dsh/profiles/node_modules/dsh-agent-hud-approval"
DSH_BLOCK = """- insert:
    - id: agent-hud-approval
      name: dsh-agent-hud-approval
      config:
        socket: /tmp/agenthud-approval.sock
        timeoutMs: 120000
"""
ALL = [*JSON_TARGETS, "gemini", "dsh"]


def load(path):
    return json.loads(path.read_text()) if path.exists() else {}


def write(path, text):
    """先备份再原子替换，保留原文件权限。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        shutil.copy2(path, f"{path}.bak.{time.strftime('%Y%m%d-%H%M%S')}-notchhub")
    tmp = path.with_name(path.name + ".notchhub-tmp")
    tmp.write_text(text)
    if path.exists():
        shutil.copymode(path, tmp)
    tmp.replace(path)


def dump(data):
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def without_mark(groups):
    return [g for g in groups if MARK not in json.dumps(g)]


def json_installed(path):
    return MARK in json.dumps(load(path).get("hooks", {}))


def install_json(path, agent):
    data = load(path)
    hooks = data.setdefault("hooks", {})
    hooks["PermissionRequest"] = without_mark(hooks.get("PermissionRequest", [])) + [{
        "matcher": "",
        "hooks": [{"type": "command", "command": f"{HOOK} --agent {agent}", "timeout": 130,
                   "statusMessage": "等待 NotchHub 审批"}],
    }]
    write(path, dump(data))


def uninstall_json(path):
    data = load(path)
    hooks = data.get("hooks", {})
    left = without_mark(hooks.get("PermissionRequest", []))
    if left:
        hooks["PermissionRequest"] = left
    else:
        hooks.pop("PermissionRequest", None)
    if not hooks:
        data.pop("hooks", None)
    write(path, dump(data))


def installed(name):
    if name in JSON_TARGETS:
        return json_installed(JSON_TARGETS[name][0])
    if name == "gemini":
        return "notchhub-approval" in load(GEMINI)
    return DSH_PLUGIN.exists() and DSH_PATCH.exists() and DSH_BLOCK in DSH_PATCH.read_text()


def install(name):
    if name in JSON_TARGETS:
        install_json(*JSON_TARGETS[name])
    elif name == "gemini":
        data = load(GEMINI)
        # agy 没有 PermissionRequest，PreToolUse 对每次工具调用都触发，所以只接执行命令。
        data["notchhub-approval"] = {"PreToolUse": [{"matcher": "run_command", "hooks": [
            {"type": "command", "command": f"{HOOK} --agent Gemini --format agy", "timeout": 130}]}]}
        write(GEMINI, dump(data))
    else:
        if not DSH_PATCH.exists():
            raise SystemExit(f"未找到 {DSH_PATCH}，请先运行一次 DeepSeek Harness")
        DSH_PLUGIN.mkdir(parents=True, exist_ok=True)
        for file in ("index.js", "package.json"):
            shutil.copy2(ROOT / "integrations/dsh-agent-hud-approval" / file, DSH_PLUGIN / file)
        text = DSH_PATCH.read_text()
        if DSH_BLOCK not in text:
            write(DSH_PATCH, text.rstrip("\n") + "\n" + DSH_BLOCK)


def uninstall(name):
    if name in JSON_TARGETS:
        uninstall_json(JSON_TARGETS[name][0])
    elif name == "gemini":
        data = load(GEMINI)
        data.pop("notchhub-approval", None)
        write(GEMINI, dump(data))
    else:
        if DSH_PATCH.exists() and DSH_BLOCK in DSH_PATCH.read_text():
            write(DSH_PATCH, DSH_PATCH.read_text().replace(DSH_BLOCK, ""))
        shutil.rmtree(DSH_PLUGIN, ignore_errors=True)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    names = sys.argv[2:] or ALL
    unknown = [n for n in names if n not in ALL]
    if command not in ("status", "install", "uninstall") or unknown:
        raise SystemExit(__doc__)
    if command == "install":
        HOOK.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "tools/notchhub-approval-hook", HOOK)
        HOOK.chmod(0o755)
    for name in names:
        if command == "install" and not installed(name):
            install(name)
        elif command == "uninstall" and installed(name):
            uninstall(name)
        print(f"{name}: {'已接入' if installed(name) else '未接入'}")
    if command == "install" and "codex" in names:
        print("Codex 还需要你确认信任钩子：CLI 里运行 /hooks，或在桌面应用的 设置 > Hooks 中确认。")
    if command == "install":
        print("已打开的智能体需要重启后才会读取新配置。")


if __name__ == "__main__":
    main()
