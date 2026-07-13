#!/usr/bin/env python3
"""Optional battery-aware execution gate for coding agents.

When Agent Mode is enabled in Battery Hog and the Mac is on battery power,
heavy commands launched through this wrapper share a small global semaphore.
On AC power—or while Agent Mode is disabled—the wrapper immediately execs the
command without changing its behavior.
"""

import argparse
import fcntl
import json
import os
import shlex
import signal
import subprocess
import sys
import time


DEFAULT_DATA_DIR = os.path.expanduser("~/Library/Application Support/BatteryHog")


def data_dir():
    return os.environ.get("BATTERY_HOG_DATA_DIR", DEFAULT_DATA_DIR)


def settings_path():
    return os.path.join(data_dir(), "settings.json")


def registry_path():
    return os.path.join(data_dir(), "agent-gate.json")


def load_dev_settings():
    defaults = {"enabled": False, "slots": 2, "workers": 2, "draw_threshold": 30, "notify_draw": True}
    try:
        with open(settings_path(), encoding="utf-8") as handle:
            value = json.load(handle).get("dev", {})
        if isinstance(value, dict):
            defaults.update(value)
    except Exception:
        pass
    defaults["enabled"] = bool(defaults.get("enabled"))
    for key in ("slots", "workers"):
        try:
            defaults[key] = max(1, min(8, int(defaults[key])))
        except (TypeError, ValueError):
            defaults[key] = 2
    return defaults


def on_battery():
    try:
        out = subprocess.run(["/usr/bin/pmset", "-g", "batt"], capture_output=True,
                             text=True, timeout=3).stdout
        return "Battery Power" in out
    except Exception:
        return False


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        # The process exists but this execution context cannot signal it.
        return True
    except (ProcessLookupError, TypeError, ValueError):
        return False


def _read_registry(handle):
    handle.seek(0)
    try:
        value = json.load(handle)
        if not isinstance(value, dict):
            raise ValueError
    except Exception:
        value = {"version": 1, "entries": []}
    entries = value.get("entries") if isinstance(value.get("entries"), list) else []
    value["entries"] = [e for e in entries if _pid_alive(e.get("pid"))]
    return value


def _update_registry(callback):
    os.makedirs(data_dir(), exist_ok=True)
    path = registry_path()
    with open(path, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        value = _read_registry(handle)
        result = callback(value)
        value["updated_at"] = int(time.time())
        handle.seek(0)
        handle.truncate()
        json.dump(value, handle)
        handle.flush()
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    return result


def gate_snapshot():
    """Return live active/queued entries and prune abandoned gate processes."""
    try:
        return _update_registry(lambda value: {
            "active": [dict(e) for e in value["entries"] if e.get("state") == "active"],
            "queued": [dict(e) for e in value["entries"] if e.get("state") == "queued"],
        })
    except Exception:
        return {"active": [], "queued": []}


def gate_command():
    prefix = ""
    custom_dir = os.environ.get("BATTERY_HOG_DATA_DIR")
    if custom_dir:
        prefix = "BATTERY_HOG_DATA_DIR=%s " % shlex.quote(custom_dir)
    return "%s%s %s --" % (prefix, shlex.quote(sys.executable), shlex.quote(os.path.abspath(__file__)))


def _command_label(command):
    if not command:
        return "command"
    base = os.path.basename(command[0]) or command[0]
    second = command[1] if len(command) > 1 and not command[1].startswith("-") else ""
    return (base + (" " + second if second else ""))[:80]


def _project_label(cwd):
    name = os.path.basename(cwd.rstrip(os.sep))
    return name or cwd or "Development"


def prepare_command(command, worker_limit, env=None):
    """Apply conservative, documented worker caps without changing semantics."""
    command = list(command)
    env = dict(os.environ if env is None else env)
    workers = str(max(1, int(worker_limit)))
    env.setdefault("BATTERY_HOG_GATED", "1")
    env.setdefault("CARGO_BUILD_JOBS", workers)
    env.setdefault("RAYON_NUM_THREADS", workers)
    env.setdefault("GOMAXPROCS", workers)
    if command:
        base = os.path.basename(command[0])
        if base in {"gradle", "gradlew"} and not any(a.startswith("--max-workers") for a in command):
            command.append("--max-workers=" + workers)
    return command, env


def _remove_entry(pid):
    def update(value):
        value["entries"] = [e for e in value["entries"] if int(e.get("pid", -1)) != int(pid)]
    try:
        _update_registry(update)
    except Exception:
        pass


def _wait_for_slot(entry, slots):
    announced = False
    while True:
        def update(value):
            entries = value["entries"]
            current = next((e for e in entries if e.get("id") == entry["id"]), None)
            if current is None:
                current = dict(entry)
                entries.append(current)
            active = [e for e in entries if e.get("state") == "active"]
            queued = sorted((e for e in entries if e.get("state") == "queued"),
                            key=lambda e: (e.get("requested_at", 0), e.get("id", "")))
            available = max(0, slots - len(active))
            admitted = current in queued[:available]
            if admitted:
                current["state"] = "active"
                current["started_at"] = int(time.time())
            position = next((i + 1 for i, e in enumerate(queued) if e.get("id") == entry["id"]), 1)
            return admitted, position, len(active)

        admitted, position, active = _update_registry(update)
        if admitted:
            return
        if not announced:
            print("Battery Hog: queued %s (position %d, %d/%d active)" %
                  (entry["label"], position, active, slots), file=sys.stderr, flush=True)
            announced = True
        time.sleep(0.75)


def run_gated(command, settings):
    pid = os.getpid()
    cwd = os.getcwd()
    entry = {
        "id": "%d-%d" % (pid, int(time.time() * 1000)),
        "pid": pid, "child_pid": None, "state": "queued",
        "label": _command_label(command), "project": _project_label(cwd),
        "cwd": cwd.replace(os.path.expanduser("~"), "~", 1),
        "requested_at": int(time.time()), "started_at": None,
    }
    child = None
    try:
        _wait_for_slot(entry, settings["slots"])
        prepared, env = prepare_command(command, settings["workers"])
        print("Battery Hog: running %s with %d worker%s" %
              (entry["label"], settings["workers"], "" if settings["workers"] == 1 else "s"),
              file=sys.stderr, flush=True)
        child = subprocess.Popen(prepared, env=env)

        def forward(signum, _frame):
            if child and child.poll() is None:
                child.send_signal(signum)

        signal.signal(signal.SIGINT, forward)
        signal.signal(signal.SIGTERM, forward)

        def child_started(value):
            for item in value["entries"]:
                if item.get("id") == entry["id"]:
                    item["child_pid"] = child.pid
                    item["worker_limit"] = settings["workers"]
                    item["slot_limit"] = settings["slots"]
        _update_registry(child_started)
        return child.wait()
    finally:
        _remove_entry(pid)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Run a command through Battery Hog Agent Mode")
    parser.add_argument("--force-battery", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--force-enabled", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        parser.error("provide a command after --")

    settings = load_dev_settings()
    enabled = settings["enabled"] or args.force_enabled
    battery = on_battery() or args.force_battery
    if not enabled or not battery:
        os.execvpe(command[0], command, os.environ.copy())
    return run_gated(command, settings)


if __name__ == "__main__":
    raise SystemExit(main())
