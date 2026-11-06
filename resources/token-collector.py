#!/usr/bin/env python3
"""把 DSH / Codex / Claude Code 的 token 用量聚合成 24 小时直方图，供 Agent HUD 显示。
NotchHub 版：在 AgentHUD 原版基础上增加 Claude Code（~/.claude/projects）。
输出: /tmp/agenthud-tokens.json
"""
import json, os, sys, glob, time, datetime

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))

OUT = os.environ.get("AGENTHUD_TOKEN_OUTPUT", os.path.expanduser("~/Library/Caches/NotchHub/tokens.json"))
HOME = os.path.expanduser("~")
HOURS = 24


def recent(files, cutoff):
    """只处理统计窗口内改动过的文件，否则每次都要全量读取所有历史会话。"""
    result = []
    for f in files:
        try:
            if os.path.getmtime(f) >= cutoff:
                result.append(f)
        except OSError:
            pass
    return result


def hour_key(ts):
    return int(ts // 3600 * 3600)


def collect_dsh(buckets, cutoff=0, now=float("inf")):
    try:
        import zstandard
    except Exception:
        return 0, 0  # 可选依赖：没有 zstandard 时只跳过 DSH，不影响其他智能体
    files = glob.glob(os.path.join(HOME, ".dsh/sessions/*/*/session*.jsonl.zstd"))
    d = zstandard.ZstdDecompressor()
    total = events = 0
    for f in recent(files, cutoff):
        try:
            with open(f, "rb") as fh:
                raw = d.stream_reader(fh).read().decode("utf-8", "ignore")
        except Exception:
            continue
        for line in raw.splitlines():
            if '"usage"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            data = o.get("data") or {}
            u = None
            # v4: assistant/message 带 usage
            if isinstance(data.get("usage"), dict):
                u = data["usage"]
            # 旧格式: assistant/chunk -> chunk.type == usage
            else:
                ch = data.get("chunk") or {}
                if ch.get("type") == "usage":
                    u = ch.get("usage") or {}
            if not isinstance(u, dict):
                continue
            t = o.get("time")
            if not isinstance(t, (int, float)):
                continue
            n = u.get("totalTokens") or ((u.get("inputTokens") or 0) + (u.get("outputTokens") or 0) + (u.get("cacheReadTokens") or 0))
            if n <= 0:
                continue
            if not cutoff <= t / 1000.0 <= now:
                continue
            k = hour_key(t / 1000.0)
            buckets.setdefault(k, {"dsh": 0, "codex": 0, "claude": 0})["dsh"] += n
            total += n
            events += 1
    return total, events


def collect_codex(buckets, cutoff=0, now=float("inf")):
    files = glob.glob(os.path.join(HOME, ".codex/sessions/*/*/*/*.jsonl"))
    total = events = 0
    for f in recent(files, cutoff):
        try:
            fh = open(f, "r", encoding="utf-8", errors="ignore")
        except Exception:
            continue
        previous = None
        for line in fh:
            if '"token_count"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if (o.get("payload") or {}).get("type") != "token_count":
                continue
            ts = o.get("timestamp")
            if not ts:
                continue
            try:
                dt = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%fZ")
            except Exception:
                try:
                    dt = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                except Exception:
                    continue
            t = dt.replace(tzinfo=datetime.timezone.utc).timestamp()
            info = (o.get("payload") or {}).get("info") or {}
            last = info.get("last_token_usage") or {}
            cumulative = (info.get("total_token_usage") or {}).get("total_tokens")
            if isinstance(cumulative, (int, float)) and cumulative >= 0:
                # 累计值不变的额度通知不是一次新调用；回退时仅计本次增量。
                n = max(0, cumulative - previous) if previous is not None and cumulative >= previous else last.get("total_tokens", 0)
                previous = cumulative
            else:
                n = last.get("total_tokens", 0)
            if not isinstance(n, (int, float)) or n <= 0 or not cutoff <= t <= now:
                continue
            k = hour_key(t)
            buckets.setdefault(k, {"dsh": 0, "codex": 0, "claude": 0})["codex"] += n
            total += n
            events += 1
        fh.close()
    return total, events


def collect_claude(buckets, cutoff=0, now=float("inf")):
    # 同一条 assistant 消息会按内容块重复记录，按 message.id 去重；计入输入、缓存与输出，口径与 Codex total_tokens 一致。
    files = glob.glob(os.path.join(HOME, ".claude/projects/*/*.jsonl"))
    seen = set()
    total = events = 0
    for f in recent(files, cutoff):
        try:
            if os.path.getmtime(f) < cutoff:
                continue
            fh = open(f, "r", encoding="utf-8", errors="ignore")
        except Exception:
            continue
        for line in fh:
            if '"usage"' not in line or '"assistant"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            msg = o.get("message") or {}
            u = msg.get("usage") or {}
            mid = msg.get("id")
            if not u or (mid and mid in seen):
                continue
            ts = o.get("timestamp") or ""
            try:
                t = datetime.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
            except Exception:
                continue
            if not cutoff <= t <= now:
                continue
            n = sum(u.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"))
            if n <= 0:
                continue
            if mid:
                seen.add(mid)
            buckets.setdefault(hour_key(t), {"dsh": 0, "codex": 0, "claude": 0}).setdefault("claude", 0)
            buckets[hour_key(t)]["claude"] += n
            total += n
            events += 1
        fh.close()
    return total, events


def main():
    now = time.time()
    buckets = {}
    dsh_total, dsh_events = collect_dsh(buckets, now - HOURS * 3600, now)
    codex_total, codex_events = collect_codex(buckets, now - HOURS * 3600, now)
    claude_total, claude_events = collect_claude(buckets, now - HOURS * 3600, now)

    current = hour_key(now)
    series = []
    for i in range(HOURS, -1, -1):
        k = current - i * 3600
        b = buckets.get(k, {})
        series.append({"t": k, "dsh": b.get("dsh", 0), "codex": b.get("codex", 0), "claude": b.get("claude", 0)})

    # 速率：最近 1 小时 vs 上一个小时
    hour_sum = lambda s: s["dsh"] + s["codex"] + s["claude"]
    last = hour_sum(series[-1])
    prev = hour_sum(series[-2]) if len(series) > 1 else 0
    payload = {
        "hours": series,
        "dshTotal24h": sum(s["dsh"] for s in series),
        "codexTotal24h": sum(s["codex"] for s in series),
        "claudeTotal24h": sum(s["claude"] for s in series),
        "lastHour": last,
        "prevHour": prev,
        "dshEvents": dsh_events,
        "codexEvents": codex_events,
        "claudeEvents": claude_events,
        "updated": now,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f)
    os.replace(tmp, OUT)


if __name__ == "__main__":
    main()
