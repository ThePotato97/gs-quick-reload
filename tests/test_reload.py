"""Host regression tests; Android commands are mocked, no device operations."""
import os
import re
from pathlib import Path
import subprocess
import tempfile
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
        self.command("pidof", 'case "$1" in vectord) echo "${TEST_VECTOR_PIDS-101}";; lspd) echo "${TEST_LSPD_PIDS-}";; esac\n')
        self.command("sleep", "exit 0\n")
        self.command("date", '''if [ "$1" = "+%s" ]; then
    clock=$(cat "$TEST_ROOT/clock" 2>/dev/null || echo 1000)
    echo "$clock"
    echo $((clock + 1)) > "$TEST_ROOT/clock"
else
    /bin/date "$@"
fi
''')
        self.command("getprop", 'case "$1" in sys.boot_completed) cat "$TEST_ROOT/boot";; esac\n')
        self.command("resetprop", 'printf "%s\\n" "$2" > "$TEST_ROOT/boot"\n')
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
        self.command("setprop", 'echo "$*" >> "$TEST_ROOT/setprop-calls"\n')
        self.command("settings", 'echo 2\n')
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


if __name__ == "__main__":
    unittest.main()
