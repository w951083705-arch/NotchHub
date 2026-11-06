#!/usr/bin/python3 -I
"""用假的审批服务测试 notchhub-approval-hook，不会弹真实卡片。"""
import json, os, pathlib, socket, subprocess, tempfile, threading

HOOK = str(pathlib.Path(__file__).resolve().parent.parent / "tools/notchhub-approval-hook")
tmp = tempfile.mkdtemp(prefix="nh", dir="/tmp")
SOCK = tmp + "/a.sock"
seen = []


def serve(decision, wrong_id=False, close=False):
    server = socket.socket(socket.AF_UNIX)
    server.bind(SOCK)
    server.listen(1)
    def run():
        client, _ = server.accept()
        data = b""
        while b"\n" not in data:
            data += client.recv(65536)
        request = json.loads(data)
        seen.append(request)
        if not close:
            client.sendall((json.dumps({"id": "x" if wrong_id else request["id"], "decision": decision}) + "\n").encode())
        client.close()
        server.close()
        os.unlink(SOCK)
    thread = threading.Thread(target=run)
    thread.start()
    return thread


def hook(event, *extra):
    done = subprocess.run([HOOK, "--socket", SOCK, *extra], input=json.dumps(event), capture_output=True, text=True, timeout=20)
    assert done.returncode == 0, done.stderr
    return json.loads(done.stdout) if done.stdout.strip() else None


CLAUDE = {"tool_name": "Bash", "tool_input": {"command": "rm -rf build", "description": "清理"}}
AGY = {"toolCall": {"name": "run_command", "args": {"CommandLine": "npm test"}}}
ALLOW = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}


def check(name, got, want):
    assert got == want, f"{name}: {got!r} != {want!r}"
    print("通过", name)


t = serve("allowed-once"); got = hook(CLAUDE, "--agent", "Claude"); t.join(); check("允许", got, ALLOW)
check("卡片内容", (seen[-1]["agent"], seen[-1]["tool"], seen[-1]["command"], seen[-1]["reason"]), ("Claude", "Bash", "rm -rf build", "清理"))
t = serve("rejected"); got = hook(CLAUDE); t.join(); check("拒绝", got["hookSpecificOutput"]["decision"]["behavior"], "deny")
t = serve("unavailable"); got = hook(CLAUDE); t.join(); check("超时不做决定", got, None)
t = serve("allowed-once", wrong_id=True); got = hook(CLAUDE); t.join(); check("回复 id 不符不放行", got, None)
t = serve("", close=True); got = hook(CLAUDE); t.join(); check("连接中断不放行", got, None)
check("NotchHub 没运行不放行", hook(CLAUDE), None)
open(SOCK, "w").close(); check("路径不是 socket 不放行", hook(CLAUDE), None); os.unlink(SOCK)
t = serve("allowed-once"); got = hook(AGY, "--format", "agy"); t.join(); check("agy 允许", got, {"decision": "allow"})
check("agy 命令显示", seen[-1]["command"], "npm test")
t = serve("rejected"); got = hook(AGY, "--format", "agy"); t.join(); check("agy 拒绝", got["decision"], "deny")
check("agy 没运行走自带审批", hook(AGY, "--format", "agy"), {"decision": "ask"})
done = subprocess.run([HOOK, "--socket", SOCK], input="不是 JSON", capture_output=True, text=True)
check("坏输入不放行", (done.returncode, done.stdout), (0, ""))
check("提问类工具不接管", hook({"tool_name": "AskUserQuestion", "tool_input": {}}), None)
os.rmdir(tmp)
