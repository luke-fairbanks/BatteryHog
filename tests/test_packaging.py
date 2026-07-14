import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


class DmgPackagingContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = (SRC / "build.sh").read_text(encoding="utf-8")
        cls.package = (SRC / "package.sh").read_text(encoding="utf-8")
        cls.release = (SRC / "release.sh").read_text(encoding="utf-8")
        cls.native_build = (SRC / "native_build.sh").read_text(encoding="utf-8")
        cls.backend = (SRC / "BatteryHogBackend.swift").read_text(encoding="utf-8")
        cls.stores = (SRC / "BatteryHogStores.swift").read_text(encoding="utf-8")
        cls.builder = (SRC / "build_dmg.sh").read_text(encoding="utf-8")
        cls.artwork = (SRC / "make_dmg_background.swift").read_text(encoding="utf-8")

    def test_shared_native_build_produces_app_and_gate_executables(self):
        self.assertIn("BATTERY_HOG_APP_SOURCES=(", self.native_build)
        self.assertIn("BATTERY_HOG_GATE_SOURCES=(", self.native_build)
        self.assertIn('-o "$contents/MacOS/BatteryHog"', self.native_build)
        self.assertIn('-o "$contents/Helpers/batteryhog-gate"', self.native_build)
        self.assertIn('chmod 755 "$contents/Helpers/batteryhog-gate"', self.native_build)

    def test_every_bundle_path_uses_native_runtime_resources_only(self):
        for script_name, script in (
            ("build.sh", self.build),
            ("package.sh", self.package),
            ("release.sh", self.release),
        ):
            with self.subTest(script=script_name):
                self.assertIn('source "$ROOT/src/native_build.sh"', script)
                self.assertIn('compile_battery_hog_native "$C"', script)
                self.assertIn('"$C/Helpers"', script)
                self.assertIn('cp "$ROOT/dashboard.html" "$C/Resources/dashboard.html"', script)
                self.assertNotRegex(script, r"(?m)^\s*(?:cp|ditto)\s+[^\n]*\.py(?:\s|$)")
                for legacy_runtime in (
                    "battery_hog.py", "batteryhog_workloads.py", "batteryhog_gate.py",
                ):
                    self.assertNotIn(legacy_runtime, script)

    def test_power_log_scan_is_single_flight_and_history_is_persisted(self):
        scan = '"/usr/bin/pmset", ["-g", "log"]'
        self.assertEqual(self.backend.count(scan), 1)
        refresh = self.backend.split("private func startSlowRefresh", 1)[1]
        self.assertIn(scan, refresh)
        self.assertNotIn("private func powerLog()", self.backend)
        self.assertNotIn("rowsCache", self.backend)
        self.assertIn('"history_rows"', self.stores)
        self.assertIn('"wake_dates"', self.stores)

    def test_every_bundle_path_signs_both_native_executables_before_the_app(self):
        sections = {
            "build.sh": self.build.split('echo "==> Ad-hoc code signing"', 1)[1].split(
                'echo "==> Installing', 1)[0],
            "package.sh": self.package.split('echo "==> Ad-hoc sign"', 1)[1].split(
                'if [ "${SKIP_DMG', 1)[0],
            "release.sh": self.release.split('echo "==> Sign', 1)[1].split(
                'echo "==> Build DMG', 1)[0],
        }
        ordered = (
            '"$C/Helpers/batteryhog-gate"',
            '"$C/MacOS/BatteryHog"',
            '"$APP"',
        )
        for script_name, section in sections.items():
            with self.subTest(script=script_name):
                offsets = [section.index(target) for target in ordered]
                self.assertEqual(offsets, sorted(offsets))
                for target in ordered:
                    signing_line = next(
                        line for line in section.splitlines()
                        if target in line and "codesign" in line
                    )
                    self.assertNotIn("--deep --sign", signing_line)

    def test_ad_hoc_and_notarized_builds_share_the_styled_dmg_builder(self):
        invocation = '"$ROOT/src/build_dmg.sh" "$APP" "$DMG" "Battery Hog Installer"'
        self.assertIn(invocation, self.package)
        self.assertIn(invocation, self.release)

    def test_builder_keeps_the_native_drag_to_install_contract(self):
        for required in (
            'ln -s /Applications "$MOUNT_DIR/Applications"',
            '"$MOUNT_DIR/.background/background.png"',
            'set bounds of container window to {140, 120, 820, 572}',
            'set icon size of viewOptions to 112',
            'set position of item applicationName of container window to {170, 236}',
            'set position of item "Applications" of container window to {510, 236}',
            'set background picture of viewOptions to file ".background:background.png"',
            'SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns"',
            'hdiutil convert "$RW_DMG"',
            '-format UDZO',
            'for _ in $(seq 1 80)',
            'DMG_VERIFIED=1',
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.builder)

        self.assertIn('[ -s "$MOUNT_DIR/.DS_Store" ]', self.builder)
        self.assertIn('rm -rf "$MOUNT_DIR/.fseventsd"', self.builder)

    def test_artwork_matches_the_current_battery_hog_visual_language(self):
        for required in (
            'NSSize(width: 680, height: 420)',
            '"Drag Battery Hog to Applications"',
            '"Then launch it from Spotlight or Launchpad."',
            'NSColor(hex: 0xcaff58)',
            'drawLabelPlate(x: 105, width: 130)',
            'drawLabelPlate(x: 445, width: 130)',
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.artwork)

        self.assertNotIn("BATTERY HOG / INSTALL", self.artwork)
        self.assertNotIn("SIGNED & NOTARIZED", self.artwork)


if __name__ == "__main__":
    unittest.main()
