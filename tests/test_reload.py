"""Host regression tests; Android commands are mocked, no device operations."""
import os
import re
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "module/gs-reload-modules.sh"
SCRIPT = SOURCE.read_text()
HELPERS = SCRIPT.split("# BEGIN framework helpers\n", 1)[1].split("# END framework helpers", 1)[0]


class ReloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.modules = self.root / "data/adb/modules"
        self.modules.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "TEST_ROOT": str(self.root),
        }
        (self.root / "boot").write_text("1\n")
        self.command("pidof", 'case "$1" in vectord) echo "${TEST_VECTOR_PIDS-101}";; lspd) echo "${TEST_LSPD_PIDS-}";; zn-daemon) echo "${TEST_ZN_PIDS-}";; esac\n')
        self.command("sleep", '[ "${TEST_REAL_SLEEP:-0}" = 1 ] && /bin/sleep 0.01\nexit 0\n')
        self.command("date", '''if [ "$1" = "+%s" ]; then
    clock=$(cat "$TEST_ROOT/clock" 2>/dev/null || echo 1000)
    echo "$clock"
    echo $((clock + 1)) > "$TEST_ROOT/clock"
else
    /bin/date "$@"
fi
''')
        self.command("getprop", 'case "$1" in sys.boot_completed) cat "$TEST_ROOT/boot";; esac\n')
        self.command("resetprop", 'printf "%s\\n" "$2" >> "$TEST_ROOT/boot-writes"\nprintf "%s\\n" "$2" > "$TEST_ROOT/boot"\n')
        self.command("app_process", '''printf '%s\\n' "$@" >> "$TEST_ROOT/app-process-args"
case "$1" in -Djava.class.path=*) apk=${1#*=};; *) exit 91;; esac
[ -r "$apk" ] || exit 92
[ "$4" = org.matrix.vector.daemon.Cli ] && [ "$5" = status ] || exit 93
exit "${TEST_VECTOR_CLI_RC:-0}"
''')

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def module(self, directory, identity, name="", disabled=False, remove=False, apk=True):
        path = self.modules / directory
        path.mkdir()
        (path / "module.prop").write_text(f"id={identity}\nname={name}\n")
        if disabled:
            (path / "disable").touch()
        if remove:
            (path / "remove").touch()
        if identity == "zygisk_vector" and apk:
            (path / "daemon.apk").touch()
            # The upstream wrapper does not support renamed directories. Never
            # invoke it: the detected APK must be supplied directly instead.
            (path / "cli").write_text('echo wrapper-called >&2; exit 91\n')
        return path

    def shell(self, body):
        helpers = HELPERS.replace("/system/bin/app_process", str(self.bin / "app_process"))
        code = f'set -u\nMODDIR_BASE="{self.modules}"\ntlog() {{ echo "$*"; }}\n' + helpers + body
        return subprocess.run(["sh", "-c", code], env=self.env, text=True, capture_output=True, timeout=10)

    def run_reload(self, args=(), stage_rc=0):
        # Rewrite Android paths only in this disposable copy; all mutations stay
        # inside the temporary fixture. Init control is captured, never executed.
        self.command("id", 'echo 0\n')
        self.command("setprop", 'echo "$*" >> "$TEST_ROOT/setprop-calls"\nexit "${TEST_SETPROP_RC:-0}"\n')
        self.command("settings", 'echo "${TEST_NIGHT_MODE:-2}"\n')
        self.command("cmd", 'echo "$*" >> "$TEST_ROOT/cmd-calls"\n')
        self.command("logcat", 'exit 0\n')
        self.command("dumpsys", 'exit 0\n')
        self.command("ps", 'exit 0\n')
        ksud = self.root / "data/adb/ksu/bin/ksud"
        ksud.parent.mkdir(parents=True)
        ksud.write_text(f'#!/bin/sh\nexit {stage_rc}\n')
        ksud.chmod(0o755)
        (self.root / "data/local/tmp").mkdir(parents=True)
        script = SCRIPT.replace("/data/", f"{self.root}/data/").replace("/sdcard/", f"{self.root}/sdcard/")
        script = script.replace("/system/bin/app_process", str(self.bin / "app_process"))
        path = self.root / "reload.sh"
        path.write_text(script)
        return subprocess.run(["sh", str(path), *args], env=self.env, text=True, capture_output=True, timeout=10)

    def test_vector_and_neo_identified_by_metadata(self):
        self.module("renamed-vector", "zygisk_vector", "Vector")
        self.module("renamed-neo", "zygisksu", "NeoZygisk")
        result = self.shell('\ndetect_framework && echo "$FRAMEWORK_KIND:$(zygisk_kind)"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("vector:neozygisk", result.stdout)

    def test_disabled_and_removed_frameworks_are_ignored(self):
        self.module("old", "zygisk_lsposed", disabled=True)
        self.module("vector", "zygisk_vector", remove=True)
        result = self.shell('\ndetect_framework && echo "$FRAMEWORK_KIND"\n')
        self.assertEqual(result.stdout.strip(), "none")

    def test_conflicting_frameworks_abort_before_stages(self):
        self.module("old", "zygisk_lsposed")
        self.module("vector", "zygisk_vector")
        result = self.run_reload()
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("stage post-fs-data", result.stdout)
        self.assertEqual((self.root / "boot").read_text().strip(), "1")

    def test_vector_needs_responsive_ipc_and_one_daemon(self):
        self.module("vector", "zygisk_vector")
        self.assertEqual(self.shell("\ndetect_framework && vector_ready\n").returncode, 0)
        self.env["TEST_VECTOR_CLI_RC"] = "1"
        self.assertNotEqual(self.shell("\ndetect_framework && vector_ready\n").returncode, 0)
        self.env["TEST_VECTOR_CLI_RC"] = "0"
        self.env["TEST_VECTOR_PIDS"] = "101 102"
        self.assertNotEqual(self.shell("\ndetect_framework && vector_ready\n").returncode, 0)

    def test_missing_vector_apk_aborts_before_mutation(self):
        self.module("vector", "zygisk_vector", apk=False)
        result = self.run_reload()
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("stage post-fs-data", result.stdout)
        self.assertEqual((self.root / "boot").read_text().strip(), "1")

    def test_actual_vector_failure_restores_boot_flag_and_never_restarts(self):
        self.module("vector", "zygisk_vector")
        self.module("neo", "zygisksu", "NeoZygisk")
        self.env["TEST_VECTOR_CLI_RC"] = "1"
        result = self.run_reload()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("Vector readiness failed", result.stdout)
        self.assertIn("Abort cleanup", result.stdout)
        self.assertNotIn("找不到 zygisk_lsposed", result.stdout)
        self.assertEqual((self.root / "boot").read_text().strip(), "1")
        self.assertFalse((self.root / "setprop-calls").exists())

    def test_renamed_vector_uses_detected_apk_not_wrapper(self):
        module = self.module("custom-vector", "zygisk_vector")
        result = self.run_reload(["-n"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = (self.root / "app-process-args").read_text()
        self.assertIn(f"-Djava.class.path={module}/daemon.apk", args)
        self.assertNotIn("wrapper-called", result.stderr)

    def test_module_identity_trims_whitespace(self):
        module = self.module("custom-vector", "zygisk_vector")
        (module / "module.prop").write_bytes(b"id=zygisk_vector  \r\nname=Vector\r\n")
        result = self.shell('\ndetect_framework && echo "$FRAMEWORK_KIND"\n')
        self.assertEqual(result.stdout.strip(), "vector")

    def test_lsposed_healthy_and_broken_daemon_checks(self):
        self.module("legacy", "zygisk_lsposed")
        legacy = '\n'.join(re.search(r"(?ms)^" + name + r"\(\) \{\n.*?^\}", SCRIPT).group()
                           for name in ("find_lsposed_dir", "lspd_newest", "lspd_kill_all", "lspd_start_fresh", "ensure_lspd"))
        body = '\nlspbridge_count() { echo "${TEST_LSP_SOCKETS:-0}"; }\n' + legacy + '\nKSUD=mock-ksud\ndetect_framework && ensure_framework ""\n'
        self.env["TEST_LSPD_PIDS"] = "301"
        self.env["TEST_LSP_SOCKETS"] = "1"
        result = self.shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.env["TEST_LSPD_PIDS"] = ""
        self.env["TEST_LSP_SOCKETS"] = "0"
        result = self.shell(body)
        self.assertNotEqual(result.returncode, 0)

    def test_lsposed_fallback_skips_recovery(self):
        self.module("legacy", "zygisk_lsposed")
        result = self.shell('\nensure_lspd() { echo unexpected-recovery; return 1; }\nKSUD=""\ndetect_framework && ensure_framework ""\n')
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("unexpected-recovery", result.stdout)

    def test_lsposed_no_zygote_preserves_upstream_recovery(self):
        self.module("legacy", "zygisk_lsposed")
        result = self.shell('\nensure_lspd() { echo recovery-called; }\nKSUD=mock-ksud\nDO_ZYGOTE=0\ndetect_framework && ensure_framework ""\n')
        self.assertEqual(result.returncode, 0)
        self.assertIn("recovery-called", result.stdout)

    def test_successful_vector_no_restart_run_bypasses_legacy_gate(self):
        self.module("vector", "zygisk_vector")
        self.module("neo", "zygisksu", "NeoZygisk")
        result = self.run_reload(["-n"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Vector daemon IPC ready", result.stdout)
        self.assertNotIn("找不到 zygisk_lsposed", result.stdout)
        self.assertNotIn("Zygisk Next：", result.stdout)
        self.assertNotIn("警告: lspd 未运行", result.stdout)
        self.assertFalse((self.root / "setprop-calls").exists())

    def test_stage_failure_restores_boot_flag(self):
        result = self.run_reload(stage_rc=7)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual((self.root / "boot").read_text().strip(), "1")
        self.assertFalse((self.root / "setprop-calls").exists())

    def test_handoff_keeps_boot_state_for_watchdog(self):
        result = self.shell(f'''\nBOOT_CHANGED=1
BOOT_HANDOFF=1
BOOT_ORIGINAL=1
BOOT_RESETPROP="{self.bin / 'resetprop'}"
resetprop sys.boot_completed 0
trap 'restore_boot_state' 0
exit 0
''')
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.root / "boot").read_text().strip(), "0")

    def test_term_before_handoff_restores_boot_state(self):
        result = self.shell(f'''\nBOOT_CHANGED=1
BOOT_HANDOFF=0
BOOT_ORIGINAL=1
BOOT_RESETPROP="{self.bin / 'resetprop'}"
resetprop sys.boot_completed 0
trap 'restore_boot_state' 0
trap 'exit 143' TERM
kill -TERM $$
''')
        self.assertEqual(result.returncode, 143)
        self.assertEqual((self.root / "boot").read_text().strip(), "1")

    def test_existing_run_lock_rejects_second_run_without_stages(self):
        gs = self.root / "data/adb/gs"
        boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        lock = gs / f".reload-lock-{boot_id}"
        lock.mkdir(parents=True)
        (lock / "parent").mkdir()
        result = self.run_reload(["-n"])
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertNotIn("stage post-fs-data", result.stdout)
        self.assertTrue((lock / "parent").exists())
        self.assertEqual((self.root / "boot").read_text().strip(), "1")

    def test_rejected_restart_cancels_helpers_and_restores_flag(self):
        self.env.update(TEST_SETPROP_RC="1", TEST_NIGHT_MODE="0", TEST_REAL_SLEEP="1")
        result = self.run_reload()
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        # Detached wrappers must see cancellation before executing either helper.
        gs = self.root / "data/adb/gs"
        for _ in range(100):
            if not list(gs.glob(".reload-lock-*")):
                break
            time.sleep(0.01)
        self.assertFalse(list(gs.glob(".reload-lock-*")))
        self.assertFalse((self.root / "cmd-calls").exists())
        self.assertEqual((self.root / "boot-writes").read_text().splitlines(), ["0", "1"])

    def test_watchdog_uses_resolved_resetprop_in_both_fallbacks(self):
        self.env["TEST_REAL_SLEEP"] = "1"
        # Missing canonical resetprop is intentional: only the PATH command
        # exists. A directory at the helper path also forces write-failure mode.
        gs = self.root / "data/adb/gs"
        gs.mkdir(parents=True)
        (gs / ".gs-boot-wd.sh").mkdir()
        result = self.run_reload()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for _ in range(100):
            if not list(gs.glob(".reload-lock-*")):
                break
            time.sleep(0.01)
        self.assertEqual((self.root / "boot-writes").read_text().splitlines(), ["0", "1"])
        self.assertFalse(list(gs.glob(".reload-lock-*")))

    def test_no_waiters_watchdog_uses_resolved_resetprop(self):
        self.env["TEST_REAL_SLEEP"] = "1"
        result = self.run_reload()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        gs = self.root / "data/adb/gs"
        for _ in range(100):
            if not list(gs.glob(".reload-lock-*")):
                break
            time.sleep(0.01)
        self.assertEqual((self.root / "boot-writes").read_text().splitlines(), ["0", "1"])
        self.assertFalse(list(gs.glob(".reload-lock-*")))

    def test_accepted_helper_holds_lock_until_completion(self):
        self.env["TEST_REAL_SLEEP"] = "1"
        gs = self.root / "gs"
        gs.mkdir()
        result = self.shell(f'''\nGS_DIR="{gs}"
LOCK_HELD=0
BOOT_CHANGED=0
BOOT_HANDOFF=0
acquire_reload_lock || exit 1
launch_restart_helper boot sh -c 'while [ ! -f "$TEST_ROOT/finish-helper" ]; do sleep 1; done; echo done > "$TEST_ROOT/helper-done"'
BOOT_HANDOFF=1
cleanup_reload
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(gs.glob(".reload-lock-*"))), 1)
        (self.root / "finish-helper").touch()
        for _ in range(100):
            if not list(gs.glob(".reload-lock-*")):
                break
            time.sleep(0.01)
        self.assertTrue((self.root / "helper-done").exists())
        self.assertFalse(list(gs.glob(".reload-lock-*")))

    def test_explicit_handoff_survives_parent_sigkill(self):
        self.env["TEST_REAL_SLEEP"] = "1"
        gs = self.root / "gs"
        gs.mkdir()
        result = self.shell(f'''\nGS_DIR="{gs}"
LOCK_HELD=0
BOOT_CHANGED=0
BOOT_HANDOFF=0
acquire_reload_lock || exit 1
launch_restart_helper boot sh -c 'while [ ! -f "$TEST_ROOT/finish-helper" ]; do sleep 1; done; echo done > "$TEST_ROOT/helper-done"'
BOOT_HANDOFF=1
accept_restart || exit 2
kill -KILL $$
''')
        self.assertEqual(result.returncode, -9)
        locks = list(gs.glob(".reload-lock-*"))
        self.assertEqual(len(locks), 1)
        self.assertFalse((locks[0] / "parent").exists())
        self.assertEqual((locks[0] / "gate").read_text().strip(), "accepted")
        (self.root / "finish-helper").touch()
        for _ in range(100):
            if not list(gs.glob(".reload-lock-*")):
                break
            time.sleep(0.01)
        self.assertTrue((self.root / "helper-done").exists())
        self.assertFalse(list(gs.glob(".reload-lock-*")))

    def test_trim_cannot_enter_during_reload(self):
        gs = self.root / "data/adb/gs"
        boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        lock = gs / f".reload-lock-{boot_id}"
        lock.mkdir(parents=True)
        (lock / "parent").mkdir()
        result = self.run_reload(["trim"])
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertNotIn("== 清理重复常驻实例 ==", result.stdout)
        self.assertTrue((lock / "parent").exists())

    def test_prunes_only_owned_old_boot_lock_directories(self):
        gs = self.root / "gs"
        gs.mkdir()
        old_uuid = "00000000-0000-0000-0000-000000000000"
        old = gs / f".reload-lock-{old_uuid}"
        old.mkdir()
        (old / "boot-id").write_text(old_uuid)
        (old / "parent").mkdir()
        foreign = gs / ".reload-lock-not-our-protocol"
        foreign.mkdir()
        mismatched = gs / ".reload-lock-11111111-1111-1111-1111-111111111111"
        mismatched.mkdir()
        (mismatched / "boot-id").write_text("different owner")
        target = self.root / "symlink-target"
        target.mkdir()
        link = gs / ".reload-lock-22222222-2222-2222-2222-222222222222"
        link.symlink_to(target, target_is_directory=True)
        result = self.shell(f'\nGS_DIR="{gs}"\nLOCK_HELD=0\nacquire_reload_lock && cleanup_reload\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old.exists())
        self.assertTrue(foreign.exists())
        self.assertTrue(mismatched.exists())
        self.assertTrue(link.is_symlink())
        self.assertTrue(target.exists())

    def test_failed_night_helper_setup_does_not_block_restart(self):
        self.env.update(TEST_REAL_SLEEP="1", TEST_NIGHT_MODE="0")
        gs = self.root / "data/adb/gs"
        gs.mkdir(parents=True)
        (gs / ".gs-night-fix.sh").mkdir()
        result = self.run_reload()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Night helper setup failed", result.stdout)
        self.assertIn("ctl.restart zygote", (self.root / "setprop-calls").read_text())
        for _ in range(100):
            if not list(gs.glob(".reload-lock-*")):
                break
            time.sleep(0.01)
        self.assertEqual((self.root / "boot").read_text().strip(), "1")
        self.assertFalse(list(gs.glob(".reload-lock-*")))

    def test_exported_script_cannot_overwrite_backup(self):
        backup = self.root / "data/adb/gs/gs-reload-modules.sh"
        backup.parent.mkdir(parents=True)
        backup.write_text("newer installed backup\n")
        result = self.run_reload(["-n"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(backup.read_text(), "newer installed backup\n")

    def test_install_refreshes_backup_and_legacy_tmp_copy(self):
        package = self.root / "package"
        package.mkdir()
        (package / "gs-reload-modules.sh").write_text("fresh package\n")
        legacy = self.root / "data/local/tmp/gs-reload-modules.sh"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("old copy\n")
        installer = (SOURCE.parent / "customize.sh").read_text().replace("/data/", f"{self.root}/data/").replace("/sdcard/", f"{self.root}/sdcard/")
        path = self.root / "customize.sh"
        path.write_text(installer)
        result = subprocess.run(["sh", "-c", 'ui_print() { :; }; set_perm_recursive() { :; }; set_perm() { :; }; . "$1"', "sh", str(path)],
                                env=self.env | {"MODPATH": str(package)}, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(legacy.read_text(), "fresh package\n")
        self.assertEqual((self.root / "data/adb/gs/gs-reload-modules.sh").read_text(), "fresh package\n")

    def test_socket_owner_matches_inode_column_only(self):
        proc = self.root / "proc"
        fd = proc / "301/fd"
        fd.mkdir(parents=True)
        (fd / "0").symlink_to("socket:[456]")
        net = proc / "net/unix"
        net.parent.mkdir()
        fn = re.search(r"(?ms)^socket_owner\(\) \{\n.*?^\}", SCRIPT).group().replace("/proc/", f"{proc}/")
        self.env["TEST_LSPD_PIDS"] = "301"
        net.write_text("0000: 456 0 00010000 0001 01 999 @other\n")
        result = self.shell('\n' + fn + '\nsocket_owner lspd\n')
        self.assertNotEqual(result.returncode, 0)
        net.write_text("0000: 1 0 00010000 0001 01 456 @correct\n")
        result = self.shell('\n' + fn + '\nsocket_owner lspd\n')
        self.assertEqual(result.stdout.strip(), "301")

    def test_dedupe_uses_start_time_not_pidof_order(self):
        proc = self.root / "proc"
        for pid, start in ((202, 500), (101, 100)):
            path = proc / str(pid)
            path.mkdir(parents=True)
            (path / "stat").write_text(" ".join([str(pid), "(daemon)", "S"] + ["0"] * 18 + [str(start)]))
        funcs = '\n'.join(re.search(r"(?ms)^" + name + r"\(\) \{\n.*?^\}", SCRIPT).group()
                          for name in ("lspd_newest", "dedupe_new")).replace("/proc/", f"{proc}/")
        self.env["TEST_ZN_PIDS"] = "202 101"
        result = self.shell('\n' + funcs + '\nkill() { echo "kill:$*"; }\ndedupe_new zn-daemon ""\n')
        self.assertEqual(result.returncode, 0)
        self.assertIn("kill:101", result.stdout)
        self.assertNotIn("kill:202", result.stdout)


if __name__ == "__main__":
    unittest.main()
