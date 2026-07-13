#!/usr/bin/env python3
"""
Battery Hog - a tiny local dashboard that shows what's draining your Mac's
battery right now (CPU + memory + real energy) and lets you quit the worst
offenders, toggle Low Power Mode, and measure true power draw.

No third-party dependencies: uses only the Python standard library + built-in
macOS tools (ps, pmset, vm_stat, sysctl, powermetrics, osascript). Runs
entirely on your machine at http://127.0.0.1:<port> - nothing is sent anywhere.

Run:   python3 battery_hog.py        (opens your browser automatically)
Stop:  press Ctrl-C in this window, or just close it.
"""

import http.server
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from datetime import datetime

from batteryhog_gate import gate_command, gate_snapshot
from batteryhog_workloads import discover_workloads, parse_pmset_assertions

# ---------------------------------------------------------------------------
# System constants (read once at startup)
# ---------------------------------------------------------------------------

def run(cmd, timeout=12):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout).stdout
    except Exception:
        return ""

def _sysctl_int(name, default):
    v = run(["sysctl", "-n", name]).strip()
    try:
        return int(v)
    except Exception:
        return default

PAGESIZE  = _sysctl_int("hw.pagesize", 16384)
TOTAL_MEM = _sysctl_int("hw.memsize", 0)
NCPU      = _sysctl_int("hw.ncpu", 8)

# Names / paths we never offer to kill (would break the system or be pointless).
CRITICAL_NAMES = {
    "kernel_task", "launchd", "WindowServer", "loginwindow", "logind",
    "powerd", "watchdogd", "systemstats", "UserEventAgent", "distnoted",
    "cfprefsd", "coreaudiod", "Dock", "Finder", "SystemUIServer",
    "Terminal", "iTerm2", "iTerm", "Spotlight", "controlcenter",
    "Control Center", "NotificationCenter", "secd", "trustd",
    "pmset", "ioreg", "system_profiler", "vm_stat", "sysctl", "ps",
    "lsof", "powermetrics", "osascript",
}

def osascript_admin(shell_cmd, timeout=60):
    """Run a shell command with admin rights via the native macOS prompt.
    Returns (ok, stdout, message). Auth is cached ~5 min by macOS."""
    try:
        r = subprocess.run(
            ["osascript", "-e",
             'do shell script "%s" with administrator privileges' % shell_cmd],
            capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "", "Timed out waiting for the password prompt."
    if r.returncode == 0:
        return True, r.stdout, ""
    err = (r.stderr or "").strip()
    if "User canceled" in err or "cancel" in err.lower():
        return False, "", "Cancelled."
    return False, "", err or "Command failed."


def run_priv(argv, timeout=45):
    """Run a privileged command. First try passwordless sudo (works only if the
    user installed the optional, tightly-scoped sudoers rule via
    enable-no-password.sh); if that's not set up, fall back to the GUI admin
    prompt (which macOS caches for ~5 min). Returns (ok, stdout, message)."""
    try:
        r = subprocess.run(["/usr/bin/sudo", "-n"] + argv,
                           capture_output=True, text=True, timeout=timeout)
        if r.returncode == 0:
            return True, r.stdout, ""
    except subprocess.TimeoutExpired:
        return False, "", "Timed out."
    except Exception:
        pass
    return osascript_admin(" ".join(argv), timeout=timeout)

# ---------------------------------------------------------------------------
# Process / battery / memory collection
# ---------------------------------------------------------------------------

def parse_cputime(t):
    """Parse a ps TIME field like '12:34.56', '1:02:03' or '3-01:02:03'."""
    days = 0
    if "-" in t:
        d, t = t.split("-", 1)
        try:
            days = int(d)
        except Exception:
            days = 0
    secs = 0.0
    try:
        for part in t.split(":"):
            secs = secs * 60 + float(part)
    except Exception:
        return 0.0
    return days * 86400 + secs


def snapshot():
    """pid -> (ppid, rss_kb, cputime_seconds, command_string)"""
    out = run(["ps", "-axo", "pid=,ppid=,rss=,time=,command="])
    d = {}
    for line in out.splitlines():
        line = line.rstrip()
        if not line.strip():
            continue
        parts = line.split(None, 4)
        if len(parts) == 4:
            parts.append("")
        if len(parts) < 5:
            continue
        pid, ppid, rss, tm, cmd = parts
        try:
            d[int(pid)] = (int(ppid), int(rss), parse_cputime(tm), cmd)
        except Exception:
            continue
    return d


def classify(command):
    """Return (display_name, is_app_bundle, exe_or_bundle_path)."""
    m = re.search(r"/([^/]+)\.app/", command)
    if m:
        idx = command.find(".app/")
        bundle_path = command[:idx + 4]            # up to and including '.app'
        return m.group(1), True, bundle_path
    first = command.strip().split(" ")[0]
    name = os.path.basename(first) if "/" in first else first
    return (name or "?"), False, first


def is_protected(name, path, command):
    if "battery_hog" in command:
        return True
    if name in CRITICAL_NAMES:
        return True
    low = (path or "").lower()
    if "sentinel" in low or "sentinel" in name.lower():
        return True
    if path.startswith("/System/Applications/"):
        return False  # built-in user apps (Music, Mail, Safari, Photos…) are fine to quit
    if path.startswith("/System/"):
        return True
    if path.startswith("/usr/") and not path.startswith("/usr/local/"):
        return True
    if path.startswith("/Library/") or path.startswith("/private/"):
        return True
    return False


_PROC = {"t": 0.0, "processes": None, "workloads": [], "summary": {}}
_PROC_LOCK = threading.Lock()
_PROC_TTL = 6.0

def get_process_data():
    # cache briefly so the web + menu-bar + alert pollers don't each pay the
    # 0.8s sampling cost when they land close together
    if (_PROC["processes"] is not None
            and time.monotonic() - _PROC["t"] < _PROC_TTL):
        return _PROC
    # ThreadingHTTPServer, the native menu and the alert monitor can all land
    # here together. Only one caller should pay for a cold CPU sample; callers
    # that queued behind it reuse the completed result.
    with _PROC_LOCK:
        if (_PROC["processes"] is not None
                and time.monotonic() - _PROC["t"] < _PROC_TTL):
            return _PROC

        s0 = snapshot()
        t0 = time.monotonic()
        time.sleep(0.8)
        s1 = snapshot()
        dt = max(0.2, time.monotonic() - t0)

        groups = {}
        samples = []
        for pid, (ppid, rss, ct1, cmd) in s1.items():
            prev = s0.get(pid)
            ct0 = prev[2] if prev else ct1            # new process -> 0 delta
            cpu = max(0.0, (ct1 - ct0)) / dt * 100.0
            samples.append({"pid": pid, "ppid": ppid, "rss_kb": rss,
                            "cpu": cpu, "command": cmd})
            name, bundle, path = classify(cmd)
            g = groups.get(name)
            if not g:
                g = {"name": name, "bundle": bundle, "path": path,
                     "cpu": 0.0, "mem_kb": 0, "pids": [],
                     "protected": is_protected(name, path, cmd)}
                groups[name] = g
            g["cpu"] += cpu
            g["mem_kb"] += rss
            g["pids"].append(pid)

        procs = []
        for g in groups.values():
            cpu = round(g["cpu"], 1)
            mem_mb = round(g["mem_kb"] / 1024.0, 1)
            score = cpu + mem_mb / 50.0
            if cpu >= 50 or score >= 80:
                level = "high"
            elif cpu >= 12 or score >= 25:
                level = "med"
            else:
                level = "low"
            procs.append({
                "name": g["name"], "cpu": cpu, "mem_mb": mem_mb,
                "procs": len(g["pids"]), "pids": g["pids"][:50],
                "bundle": g["bundle"], "protected": g["protected"],
                "path": g["path"],
                "level": level, "score": round(score, 1),
            })
        procs.sort(key=lambda p: p["score"], reverse=True)
        dev = discover_workloads(samples)
        _PROC.update(t=time.monotonic(), processes=procs[:40],
                     workloads=dev["workloads"], summary=dev["summary"])
        return _PROC


def get_processes():
    return get_process_data()["processes"]


def get_battery():
    out = run(["pmset", "-g", "batt"])
    pct = re.search(r"(\d+)%", out)
    tm = re.search(r"(\d+:\d+)\s+remaining", out)
    on_ac = "AC Power" in out
    low = out.lower()
    # status word follows the percentage, e.g. "50%; discharging; 2:49 remaining"
    m = re.search(r"\d+%;\s*([^;]+)", low)
    status = m.group(1).strip() if m else ""
    if not on_ac:
        state = "discharging"                 # drawing from the battery
    elif "discharging" in status:
        state = "discharging"
    elif "charged" in status or "finishing charge" in low:
        state = "charged"
    elif "not charging" in low:
        state = "ac"                          # plugged in but holding (not topping up)
    elif "charging" in status:                # safe now: "discharging" handled above
        state = "charging"
    else:
        state = "ac"
    return {
        "percent": int(pct.group(1)) if pct else None,
        "state": state,
        "on_ac": on_ac,
        "time": tm.group(1) if tm else None,
    }


def get_memory():
    vs = run(["vm_stat"])
    def pages(label):
        m = re.search(re.escape(label) + r":\s+(\d+)\.", vs)
        return int(m.group(1)) if m else 0
    free = pages("Pages free")
    spec = pages("Pages speculative")
    comp = pages("Pages occupied by compressor")
    wired = pages("Pages wired down")

    free_b = (free + spec) * PAGESIZE
    comp_b = comp * PAGESIZE
    wired_b = wired * PAGESIZE
    used_b = max(0, TOTAL_MEM - free_b)

    sw = run(["sysctl", "vm.swapusage"])
    m = re.search(r"used = ([\d.]+)M", sw)
    swap_used = float(m.group(1)) if m else 0.0

    free_mb = free_b / 1048576.0
    if free_mb < 1500 or swap_used > 1024:
        pressure = "high"
    elif free_mb < 4000 or swap_used > 256:
        pressure = "elevated"
    else:
        pressure = "normal"

    gb = 1073741824.0
    return {
        "total_gb": round(TOTAL_MEM / gb, 1),
        "used_gb": round(used_b / gb, 1),
        "free_gb": round(free_b / gb, 2),
        "compressed_gb": round(comp_b / gb, 1),
        "wired_gb": round(wired_b / gb, 1),
        "swap_used_mb": round(swap_used),
        "pressure": pressure,
    }


def get_lowpowermode():
    """True / False, or None if it can't be read."""
    out = run(["pmset", "-g"])
    m = re.search(r"lowpowermode\s+(\d+)", out)
    if not m:
        return None
    return m.group(1) == "1"


_HEALTH = {"t": 0.0, "data": None}

def get_battery_health():
    """Battery condition/cycles/capacity. Cached ~45s (system_profiler is slow)."""
    now = time.time()
    if _HEALTH["data"] and now - _HEALTH["t"] < 45:
        return _HEALTH["data"]

    io = run(["ioreg", "-rn", "AppleSmartBattery"])
    def iv(key):
        m = re.search(r'"%s"\s*=\s*(-?\d+)' % re.escape(key), io)
        return int(m.group(1)) if m else None
    design = iv("DesignCapacity")
    full = iv("NominalChargeCapacity") or iv("AppleRawMaxCapacity")
    traw = iv("Temperature")
    temp_c = round(traw / 100.0, 1) if traw else None
    cycles_io = iv("CycleCount")

    sp = run(["system_profiler", "SPPowerDataType"])
    def spm(pat):
        m = re.search(pat, sp)
        return m.group(1).strip() if m else None
    maxcap = spm(r"Maximum Capacity:\s*(\d+)%")
    condition = spm(r"Condition:\s*([^\n]+)")
    cyc = spm(r"Cycle Count:\s*(\d+)")

    cycles = int(cyc) if cyc else cycles_io
    if maxcap:
        health = int(maxcap)
    elif full and design:
        health = round(full / design * 100)
    else:
        health = None

    data = {
        "health": health,            # max capacity % vs new
        "cycles": cycles,
        "condition": condition,      # "Normal", "Service Recommended", ...
        "temp_c": temp_c,
        "design_mah": design,
        "full_mah": full,
    }
    _HEALTH.update(t=now, data=data)
    return data


# ---------------------------------------------------------------------------
# Live power draw + uptime (read from ioreg / sysctl — no password)
# ---------------------------------------------------------------------------

def get_power():
    """Real-time wattage in/out of the battery, decoded from AppleSmartBattery."""
    io = run(["ioreg", "-rn", "AppleSmartBattery"])
    def iv(key):
        m = re.search(r'"%s"\s*=\s*(-?\d+)' % re.escape(key), io)
        return int(m.group(1)) if m else None
    def yn(key):
        m = re.search(r'"%s"\s*=\s*(Yes|No)' % re.escape(key), io)
        return (m.group(1) == "Yes") if m else None
    amp = iv("InstantAmperage")
    if amp is None:
        amp = iv("Amperage")
    volt = iv("Voltage")
    charging = yn("IsCharging")
    on_ac = yn("ExternalConnected")
    watts = None
    if amp is not None and volt is not None:
        if amp >= 2 ** 63:           # unsigned 64-bit -> signed (two's complement)
            amp -= 2 ** 64
        watts = round(abs(amp) * volt / 1e6, 1)
    if charging:
        direction = "charging"
    elif on_ac:
        direction = "ac"
    else:
        direction = "discharging"
    return {"watts": watts, "direction": direction,
            "charging": bool(charging), "on_ac": bool(on_ac)}


def get_uptime():
    """Seconds since last boot (for the 'time to restart' tip)."""
    out = run(["sysctl", "-n", "kern.boottime"])
    m = re.search(r"sec\s*=\s*(\d+)", out)
    if not m:
        return None
    secs = max(0, int(time.time()) - int(m.group(1)))
    return {"secs": secs, "days": round(secs / 86400.0, 1)}


_SLEEP = {"t": 0.0, "blockers": None, "policy": None}


def get_sleep_data():
    """Live sleep blockers plus the current battery sleep/display policy."""
    now = time.monotonic()
    if _SLEEP["blockers"] is not None and now - _SLEEP["t"] < 12:
        return _SLEEP

    blockers = parse_pmset_assertions(run(["pmset", "-g", "assertions"]))
    custom = run(["pmset", "-g", "custom"])
    battery_section = custom.split("Battery Power:", 1)[-1]
    if "AC Power:" in battery_section:
        battery_section = battery_section.split("AC Power:", 1)[0]

    def setting(name):
        match = re.search(r"^\s*%s\s+(\d+)\s*$" % re.escape(name),
                          battery_section, re.MULTILINE)
        return int(match.group(1)) if match else None

    policy = {
        "display_sleep": setting("displaysleep"),
        "system_sleep": setting("sleep"),
        "powernap": setting("powernap"),
        "tcpkeepalive": setting("tcpkeepalive"),
    }
    _SLEEP.update(t=now, blockers=blockers, policy=policy)
    return _SLEEP


# ---------------------------------------------------------------------------
# Charge history (parsed from `pmset -g log`, ~the last week of events)
# ---------------------------------------------------------------------------

_PLOG = {"t": 0.0, "raw": None}
_PLOG_LOCK = threading.Lock()

def _pmset_log():
    """Raw `pmset -g log` output, cached ~2 min (it is large + slow)."""
    now = time.time()
    if _PLOG["raw"] is not None and now - _PLOG["t"] < 120:
        return _PLOG["raw"]
    # The log can be tens of megabytes and take several seconds. Prevent
    # concurrent history/insights requests from launching duplicate scans.
    with _PLOG_LOCK:
        now = time.time()
        if _PLOG["raw"] is not None and now - _PLOG["t"] < 120:
            return _PLOG["raw"]
        raw = run(["pmset", "-g", "log"], timeout=20)
        _PLOG.update(t=time.time(), raw=raw)
        return raw

def get_wakes(hours=14):
    """Count dark-wake events in the last `hours` (overnight battery drain)."""
    cutoff = time.time() - hours * 3600
    n = 0
    for ln in _pmset_log().splitlines():
        if "DarkWake" not in ln:
            continue
        m = re.match(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+([+-]\d{4})", ln)
        if not m:
            continue
        try:
            ts = datetime.strptime(m.group(1) + " " + m.group(2),
                                   "%Y-%m-%d %H:%M:%S %z").timestamp()
        except ValueError:
            continue
        if ts >= cutoff:
            n += 1
    return n

_HIST = {"t": 0.0, "rows": None}
_HIST_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+([+-]\d{4})"
    r".*?Using\s+(AC|Batt|BATT)\s*\(Charge:\s*(\d+)"
)

def _hist_rows():
    """[(epoch, pct, on_ac), ...] sorted ascending. Cached ~3 min (log is big)."""
    now = time.time()
    if _HIST["rows"] is not None and now - _HIST["t"] < 180:
        return _HIST["rows"]
    raw = _pmset_log()
    rows = []
    for ln in raw.splitlines():
        m = _HIST_RE.search(ln)
        if not m:
            continue
        try:
            dt = datetime.strptime(m.group(1) + " " + m.group(2),
                                   "%Y-%m-%d %H:%M:%S %z")
        except ValueError:
            continue
        rows.append((dt.timestamp(), int(m.group(4)), m.group(3).upper() == "AC"))
    rows.sort()
    _HIST.update(t=now, rows=rows)
    return rows

def get_history(days=1):
    """Battery level binned over the window, with min/max + AC state per bin.
    Empty interior bins (sleep/idle gaps) carry forward the last known level so
    the chart stays continuous, like macOS Battery settings."""
    rows = _hist_rows()
    now = time.time()
    binsec = 900 if days <= 1 else 10800        # 15 min (24h) / 3 h (10d)
    start = now - days * 86400
    n = int(round(days * 86400 / binsec))

    # fold a live sample onto the right edge so it matches the ring
    b = get_battery()
    if b.get("percent") is not None:
        rows = rows + [(now, int(b["percent"]), bool(b.get("on_ac")))]

    raw_bins = [None] * n
    for ts, pct, ac in rows:
        if ts < start or ts > now:
            continue
        i = int((ts - start) // binsec)
        if i < 0:
            continue
        if i >= n:                 # the right-edge sample (e.g. the live point) -> last bin
            i = n - 1
        cell = raw_bins[i]
        if cell is None:
            raw_bins[i] = {"lo": pct, "hi": pct, "ac": ac, "_last": ts, "v": pct}
        else:
            cell["lo"] = min(cell["lo"], pct)
            cell["hi"] = max(cell["hi"], pct)
            if ts >= cell["_last"]:
                cell["_last"] = ts
                cell["ac"] = ac
                cell["v"] = pct           # value at the end of the bucket

    out, prev = [], None
    for cell in raw_bins:
        if cell is None:
            out.append(None if prev is None
                       else {"lo": prev["lo"], "hi": prev["hi"], "ac": prev["ac"], "v": prev["v"]})
        else:
            c = {"lo": cell["lo"], "hi": cell["hi"], "ac": cell["ac"], "v": cell["v"]}
            out.append(c)
            prev = c

    full = [r[0] for r in rows if r[1] >= 100]
    return {
        "range": "24h" if days <= 1 else "10d",
        "bins": out,
        "bin_sec": binsec,
        "start": int(start),
        "end": int(now),
        "last_full": int(full[-1]) if full else None,
        "span_days": round((rows[-1][0] - rows[0][0]) / 86400, 1) if rows else 0,
    }


DATA_DIR = os.environ.get(
    "BATTERY_HOG_DATA_DIR",
    os.path.expanduser("~/Library/Application Support/BatteryHog"),
)
IGNORE_FILE = os.path.join(DATA_DIR, "ignored.json")

def _load_ignored():
    try:
        with open(IGNORE_FILE, encoding="utf-8") as f:
            return set(json.load(f))
    except Exception:
        return set()

def _save_ignored():
    try:
        os.makedirs(os.path.dirname(IGNORE_FILE), exist_ok=True)
        with open(IGNORE_FILE, "w", encoding="utf-8") as f:
            json.dump(sorted(_IGNORED), f)
    except Exception:
        pass

_IGNORED = _load_ignored()   # apps the user muted from quit-suggestions


# ---------------------------------------------------------------------------
# Settings (opt-in alerts) + the background notification monitor
# ---------------------------------------------------------------------------

SETTINGS_FILE = os.path.join(DATA_DIR, "settings.json")
_DEFAULT_SETTINGS = {
    "alerts": False,
    "low_threshold": 20,
    "menubar": {"percent": True, "watts": True, "time": False,
                "hog": False, "dev": False},
    "dev": {"enabled": False, "slots": 2, "workers": 2,
            "draw_threshold": 30, "notify_draw": True},
    "heat": {"enabled": False},
}

def _load_settings():
    s = json.loads(json.dumps(_DEFAULT_SETTINGS))      # deep copy of defaults
    try:
        with open(SETTINGS_FILE, encoding="utf-8") as f:
            v = json.load(f)
            if isinstance(v, dict):
                # Read nested groups without removing them from the parsed
                # object. This keeps loading side-effect free and prevents an
                # invalid group from replacing its validated defaults.
                mb = v.get("menubar")
                dev = v.get("dev")
                heat = v.get("heat")
                s.update({k: value for k, value in v.items()
                          if k not in ("menubar", "dev", "heat")})
                if isinstance(mb, dict):
                    s["menubar"].update({k: bool(mb[k]) for k in s["menubar"] if k in mb})
                if isinstance(dev, dict):
                    for key in ("enabled", "notify_draw"):
                        if key in dev:
                            s["dev"][key] = bool(dev[key])
                    for key, lo, hi in (("slots", 1, 4), ("workers", 1, 8),
                                        ("draw_threshold", 10, 80)):
                        if key in dev:
                            try:
                                s["dev"][key] = max(lo, min(hi, int(dev[key])))
                            except (TypeError, ValueError):
                                pass
                if (isinstance(heat, dict)
                        and isinstance(heat.get("enabled"), bool)):
                    s["heat"]["enabled"] = heat["enabled"]
    except Exception:
        pass
    return s

def _save_settings():
    try:
        os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump(_SETTINGS, f)
    except Exception:
        pass

_SETTINGS = _load_settings()

def _notify(title, msg):
    try:
        subprocess.run(["osascript", "-e",
                        "display notification %s with title %s"
                        % (json.dumps(msg), json.dumps(title))], timeout=5)
    except Exception:
        pass

_ALERT = {"low": False, "full": False, "cpu": set(),
          "draw": False, "draw_hits": 0}

def _alert_loop():
    """Fire native notifications for low battery / fully charged / CPU spikes.
    Each condition fires once and rearms only after it clears (no nagging)."""
    while True:
        try:
            if _SETTINGS.get("alerts"):
                b = get_battery()
                pct, st = b.get("percent"), b.get("state")
                thr = int(_SETTINGS.get("low_threshold", 20) or 20)
                # low battery
                if st == "discharging" and pct is not None and pct <= thr:
                    if not _ALERT["low"]:
                        _notify("Battery low", "%d%% left — plug in soon." % pct)
                        _ALERT["low"] = True
                elif pct is None or st != "discharging" or pct > thr + 5:
                    _ALERT["low"] = False
                # fully charged on AC
                if b.get("on_ac") and pct is not None and pct >= 100:
                    if not _ALERT["full"]:
                        _notify("Fully charged", "Unplug when you can to ease battery wear.")
                        _ALERT["full"] = True
                elif (not b.get("on_ac")) or (pct is not None and pct < 98):
                    _ALERT["full"] = False
                # sustained CPU spike (non-system apps only)
                hot = set()
                for p in get_processes()[:8]:
                    if not p.get("protected") and (p.get("cpu") or 0) >= 95:
                        hot.add(p["name"])
                        if p["name"] not in _ALERT["cpu"]:
                            _notify("High CPU", "%s is using %.0f%% CPU." % (p["name"], p["cpu"]))
                _ALERT["cpu"] = hot
                # sustained high system draw while on battery. Two consecutive
                # minute samples are required so short compiler bursts do not nag.
                dev_settings = _SETTINGS.get("dev", {})
                draw_threshold = int(dev_settings.get("draw_threshold", 30) or 30)
                power = get_power()
                if (dev_settings.get("notify_draw", True) and not b.get("on_ac")
                        and (power.get("watts") or 0) >= draw_threshold):
                    _ALERT["draw_hits"] += 1
                    if _ALERT["draw_hits"] >= 2 and not _ALERT["draw"]:
                        summary = get_process_data().get("summary", {})
                        msg = "%.0f W with %d active dev workers across %d projects." % (
                            power["watts"], summary.get("active_workers", 0),
                            summary.get("projects", 0))
                        _notify("Heavy battery draw", msg)
                        _ALERT["draw"] = True
                else:
                    _ALERT["draw_hits"] = 0
                    _ALERT["draw"] = False
        except Exception:
            pass
        time.sleep(60)


_INS = {"t": 0.0, "data": None}

def get_insights():
    """Battery-drain analysis from the charge log: typical drain rate, projected
    runtime, time on battery, charge sessions, overnight wake-ups. Cached ~60s."""
    now = time.time()
    if _INS["data"] is not None and now - _INS["t"] < 60:
        return _INS["data"]
    rows = _hist_rows()

    def analyze(since):
        seg = [r for r in rows if r[0] >= since]
        on_b = charg = disch = drop = 0.0
        for (t0, p0, a0), (t1, p1, a1) in zip(seg, seg[1:]):
            dt = t1 - t0
            if dt <= 0 or dt > 2 * 3600:        # skip long unlogged / deep-sleep gaps
                continue
            if not a0:
                on_b += dt
                if p1 < p0:
                    drop += (p0 - p1); disch += dt
            else:
                charg += dt
        rate = (drop / (disch / 3600.0)) if disch >= 600 else None   # %/hr, need >=10min
        return {
            "rate": round(rate, 1) if rate else None,
            "runtime_h": round(100.0 / rate, 1) if rate and rate > 0 else None,
            "on_battery_h": round(on_b / 3600.0, 1),
            "charging_h": round(charg / 3600.0, 1),
        }

    today = analyze(now - 24 * 3600)
    week = analyze(now - 7 * 86400)
    charges, prev = 0, None
    for ts, p, ac in rows:
        if ts < now - 24 * 3600:
            continue
        if ac and prev is False:
            charges += 1
        prev = ac
    data = {"today": today, "week": week, "charges": charges,
            "wakes": get_wakes(24), "ok": today.get("rate") is not None}
    _INS.update(t=now, data=data)
    return data


_EMPTY_INSIGHTS = {
    "today": {"rate": None, "runtime_h": None,
              "on_battery_h": 0.0, "charging_h": 0.0},
    "week": {"rate": None, "runtime_h": None,
             "on_battery_h": 0.0, "charging_h": 0.0},
    "charges": 0,
    "wakes": 0,
    "ok": False,
}
_SLOW_CACHE_SCHEMA = 1
_SLOW_REFRESH_INTERVAL = 300
_SLOW_RETRY_INTERVAL = 60
_SLOW_LOCK = threading.Lock()


def _slow_cache_file():
    return os.path.join(DATA_DIR, "insights-cache.json")


def _new_slow_snapshot():
    return {
        "wakes": 0,
        "insights": json.loads(json.dumps(_EMPTY_INSIGHTS)),
        "saved_at": 0.0,
        "refreshed_at": 0.0,
        "last_attempt": 0.0,
        "refreshing": False,
        # A disk snapshot is useful immediately but remains stale until this
        # process completes its first background refresh.
        "fresh": False,
        "last_error": None,
    }


def _load_slow_snapshot():
    snapshot = _new_slow_snapshot()
    try:
        with open(_slow_cache_file(), encoding="utf-8") as handle:
            cached = json.load(handle)
        if not isinstance(cached, dict) or cached.get("schema") != _SLOW_CACHE_SCHEMA:
            return snapshot
        wakes = cached.get("wakes")
        insights = cached.get("insights")
        saved_at = cached.get("saved_at")
        if (isinstance(wakes, bool) or not isinstance(wakes, int) or wakes < 0
                or not isinstance(insights, dict)
                or not isinstance(insights.get("today"), dict)
                or not isinstance(insights.get("week"), dict)
                or not isinstance(saved_at, (int, float))):
            return snapshot
        snapshot.update(wakes=wakes, insights=insights,
                        saved_at=float(saved_at))
    except Exception:
        pass
    return snapshot


_SLOW = _load_slow_snapshot()


def _save_slow_snapshot():
    """Atomically persist only the last complete wake/insights result."""
    with _SLOW_LOCK:
        payload = {
            "schema": _SLOW_CACHE_SCHEMA,
            "saved_at": _SLOW["saved_at"],
            "wakes": _SLOW["wakes"],
            "insights": _SLOW["insights"],
        }
    path = _slow_cache_file()
    temp_path = "%s.%d.%d.tmp" % (path, os.getpid(), threading.get_ident())
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(temp_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(temp_path, path)
    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass


def _slow_stats_snapshot():
    with _SLOW_LOCK:
        has_saved = _SLOW["saved_at"] > 0
        return {
            "wakes": _SLOW["wakes"],
            "insights": _SLOW["insights"],
            # Loading means there is not yet meaningful history to render.
            # Refreshing also covers the tiny gap before the post-response
            # worker starts, letting the first UI accurately say it is coming.
            "insights_loading": not has_saved and not _SLOW["fresh"],
            "insights_refreshing": bool(_SLOW["refreshing"] or not _SLOW["fresh"]),
            "insights_stale": bool(has_saved and not _SLOW["fresh"]),
        }


def _refresh_slow_snapshot():
    """Refresh expensive power-log summaries on a background thread."""
    try:
        wakes = get_wakes()
        insights = get_insights()
        finished = time.time()
        with _SLOW_LOCK:
            _SLOW.update(wakes=wakes, insights=insights,
                         saved_at=finished, refreshed_at=finished,
                         refreshing=False, fresh=True, last_error=None)
        _save_slow_snapshot()
        return True
    except Exception as exc:
        with _SLOW_LOCK:
            _SLOW.update(refreshing=False, last_error=str(exc))
        return False


def start_slow_refresh(force=False):
    """Start at most one expensive history refresh, returning whether started."""
    now = time.time()
    with _SLOW_LOCK:
        if _SLOW["refreshing"]:
            return False
        if not force:
            if (_SLOW["fresh"]
                    and now - _SLOW["refreshed_at"] < _SLOW_REFRESH_INTERVAL):
                return False
            if (_SLOW["last_attempt"]
                    and now - _SLOW["last_attempt"] < _SLOW_RETRY_INTERVAL):
                return False
        _SLOW.update(refreshing=True, last_attempt=now)
    threading.Thread(target=_refresh_slow_snapshot,
                     name="battery-hog-history", daemon=True).start()
    return True


def build_stats():
    proc_data = get_process_data()
    sleep = get_sleep_data()
    slow = _slow_stats_snapshot()
    gate = gate_snapshot()
    gate.update({
        "command": gate_command(),
        "enabled": bool(_SETTINGS.get("dev", {}).get("enabled")),
        "slots": int(_SETTINGS.get("dev", {}).get("slots", 2)),
        "workers": int(_SETTINGS.get("dev", {}).get("workers", 2)),
    })
    return {
        "battery": get_battery(),
        "memory": get_memory(),
        "processes": proc_data["processes"],
        "workloads": proc_data["workloads"],
        "dev_summary": proc_data["summary"],
        "sleep_blockers": sleep["blockers"],
        "power_policy": sleep["policy"],
        "gate": gate,
        "lowpower": get_lowpowermode(),
        "health": get_battery_health(),
        "power": get_power(),
        "uptime": get_uptime(),
        "wakes": slow["wakes"],
        "insights": slow["insights"],
        "insights_loading": slow["insights_loading"],
        "insights_refreshing": slow["insights_refreshing"],
        "insights_stale": slow["insights_stale"],
        "ignored": sorted(_IGNORED),
        "settings": _SETTINGS,
        "preview": bool(os.environ.get("BATTERY_HOG_PREVIEW")),
        "ncpu": NCPU,
        "ts": int(time.time()),
    }


# ---------------------------------------------------------------------------
# Actions: quit a process, toggle Low Power Mode, measure real energy
# ---------------------------------------------------------------------------

def _alive_pids(pids):
    """Return the subset of pids that are still running."""
    alive = []
    for p in pids:
        try:
            os.kill(p, 0)            # signal 0 just tests existence
            alive.append(p)
        except ProcessLookupError:
            pass
        except PermissionError:
            alive.append(p)          # exists, just not ours to signal
        except Exception:
            pass
    return alive


def quit_target(name, bundle, pids):
    """Actually quit it: graceful app quit first (so it can save), then verify
    and escalate to SIGTERM and finally SIGKILL any survivors."""
    pids = [int(p) for p in (pids or []) if str(p).lstrip("-").isdigit()]

    # 1) Graceful, app-level quit (gives the app a chance to save). Best effort.
    if bundle and name:
        try:
            subprocess.run(
                ["osascript", "-e", 'tell application "%s" to quit' % name.replace('"', "")],
                capture_output=True, text=True, timeout=7)
        except Exception:
            pass
        deadline = time.time() + 1.5
        while time.time() < deadline and _alive_pids(pids):
            time.sleep(0.15)
        if pids and not _alive_pids(pids):
            return True, "Quit %s." % name

    # 2) Polite terminate, then wait.
    for p in pids:
        try:
            os.kill(p, signal.SIGTERM)
        except Exception:
            pass
    deadline = time.time() + 1.8
    while time.time() < deadline and _alive_pids(pids):
        time.sleep(0.15)

    # 3) Force-kill whatever is still standing.
    survivors = _alive_pids(pids)
    for p in survivors:
        try:
            os.kill(p, signal.SIGKILL)
        except Exception:
            pass
    if survivors:
        time.sleep(0.25)

    still = _alive_pids(pids)
    if not pids and not bundle:
        return False, "Nothing to quit."
    if still:
        return False, "Couldn't fully quit %s (%d still running)." % (name, len(still))
    return True, "Quit %s." % name


def set_lowpower(on):
    val = "1" if on else "0"
    ok, _out, msg = run_priv(["/usr/bin/pmset", "-a", "lowpowermode", val])
    if ok:
        return True, "Low Power Mode turned %s." % ("on" if on else "off")
    return False, msg


def parse_powermetrics(text):
    res = {"ok": True, "system": {}, "tasks": []}
    patterns = [
        ("CPU Power", "cpu"),
        ("GPU Power", "gpu"),
        ("ANE Power", "ane"),
        (r"Combined Power \(CPU \+ GPU \+ ANE\)", "combined"),
        ("Package Power", "package"),
    ]
    for pat, key in patterns:
        m = re.search(pat + r":\s*([\d.]+)\s*mW", text)
        if m:
            res["system"][key] = round(float(m.group(1)) / 1000.0, 2)

    in_table = False
    for ln in text.splitlines():
        if ("Energy Impact" in ln) and ("ID" in ln):
            in_table = True
            continue
        if not in_table:
            continue
        if not ln.strip():
            break
        toks = ln.split()
        pid_idx = None
        for i, t in enumerate(toks):
            if re.fullmatch(r"-?\d+", t):
                pid_idx = i
                break
        if not pid_idx:        # need a name before the pid (idx >= 1)
            continue
        name = " ".join(toks[:pid_idx])
        if name.upper().startswith("ALL_TASKS"):
            continue
        try:
            energy = float(toks[-1])
            pid = int(toks[pid_idx])
        except ValueError:
            continue
        res["tasks"].append({"name": name, "pid": pid, "energy": round(energy, 1)})

    res["tasks"].sort(key=lambda x: x["energy"], reverse=True)
    res["tasks"] = res["tasks"][:20]
    if not res["tasks"] and not res["system"]:
        return {"ok": False, "message": "Could not parse powermetrics output."}
    return res


def get_energy():
    ok, out, msg = run_priv(
        ["/usr/bin/powermetrics", "--samplers", "tasks,cpu_power", "-n1", "-i500"],
        timeout=45)
    if not ok:
        return {"ok": False, "message": msg}
    return parse_powermetrics(out)


# ---------------------------------------------------------------------------
# Web page
# ---------------------------------------------------------------------------

PAGE = r"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Battery Hog</title>
<style>
  :root{
    --bg:#0e1116; --card:#171b22; --line:#262c36; --txt:#e6e9ef; --dim:#9aa4b2;
    --green:#3fb950; --amber:#d29922; --red:#f85149; --blue:#388bfd; --violet:#a371f7;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--txt);
       font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
  .wrap{max-width:900px;margin:0 auto;padding:22px 18px 60px}
  header{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin-bottom:16px}
  h1{font-size:20px;margin:0;letter-spacing:.2px}
  .sub{color:var(--dim);font-size:12px}
  .cards{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:14px}
  @media(max-width:640px){.cards{grid-template-columns:1fr}}
  .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
  .card h2{font-size:12px;text-transform:uppercase;letter-spacing:.6px;color:var(--dim);margin:0 0 8px}
  .big{font-size:26px;font-weight:600}
  .row{display:flex;align-items:center;justify-content:space-between;gap:10px}
  .bar{height:9px;border-radius:6px;background:#0a0d12;overflow:hidden;margin-top:10px;border:1px solid var(--line)}
  .bar>span{display:block;height:100%}
  .muted{color:var(--dim);font-size:12px;margin-top:8px}
  .pill{display:inline-block;padding:1px 8px;border-radius:999px;font-size:11px;font-weight:600;vertical-align:middle}
  .pill.high{background:rgba(248,81,73,.15);color:#ff7b72;border:1px solid rgba(248,81,73,.35)}
  .pill.elevated,.pill.med{background:rgba(210,153,34,.15);color:#e3b341;border:1px solid rgba(210,153,34,.35)}
  .pill.normal,.pill.low{background:rgba(139,148,158,.12);color:var(--dim);border:1px solid var(--line)}
  .toolbar{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:6px 0 10px;flex-wrap:wrap}
  .seg button,.act{background:var(--card);color:var(--dim);border:1px solid var(--line);
       padding:5px 12px;border-radius:8px;cursor:pointer;font-size:12px}
  .seg button.on{color:var(--txt);border-color:var(--blue);background:rgba(56,139,253,.12)}
  .toolbar label{color:var(--dim);font-size:12px;cursor:pointer}
  .toggle{display:inline-flex;align-items:center;gap:8px;border:1px solid var(--line);
          background:var(--card);border-radius:999px;padding:4px 12px 4px 10px;cursor:pointer;font-size:12px;color:var(--txt)}
  .toggle .dot{width:30px;height:18px;border-radius:999px;background:#0a0d12;border:1px solid var(--line);position:relative;transition:.15s}
  .toggle .dot::after{content:"";position:absolute;top:1px;left:1px;width:14px;height:14px;border-radius:50%;background:var(--dim);transition:.15s}
  .toggle.on .dot{background:rgba(63,185,80,.3);border-color:var(--green)}
  .toggle.on .dot::after{left:13px;background:var(--green)}
  .act.energy{color:#d6c2f7;border-color:rgba(163,113,247,.4);background:rgba(163,113,247,.12)}
  table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
  th,td{padding:10px 12px;text-align:left;border-bottom:1px solid var(--line);font-size:13px}
  th{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.5px;font-weight:600}
  tr:last-child td{border-bottom:none}
  td.num{font-variant-numeric:tabular-nums;text-align:right;white-space:nowrap}
  .name{font-weight:600}
  .nprocs{color:var(--dim);font-weight:400;font-size:11px}
  .kill{background:rgba(248,81,73,.12);color:#ff7b72;border:1px solid rgba(248,81,73,.35);
        padding:4px 12px;border-radius:8px;cursor:pointer;font-size:12px}
  .kill:hover{background:rgba(248,81,73,.22)}
  .sys{color:var(--dim);font-size:11px;border:1px solid var(--line);padding:3px 9px;border-radius:8px}
  .note{color:var(--dim);font-size:11.5px;margin-top:14px;line-height:1.6}
  .flash{position:fixed;left:50%;bottom:22px;transform:translateX(-50%);
         background:var(--card);border:1px solid var(--blue);color:var(--txt);
         padding:10px 16px;border-radius:10px;font-size:13px;opacity:0;transition:opacity .2s;pointer-events:none;max-width:80%}
  .flash.show{opacity:1}
  #energy .ecols{display:grid;grid-template-columns:1fr 1fr;gap:14px}
  @media(max-width:640px){#energy .ecols{grid-template-columns:1fr}}
  .watt{font-size:30px;font-weight:700}
  .elist div{display:flex;justify-content:space-between;padding:3px 0;border-bottom:1px solid var(--line);font-size:12.5px}
  .elist div:last-child{border-bottom:none}
</style></head>
<body><div class="wrap">
  <header>
    <h1>🔋 Battery Hog</h1>
    <div class="sub" id="updated">loading…</div>
  </header>

  <div class="cards">
    <div class="card" id="batt"><h2>Battery</h2><div class="big">…</div></div>
    <div class="card" id="mem"><h2>Memory</h2><div class="big">…</div></div>
  </div>

  <div class="card" id="energy" style="display:none;margin-bottom:14px">
    <h2>Real energy <span class="pill" style="background:rgba(163,113,247,.15);color:#d6c2f7;border:1px solid rgba(163,113,247,.35)">powermetrics</span></h2>
    <div class="ecols">
      <div><div class="watt" id="watt">—</div><div class="muted" id="wattbreak"></div></div>
      <div class="elist" id="elist"></div>
    </div>
    <div class="muted">Energy Impact is macOS's own relative measure (same one Activity Monitor uses) — it factors in CPU, GPU, wakeups and more, not just CPU time.</div>
  </div>

  <div class="toolbar">
    <div class="seg">
      <span style="color:var(--dim);font-size:12px;margin-right:6px">Sort by</span>
      <button data-sort="score" class="on">Battery impact</button>
      <button data-sort="cpu">CPU</button>
      <button data-sort="mem_mb">Memory</button>
    </div>
    <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
      <div class="toggle" id="lpm" title="Low Power Mode"><span>Low Power Mode</span><span class="dot"></span></div>
      <button class="act energy" id="energybtn">⚡ Measure real energy</button>
      <label><input type="checkbox" id="auto" checked> Auto</label>
      <button class="act" id="refresh">Refresh</button>
    </div>
  </div>

  <table>
    <thead><tr>
      <th>App / Process</th><th>Impact</th>
      <th class="num">CPU</th><th class="num">Memory</th><th></th>
    </tr></thead>
    <tbody id="rows"><tr><td colspan="5" style="color:var(--dim)">Measuring…</td></tr></tbody>
  </table>

  <p class="note">
    <b>Quit</b> asks an app to close gracefully — save your work first. CPU is % of one core
    (100% = one full core; your Mac has <span id="ncpu">?</span> cores). Memory is resident RAM,
    summed across an app's processes. <b>Low Power Mode</b> and <b>Measure real energy</b> need your
    admin password (macOS remembers it for ~5 min). System processes are protected. Everything runs
    locally — nothing leaves your Mac.
  </p>
</div>
<div class="flash" id="flash"></div>

<script>
let DATA = null, sortKey = "score";

function fmtMB(mb){ return mb >= 1024 ? (mb/1024).toFixed(1)+" GB" : Math.round(mb)+" MB"; }
function flash(msg){ const f=document.getElementById("flash"); f.textContent=msg;
  f.classList.add("show"); clearTimeout(f._t); f._t=setTimeout(()=>f.classList.remove("show"),3600); }
function escapeHtml(s){ return s.replace(/[&<>"']/g, c=>(
  {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c])); }
function barColor(p){ return p>50?"var(--green)":p>20?"var(--amber)":"var(--red)"; }

function renderBattery(b){
  const el = document.getElementById("batt");
  if(b.percent===null){ el.innerHTML="<h2>Battery</h2><div class='muted'>No battery detected.</div>"; return; }
  const charge = b.on_ac ? (b.state==="charged"?"Plugged in · charged":"Plugged in · charging") : "On battery";
  const icon = b.on_ac ? "⚡" : "";
  const time = b.time ? (b.on_ac ? "" : b.time+" left") : "";
  el.innerHTML =
    "<h2>Battery</h2>"+
    "<div class='row'><div class='big'>"+icon+b.percent+"%</div><div class='sub'>"+time+"</div></div>"+
    "<div class='bar'><span style='width:"+b.percent+"%;background:"+barColor(b.percent)+"'></span></div>"+
    "<div class='muted'>"+charge+"</div>";
}

function renderMemory(m){
  const el = document.getElementById("mem");
  const usedPct = m.total_gb ? Math.min(100, m.used_gb/m.total_gb*100) : 0;
  const col = m.pressure==="high"?"var(--red)":m.pressure==="elevated"?"var(--amber)":"var(--green)";
  const label = m.pressure==="high"?"High pressure":m.pressure==="elevated"?"Elevated":"Healthy";
  let hint = "";
  if(m.pressure!=="normal")
    hint = "<div class='muted'>Memory is tight ("+m.compressed_gb+" GB compressed, "+
           m.swap_used_mb+" MB on swap) — this drains battery. Quit a few apps below.</div>";
  el.innerHTML =
    "<h2>Memory <span class='pill "+m.pressure+"'>"+label+"</span></h2>"+
    "<div class='row'><div class='big'>"+m.used_gb+" / "+m.total_gb+" GB</div>"+
      "<div class='sub'>"+m.free_gb+" GB free</div></div>"+
    "<div class='bar'><span style='width:"+usedPct+"%;background:"+col+"'></span></div>"+
    hint;
}

function renderLPM(){
  const el = document.getElementById("lpm");
  if(DATA.lowpower===null){ el.style.display="none"; return; }
  el.style.display="inline-flex";
  el.classList.toggle("on", !!DATA.lowpower);
}

function renderRows(){
  const rows = document.getElementById("rows");
  const list = [...DATA.processes].sort((a,b)=> b[sortKey]-a[sortKey]);
  rows.innerHTML = "";
  for(const p of list){
    const tr = document.createElement("tr");
    const np = p.procs>1 ? " <span class='nprocs'>×"+p.procs+"</span>" : "";
    const impact = "<span class='pill "+p.level+"'>"+
                   (p.level==="high"?"High":p.level==="med"?"Medium":"Low")+"</span>";
    const action = p.protected
      ? "<span class='sys'>System</span>"
      : "<button class='kill' data-name='"+encodeURIComponent(p.name)+
        "' data-bundle='"+(p.bundle?1:0)+"' data-pids='"+p.pids.join(",")+"'>Quit</button>";
    tr.innerHTML =
      "<td class='name'>"+escapeHtml(p.name)+np+"</td>"+
      "<td>"+impact+"</td>"+
      "<td class='num'>"+p.cpu.toFixed(0)+"%</td>"+
      "<td class='num'>"+fmtMB(p.mem_mb)+"</td>"+
      "<td class='num'>"+action+"</td>";
    rows.appendChild(tr);
  }
  rows.querySelectorAll(".kill").forEach(btn=>btn.addEventListener("click", onKill));
}

async function onKill(e){
  const b = e.currentTarget;
  const name = decodeURIComponent(b.dataset.name);
  if(!confirm("Quit "+name+"?\n\nIt will be asked to close — save your work first.")) return;
  b.disabled = true; b.textContent = "Quitting…";
  try{
    const r = await fetch("/api/kill", {method:"POST", headers:{"Content-Type":"application/json"},
      body: JSON.stringify({name, bundle: b.dataset.bundle==="1",
        pids: b.dataset.pids? b.dataset.pids.split(",").map(Number):[]})});
    const j = await r.json();
    flash(j.message || (j.ok?"Done.":"Could not quit."));
  }catch(err){ flash("Error: "+err); }
  setTimeout(load, 1200);
}

document.getElementById("lpm").addEventListener("click", async ()=>{
  if(!DATA || DATA.lowpower===null) return;
  const turnOn = !DATA.lowpower;
  flash("Setting Low Power Mode "+(turnOn?"on":"off")+"… (enter password if asked)");
  try{
    const r = await fetch("/api/lowpower",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({on:turnOn})});
    const j = await r.json();
    flash(j.message || "Done.");
  }catch(err){ flash("Error: "+err); }
  setTimeout(load, 800);
});

document.getElementById("energybtn").addEventListener("click", async ()=>{
  const btn = document.getElementById("energybtn");
  btn.disabled = true; btn.textContent = "⏳ Sampling… (enter password if asked)";
  try{
    const r = await fetch("/api/energy", {method:"POST"});
    const j = await r.json();
    if(j.ok){ renderEnergy(j); }
    else { flash(j.message || "Couldn't measure energy."); }
  }catch(err){ flash("Error: "+err); }
  btn.disabled = false; btn.textContent = "⚡ Measure real energy";
});

function renderEnergy(j){
  document.getElementById("energy").style.display = "block";
  const s = j.system || {};
  const total = (s.combined!=null) ? s.combined :
        ((s.cpu||0)+(s.gpu||0)+(s.ane||0));
  document.getElementById("watt").textContent = total ? total.toFixed(2)+" W" : "—";
  let parts = [];
  if(s.cpu!=null) parts.push("CPU "+s.cpu.toFixed(2)+" W");
  if(s.gpu!=null) parts.push("GPU "+s.gpu.toFixed(2)+" W");
  if(s.ane!=null) parts.push("ANE "+s.ane.toFixed(2)+" W");
  document.getElementById("wattbreak").textContent = parts.join(" · ") || "system-wide draw";
  const el = document.getElementById("elist");
  el.innerHTML = "<div style='color:var(--dim);border:none'><span>Top energy impact</span><span></span></div>";
  for(const t of (j.tasks||[]).slice(0,8)){
    const d = document.createElement("div");
    d.innerHTML = "<span>"+escapeHtml(t.name)+"</span><span style='font-variant-numeric:tabular-nums'>"+t.energy+"</span>";
    el.appendChild(d);
  }
  flash("Measured real power draw.");
}

function render(){
  renderBattery(DATA.battery);
  renderMemory(DATA.memory);
  renderLPM();
  document.getElementById("ncpu").textContent = DATA.ncpu;
  renderRows();
  const d = new Date(DATA.ts*1000);
  document.getElementById("updated").textContent = "updated "+d.toLocaleTimeString();
}

async function load(){
  try{
    const r = await fetch("/api/stats");
    DATA = await r.json();
    render();
  }catch(err){ document.getElementById("updated").textContent = "connection lost"; }
}

document.querySelectorAll(".seg button").forEach(btn=>btn.addEventListener("click",()=>{
  sortKey = btn.dataset.sort;
  document.querySelectorAll(".seg button").forEach(x=>x.classList.toggle("on", x===btn));
  if(DATA) renderRows();
}));
document.getElementById("refresh").addEventListener("click", load);
setInterval(()=>{ if(document.getElementById("auto").checked) load(); }, 5000);
load();
</script>
</body></html>
"""

# Prefer an external dashboard.html (keeps the UI decoupled from this file and
# easy to iterate on); fall back to the embedded PAGE above if it's missing.
try:
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "dashboard.html"), encoding="utf-8") as _f:
        PAGE = _f.read()
except OSError:
    pass


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(data)
        except Exception:
            pass

    def _read_json(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return {}

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif self.path.startswith("/api/stats"):
            self._send(200, json.dumps(build_stats()))
            # Do not let the multi-second `pmset -g log` scan contend with the
            # response that removes the launch loader. It begins only after
            # that first fast stats payload has been written to the client.
            start_slow_refresh()
        elif self.path.startswith("/api/history"):
            days = 10 if "range=10d" in self.path else 1
            self._send(200, json.dumps(get_history(days)))
        elif self.path.startswith("/api/settings"):
            self._send(200, json.dumps(_SETTINGS))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        if self.path.startswith("/api/kill"):
            p = self._read_json()
            name = str(p.get("name", ""))
            if is_protected(name, "", "") or name in CRITICAL_NAMES or "battery_hog" in name:
                self._send(200, json.dumps({"ok": False, "message": "That process is protected."}))
                return
            ok, msg = quit_target(name, bool(p.get("bundle")), p.get("pids", []) or [])
            self._send(200, json.dumps({"ok": ok, "message": msg}))
        elif self.path.startswith("/api/lowpower"):
            p = self._read_json()
            ok, msg = set_lowpower(bool(p.get("on")))
            self._send(200, json.dumps({"ok": ok, "message": msg, "on": bool(p.get("on")) if ok else None}))
        elif self.path.startswith("/api/energy"):
            self._send(200, json.dumps(get_energy()))
        elif self.path.startswith("/api/ignore"):
            p = self._read_json()
            if p.get("reset"):
                _IGNORED.clear()
            else:
                name = str(p.get("name", ""))
                if name:
                    _IGNORED.add(name) if p.get("on") else _IGNORED.discard(name)
            _save_ignored()
            self._send(200, json.dumps({"ok": True, "ignored": sorted(_IGNORED)}))
        elif self.path.startswith("/api/settings"):
            p = self._read_json()
            if "alerts" in p:
                _SETTINGS["alerts"] = bool(p["alerts"])
            if "low_threshold" in p:
                try:
                    _SETTINGS["low_threshold"] = max(5, min(95, int(p["low_threshold"])))
                except (TypeError, ValueError):
                    pass
            if isinstance(p.get("menubar"), dict):
                for k in ("percent", "watts", "time", "hog", "dev"):
                    if k in p["menubar"]:
                        _SETTINGS["menubar"][k] = bool(p["menubar"][k])
            if isinstance(p.get("dev"), dict):
                incoming = p["dev"]
                for key in ("enabled", "notify_draw"):
                    if key in incoming:
                        _SETTINGS["dev"][key] = bool(incoming[key])
                for key, lo, hi in (("slots", 1, 4), ("workers", 1, 8),
                                    ("draw_threshold", 10, 80)):
                    if key in incoming:
                        try:
                            _SETTINGS["dev"][key] = max(lo, min(hi, int(incoming[key])))
                        except (TypeError, ValueError):
                            pass
            if isinstance(p.get("heat"), dict):
                enabled = p["heat"].get("enabled")
                if isinstance(enabled, bool):
                    _SETTINGS["heat"]["enabled"] = enabled
            _save_settings()
            self._send(200, json.dumps({"ok": True, "settings": _SETTINGS}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, *a):
        pass


def main():
    if "--selftest" in sys.argv:
        print(json.dumps(build_stats(), indent=2))
        return

    fixed = None
    for i, a in enumerate(sys.argv):
        if a == "--port" and i + 1 < len(sys.argv):
            try:
                fixed = int(sys.argv[i + 1])
            except ValueError:
                pass
        elif a.startswith("--port="):
            try:
                fixed = int(a.split("=", 1)[1])
            except ValueError:
                pass

    candidates = [fixed] if fixed else list(range(8765, 8786))
    server = None
    port = None
    for p in candidates:
        try:
            srv = http.server.ThreadingHTTPServer(("127.0.0.1", p), Handler)
            srv.allow_reuse_address = True
            server, port = srv, p
            break
        except OSError:
            continue
    if not server:
        print("Could not bind a port (%s). Is it already running?" % candidates)
        return

    threading.Thread(target=_alert_loop, daemon=True).start()

    url = "http://127.0.0.1:%d/" % port
    print("\n  🔋  Battery Hog is running")
    print("  →  " + url)
    print("  Opening your browser… (press Ctrl-C here to stop)\n")
    if "--no-open" not in sys.argv:
        try:
            webbrowser.open(url)
        except Exception:
            pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Stopped. Bye!\n")
        server.shutdown()


if __name__ == "__main__":
    main()
