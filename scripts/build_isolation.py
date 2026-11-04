#!/usr/bin/env python3
"""Keep development apps out of macOS application search, without deleting them.

Adapted from MacClean e790488 and QuietLock d69c43a. Python 3.9+, no dependencies.
"""

import argparse
import os
from pathlib import Path
import plistlib
import pwd
import re
import signal
import subprocess
import sys


LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)
LOCAL_BUILD_FOLDERS = (".build", "build", "DerivedData", "TestResults")
XCODE_PATH_OPTIONS = ("-derivedDataPath", "-archivePath", "-resultBundlePath")
XCODE_PATH_SETTINGS = {
    "SYMROOT", "OBJROOT", "DSTROOT", "CONFIGURATION_BUILD_DIR", "CONFIGURATION_TEMP_DIR",
}


def is_inside(path, directory):
    return path == directory or directory in path.parents


def protected(path):
    """An explicit cache path must never include an installed application area."""
    locations = [Path("/Applications"), Path("/System"), Path("/Library"), Path.home() / "Applications"]
    folded = Path(str(path).casefold())
    return (
        path in (Path("/"), Path.home(), Path("/Users"), Path("/private"), Path("/private/tmp"), Path("/Volumes"))
        or os.path.ismount(path)
        or any(
            is_inside(folded, Path(str(location).casefold()))
            or is_inside(Path(str(location).casefold()), folded)
            for location in locations
        )
        or any(part.casefold().endswith(".app") for part in path.parts)
    )


def registered_paths(dump):
    """Read only path fields; bundle IDs alone cannot distinguish installed copies."""
    paths = set()
    for line in dump.splitlines():
        match = re.match(r"^path:\s+(.+?)(?: \(0x[0-9a-fA-F]+\))?\s*$", line)
        if match and match[1].endswith(".app"):
            path = Path(match[1])
            if path.is_absolute():
                paths.add(path)
    return paths


class BuildArea:
    def __init__(self, root, extra_build_dirs=(), derived_data_home=None):
        self.root = Path(root).resolve(strict=True)
        if not self.root.is_dir() or protected(self.root):
            raise ValueError("Choose a project directory, not a system/application/home directory")
        self.build = self.root / ".build"
        self.work = self.build / "artifacts.noindex"
        self.roots = []
        for name in LOCAL_BUILD_FOLDERS:
            candidate = self.root / name
            if candidate.is_symlink():
                raise ValueError(f"Build directory must not be a symlink: {candidate}")
            self.roots.append(candidate)
        for value in extra_build_dirs:
            candidate = Path(value).resolve(strict=True)
            if not candidate.is_dir() or protected(candidate) or is_inside(self.root, candidate):
                raise ValueError(f"Not a safe extra build directory: {candidate}")
            self.roots.append(candidate)
        derived_data_home = derived_data_home or Path.home() / "Library/Developer/Xcode/DerivedData"
        self.roots.extend(self._owned_derived_data(derived_data_home))

    def _owned_derived_data(self, derived_data_home):
        """Discover old Xcode caches by workspace metadata, never by folder name."""
        for info in Path(derived_data_home).glob("*/info.plist"):
            try:
                metadata = plistlib.loads(info.read_bytes())
                if not isinstance(metadata, dict) or not isinstance(metadata.get("WorkspacePath"), str):
                    continue
                workspace = Path(metadata["WorkspacePath"])
                if not workspace.is_absolute():
                    continue
                workspace = workspace.resolve()
                if workspace.suffix in (".xcodeproj", ".xcworkspace") and is_inside(workspace, self.root):
                    candidate = info.parent.resolve()
                    if not protected(candidate):
                        yield candidate
            except (OSError, ValueError, plistlib.InvalidFileException):
                continue

    def owns(self, path):
        # Require both lexical and resolved containment; never follow a build symlink to /Applications.
        path = Path(os.path.abspath(path))
        if path.suffix != ".app":
            return False
        resolved = path.resolve()
        if any(is_inside(resolved, place) for place in (Path("/Applications"), Path.home() / "Applications")):
            return False
        # Older ProcScope scripts exported this one app beside the DMG. Never
        # treat the whole release directory (or an installed symlink) as a cache.
        if path == self.root / "release/ProcScope.app" and resolved == path:
            return self._is_legacy_app(path)
        return any(is_inside(path, root) and is_inside(resolved, root) for root in self.roots)

    @staticmethod
    def _is_legacy_app(path):
        if not path.exists():
            return True  # A stale registration for the former build product.
        try:
            info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
            return isinstance(info, dict) and info.get("CFBundleIdentifier") == "com.yikwing.ProcScope"
        except (OSError, ValueError, plistlib.InvalidFileException):
            return False

    def prepare(self):
        for directory in (self.build, self.work, self.work / "logs", self.work / "cache"):
            if directory.is_symlink() or not is_inside(directory.resolve(), self.root):
                raise ValueError(f"Build directory escapes the project: {directory}")
            directory.mkdir(parents=True, exist_ok=True)
        # Auxiliary marker only. The .noindex suffix is the actual per-folder indexing exclusion.
        marker = self.build / ".metadata_never_index"
        if marker.is_symlink():
            raise ValueError(f"Index marker must not be a symlink: {marker}")
        marker.touch(exist_ok=True)
        self.configure_xcode()

    def configure_xcode(self):
        """DerivedData location is a user workspace setting; shared settings are ignored by Xcode."""
        username = pwd.getpwuid(os.getuid()).pw_name
        for project in sorted(self.root.iterdir()):
            if project.suffix not in (".xcodeproj", ".xcworkspace") or not project.is_dir():
                continue
            workspace = project / "project.xcworkspace" if project.suffix == ".xcodeproj" else project
            settings = workspace / "xcuserdata" / f"{username}.xcuserdatad" / "WorkspaceSettings.xcsettings"
            if not is_inside(settings.resolve(), self.root):
                raise ValueError(f"Xcode settings path escapes the project: {settings}")
            current = plistlib.loads(settings.read_bytes()) if settings.exists() else {}
            if not isinstance(current, dict):
                raise ValueError(f"Invalid Xcode settings dictionary: {settings}")
            updated = {
                **current,
                "BuildLocationStyle": "UniqueDerivedDataSubfolder",
                "DerivedDataLocationStyle": "WorkspaceRelativePath",
                "DerivedDataCustomLocation": ".build/artifacts.noindex/Xcode",
            }
            if updated != current:
                settings.parent.mkdir(parents=True, exist_ok=True)
                settings.write_bytes(plistlib.dumps(updated))

    def registered(self):
        result = subprocess.run([str(LSREGISTER), "-dump"], capture_output=True, text=True, timeout=45, check=True)
        return sorted(path for path in registered_paths(result.stdout) if self.owns(path))

    def cleanup(self, dry_run=False):
        paths = self.registered()
        failures = []
        for path in paths:
            print(f"[build-isolation] {'Would unregister' if dry_run else 'Unregister'}: {path}", flush=True)
            if dry_run:
                continue
            # Recheck immediately before touching the registry in case a symlink changed.
            if not self.owns(path):
                failures.append(str(path))
                continue
            result = subprocess.run([str(LSREGISTER), "-u", str(path)], capture_output=True, text=True, timeout=30)
            if result.returncode:
                failures.append(f"{path}: {(result.stderr or result.stdout).strip()}")
        if failures:
            raise RuntimeError("Could not unregister development apps:\n" + "\n".join(failures))
        # A successful -u can leave launch-disabled records in the database.
        # Report the operation, not an unverified claim that every record vanished.
        outcome = "development registration(s) found" if dry_run else "development unregister request(s) completed"
        print(f"[build-isolation] {len(paths)} {outcome}.", flush=True)

    def _build_path(self, value):
        candidate = Path(value)
        if not candidate.is_absolute():
            candidate = self.root / candidate
        candidate = candidate.resolve()
        if not is_inside(candidate, self.work):
            raise ValueError(f"Xcode output paths must be under {self.work}: {candidate}")
        return candidate

    def _configure_xcode_command(self, arguments, derived, insertion):
        derived = self._build_path(derived)
        for option in XCODE_PATH_OPTIONS:
            if arguments.count(option) > 1 or any(arg.startswith(option + "=") for arg in arguments):
                raise ValueError(f"Use at most one {option} followed by a separate path")
            if option not in arguments:
                continue
            index = arguments.index(option) + 1
            if index == len(arguments):
                raise ValueError(f"{option} requires a path")
            candidate = self._build_path(arguments[index])
            if option == "-derivedDataPath":
                derived = candidate
        for argument in arguments:
            key, separator, value = argument.partition("=")
            if separator and key in XCODE_PATH_SETTINGS:
                self._build_path(value)
        if "-derivedDataPath" not in arguments:
            arguments[insertion:insertion] = ["-derivedDataPath", str(derived)]
        return derived

    def command(self, arguments, lane):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", lane):
            raise ValueError("Lane must contain only letters, numbers, underscores and hyphens")
        if not arguments:
            raise ValueError("Pass a command after --")
        arguments = list(arguments)
        derived = self.work / "xcode" / lane
        executable = Path(arguments[0]).name
        if executable == "xcodebuild":
            derived = self._configure_xcode_command(arguments, derived, insertion=1)
        elif executable == "xcrun" and arguments[1:2] == ["xcodebuild"]:
            derived = self._configure_xcode_command(arguments, derived, insertion=2)
        return arguments, {
            **os.environ,
            "ISOLATED_BUILD_DIR": str(self.work),
            "ISOLATED_DERIVED_DATA": str(derived),
            "ISOLATED_LOG_DIR": str(self.work / "logs"),
        }


def execute(area, arguments, lane):
    area.prepare()
    arguments, environment = area.command(arguments, lane)
    code = 1
    process = None
    previous = {}
    interrupted_signal = signal.SIGINT

    def interrupt(signum, _frame):
        nonlocal interrupted_signal
        interrupted_signal = signum
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signum)
        raise KeyboardInterrupt

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, interrupt)
        process = subprocess.Popen(arguments, cwd=area.root, env=environment, start_new_session=True)
        code = process.wait()
    except KeyboardInterrupt:
        code = 128 + interrupted_signal
        if process is not None:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        try:
            area.cleanup()
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            print(f"[build-isolation] Cleanup failed: {error}", file=sys.stderr)
            if code == 0:
                code = 1
    return code if code >= 0 else 128 - code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    for name in ("prepare", "status", "cleanup", "exec"):
        command = commands.add_parser(name)
        command.add_argument("--root", type=Path, default=Path.cwd(), help="Project directory (default: current directory)")
        command.add_argument("--extra-build-dir", action="append", default=[], help="Additional explicit legacy build cache")
        if name == "cleanup":
            command.add_argument("--dry-run", action="store_true")
        if name == "exec":
            command.add_argument("--lane", default="local", help="Separate DerivedData bucket, e.g. mac or ios")
            command.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("This tool manages macOS build artifacts and requires macOS")
    try:
        area = BuildArea(args.root, args.extra_build_dir)
        if args.operation == "prepare":
            area.prepare()
            print(area.work)
        elif args.operation == "status":
            print(f"Build artifacts: {area.work}")
            area.cleanup(dry_run=True)
        elif args.operation == "cleanup":
            area.cleanup(dry_run=args.dry_run)
        else:
            arguments = args.command[1:] if args.command[:1] == ["--"] else args.command
            return execute(area, arguments, args.lane)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"[build-isolation] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
