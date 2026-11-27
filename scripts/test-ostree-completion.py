"""Exercise the same completion program used by curl and by the next desktop login."""
import builtins
import contextlib
import errno
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import pty
import runpy
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch


INSTALLER = Path(__file__).resolve().parents[1] / "site/install.sh"
A, B = "a" * 64, "b" * 64
KMS = "/usr/libexec/polaris/polaris-kms"
OVERRIDE = f"[Service]\nExecStart=\nExecStart={KMS}\n"


class DesktopSetup(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.program = self.home / "finish.py"
        self.job = self.home / ".config/autostart/com.papiux.PolarisInstaller.desktop"
        self.helper = self.home / ".local/state/polaris-installer/finish-host.py"
        self.unit = self.home / "pkg" / "polaris.service"
        self.unit.parent.mkdir()
        self.unit.touch()
        self.boot_id = self.home / "boot-id"
        self.boot_id.write_text("boot-1\n")
        self.drop = self.home / ".config/systemd/user/polaris.service.d/20-polaris-kms.conf"
        self.park = self.drop.with_suffix(".conf.disabled-until-relogin")
        self.want = self.home / ".config/systemd/user/default.target.wants/polaris.service"
        self.modules = self.home / "modules"
        self.modules.mkdir()
        self.nvidia = self.home / "nvidia-version"
        program = INSTALLER.read_text().split("<<'POLARIS_FINISH'\n", 1)[1].split("\nPOLARIS_FINISH\n", 1)[0]
        # The test process owns the simulated listener and supplies its real /proc identity.
        program = program.replace('POLARIS = "/usr/bin/polaris"', f"POLARIS = {sys.executable!r}")
        program = program.replace('Path("/usr/lib/systemd/user")', f"Path({str(self.unit.parent)!r})")
        program = program.replace('Path(f"/usr/lib/modules/{release}")', f"Path({str(self.modules)!r})")
        program = program.replace('Path("/sys/module/nvidia/version")', f"Path({str(self.nvidia)!r})")
        # Model the previously shipped helper's identity without duplicating
        # its full source in the fixture repository.
        self.legacy_program = b'MARKER = "X-Polaris-Installer=true"\n# previous guided installer\n'
        previous = hashlib.sha256(self.legacy_program).hexdigest()
        program = program.replace("LEGACY_IMAGE_HELPERS = {", "LEGACY_IMAGE_HELPERS = {" + repr(previous) + ",")
        self.program.write_text(program.replace('Path("/proc/sys/kernel/random/boot_id")', f"Path({str(self.boot_id)!r})"))
        self.calls = []
        self.serving = False
        self.available = True
        self.wrong_reply = False
        self.hidden_listener_group = None
        self.unit_group = "/user.slice/user-1000.slice/user@1000.service/app.slice/polaris.service"
        self.unit_executable = "/usr/libexec/polaris/polaris-kms"
        self.admin_needed = False
        self.denied = False
        self.manager = True
        self.booted, self.staged = A, None
        self.osname = "default"
        self.boot_fields = {}
        self.transaction = None
        self.commit_versions = None
        self.opened = []
        self.env = {"HOME": temp.name, "WAYLAND_DISPLAY": "wayland-0"}
        self.group_live = True
        self.linger = False
        self.fixed_userdb = True
        self.apply_native = True
        self.unit_command = sys.executable
        self.running = None
        self.invocation = "1" * 32
        self.service_generation = 1
        self.service_states = []
        self.service_start_error = None
        self.restart_noop = False
        self.versions = {"polaris": "1.5.0-1", "polaris-kms": "1.5.0-1"}
        self.nvidia_library = None

    def command(self, args, **_):
        args = list(args)
        self.calls.append(args)
        result, output = 0, ""
        if args[:2] == ["rpm-ostree", "status"]:
            rows = [{"booted": True, "staged": False, "checksum": self.booted, "osname": self.osname,
                     "unlocked": "none", **self.boot_fields}]
            if self.staged:
                rows.insert(0, {"booted": False, "staged": True, "checksum": self.staged})
            output = json.dumps({"deployments": rows, "transaction": self.transaction})
        elif args[:3] == ["rpm-ostree", "db", "list"]:
            self.assertEqual(args[3], self.boot_fields.get("live-replaced") or self.booted)
            versions = self.versions if self.commit_versions is None else self.commit_versions
            output = f"ostree commit: {args[3]}\n" + "".join(f" {n}-{v}.x86_64\n" for n, v in versions.items())
        elif args[0] in ("rpm", "pacman"):
            result = int(not self.available)
            if args[-1] == "nvidia-utils":
                result, output = (0, self.nvidia_library) if self.nvidia_library else (1, "absent")
            elif args[:2] == ["pacman", "-Q"] or "--qf" in args:
                names = args[2:] if args[0] == "pacman" else args[4:]
                if not self.available or any(n not in self.versions for n in names):
                    result, output = 1, "package not installed"
                else:
                    output = "".join(f"{n} {self.versions[n]}\n" if args[0] == "pacman" else
                                     f"{n} 0:{self.versions[n]}.x86_64\n" for n in names)
        elif args == [sys.executable, "--setup-host", "--help"]:
            output = ("--enable-kms (on rpm-ostree hosts through systemd's userdb, never\n /etc/group)."
                      if self.fixed_userdb else "--enable-kms Add this account to the polaris-kms group.")
        elif args == [sys.executable, "--setup-host"]:
            result = int(self.admin_needed)
            output = "Host setup requires root." if result else "Input rules ready.\nStart Polaris directly with `polaris`, or enable autostart.\n"
        elif args[0] == "sudo":
            result = int(self.denied)
            output = "local authentication required" if result else "Input rules installed.\n"
            if not result and self.apply_native:
                if "--enable-kms" in args:
                    self.drop.parent.mkdir(parents=True, exist_ok=True)
                    if self.group_live:
                        self.drop.write_text(OVERRIDE)
                        self.park.unlink(missing_ok=True)
                        if self.running == KMS:
                            output += f"The polaris user service already runs {KMS} ({self.drop}),\n"
                    else:
                        self.park.write_text(OVERRIDE)
                        self.drop.unlink(missing_ok=True)
                if "--enable-headless-boot" in args:
                    self.want.parent.mkdir(parents=True, exist_ok=True)
                    if not self.want.exists():
                        self.want.symlink_to(self.unit)
                    self.linger = True
        elif args == ["loginctl", "show-user", "1000", "-p", "Linger", "--value"]:
            output = "yes\n" if self.linger else "no\n"
        elif args == ["systemctl", "show", "user@1000.service", "-p", "InvocationID", "--value"]:
            output = self.invocation
        elif args[:2] == ["systemctl", "--user"]:
            if args[2] == "daemon-reload" and not self.manager:
                result, output = 1, "Failed to connect to bus: No medium found"
            elif args[2] == "daemon-reload":
                self.unit_command = KMS if self.drop.exists() else sys.executable
            elif args[2:4] == ["show", "default.target"]:
                output = "polaris.service other.service" if self.want.exists() else "other.service"
            elif args[2] == "show" and "LoadState" in args[-1]:
                state = self.service_states.pop(0) if self.service_states else ("active" if self.running else "inactive")
                pid = 200_000 + self.service_generation if self.running else 0
                output = (f"LoadState=loaded\nActiveState={state}\nMainPID={pid}\n"
                          f"InvocationID={self.service_generation:032x}\n"
                          f"ExecStart={{ path={self.unit_command} ; argv[]={self.unit_command} ; }}\n")
            elif args[2] == "show":
                output = (f"ActiveState=active\nMainPID=2889\nControlGroup={self.unit_group}\n"
                          f"ExecStart={{ path={self.unit_executable} ; argv[]={self.unit_executable} ; }}\n")
            elif args[2:4] == ["enable", "--now"]:
                self.serving = True
            elif args[2] in ("start", "restart"):
                if self.service_start_error:
                    result, output = 1, self.service_start_error
                elif not self.restart_noop:
                    self.running = self.unit_command
                    self.service_generation += 1
                    self.serving = True
        elif args[0] == "ss":
            if self.serving:
                if self.hidden_listener_group is None:
                    output = f'LISTEN 0 128 *:47990 *:* users:(("polaris",pid={os.getpid()},fd=11))\n'
                else:
                    output = f"LISTEN 0 128 *:47990 *:* uid:1000 cgroup:{self.hidden_listener_group}\n"
        elif args[0] == "curl":
            output = "<html>other service</html>" if self.wrong_reply else '{"status":true,"locale":"en"}'
        elif args[:5] == ["systemd-run", "--user", "--quiet", "--collect", "--"]:
            self.opened.append(args[5:])
        else:
            self.fail(f"unexpected command {args}")
        return subprocess.CompletedProcess(args, result, output)

    def invoke(self, mode, target="", guided="1", log="", program=None, frames=(), tty=False,
               options=None, manager="dnf", next_deployment="-", uid=1000, real_tty=False):
        output = io.StringIO()
        output.isatty = lambda: tty
        self.output = output
        tick = iter(range(0, 200, 5))
        if options is not None:
            frames = [*(frames or ("", "[ok] ")), *options, manager, next_deployment]
        real_open = builtins.open
        readlink = os.readlink

        def terminal(path, mode="r", *args, **kwargs):
            if path == "/dev/tty" and not real_tty:
                raise OSError("No controlling terminal in this case.")
            return real_open(path, mode, *args, **kwargs)

        def executable(path, *args, **kwargs):
            if path == f"/proc/{200_000 + self.service_generation}/exe":
                if self.running == KMS:
                    raise PermissionError("capability-bearing helper")
                return self.running
            return readlink(path, *args, **kwargs)

        with contextlib.ExitStack() as ctx:
            ctx.enter_context(patch.dict(os.environ, self.env, clear=True))
            ctx.enter_context(patch.object(sys, "argv", [str(program or self.program), mode, target, guided, log, *frames]))
            ctx.enter_context(patch("os.geteuid", return_value=uid))
            ctx.enter_context(patch("pwd.getpwuid", return_value=SimpleNamespace(pw_dir=str(self.home), pw_name="player")))
            ctx.enter_context(patch("builtins.open", side_effect=terminal))
            ctx.enter_context(patch("os.readlink", side_effect=executable))
            ctx.enter_context(patch("subprocess.run", side_effect=self.command))
            ctx.enter_context(patch("time.monotonic", side_effect=lambda: next(tick)))
            ctx.enter_context(patch("time.sleep"))
            ctx.enter_context(patch("shutil.which", return_value="/usr/bin/xdg-open"))
            ctx.enter_context(contextlib.redirect_stdout(output))
            runpy.run_path(str(program or self.program))
        return output.getvalue()

    def test_mutable_headless_applies_only_boot_start_and_is_repeatable(self):
        self.assertIn("start before sign-in for player", self.invoke("options-now", options=("0", "1")))
        self.assertTrue(self.want.samefile(self.unit))
        self.assertTrue(self.linger)
        self.assertIn(["sudo", "-H", sys.executable, "--setup-host", "--enable-headless-boot"], self.calls)
        self.assertIn(["systemctl", "--user", "start", "polaris.service"], self.calls)
        self.calls.clear()
        self.invoke("options-now", options=("0", "1"))
        self.assertFalse(any(set(c) & {"enable", "restart", "--enable-kms", "start"} for c in self.calls))
        self.assertFalse(self.opened)
        self.assertFalse(self.job.exists())

    def test_parked_arch_group_retries_from_the_saved_program_after_new_login(self):
        self.group_live = False
        result = self.invoke("options-now", options=("1", "0"), manager="pacman")
        self.assertIn("Sign out of all sessions", result)
        self.assertIn("If another session stays open, restart when ready", result)
        self.assertTrue(self.park.is_file())
        self.assertIn(["pacman", "-Q", "polaris", "polaris-kms"], self.calls)
        self.assertFalse(any("enable" in c or "start" in c or "restart" in c for c in self.calls))
        self.program.unlink()
        self.calls.clear()
        self.assertIn("same service manager", self.invoke("login", "pacman", program=self.helper))
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))
        self.group_live = True
        self.invocation = "2" * 32
        self.assertIn("running with the DRM/KMS helper", self.invoke("login", "pacman", program=self.helper))
        self.assertEqual(self.running, KMS)
        self.assertFalse(self.job.exists())
        self.assertFalse(self.park.exists())
        self.assertFalse(self.want.exists())

    def test_old_ostree_package_parks_once_and_recovers_on_a_verified_update(self):
        self.fixed_userdb = False
        self.invoke("after-reboot", A, options=("1", "0"))
        self.assertIn("Waiting for a compatible Polaris update", self.invoke("login", A, program=self.helper))
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))
        entry, program = self.job.read_bytes(), self.helper.read_bytes()
        self.calls.clear()
        self.invoke("login", A, program=self.helper)
        self.assertEqual(self.calls, [["rpm-ostree", "status", "--json"]])
        self.assertEqual((self.job.read_bytes(), self.helper.read_bytes()), (entry, program))
        self.assertFalse((self.helper.parent / "finish.log").exists())
        self.booted, self.fixed_userdb = B, True
        self.versions = {name: "1.5.1-2" for name in self.versions}
        result = self.invoke("login", A, program=self.helper)
        self.assertIn("running with the DRM/KMS helper", result)
        sudo = [c for c in self.calls if c[0] == "sudo"]
        self.assertEqual(sudo, [["sudo", "-H", sys.executable, "--setup-host", "--enable-kms"]])
        self.assertIn(["rpm-ostree", "db", "list", B], self.calls[:self.calls.index(sudo[0])])
        self.assertFalse(self.job.exists())

    def test_cancel_keeps_independent_headless_request_and_requires_the_reviewed_job(self):
        self.fixed_userdb = False
        self.invoke("after-reboot", A, options=("1", "1"))
        original = self.job.read_bytes()
        with (self.helper.parent / "finish.lock").open("r") as other_installer:
            fcntl.flock(other_installer, fcntl.LOCK_EX)
            self.assertEqual(self.invoke("review-kms"), "")
            self.assertEqual(self.job.read_bytes(), original)
        token = self.invoke("review-kms").split()[0]
        self.assertEqual(self.job.read_bytes(), original)
        self.invoke("after-reboot", A, options=("1", "1"))
        with self.assertRaisesRegex(SystemExit, "request changed"):
            self.invoke("cancel-kms", token)
        token = self.invoke("review-kms").split()[0]
        self.assertIn("request cancelled", self.invoke("cancel-kms", token))
        self.assertIn('"kms":false', self.job.read_text())
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))
        self.assertIn("start before sign-in", self.invoke("login", A, program=self.helper))
        self.assertTrue(self.want.samefile(self.unit))
        self.assertFalse(self.job.exists())
        self.assertFalse(any("--enable-kms" in c for c in self.calls))

    def test_both_options_on_an_unsupported_image_apply_headless_only_once(self):
        self.fixed_userdb = False
        self.assertIn("Waiting for a compatible Polaris update", self.invoke("now", A, options=("1", "1")))
        self.assertTrue(self.want.samefile(self.unit))
        self.assertTrue(self.linger)
        self.assertFalse(self.drop.exists() or self.park.exists())
        self.assertEqual([c for c in self.calls if c[0] == "sudo"],
                         [["sudo", "-H", sys.executable, "--setup-host", "--enable-headless-boot"]])
        self.calls.clear()
        self.invoke("login", A, program=self.helper)
        self.assertEqual(self.calls, [["rpm-ostree", "status", "--json"]])
        self.invoke("cancel-kms", self.invoke("review-kms").split()[0])
        self.assertFalse(self.job.exists() or self.helper.exists())
        self.assertTrue(self.linger and self.want.samefile(self.unit))
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))

    def test_waiting_request_checks_new_stateroot_commit_and_matching_pair(self):
        self.fixed_userdb = False
        self.invoke("now", A, options=("1", "0"))
        original = self.job.read_bytes()
        self.booted, self.osname, self.fixed_userdb = B, "other", True
        self.calls.clear()
        self.invoke("login", A, program=self.helper)
        self.assertEqual(self.calls, [["rpm-ostree", "status", "--json"]])
        self.osname = "default"
        self.versions["polaris"] = "1.5.1-2"
        with self.assertRaisesRegex(SystemExit, "matching installed versions"):
            self.invoke("login", A, program=self.helper)
        self.versions["polaris-kms"] = "1.5.1-2"
        self.commit_versions = {name: "1.5.0-1" for name in self.versions}
        with self.assertRaisesRegex(SystemExit, "does not match the booted deployment"):
            self.invoke("login", A, program=self.helper)
        self.assertEqual(self.job.read_bytes(), original)
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))

    def test_compatible_plasma_login_without_a_password_terminal_can_finish_from_review(self):
        self.fixed_userdb = False
        self.invoke("now", A, options=("1", "0"))
        self.booted, self.fixed_userdb, self.denied = B, True, True
        token, _, state = self.invoke("review-kms").split()
        self.assertEqual(state, "ready")
        self.assertIn("Open Host review", self.invoke("login", A, program=self.helper))
        self.assertIn("local authentication required", (self.helper.parent / "finish.log").read_text())
        self.assertFalse(self.drop.exists() or self.park.exists())
        self.calls.clear()
        self.invoke("login", A, program=self.helper)
        self.assertEqual(self.calls, [["rpm-ostree", "status", "--json"]])
        with self.assertRaisesRegex(SystemExit, "request changed"):
            self.invoke("finish-kms", token)
        token, _, state = self.invoke("review-kms").split()
        self.assertEqual(state, "ready")
        self.denied = False
        self.assertIn("running with the DRM/KMS helper", self.invoke("finish-kms", token))
        self.assertEqual([c for c in self.calls if c[0] == "sudo"],
                         [["sudo", "-H", sys.executable, "--setup-host", "--enable-kms"]])
        self.assertFalse(self.job.exists())

    def test_independent_startup_can_finish_in_the_terminal_while_kms_waits(self):
        self.fixed_userdb = False
        self.invoke("after-reboot", A, options=("1", "1"))
        self.denied = True
        self.assertIn("Open Host review", self.invoke("login", A, program=self.helper))
        self.denied = False
        self.calls.clear()
        self.invoke("login", A, program=self.helper)
        self.assertEqual(self.calls, [["rpm-ostree", "status", "--json"]])
        token, _, state = self.invoke("review-kms").split()
        self.assertEqual(state, "headless")
        self.assertIn("start before sign-in", self.invoke("finish-kms", token))
        self.assertFalse(self.drop.exists() or self.park.exists())
        self.assertTrue(self.linger and self.want.samefile(self.unit))
        self.calls.clear()
        self.invoke("login", A, program=self.helper)
        self.assertEqual(self.calls, [["rpm-ostree", "status", "--json"]])
        self.assertEqual(self.invoke("review-kms").split()[-1], "waiting")

    def test_plain_rerun_upgrades_a_shipped_request_even_with_an_unrelated_stage(self):
        self.fixed_userdb = False
        self.invoke("after-reboot", A, options=("1", "0"))
        # The shipped entry uses these same fields but embeds the older program.
        self.job.write_bytes(b"".join(line for line in self.job.read_bytes().splitlines(keepends=True)
                                      if not line.startswith(b"X-Polaris-Helper-SHA256=")))
        self.helper.write_bytes(self.legacy_program)
        original = self.job.read_bytes(), self.helper.read_bytes()
        self.assertEqual(self.invoke("review-kms").split()[-1], "waiting")
        self.assertEqual((self.job.read_bytes(), self.helper.read_bytes()), original)
        self.staged = B
        self.invoke("after-reboot", B)
        self.assertEqual(self.program.read_bytes(), self.helper.read_bytes())
        self.assertIn('"wait_update":', self.job.read_text())
        next_job = self.job.with_name(f"com.papiux.PolarisInstaller-{B}.desktop")
        new_plan = next_job.read_bytes()
        self.calls.clear()
        self.invoke("login", A, program=self.helper)
        self.assertEqual(self.calls, [["rpm-ostree", "status", "--json"]])
        self.invoke("cancel-kms", self.invoke("review-kms").split()[0])
        self.assertEqual(next_job.read_bytes(), new_plan)
        self.assertTrue(self.helper.with_name(f"finish-host-{B}.py").exists())
        self.assertFalse(self.job.exists() or self.helper.exists())

    def test_legacy_request_already_on_its_compatible_boot_can_finish_without_reselecting_options(self):
        self.invoke("after-reboot", A, options=("1", "0"))
        token, _, state = self.invoke("review-kms").split()
        self.assertEqual(state, "ready")
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))
        self.assertIn("running with the DRM/KMS helper", self.invoke("finish-kms", token))
        self.assertFalse(self.job.exists())

    def test_cancel_ignores_foreign_jobs_helpers_and_other_accounts(self):
        self.fixed_userdb = False
        self.invoke("now", A, options=("1", "0"))
        original, helper = self.job.read_bytes(), self.helper.read_bytes()
        token = self.invoke("review-kms").split()[0]
        self.assertEqual(self.invoke("review-kms", uid=1001), "")
        with self.assertRaisesRegex(SystemExit, "request changed"):
            self.invoke("cancel-kms", token, uid=1001)
        self.assertEqual(self.job.read_bytes(), original)
        for data in (original + b"Hidden=true\n", original.replace(b'"kms":true', b'"kms":true,"future":1'),
                     original.replace(b"Exec=/usr/bin/python3", b"Exec=/usr/bin/other")):
            self.job.write_bytes(data)
            self.assertEqual(self.invoke("review-kms"), "")
            with self.assertRaisesRegex(SystemExit, "request changed"):
                self.invoke("cancel-kms", token)
            self.assertEqual((self.job.read_bytes(), self.helper.read_bytes()), (data, helper))
        self.job.write_bytes(original)
        self.helper.write_bytes(helper + b"\n# Locally maintained helper\n")
        self.assertEqual(self.invoke("review-kms"), "")
        self.helper.unlink()
        self.helper.symlink_to(self.program)
        self.assertEqual(self.invoke("review-kms"), "")
        self.assertTrue(self.helper.is_symlink())

    def test_native_exit_zero_is_insufficient_for_each_option(self):
        self.apply_native = False
        for options, error in ((("1", "0"), "verifiable active or pending"),
                               (("0", "1"), "verify lingering")):
            with self.subTest(options=options), self.assertRaisesRegex(SystemExit, error):
                self.invoke("options-now", options=options)
            self.assertNotIn("running with", self.output.getvalue())
            self.assertTrue(self.job.exists())

    def test_queued_group_survives_headless_only_and_plain_reruns(self):
        self.group_live = False
        self.invoke("options-now", options=("1", "0"))
        self.calls.clear()
        self.invoke("options-now", options=("0", "1"))
        self.assertNotIn("--enable-kms", next(c for c in self.calls if c[0] == "sudo"))
        self.assertTrue(self.park.exists())
        self.assertTrue(self.job.exists())
        self.running, self.serving = None, False
        self.group_live = True
        self.invocation = "2" * 32
        self.invoke("login", "dnf", program=self.helper)
        self.assertTrue(self.want.exists())
        self.assertEqual(self.running, KMS)
        self.assertFalse(self.job.exists())
        self.invoke("after-reboot", A, options=("1", "0"))
        self.invoke("after-reboot", A)
        self.invoke("now", A)
        self.assertIn('"kms":true', self.job.read_text())

    def test_selected_and_unrelated_deployments_keep_separate_login_jobs(self):
        self.invoke("after-reboot", A, options=("1", "1"))
        self.invoke("after-reboot", B)
        second = self.helper.with_name(f"finish-host-{B}.py")
        self.assertTrue(second.is_file())
        self.booted, self.staged = B, None
        self.calls.clear()
        self.assertIn("replaced", self.invoke("login", A, program=self.helper))
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))
        self.assertIn("console ready", self.invoke("login", B, program=second))
        self.assertFalse(second.exists())
        self.assertFalse(self.want.exists())

    def test_offline_plain_rerun_preserves_the_bound_deployment(self):
        self.invoke("after-reboot", A, options=("1", "0"))
        original = self.job.read_bytes()
        self.manager = False
        self.invoke("now", A)
        self.assertEqual(self.job.read_bytes(), original)
        self.manager = True
        self.booted, self.staged = B, None
        self.assertIn("replaced", self.invoke("login", A, program=self.helper))
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))

    def test_login_waits_for_an_existing_service_start_without_restarting_it(self):
        self.invoke("after-reboot", A, options=("1", "0"))
        self.running, self.serving = KMS, True
        self.service_states = ["activating", "activating", "active"]
        self.assertIn("running with the DRM/KMS helper", self.invoke("login", A, program=self.helper))
        self.assertFalse(any(set(c) & {"start", "restart"} for c in self.calls))
        self.assertFalse(self.job.exists())

    def test_live_applied_job_continues_on_its_verified_next_deployment(self):
        self.group_live = False
        self.booted, self.staged = A, B
        self.invoke("now", A, options=("1", "0"), next_deployment=B)
        self.assertTrue(self.park.exists())
        self.group_live = True
        self.invocation = "2" * 32
        self.booted, self.staged = B, None
        self.running, self.serving = None, False
        self.assertIn("running with the DRM/KMS helper", self.invoke("login", A, program=self.helper))
        self.assertFalse(self.job.exists())

    def test_root_and_another_account_cannot_enroll_or_consume_the_job(self):
        for mode in ("options-now", "options-after-reboot"):
            with self.subTest(mode=mode), self.assertRaisesRegex(SystemExit, "desktop account"):
                self.invoke(mode, uid=0, options=("1", "1"))
        self.assertFalse(self.job.exists())
        self.invoke("after-reboot", A, options=("1", "1"))
        first = self.job.read_bytes()
        with self.assertRaisesRegex(SystemExit, "different account"):
            self.invoke("login", A, program=self.helper, uid=1001)
        with self.assertRaisesRegex(SystemExit, "desktop account"):
            self.invoke("login", A, program=self.helper, uid=0)
        self.assertFalse(self.calls)
        self.assertEqual(self.job.read_bytes(), first)

    def test_preserve_foreign_autostart_helper_and_native_entries(self):
        self.helper.parent.mkdir(parents=True)
        self.helper.write_text("owned by another tool\n")
        with self.assertRaisesRegex(SystemExit, "different file"):
            self.invoke("options-now", options=("1", "0"))
        self.assertEqual(self.helper.read_text(), "owned by another tool\n")
        self.helper.unlink()
        self.job.parent.mkdir(parents=True)
        self.job.write_text("[Desktop Entry]\nExec=/usr/bin/other\nX-Polaris-Installer=true\n"
                            "X-Polaris-Deployment=dnf\n")
        with self.assertRaisesRegex(SystemExit, "different desktop entry"):
            self.invoke("options-now", options=("1", "0"))
        self.job.unlink()
        self.want.parent.mkdir(parents=True)
        self.want.symlink_to(self.program)
        with self.assertRaisesRegex(SystemExit, "different boot-start entry"):
            self.invoke("options-now", options=("0", "1"))
        self.drop.parent.mkdir(parents=True)
        self.drop.write_text("[Service]\nExecStart=/usr/bin/other\n")
        with self.assertRaisesRegex(SystemExit, "different service override"):
            self.invoke("options-now", options=("1", "0"))
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))
        self.assertTrue(self.want.samefile(self.program))
        self.assertIn("/usr/bin/other", self.drop.read_text())

    def test_legacy_desktop_entry_can_still_finish_without_options(self):
        self.invoke("after-reboot", A)
        self.job.write_text("".join(line for line in self.job.read_text().splitlines(True)
                                    if not line.startswith("X-Polaris-Setup=")))
        self.assertIn("console ready", self.invoke("login", A, program=self.helper))
        self.assertFalse(self.job.exists())
        self.assertFalse(any("--enable-kms" in c or "--enable-headless-boot" in c for c in self.calls))

    def test_reboot_gate_and_updated_package_pair_are_checked_before_sudo(self):
        self.invoke("options-after-reboot", options=("1", "0"), manager="pacman")
        self.program.unlink()
        self.assertIn("waiting for a restart", self.invoke("login", "pacman", program=self.helper))
        self.boot_id.write_text("boot-2")
        self.modules.rmdir()
        with self.assertRaisesRegex(SystemExit, "still has no installed modules"):
            self.invoke("login", "pacman", program=self.helper)
        self.modules.mkdir()
        self.nvidia.write_text("580.4")
        self.nvidia_library = "nvidia-utils 2:590.1-2"
        with self.assertRaisesRegex(SystemExit, "libraries still differ"):
            self.invoke("login", "pacman", program=self.helper)
        self.nvidia.write_text("590.1")
        self.versions["polaris"] = "1.5.1-2"
        with self.assertRaisesRegex(SystemExit, "matching installed versions"):
            self.invoke("login", "pacman", program=self.helper)
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))
        self.assertTrue(self.job.exists())
        self.versions["polaris-kms"] = "1.5.1-2"
        self.assertIn("running with the DRM/KMS helper", self.invoke("login", "pacman", program=self.helper))
        self.assertFalse(self.job.exists())

    def test_lingering_parked_group_signals_reboot_only_to_the_installer(self):
        self.group_live = False
        with self.assertRaises(SystemExit) as stop:
            self.invoke("options-now", options=("1", "1"))
        self.assertEqual(stop.exception.code, 75)
        self.assertIn("Restart when ready", self.output.getvalue())
        self.assertNotIn("running with the DRM/KMS", self.output.getvalue())
        self.assertTrue(self.want.samefile(self.unit))
        self.assertTrue(self.park.exists())
        self.calls.clear()
        self.invoke("login", "dnf", program=self.helper)
        self.assertFalse(any(c[0] == "sudo" for c in self.calls))

    def test_shell_shows_the_admin_command_and_translates_only_the_reboot_signal(self):
        source = INSTALLER.read_text()
        function = source[source.index("host_completion_program() {"):
                          source.index("\n}\n", source.index("finish_ostree_host() {")) + 3]
        script = function + """
key_dir=$1 dry_run=$2 guided=$3 status=$4
enable_kms=1 enable_headless=1 manager=dnf log_file= ready_star= ready_check='[ok] '
installer_restart_pending=0
note() { :; }
command_words() { printf '%s' "$*"; }
show_command() { printf '%s\\n' "$*"; }
has_client() { return 1; }
id() { echo 1000; }
python3() { return "$status"; }
finish_ostree_host options-now
printf '%d %d\\n' "$?" "$installer_restart_pending"
"""
        def shell(dry_run, guided, status=0):
            return subprocess.check_output(["sh", "-c", script, "sh", str(self.home),
                                            str(dry_run), str(guided), str(status)], text=True)
        flags = "-H /usr/bin/polaris --setup-host --enable-kms --enable-headless-boot"
        self.assertIn(f"sudo -n {flags}", shell(1, 0))
        self.assertIn(f"sudo {flags}", shell(1, 1))
        self.assertEqual(shell(0, 1, 75), "0 1\n")
        self.assertEqual(shell(0, 1, 1), "1 0\n")

    def test_denied_admin_and_failed_unit_keep_automatic_recovery(self):
        self.denied = True
        with self.assertRaisesRegex(SystemExit, "local authentication required"):
            self.invoke("options-now", options=("1", "1"), guided="0")
        self.assertIn(["sudo", "-n", "-H", sys.executable, "--setup-host", "--enable-kms",
                       "--enable-headless-boot"], self.calls)
        self.denied = False
        self.service_start_error = "unable to start polaris.service"
        with self.assertRaisesRegex(SystemExit, "unable to start polaris.service"):
            self.invoke("login", "dnf", program=self.helper)
        self.assertTrue(self.job.exists())
        self.assertIn("unable to start polaris.service", (self.helper.parent / "finish.log").read_text())
        self.service_start_error = None
        self.invoke("login", "dnf", program=self.helper)
        self.assertFalse(self.job.exists())

    def test_unmanaged_listener_keeps_the_current_host_and_retries(self):
        self.serving = True
        self.assertIn("console port is already in use", self.invoke("options-now", options=("1", "0")))
        self.assertTrue(self.job.exists())
        self.assertFalse(any(set(c) & {"start", "enable", "restart"} for c in self.calls))
        self.serving = False
        self.invoke("login", "dnf", program=self.helper)
        self.assertFalse(self.job.exists())

    def test_restart_choices_on_a_real_controlling_terminal(self):
        self.running = sys.executable
        for keys, expected in ((b"\n", False), (b"\x1b[B\n", True), (b"yes\n", True), (b"n\n", False)):
            with self.subTest(keys=keys):
                view = self.restart_terminal(keys)
                self.assertIn("disconnects any active stream", view)
                before_choice = view.split("> Keep streaming", 1)[0]
                self.assertIn(
                    "Choose Keep streaming to finish setup after your next PC restart and sign-in.",
                    before_choice,
                )
                self.assertIn(f"restart={expected} restored=True", view)
                self.assertEqual(self.job.exists(), not expected)
        self.restart_noop = True
        view = self.restart_terminal(b"\x1b[B\n")
        self.assertIn("Could not verify that the running service switched", view)
        self.assertTrue(self.job.exists())

    def restart_terminal(self, keys):
        pid, fd = pty.fork()
        if pid == 0:
            try:
                saved = termios.tcgetattr(0)
                try:
                    self.invoke("options-now", options=("1", "0"), real_tty=True)
                except SystemExit as exc:
                    os.write(1, str(exc).encode())
                restart = ["systemctl", "--user", "restart", "polaris.service"] in self.calls
                os.write(1, f"\nrestart={restart} restored={termios.tcgetattr(0) == saved}\n".encode())
                os._exit(0)
            except BaseException as exc:
                os.write(1, repr(exc).encode())
                os._exit(1)
        result = bytearray()
        sent = False
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if not select.select([fd], [], [], 0.1)[0]:
                    continue
                try:
                    chunk = os.read(fd, 4096)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                result.extend(chunk)
                if not sent and b"> Keep streaming" in result:
                    os.write(fd, keys)
                    sent = True
            else:
                os.kill(pid, signal.SIGKILL)
                self.fail(f"restart terminal timed out: {result!r}")
        finally:
            os.close(fd)
            _, status = os.waitpid(pid, 0)
        self.assertTrue(sent, result)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0, result)
        return result.decode()

    def test_install_and_rerun_preserve_a_running_service(self):
        log = self.home / "install.log"
        result = self.invoke("now", log=str(log))
        self.assertIn("Polaris console ready", result)
        self.assertNotIn("Start Polaris directly", result)
        self.assertIn("Start Polaris directly", log.read_text())
        self.assertIn(["systemctl", "--user", "enable", "--now", "polaris.service"], self.calls)
        self.assertEqual(self.opened, [["/usr/bin/xdg-open", "https://localhost:47990/"]])
        self.calls.clear()
        self.env["SSH_CONNECTION"] = "test"
        self.invoke("now")
        self.assertIn(["systemctl", "--user", "enable", "polaris.service"], self.calls)
        self.assertFalse(any("--now" in call for call in self.calls))
        self.assertEqual(len(self.opened), 1)

    def test_custom_port_and_noninteractive_input_setup(self):
        config = self.home / ".config/polaris/polaris.conf"
        config.parent.mkdir(parents=True)
        config.write_text("port = 50800\n")
        self.admin_needed = True
        self.assertIn("https://localhost:50801/", self.invoke("now", guided="0"))
        self.assertIn(["sudo", "-n", "-H", sys.executable, "--setup-host"], self.calls)
        self.assertFalse(self.opened)

    def test_no_ready_result_on_wrong_body_or_unauthorized_setup(self):
        self.wrong_reply = True
        with self.assertRaisesRegex(SystemExit, "did not answer"):
            self.invoke("now", frames=("✦", "✓ "), tty=True)
        self.assertNotIn("✦", self.output.getvalue())
        self.assertNotIn("Polaris console ready", self.output.getvalue())
        self.assertFalse(self.opened)
        self.admin_needed = self.denied = True
        with self.assertRaisesRegex(SystemExit, "local authentication required"):
            self.invoke("now")
        self.assertNotIn("Polaris console ready", self.output.getvalue())

    def test_ready_cue_requires_the_live_console(self):
        frames = ("✦", "✓ ")
        pending = self.invoke("after-reboot", A, frames=frames, tty=True)
        self.assertNotIn("✦", pending)
        self.assertNotIn("Polaris console ready", pending)
        self.assertIn("✦\r✓ Polaris console ready\n  https://localhost:47990/",
                      self.invoke("now", frames=frames, tty=True, log=str(self.home / "missing/log")))
        self.assertNotIn("✦", self.invoke("now", frames=frames, tty=False))

    def test_kms_socket_without_visible_pid_completes_login(self):
        self.serving = True
        self.hidden_listener_group = self.unit_group
        self.invoke("after-reboot", A)
        self.assertIn("Polaris console ready", self.invoke("login", A, program=self.helper))
        self.assertFalse(self.job.exists())
        self.assertFalse(any("--now" in call for call in self.calls))

    def test_another_socket_cannot_complete_a_kms_login(self):
        self.serving = True
        for group, executable in ((self.unit_group + ".backup", self.unit_executable),
                                  (self.unit_group, "/usr/bin/true")):
            with self.subTest(group=group, executable=executable):
                self.hidden_listener_group = group
                self.unit_executable = executable
                with self.assertRaisesRegex(SystemExit, "did not answer"):
                    self.invoke("now")
        self.assertFalse(self.opened)

    def test_successful_rerun_retires_only_the_current_deployment_job(self):
        self.invoke("after-reboot", A)
        self.invoke("now", A)
        self.assertFalse(self.job.exists())
        self.invoke("after-reboot", B)
        self.invoke("now", A)
        self.assertIn(B, self.job.read_text())

    def test_deferred_first_login_only_finishes_the_selected_deployment(self):
        self.booted, self.staged = B, A
        self.invoke("after-reboot", A)
        self.assertTrue(self.helper.is_file())
        self.assertEqual(self.job.stat().st_mode & 0o777, 0o600)
        self.assertIn("still waiting", self.invoke("login", A, program=self.helper))
        self.assertFalse(self.opened)
        self.booted, self.staged = A, None
        self.assertIn("Polaris console ready", self.invoke("login", A, program=self.helper))
        self.assertFalse(self.job.exists())
        self.assertFalse(self.helper.exists())

    def test_cancelled_and_superseded_deployments(self):
        self.invoke("after-reboot", A)
        self.invoke("after-reboot", B)
        self.calls.clear()
        self.invoke("login", A, program=self.helper)
        self.assertFalse(self.calls)
        self.invoke("now")
        self.assertIn(B, self.job.read_text())
        self.assertIn("replaced", self.invoke("login", B, program=self.helper))
        self.assertFalse(self.job.exists())

    def test_headless_invocation_defers_to_desktop_and_preserves_foreign_entries(self):
        self.manager = False
        self.assertIn("next desktop login", self.invoke("now"))
        self.manager = True
        self.assertIn("ready", self.invoke("login", "desktop", program=self.helper))
        self.job.write_text("[Desktop Entry]\nName=Other\n")
        with self.assertRaisesRegex(SystemExit, "different desktop entry"):
            self.invoke("after-reboot", A)
        self.assertIn("Name=Other", self.job.read_text())


if __name__ == "__main__":
    unittest.main()
