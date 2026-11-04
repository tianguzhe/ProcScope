"""Exercise filesystem/registry boundaries without changing LaunchServices."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_isolation as isolation


class BuildIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="procscope-isolation-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "Project with spaces"
        self.root.mkdir()
        self.derived = self.base / "DerivedData"
        self.area = self.make_area()

    def make_area(self):
        return isolation.BuildArea(self.root, derived_data_home=self.derived)

    def write_plist(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def test_ownership_excludes_installed_apps_and_escaped_symlinks(self):
        self.area.prepare()
        self.assertTrue(self.area.owns(self.area.work / "xcode/Test.app"))
        self.assertTrue(self.area.owns(self.root / "build/test/Legacy.app"))
        for path in (Path("/Applications/ProcScope.app"), Path.home() / "Applications/ProcScope.app",
                     self.root / "Example.app", self.root / "build-other/Foo.app"):
            self.assertFalse(self.area.owns(path), path)
        (self.area.work / "Installed.app").symlink_to("/Applications/ProcScope.app")
        self.assertFalse(self.area.owns(self.area.work / "Installed.app"))
        (self.area.work / "escape").symlink_to(self.base)
        self.assertFalse(self.area.owns(self.area.work / "escape/Other.app"))

    def test_legacy_release_only_accepts_procscope_bundle(self):
        app = self.root / "release/ProcScope.app"
        self.assertTrue(self.area.owns(app))  # Stale registrations can outlive a bundle.
        self.write_plist(app / "Contents/Info.plist", {"CFBundleIdentifier": "another.app"})
        self.assertFalse(self.area.owns(app))
        self.write_plist(app / "Contents/Info.plist", {"CFBundleIdentifier": "com.yikwing.ProcScope"})
        self.assertTrue(self.area.owns(app))
        self.assertFalse(self.area.owns(self.root / "release/Other.app"))

    def test_legacy_release_symlink_is_not_owned(self):
        (self.root / "release").symlink_to("/Applications")
        self.assertFalse(self.area.owns(self.root / "release/ProcScope.app"))

    def test_global_derived_data_requires_matching_workspace_metadata(self):
        self.write_plist(self.derived / "Owned/info.plist", {"WorkspacePath": str(self.root / "ProcScope.xcodeproj")})
        self.write_plist(self.derived / "ProcScope-Unrelated/info.plist", {"WorkspacePath": str(self.base / "Other/ProcScope.xcodeproj")})
        self.write_plist(self.derived / "Relative/info.plist", {"WorkspacePath": "ProcScope.xcodeproj"})
        area = self.make_area()
        self.assertTrue(area.owns(self.derived / "Owned/Build/Products/Debug/ProcScope.app"))
        for folder in ("ProcScope-Unrelated", "Relative", "NoMetadata"):
            self.assertFalse(area.owns(self.derived / folder / "Build/Products/Debug/ProcScope.app"))

    def test_prepare_preserves_xcode_preferences_and_is_idempotent(self):
        username = isolation.pwd.getpwuid(isolation.os.getuid()).pw_name
        settings = self.root / f"ProcScope.xcodeproj/project.xcworkspace/xcuserdata/{username}.xcuserdatad/WorkspaceSettings.xcsettings"
        self.write_plist(settings, {"CustomPreference": True})
        self.area.prepare()
        before = settings.read_bytes()
        self.area.prepare()
        self.assertEqual(settings.read_bytes(), before)
        data = plistlib.loads(before)
        self.assertTrue(data["CustomPreference"])
        self.assertEqual(data["DerivedDataCustomLocation"], ".build/artifacts.noindex/Xcode")
        self.assertTrue((self.area.work / "logs").is_dir())

    def test_prepare_rejects_build_or_settings_symlinks(self):
        (self.root / "build").symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.make_area()
        (self.root / "build").unlink()
        (self.root / ".build").mkdir()
        (self.root / ".build/artifacts.noindex").symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.area.prepare()

    def test_command_injects_isolated_derived_data_and_preserves_arguments(self):
        arguments, env = self.area.command(["xcrun", "xcodebuild", "-scheme", "ProcScope", "test"], "test")
        self.assertEqual(arguments[:4], ["xcrun", "xcodebuild", "-derivedDataPath", str(self.area.work / "xcode/test")])
        self.assertEqual(arguments[4:], ["-scheme", "ProcScope", "test"])
        self.assertEqual(env["ISOLATED_BUILD_DIR"], str(self.area.work))
        with self.assertRaises(ValueError):
            self.area.command(["xcodebuild"], "../../outside")

    def test_command_rejects_output_path_escape_and_duplicate_options(self):
        for args in (["-derivedDataPath", str(self.base)], ["-archivePath", "/Applications/Test.xcarchive"],
                     ["-resultBundlePath", "../Test.xcresult"], ["SYMROOT=/tmp/products"],
                     ["-derivedDataPath"], ["-derivedDataPath=/tmp/build"],
                     ["-derivedDataPath", str(self.area.work), "-derivedDataPath", str(self.area.work)]):
            with self.subTest(args=args), self.assertRaises(ValueError):
                self.area.command(["xcodebuild"] + args, "test")
        self.area.prepare()
        (self.area.work / "escape").symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.area.command(["xcodebuild", "-derivedDataPath", str(self.area.work / "escape")], "test")

    def test_cleanup_filters_registry_by_path_and_supports_dry_run(self):
        own = self.area.work / "xcode/ProcScope.app"
        dump = f"path: {own} (0x123abc)\npath: /Applications/ProcScope.app\npath: {own}\nbundle id: com.yikwing.ProcScope\n"
        with patch.object(isolation.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, dump, "")) as run:
            self.area.cleanup(dry_run=True)
            self.assertEqual(run.call_count, 1)
            self.area.cleanup()
            self.assertEqual(run.call_args.args[0], [str(isolation.LSREGISTER), "-u", str(own)])
            self.assertEqual(run.call_count, 3)

    def test_cleanup_reports_unregister_failure(self):
        with patch.object(self.area, "registered", return_value=[self.area.work / "Test.app"]), \
             patch.object(isolation.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "denied")):
            with self.assertRaisesRegex(RuntimeError, "denied"):
                self.area.cleanup()

    def test_execute_preserves_failure_and_always_cleans_up(self):
        with patch.object(self.area, "cleanup") as cleanup:
            code = isolation.execute(self.area, [sys.executable, "-c", "raise SystemExit(23)"], "test")
            self.assertEqual(code, 23)
            cleanup.assert_called_once()
        with patch.object(self.area, "cleanup", side_effect=RuntimeError("cleanup failed")):
            self.assertEqual(isolation.execute(self.area, [sys.executable, "-c", "pass"], "test"), 1)
            self.assertEqual(isolation.execute(self.area, [sys.executable, "-c", "raise SystemExit(23)"], "test"), 23)

    def test_ci_logs_are_unique_and_preserve_command_failure(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("ci-annotate.sh", "build_isolation.py"):
            shutil.copyfile(Path(__file__).resolve().parents[1] / name, scripts / name)
        for code in (0, 17):
            result = subprocess.run(["bash", str(scripts / "ci-annotate.sh"), "Test", sys.executable,
                                     "-c", f"print('command output'); raise SystemExit({code})"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, code, result.stdout + result.stderr)
            self.assertIn("command output", result.stdout)
            self.assertEqual("::error" in result.stdout, code != 0)
        logs = list((self.area.work / "logs").glob("ci.log.*"))
        self.assertEqual(len(logs), 2)
        self.assertTrue(all("command output" in log.read_text() for log in logs))


if __name__ == "__main__":
    unittest.main()
