"""Launcher integration tests using disposable app bundles and account data."""

import json
import os
from pathlib import Path
import shlex
import sqlite3
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(os.environ.get("LAUNCHER_SCRIPT", Path(__file__).resolve().parents[1] / "codex-multi-account.sh"))


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="multi-account-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.primary = self.root / "primary"
        self.secondary = self.root / "secondary"
        self.profile = self.root / "Chromium Profile"
        self.registry = self.root / "registry"
        self.app = self.root / "ChatGPT Test.app"
        self.primary.mkdir()
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("CODEX_") and key != "CHATGPT_APP"
        }
        self.env.update({
            "CODEX_PRIMARY_HOME": str(self.primary),
            "CODEX_SECONDARY_HOME": str(self.secondary),
            "CODEX_PROFILE_DIR": str(self.profile),
            "CODEX_MULTI_REGISTRY_DIR": str(self.registry),
            "CHATGPT_APP": str(self.app),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        })
        self.make_executable(self.app / "Contents/MacOS/ChatGPT", "#!/bin/sh\nexit 0\n")
        (self.primary / "state_5.sqlite").write_text("primary state")

    @staticmethod
    def make_executable(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o755)
        return path

    def add_cli(self, layout="new", details=None):
        relative = "codex-cli/bin/codex" if layout == "new" else "codex"
        cli = self.app / "Contents/Resources" / relative
        if details is None:
            details = {"state DB": str(self.primary / "state_5.sqlite") + " (file)"}
        doctor_file = cli.parent / "doctor.json"
        calls_file = cli.parent / "calls.log"
        self.make_executable(cli, "#!/bin/sh\n"
                             + "printf '%s\\n' \"$CODEX_HOME|$*\" >> " + shlex.quote(str(calls_file)) + "\n"
                             + "cat " + shlex.quote(str(doctor_file)) + "\n")
        doctor_file.write_text(json.dumps({"checks": {"state.paths": {"details": details}}}))
        return cli

    def run_launcher(self, *args, expected=0, launch=False):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), *([] if launch else ["--no-launch"]), *args],
            env=self.env, text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def assert_link(self, name):
        link = self.secondary / name
        self.assertTrue(link.is_symlink(), str(link))
        self.assertEqual(os.readlink(link), str(self.primary / name))

    def test_new_bundle_layout(self):
        cli = self.add_cli()
        self.run_launcher("--symlink-history")
        self.assert_link("state_5.sqlite")
        self.assertIn(str(self.primary) + "|doctor --json", (cli.parent / "calls.log").read_text())

    def test_legacy_bundle_layout(self):
        cli = self.add_cli("legacy")
        self.run_launcher("--symlink-history")
        self.assert_link("state_5.sqlite")
        self.assertTrue((cli.parent / "calls.log").exists())

    def test_new_cli_preferred_when_both_exist(self):
        new = self.add_cli()
        old = self.add_cli("legacy")
        self.run_launcher("--symlink-history")
        self.assertTrue((new.parent / "calls.log").exists())
        self.assertFalse((old.parent / "calls.log").exists())

    def test_non_executable_new_cli_falls_back(self):
        new = self.add_cli()
        old = self.add_cli("legacy")
        new.chmod(0o644)
        self.run_launcher("--symlink-history")
        self.assertTrue((old.parent / "calls.log").exists())

    def test_directory_at_new_cli_path_falls_back(self):
        directory = self.app / "Contents/Resources/codex-cli/bin/codex"
        directory.mkdir(parents=True)
        old = self.add_cli("legacy")
        self.run_launcher("--symlink-history")
        self.assertTrue((old.parent / "calls.log").exists())

    def test_directory_is_not_a_cli(self):
        (self.app / "Contents/Resources/codex-cli/bin/codex").mkdir(parents=True)
        result = self.run_launcher(expected=1)
        self.assertIn("bundled Codex CLI not executable", result.stderr)
        self.assertFalse(self.secondary.exists())

    def test_missing_cli_fails_before_creating_profiles(self):
        result = self.run_launcher(expected=1)
        self.assertIn("bundled Codex CLI not executable", result.stderr)
        self.assertFalse(self.secondary.exists())
        self.assertFalse(self.profile.exists())

    def test_default_setup_does_not_share_history_or_auth(self):
        self.add_cli()
        (self.primary / "auth.json").write_text("test-only-primary-auth")
        self.run_launcher()
        self.assertTrue(self.secondary.is_dir())
        self.assertTrue(self.profile.is_dir())
        self.assertFalse((self.secondary / "auth.json").exists())
        self.assertFalse((self.secondary / "state_5.sqlite").exists())
        self.assertFalse(any(path.is_symlink() for path in self.secondary.iterdir()))

    def test_dry_run_leaves_profiles_and_primary_unchanged(self):
        self.add_cli()
        before = sorted(path.name for path in self.primary.iterdir())
        self.run_launcher("--dry-run", "--symlink-history")
        self.assertFalse(self.secondary.exists())
        self.assertFalse(self.profile.exists())
        self.assertFalse(self.registry.exists())
        self.assertEqual(before, sorted(path.name for path in self.primary.iterdir()))

    def test_legacy_app_option(self):
        self.add_cli("legacy")
        self.env.pop("CHATGPT_APP")
        self.run_launcher("--codex-app", str(self.app))

    def test_bundle_executable_from_plist(self):
        self.add_cli()
        executable = self.app / "Contents/MacOS/ChatGPT"
        executable.rename(executable.with_name("CustomDesktop"))
        (self.app / "Contents/Info.plist").write_text(
            '<?xml version="1.0"?><plist version="1.0"><dict>'
            '<key>CFBundleExecutable</key><string>CustomDesktop</string></dict></plist>'
        )
        if os.uname().sysname != "Darwin":
            self.skipTest("requires macOS plutil")
        self.run_launcher()

    def test_reset_does_not_require_installed_app(self):
        self.secondary.mkdir()
        self.profile.mkdir()
        self.env["CHATGPT_APP"] = str(self.root / "missing.app")
        self.run_launcher("--reset")
        self.assertFalse(self.secondary.exists())
        self.assertFalse(self.profile.exists())
        self.assertTrue(self.primary.exists())

    def test_optional_thread_history_is_skipped_on_older_versions(self):
        self.add_cli("legacy")
        self.run_launcher("--symlink-history")
        self.assertEqual(list(self.secondary.glob("thread_history_*")), [])

    def test_thread_history_and_sidecars_are_shared(self):
        self.add_cli(details={
            "state DB": str(self.primary / "state_5.sqlite") + " (file)",
            "thread history DB": str(self.primary / "thread_history_2.sqlite") + " (file)",
        })
        (self.primary / "thread_history_2.sqlite").write_text("conversation contents")
        self.run_launcher("--symlink-history")
        for base in ("state_5.sqlite", "thread_history_2.sqlite"):
            for suffix in ("", "-wal", "-shm"):
                self.assert_link(base + suffix)

    def test_doctor_selected_version_takes_precedence(self):
        self.add_cli(details={
            "state DB": str(self.primary / "state_5.sqlite") + " (file)",
            "thread history DB": str(self.primary / "thread_history_2.sqlite") + " (file)",
        })
        for name in ("thread_history_2.sqlite", "thread_history_10.sqlite"):
            (self.primary / name).touch()
        self.run_launcher("--symlink-history")
        self.assert_link("thread_history_2.sqlite")
        self.assertFalse((self.secondary / "thread_history_10.sqlite").exists())

    def test_failed_doctor_uses_highest_numeric_database_version(self):
        cli = self.add_cli()
        cli.write_text("#!/bin/sh\nexit 1\n")
        for name in ("state_9.sqlite", "state_10.sqlite", "thread_history_2.sqlite",
                     "thread_history_10.sqlite", "thread_history_invalid.sqlite"):
            (self.primary / name).touch()
        self.run_launcher("--symlink-history")
        self.assert_link("state_10.sqlite")
        self.assert_link("thread_history_10.sqlite")

    def test_reported_missing_database_is_linked_for_later_creation(self):
        self.add_cli(details={
            "state DB": str(self.primary / "state_5.sqlite") + " (file)",
            "thread history DB": str(self.primary / "thread_history_3.sqlite") + " (missing)",
        })
        self.run_launcher("--symlink-history")
        self.assert_link("thread_history_3.sqlite")
        (self.secondary / "thread_history_3.sqlite").write_text("new conversation")
        self.assertEqual((self.primary / "thread_history_3.sqlite").read_text(), "new conversation")

    def test_targeted_backup_preserves_replaced_history_and_auth(self):
        self.add_cli()
        self.secondary.mkdir()
        (self.primary / "thread_history_2.sqlite").write_text("primary conversation")
        (self.primary / "auth.json").write_text("test-only-primary-auth")
        originals = {
            "auth.json": "test-only-secondary-auth",
            "config.toml": "secondary settings",
            "state_4.sqlite": "old secondary state",
            "thread_history_1.sqlite": "old secondary conversation",
            "thread_history_1.sqlite-wal": "old secondary wal",
            "thread_history_1.sqlite-shm": "old secondary shm",
        }
        for name, content in originals.items():
            (self.secondary / name).write_text(content)
        self.run_launcher("--symlink-history")
        backups = list(self.root.glob("secondary.backup.*"))
        self.assertEqual(len(backups), 1)
        for name, content in originals.items():
            self.assertEqual((backups[0] / name).read_text(), content)
        for name in originals:
            if name.endswith((".sqlite", "-wal", "-shm")):
                self.assertFalse((self.secondary / name).exists())
        self.assertEqual((self.secondary / "auth.json").read_text(), originals["auth.json"])
        self.assertFalse((self.secondary / "auth.json").is_symlink())
        self.assert_link("thread_history_2.sqlite")
        self.assertEqual((self.primary / "thread_history_2.sqlite").read_text(), "primary conversation")

    def test_rerun_preserves_existing_symlinks_in_backup(self):
        self.add_cli()
        (self.primary / "thread_history_1.sqlite").write_text("conversation")
        self.run_launcher("--symlink-history")
        self.run_launcher("--symlink-history")
        backup = next(self.root.glob("secondary.backup.*"))
        for suffix in ("", "-wal", "-shm"):
            name = "thread_history_1.sqlite" + suffix
            self.assertTrue((backup / name).is_symlink())
            self.assert_link(name)

    def test_queue_and_runtime_databases_remain_separate(self):
        self.add_cli()
        self.secondary.mkdir()
        for name in ("queue_1.sqlite", "logs_1.sqlite", "goals_1.sqlite", "memories_1.sqlite"):
            (self.primary / name).write_text("primary")
            (self.secondary / name).write_text("secondary")
        self.run_launcher("--symlink-history")
        for name in ("queue_1.sqlite", "logs_1.sqlite", "goals_1.sqlite", "memories_1.sqlite"):
            self.assertFalse((self.secondary / name).is_symlink())
            self.assertEqual((self.secondary / name).read_text(), "secondary")

    def test_runtime_opt_in_still_leaves_queue_separate(self):
        self.add_cli()
        for name in ("queue_1.sqlite", "logs_1.sqlite", "goals_1.sqlite", "memories_1.sqlite"):
            (self.primary / name).touch()
        self.run_launcher("--symlink-history", "--share-runtime-dbs")
        for name in ("logs_1.sqlite", "goals_1.sqlite", "memories_1.sqlite"):
            self.assert_link(name)
        self.assertFalse((self.secondary / "queue_1.sqlite").exists())

    def test_sqlite_wal_connections_share_commits_and_locking(self):
        self.add_cli()
        database = self.primary / "thread_history_1.sqlite"
        first = sqlite3.connect(database, timeout=0.1)
        self.addCleanup(first.close)
        self.assertEqual(first.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
        first.execute("CREATE TABLE conversation (body TEXT)")
        first.execute("INSERT INTO conversation VALUES ('primary message')")
        first.commit()
        self.run_launcher("--symlink-history")
        second = sqlite3.connect(self.secondary / database.name, timeout=0.1)
        self.addCleanup(second.close)
        self.assertEqual(second.execute("SELECT body FROM conversation").fetchone()[0], "primary message")
        second.execute("INSERT INTO conversation VALUES ('secondary message')")
        second.commit()
        self.assertEqual(first.execute("SELECT COUNT(*) FROM conversation").fetchone()[0], 2)
        first.execute("BEGIN IMMEDIATE")
        with self.assertRaisesRegex(sqlite3.OperationalError, "locked"):
            second.execute("BEGIN IMMEDIATE")
        first.rollback()
        second.execute("BEGIN IMMEDIATE")
        second.rollback()

    def test_reset_shared_account_preserves_primary_history(self):
        self.add_cli()
        (self.primary / "thread_history_1.sqlite").write_text("conversation")
        self.run_launcher("--symlink-history")
        self.run_launcher("--reset")
        self.assertFalse(self.secondary.exists())
        self.assertFalse(self.profile.exists())
        self.assertEqual((self.primary / "thread_history_1.sqlite").read_text(), "conversation")

    def test_launch_passes_separate_home_and_profile(self):
        self.add_cli()
        self.secondary = self.root / self.root.name
        self.env["CODEX_SECONDARY_HOME"] = str(self.secondary)
        capture = self.root / "launched.txt"
        self.make_executable(self.app / "Contents/MacOS/ChatGPT",
                             "#!/bin/sh\nprintf '%s\\n' \"$CODEX_HOME\" \"$@\" > "
                             + shlex.quote(str(capture)) + "\n")
        log = Path("/tmp") / ("codex-" + self.secondary.name + ".log")
        self.assertFalse(log.exists())
        self.addCleanup(lambda: log.unlink(missing_ok=True))
        self.run_launcher(launch=True)
        deadline = time.monotonic() + 5
        while not capture.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(capture.read_text().splitlines(), [str(self.secondary), "--user-data-dir=" + str(self.profile)])


if __name__ == "__main__":
    unittest.main()
