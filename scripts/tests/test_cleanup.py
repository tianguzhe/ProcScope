"""Check exit cleanup using temporary files and a stub isolation command."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="procscope-cleanup-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.common = scripts / "common.sh"
        shutil.copyfile(Path(__file__).resolve().parents[1] / "common.sh", self.common)
        (scripts / "build_isolation.py").write_text("# No registry access in cleanup tests.\n")
        self.stage = self.root / "package with spaces"
        self.mount = self.stage / "verify"
        self.mount.mkdir(parents=True)
        (self.stage / "retained.txt").write_text("Keep if mount status is uncertain.")

    def run_cleanup(self, command_status, probe_status=3, cleanup_status=0):
        return subprocess.run(
            ["bash", "-c", '''
set -euo pipefail
source "$1"
stage_root="$2"
verify_mount="$stage_root/verify"
probe_status="$4"
cleanup_status="$5"
python3() {
    if [[ "$1" == -c ]]; then return "$probe_status"; fi
    return "$cleanup_status"
}
exit "$3"
''', "cleanup-test", str(self.common), str(self.stage), str(command_status),
             str(probe_status), str(cleanup_status)],
            capture_output=True, text=True,
        )

    def test_unmounted_stage_is_removed_without_hiding_command_failure(self):
        result = self.run_cleanup(command_status=17)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertFalse(self.stage.exists())

    def test_unknown_mount_state_preserves_files_and_marks_success_as_failure(self):
        result = self.run_cleanup(command_status=0, probe_status=2)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue((self.stage / "retained.txt").exists())
        self.assertIn("preserving package work directory", result.stderr)

    def test_registry_failure_preserves_original_status_and_removes_unmounted_stage(self):
        result = self.run_cleanup(command_status=17, cleanup_status=1)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertFalse(self.stage.exists())


if __name__ == "__main__":
    unittest.main()
