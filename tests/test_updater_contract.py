import base64
import plistlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


class UpdaterContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        cls.plist = plistlib.loads((SRC / "Info.plist").read_bytes())
        cls.swift = (SRC / "BatteryHogApp.swift").read_text(encoding="utf-8")
        cls.release = (SRC / "release.sh").read_text(encoding="utf-8")
        cls.appcast = (SRC / "generate_appcast.sh").read_text(encoding="utf-8")

    def test_version_has_one_canonical_source(self):
        self.assertRegex(self.version, r"^[0-9]+\.[0-9]+\.[0-9]+$")
        self.assertNotIn("CFBundleVersion", self.plist)
        self.assertNotIn("CFBundleShortVersionString", self.plist)

        helper = (SRC / "version.sh").read_text(encoding="utf-8")
        self.assertIn('VERSION_FILE="$ROOT/VERSION"', helper)
        self.assertIn("stamp_bundle_version", helper)
        for script_name in ("build.sh", "package.sh", "release.sh"):
            script = (SRC / script_name).read_text(encoding="utf-8")
            with self.subTest(script=script_name):
                self.assertIn('source "$ROOT/src/version.sh"', script)
                self.assertIn('stamp_bundle_version "$C/Info.plist"', script)
                self.assertNotRegex(script, r'VERSION="\$\{VERSION:-')

    def test_sparkle_dependency_is_pinned_and_verified(self):
        fetcher = (SRC / "fetch_sparkle.sh").read_text(encoding="utf-8")
        self.assertIn('SPARKLE_VERSION="2.9.4"', fetcher)
        self.assertIn(
            'SPARKLE_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"',
            fetcher,
        )
        self.assertIn('shasum -a 256 "$ARCHIVE"', fetcher)
        self.assertIn('if [ "$ACTUAL_SHA" != "$SPARKLE_SHA256" ]', fetcher)
        self.assertIn('tar -xJf "$ARCHIVE"', fetcher)
        self.assertIn('rm -rf "$DIST_ROOT"', fetcher)
        self.assertNotIn('if [ ! -f "$FRAMEWORK/Versions/B/Sparkle" ]', fetcher)

    def test_every_build_links_and_embeds_sparkle(self):
        for script_name in ("build.sh", "package.sh", "release.sh"):
            script = (SRC / script_name).read_text(encoding="utf-8")
            with self.subTest(script=script_name):
                self.assertIn('-F "$SPARKLE_ROOT" -framework Sparkle', script)
                self.assertIn("-Xlinker '@loader_path/../Frameworks'", script)
                self.assertIn(
                    'ditto "$SPARKLE_ROOT/Sparkle.framework" "$C/Frameworks/Sparkle.framework"',
                    script,
                )
                self.assertIn('Sparkle-LICENSE.txt', script)

    def test_update_security_and_privacy_defaults_are_explicit(self):
        expected_false = (
            "SUEnableAutomaticChecks",
            "SUAutomaticallyUpdate",
            "SUAllowsAutomaticUpdates",
            "SUEnableSystemProfiling",
        )
        for key in expected_false:
            with self.subTest(key=key):
                self.assertIs(self.plist.get(key), False)
        self.assertIs(self.plist.get("SUVerifyUpdateBeforeExtraction"), True)
        self.assertIs(self.plist.get("SURequireSignedFeed"), True)
        self.assertEqual(self.plist.get("SUScheduledCheckInterval"), 86400)
        self.assertEqual(
            self.plist.get("SUFeedURL"),
            "https://github.com/luke-fairbanks/BatteryHog/releases/latest/download/appcast.xml",
        )
        self.assertEqual(len(base64.b64decode(self.plist["SUPublicEDKey"], validate=True)), 32)

    def test_release_signs_nested_sparkle_code_deepest_first(self):
        signing_section = self.release.split('echo "==> Sign', 1)[1].split(
            'echo "==> Build DMG', 1
        )[0]
        ordered = (
            "XPCServices/Installer.xpc",
            "XPCServices/Downloader.xpc",
            '"$SPARKLE_BIN/Autoupdate"',
            '"$SPARKLE_BIN/Updater.app"',
            '"$SPARKLE_FRAMEWORK"',
            '"$C/MacOS/BatteryHog"',
            '"$APP"',
        )
        offsets = [signing_section.index(token) for token in ordered]
        self.assertEqual(offsets, sorted(offsets))
        deep_lines = [line for line in signing_section.splitlines() if "codesign --deep" in line]
        self.assertTrue(deep_lines)
        self.assertTrue(all("--verify" in line for line in deep_lines))
        self.assertIn("codesign --deep --verify", self.release)

    def test_release_team_is_pinned_across_app_framework_and_dmg(self):
        team = (ROOT / "RELEASE_TEAM_ID").read_text(encoding="utf-8").strip()
        self.assertEqual(team, "M58C5Q8BJC")
        helper = (SRC / "release_identity.sh").read_text(encoding="utf-8")
        self.assertIn('RELEASE_TEAM_FILE="$ROOT/RELEASE_TEAM_ID"', helper)
        for target in (
            "XPCServices/Installer.xpc", "XPCServices/Downloader.xpc",
            "Autoupdate", "Updater.app", "Sparkle.framework",
            "Contents/MacOS/BatteryHog",
        ):
            self.assertIn(target, helper)
        self.assertIn('require_battery_hog_bundle_team "$APP"', self.release)
        self.assertIn('require_codesign_team "$DMG"', self.release)
        staging = (SRC / "stage_release.sh").read_text(encoding="utf-8")
        self.assertIn('require_codesign_team "$DMG"', staging)
        self.assertIn('require_battery_hog_bundle_team "$MOUNT_DIR/Battery Hog.app"', staging)

    def test_appcast_is_generated_from_final_versioned_dmg_and_verified(self):
        for required in (
            'BatteryHog-$VERSION.dmg',
            "releases/latest/download/appcast.xml",
            "releases/download/v$VERSION/",
            '--account "$SPARKLE_KEY_ACCOUNT"',
            "--maximum-deltas 0",
            "--maximum-versions 0",
            '--versions "$VERSION"',
            'sign_update"',
            "--verify",
            "ARCHIVE_SIGNATURE",
            "sparkle-signatures:",
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.appcast)
        self.assertLess(self.release.index("xcrun stapler staple \"$DMG\""),
                        self.release.index("generate_appcast.sh"))

    def test_homebrew_install_never_starts_sparkle(self):
        for path in (
            "/opt/homebrew/Caskroom/battery-hog",
            "/usr/local/Caskroom/battery-hog",
        ):
            self.assertIn(path, self.swift)
        self.assertIn("resolvingSymlinksInPath", self.swift)
        self.assertRegex(
            self.swift,
            r'if installMethod == "direct"\s*\{\s*updaterController = SPUStandardUpdaterController',
        )
        self.assertIn("brew upgrade --cask luke-fairbanks/tap/battery-hog", self.swift)

    def test_update_consent_is_not_mirrored_to_python_settings(self):
        backend = (ROOT / "battery_hog.py").read_text(encoding="utf-8")
        self.assertNotRegex(backend, r'["\']updates["\']\s*:')
        self.assertIn("automaticallyChecksForUpdates = enabled", self.swift)

    def test_native_state_explicitly_clears_stale_update_details(self):
        for key in ("latestVersion", "lastChecked", "message", "error"):
            with self.subTest(key=key):
                self.assertIn(f'"{key}": NSNull()', self.swift)

    def test_release_staging_is_a_reviewable_draft(self):
        staging = (SRC / "stage_release.sh").read_text(encoding="utf-8")
        self.assertIn('--draft', staging)
        self.assertIn('"$DMG"', staging)
        self.assertIn('"$APPCAST"', staging)
        self.assertIn('--draft=false --latest', staging)

    def test_homebrew_cask_staging_derives_from_the_canonical_release(self):
        staging = (SRC / "stage_homebrew_cask.sh").read_text(encoding="utf-8")
        self.assertIn('source "$SCRIPT_DIR/version.sh"', staging)
        self.assertIn('BatteryHog-$VERSION.dmg', staging)
        self.assertIn('shasum -a 256 "$DMG"', staging)
        self.assertIn('gh release download "$TAG"', staging)
        self.assertIn('version "$ENV{VERSION}"', staging)
        self.assertIn('sha256 "$ENV{SHA256}"', staging)
        self.assertNotIn("git commit", staging)
        self.assertNotIn("git push", staging)


if __name__ == "__main__":
    unittest.main()
