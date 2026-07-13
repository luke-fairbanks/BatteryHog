import json
import os
import tempfile
import unittest
from unittest import mock

import batteryhog_gate
from batteryhog_workloads import (
    aggregate_workloads,
    classify_dev_command,
    parse_pmset_assertions,
)


class WorkloadTests(unittest.TestCase):
    def test_classifies_common_agent_build_tools(self):
        self.assertEqual(classify_dev_command("/opt/homebrew/bin/gitleaks detect")["kind"], "scan")
        self.assertEqual(classify_dev_command("/usr/bin/cargo check")["family"], "Rust")
        self.assertEqual(classify_dev_command("org.gradle.launcher.daemon.bootstrap.GradleDaemon")["tool"], "Gradle")
        self.assertEqual(classify_dev_command("next-server (v15.5.12)")["kind"], "server")
        self.assertIsNone(classify_dev_command("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))

    def test_groups_children_by_project_and_agent_owner(self):
        with tempfile.TemporaryDirectory() as root:
            os.mkdir(os.path.join(root, ".git"))
            sub = os.path.join(root, "src-tauri")
            os.mkdir(sub)
            samples = [
                {"pid": 10, "ppid": 1, "rss_kb": 1000, "cpu": 4,
                 "command": "/Applications/ChatGPT.app/Contents/Resources/codex"},
                {"pid": 20, "ppid": 10, "rss_kb": 200000, "cpu": 120,
                 "command": "/Users/me/.cargo/bin/cargo check"},
                {"pid": 21, "ppid": 20, "rss_kb": 300000, "cpu": 80,
                 "command": "/Users/me/.rustup/bin/rustc --crate-name app"},
                {"pid": 22, "ppid": 10, "rss_kb": 150000, "cpu": 0,
                 "command": "next-server (v15.5.12)"},
            ]
            data = aggregate_workloads(samples, {10: root, 20: sub, 21: sub, 22: root})

        self.assertEqual(data["summary"]["projects"], 1)
        self.assertEqual(data["summary"]["workers"], 3)
        self.assertEqual(data["summary"]["heavy_workers"], 2)
        self.assertEqual(data["summary"]["agents"], ["Codex"])
        workload = data["workloads"][0]
        self.assertEqual(workload["agents"], ["Codex"])
        self.assertIn("Rust", workload["families"])
        self.assertEqual(workload["servers"], 1)
        self.assertEqual(workload["status"], "Building")

    def test_parses_and_prioritizes_stale_user_sleep_blockers(self):
        text = """
   pid 663(Claude): [0x1] 26:43:18 NoIdleSleepAssertion named: "Electron"
   pid 352(powerd): [0x2] 03:29:46 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
   pid 99(helper): [0x3] 00:00:30 PreventUserIdleSystemSleep named: "Short task"
"""
        blockers = parse_pmset_assertions(text)
        self.assertEqual([b["name"] for b in blockers], ["Claude", "helper", "powerd"])
        self.assertTrue(blockers[0]["stale"])
        self.assertFalse(blockers[1]["stale"])
        self.assertTrue(blockers[2]["system"])

    def test_ignores_idle_node_helpers_in_hidden_agent_directories(self):
        samples = [{"pid": 50, "ppid": 1, "rss_kb": 90000, "cpu": 0,
                    "command": "/opt/homebrew/bin/node helper.js"}]
        data = aggregate_workloads(samples, {50: os.path.expanduser("~/.codex/plugins/example")})
        self.assertEqual(data["summary"]["projects"], 0)
        self.assertEqual(data["summary"]["workers"], 0)


class GateTests(unittest.TestCase):
    def test_permission_denied_process_check_is_treated_as_alive(self):
        with mock.patch("batteryhog_gate.os.kill", side_effect=PermissionError):
            self.assertTrue(batteryhog_gate._pid_alive(1234))

    def test_prepares_conservative_worker_limits(self):
        command, env = batteryhog_gate.prepare_command(["./gradlew", "test"], 2, {})
        self.assertIn("--max-workers=2", command)
        self.assertEqual(env["CARGO_BUILD_JOBS"], "2")
        self.assertEqual(env["RAYON_NUM_THREADS"], "2")
        self.assertEqual(env["GOMAXPROCS"], "2")

    def test_loads_agent_mode_settings_from_isolated_directory(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
                os.environ, {"BATTERY_HOG_DATA_DIR": tmp}, clear=False):
            with open(os.path.join(tmp, "settings.json"), "w", encoding="utf-8") as handle:
                json.dump({"dev": {"enabled": True, "slots": 1, "workers": 3}}, handle)
            settings = batteryhog_gate.load_dev_settings()
        self.assertTrue(settings["enabled"])
        self.assertEqual(settings["slots"], 1)
        self.assertEqual(settings["workers"], 3)

    def test_gate_snapshot_prunes_dead_processes(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
                os.environ, {"BATTERY_HOG_DATA_DIR": tmp}, clear=False):
            with open(os.path.join(tmp, "agent-gate.json"), "w", encoding="utf-8") as handle:
                json.dump({"entries": [{"pid": 99999999, "state": "active"}]}, handle)
            snapshot = batteryhog_gate.gate_snapshot()
        self.assertEqual(snapshot, {"active": [], "queued": []})


if __name__ == "__main__":
    unittest.main()
