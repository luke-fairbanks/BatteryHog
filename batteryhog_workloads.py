#!/usr/bin/env python3
"""Development-workload discovery for Battery Hog.

This module turns short-lived compiler, build, test, scan, and dev-server
processes into stable project-level workloads.  It deliberately uses only the
Python standard library and macOS's built-in ``lsof`` command.
"""

import hashlib
import os
import re
import subprocess
import time


_CWD_CACHE = {}
_CWD_TTL = 20.0
_SYSTEM_ASSERTION_OWNERS = {
    "powerd", "runningboardd", "sharingd", "bluetoothd", "WindowServer",
    "mds", "mds_stores", "coreaudiod", "airportd", "apsd",
}


def _matches(command, pattern):
    return re.search(pattern, command, re.IGNORECASE) is not None


def agent_owner(command):
    """Return the agent/editor family represented by a command, if any."""
    low = command.lower()
    if "battery_hog" in low or "batteryhog" in low:
        return None
    if "claude" in low:
        return "Claude"
    if "chatgpt.app" in low or _matches(low, r"(?:^|[/\s])codex(?:$|[\s])"):
        return "Codex"
    if "cursor.app" in low or _matches(low, r"(?:^|[/\s])cursor(?:$|[\s])"):
        return "Cursor"
    if "visual studio code.app" in low or "code helper" in low:
        return "VS Code"
    return None


def classify_dev_command(command):
    """Describe a development process or return ``None``.

    ``kind`` is intentionally coarse because it is used for power scheduling,
    not as a full process taxonomy. ``heavy`` means the command belongs behind
    the optional Agent Mode gate when it is actively consuming CPU.
    """
    low = command.lower()
    if not low or "battery_hog" in low or "batteryhog_workloads" in low:
        return None

    owner = agent_owner(command)
    if owner:
        return {"family": "Agents", "tool": owner, "kind": "agent", "heavy": False}

    rules = [
        (r"(?:^|[/\s])gitleaks(?:$|[\s])", "Security", "gitleaks", "scan", True),
        (r"(?:^|[/\s])semgrep(?:$|[\s])", "Security", "Semgrep", "scan", True),
        (r"(?:^|[/\s])trivy(?:$|[\s])", "Security", "Trivy", "scan", True),
        (r"(?:^|[/\s])rustc(?:$|[\s])", "Rust", "rustc", "compiler", True),
        (r"(?:^|[/\s])cargo(?:$|[\s])", "Rust", "Cargo", "build", True),
        (r"(?:^|[/\s])sccache(?:$|[\s])", "Rust", "sccache", "compiler", True),
        (r"org\.jetbrains\.kotlin|kotlincompiledaemon|kotlinc", "Kotlin", "Kotlin", "compiler", True),
        (r"org\.gradle|gradlewrappermain|(?:^|[/\s])gradlew?(?:$|[\s])", "JVM", "Gradle", "build", True),
        (r"(?:^|[/\s])java(?:$|[\s])", "JVM", "Java", "worker", True),
        (r"(?:^|[/\s])xcodebuild(?:$|[\s])", "Apple", "Xcode", "build", True),
        (r"(?:^|[/\s])swiftc(?:$|[\s])", "Apple", "Swift", "compiler", True),
        (r"(?:^|[/\s])swift(?:$|[\s]).*(?:build|test|package)", "Apple", "SwiftPM", "build", True),
        (r"(?:^|[/\s])pod(?:$|[\s])|cocoapods|pod install", "Apple", "CocoaPods", "install", True),
        (r"(?:^|[/\s])go(?:$|[\s]+)(?:build|test|run|install)", "Go", "Go", "build", True),
        (r"(?:^|[/\s])pytest(?:$|[\s])|python[^\n]*-m\s+pytest", "Python", "pytest", "test", True),
        (r"(?:^|[/\s])(ruff|mypy|pyright)(?:$|[\s])", "Python", "Python checks", "test", True),
        (r"(?:^|[/\s])(jest|vitest|playwright|cypress)(?:$|[\s])", "Node", "JavaScript tests", "test", True),
        (r"(?:^|[/\s])(tsc|esbuild|webpack|rollup|turbo)(?:$|[\s])", "Node", "JavaScript build", "build", True),
        (r"(?:^|[/\s])(npm|pnpm|yarn|bun)(?:$|[\s]).*(?:install|ci|build|test)", "Node", "Node package task", "build", True),
        (r"next-server|next\s+dev|vite(?:$|[\s])|webpack-dev-server|react-scripts\s+start", "Node", "Dev server", "server", False),
        (r"(?:^|[/\s])(npm|pnpm|yarn|bun|npx)(?:$|[\s])", "Node", "Node task", "worker", True),
        (r"(?:^|[/\s])node(?:$|[\s])|\(node\)", "Node", "Node", "worker", True),
        (r"(?:^|[/\s])(make|cmake|ninja)(?:$|[\s])", "Native", "Native build", "build", True),
    ]
    for pattern, family, tool, kind, heavy in rules:
        if _matches(low, pattern):
            return {"family": family, "tool": tool, "kind": kind, "heavy": heavy}
    return None


def _run_lsof(pids):
    if not pids:
        return ""
    try:
        result = subprocess.run(
            ["/usr/sbin/lsof", "-a", "-d", "cwd", "-p", ",".join(str(p) for p in pids), "-Fn"],
            capture_output=True, text=True, timeout=4,
        )
        return result.stdout
    except Exception:
        return ""


def collect_cwds(pids):
    """Return ``pid -> cwd`` with a short cache for persistent workers."""
    now = time.monotonic()
    wanted = sorted({int(p) for p in pids if int(p) > 0})
    missing = [p for p in wanted if p not in _CWD_CACHE or now - _CWD_CACHE[p][0] > _CWD_TTL]
    for start in range(0, len(missing), 70):
        chunk = missing[start:start + 70]
        found = {}
        current = None
        for line in _run_lsof(chunk).splitlines():
            if line.startswith("p") and line[1:].isdigit():
                current = int(line[1:])
            elif line.startswith("n") and current is not None:
                found[current] = line[1:]
        for pid in chunk:
            _CWD_CACHE[pid] = (now, found.get(pid))

    stale = [pid for pid, (seen, _cwd) in _CWD_CACHE.items() if now - seen > 120]
    for pid in stale:
        _CWD_CACHE.pop(pid, None)
    return {pid: _CWD_CACHE.get(pid, (0, None))[1] for pid in wanted}


def _candidate_and_ancestor_pids(samples):
    by_pid = {int(p["pid"]): p for p in samples}
    out = set()
    for proc in samples:
        if not classify_dev_command(proc.get("command", "")):
            continue
        pid = int(proc["pid"])
        for _ in range(7):
            if pid <= 0 or pid in out:
                break
            out.add(pid)
            parent = by_pid.get(pid, {}).get("ppid", 0)
            try:
                pid = int(parent)
            except (TypeError, ValueError):
                break
    return out


def _resolved_cwd(pid, by_pid, cwd_by_pid):
    seen = set()
    while pid and pid not in seen:
        seen.add(pid)
        cwd = cwd_by_pid.get(pid)
        if cwd:
            return cwd
        proc = by_pid.get(pid)
        if not proc:
            break
        pid = int(proc.get("ppid", 0) or 0)
    return None


def _clean_temp_name(name):
    # Codex/audit worktrees commonly end in a random six-character suffix.
    return re.sub(r"[._-][A-Za-z0-9]{6}$", "", name)


def project_for_cwd(cwd):
    """Return a stable project label/root for a working directory."""
    if not cwd or not os.path.isabs(cwd):
        return None
    if cwd.startswith(("/System/", "/usr/", "/bin/", "/sbin/", "/Applications/")):
        return None
    home = os.path.expanduser("~")
    try:
        home_rel = os.path.relpath(cwd, home)
        first_part = home_rel.split(os.sep, 1)[0]
        if not home_rel.startswith("..") and (first_part.startswith(".") or first_part == "Library"):
            return None
    except ValueError:
        pass

    cur = os.path.realpath(cwd)
    nearest = None
    git_root = None
    markers = ("Cargo.toml", "package.json", "pyproject.toml", "go.mod", "Podfile", "Package.swift", "gradlew")
    for _ in range(14):
        if os.path.exists(os.path.join(cur, ".git")):
            git_root = cur
            break
        if nearest is None and any(os.path.exists(os.path.join(cur, m)) for m in markers):
            nearest = cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    root = git_root or nearest or os.path.realpath(cwd)
    name = os.path.basename(root.rstrip(os.sep)) or "Development"
    if name.lower() in {"repo", "checkout", "worktree"}:
        name = os.path.basename(os.path.dirname(root.rstrip(os.sep))) or name
    name = _clean_temp_name(name)
    try:
        context = os.path.relpath(os.path.realpath(cwd), root)
    except ValueError:
        context = "."
    if context == "." or context.startswith(".."):
        context = ""
    elif len(context.split(os.sep)) > 3:
        context = os.sep.join(context.split(os.sep)[-3:])
    short_root = root.replace(os.path.expanduser("~"), "~", 1)
    return {"name": name, "root": root, "path": short_root, "context": context}


def _ancestor_agent(pid, by_pid):
    seen = set()
    while pid and pid not in seen:
        seen.add(pid)
        proc = by_pid.get(pid)
        if not proc:
            break
        owner = agent_owner(proc.get("command", ""))
        if owner:
            return owner
        pid = int(proc.get("ppid", 0) or 0)
    return None


def aggregate_workloads(samples, cwd_by_pid):
    """Pure aggregation step used by both the app and unit tests."""
    by_pid = {int(p["pid"]): p for p in samples}
    groups = {}
    agent_names = set()

    for proc in samples:
        command = proc.get("command", "")
        info = classify_dev_command(command)
        if not info:
            continue
        if info["kind"] == "agent":
            continue

        pid = int(proc["pid"])
        cpu = max(0.0, float(proc.get("cpu", 0.0) or 0.0))
        rss = max(0, int(proc.get("rss_kb", 0) or 0))
        cwd = _resolved_cwd(pid, by_pid, cwd_by_pid)
        project = project_for_cwd(cwd)
        if project is None and info["kind"] in {"worker", "server"} and cpu < 1.0:
            # Ignore idle runtime/plugin helpers that are not rooted in a user
            # project. Active workers still appear as a background toolchain.
            continue
        if project:
            key = project["root"]
        else:
            key = "background:" + info["family"]
            project = {"name": info["family"] + " tools", "root": key, "path": "Background", "context": ""}

        group = groups.setdefault(key, {
            "id": hashlib.sha1(key.encode("utf-8", "replace")).hexdigest()[:12],
            "name": project["name"], "path": project["path"], "context": project["context"],
            "cpu": 0.0, "mem_kb": 0, "workers": 0, "active_workers": 0,
            "heavy_workers": 0, "servers": 0, "families": set(), "tools": {},
            "pids": [], "agents": set(), "kinds": {},
        })
        group["cpu"] += cpu
        group["mem_kb"] += rss
        group["workers"] += 1
        group["pids"].append(pid)
        group["families"].add(info["family"])
        group["tools"][info["tool"]] = group["tools"].get(info["tool"], 0) + 1
        group["kinds"][info["kind"]] = group["kinds"].get(info["kind"], 0.0) + cpu
        if info["kind"] == "server":
            group["servers"] += 1
        if cpu >= 1.0:
            group["active_workers"] += 1
            if info["heavy"]:
                group["heavy_workers"] += 1
        owner = _ancestor_agent(pid, by_pid)
        if owner:
            group["agents"].add(owner)
            agent_names.add(owner)

    workloads = []
    for group in groups.values():
        cpu = round(group["cpu"], 1)
        mem_mb = round(group.pop("mem_kb") / 1024.0, 1)
        heavy = group["heavy_workers"]
        if cpu >= 180 or heavy >= 5:
            level = "high"
        elif cpu >= 35 or heavy >= 2 or group["servers"] >= 3:
            level = "med"
        else:
            level = "low"

        kind_cpu = group.pop("kinds")
        active_kinds = [(cpu_used, kind) for kind, cpu_used in kind_cpu.items()]
        active_kinds.sort(reverse=True)
        if active_kinds and active_kinds[0][0] > 0:
            dominant = active_kinds[0][1]
        elif group["servers"]:
            dominant = "server"
        else:
            dominant = "worker"
        status_labels = {
            "build": "Building", "compiler": "Compiling", "test": "Testing",
            "install": "Installing", "scan": "Scanning", "server": "Serving",
            "worker": "Active",
        }
        if group["active_workers"] == 0 and group["servers"]:
            status = "Serving"
        elif group["active_workers"] == 0:
            status = "Idle"
        else:
            status = status_labels.get(dominant, "Active")

        tools = sorted(group["tools"].items(), key=lambda item: (-item[1], item[0]))
        group.update({
            "cpu": cpu, "mem_mb": mem_mb, "level": level, "status": status,
            "families": sorted(group["families"]),
            "tools": [{"name": name, "count": count} for name, count in tools[:6]],
            "agents": sorted(group["agents"]), "pids": group["pids"][:80],
            "score": round(cpu + mem_mb / 75.0 + heavy * 8.0, 1),
        })
        workloads.append(group)

    workloads.sort(key=lambda w: w["score"], reverse=True)
    summary = {
        "projects": len(workloads),
        "workers": sum(w["workers"] for w in workloads),
        "active_workers": sum(w["active_workers"] for w in workloads),
        "heavy_workers": sum(w["heavy_workers"] for w in workloads),
        "servers": sum(w["servers"] for w in workloads),
        "cpu": round(sum(w["cpu"] for w in workloads), 1),
        "mem_mb": round(sum(w["mem_mb"] for w in workloads), 1),
        "agents": sorted(agent_names),
        "toolchains": sorted({family for w in workloads for family in w["families"]}),
    }
    if summary["cpu"] >= 250 or summary["heavy_workers"] >= 7:
        summary["level"] = "high"
    elif summary["cpu"] >= 60 or summary["heavy_workers"] >= 2:
        summary["level"] = "med"
    else:
        summary["level"] = "low"
    return {"workloads": workloads[:24], "summary": summary}


def discover_workloads(samples):
    """Collect candidate working directories and aggregate current workloads."""
    pids = _candidate_and_ancestor_pids(samples)
    return aggregate_workloads(samples, collect_cwds(pids))


def _duration_seconds(value):
    try:
        parts = [int(p) for p in value.split(":")]
        if len(parts) == 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
    except (TypeError, ValueError):
        pass
    return 0


def parse_pmset_assertions(text):
    """Parse application sleep assertions from ``pmset -g assertions``."""
    blockers = []
    pattern = re.compile(
        r"pid\s+(\d+)\(([^)]+)\):.*?(\d+:\d+:\d+)\s+"
        r"(NoIdleSleepAssertion|PreventUserIdleSystemSleep|PreventSystemSleep|PreventUserIdleDisplaySleep)"
        r"\s+named:\s+\"([^\"]*)\""
    )
    for line in text.splitlines():
        match = pattern.search(line)
        if not match:
            continue
        pid, name, duration, assertion, detail = match.groups()
        seconds = _duration_seconds(duration)
        system = name in _SYSTEM_ASSERTION_OWNERS or name.startswith("com.apple.")
        blockers.append({
            "pid": int(pid), "name": name, "duration": duration,
            "duration_s": seconds, "assertion": assertion, "detail": detail,
            "system": system, "stale": (not system and seconds >= 15 * 60),
        })
    blockers.sort(key=lambda b: (b["system"], -b["duration_s"]))
    return blockers
