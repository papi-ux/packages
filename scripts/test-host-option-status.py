"""Exercise the shipped read-only Host options probe with isolated account state."""

import os
from pathlib import Path
import socket
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


INSTALLER = Path(__file__).resolve().parents[1] / "site/install.sh"
SHELL_FUNCTION = "read_host_option_status() {" + INSTALLER.read_text().split(
    "read_host_option_status() {", 1)[1].split("host_options_summary() {", 1)[0]
PROGRAM = SHELL_FUNCTION.split("<<'POLARIS_OPTION_STATUS'\n", 1)[1].split("\nPOLARIS_OPTION_STATUS\n", 1)[0]


class HostOptionStatus(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.code = {"__name__": "host_option_status"}
        exec(compile(PROGRAM, "site/install.sh:POLARIS_OPTION_STATUS", "exec"), self.code)
        self.unit = self.root / "pkg/polaris.service"
        self.helper = self.root / "pkg/polaris-kms"
        self.host = self.root / "pkg/polaris"
        self.unit.parent.mkdir()
        for file in (self.unit, self.helper, self.host):
            file.touch()
        self.unit.chmod(0o644)
        self.helper.chmod(0o750)
        self.host.chmod(0o755)
        self.gid = 628
        self.uid = os.geteuid() or 1000
        self.account = SimpleNamespace(pw_name="player", pw_uid=self.uid, pw_gid=100, pw_dir=str(self.root / "home"))
        self.config = self.root / "home/.config/systemd/user"
        self.active = self.config / "polaris.service.d/20-polaris-kms.conf"
        self.parked = self.active.with_suffix(".conf.disabled-until-relogin")
        self.want = self.config / "default.target.wants/polaris.service"
        self.linger = self.root / "linger/player"
        self.private = self.root / "run" / str(self.uid) / "systemd/private"
        for file in (self.active, self.want, self.linger, self.private):
            file.parent.mkdir(parents=True)
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.bind(str(self.private))
        self.proc = self.root / "proc/2345"
        self.proc.mkdir(parents=True)
        self.manager = self.root / "proc/1234"
        self.manager.mkdir()
        (self.manager / "cmdline").write_bytes(b"/usr/lib/systemd/systemd\0--user\0")
        self.manager_groups = self.manager / "status"
        self.manager_groups.write_text(f"Uid:\t{self.uid} {self.uid} {self.uid} {self.uid}\nGid:\t100 100 100 100\nGroups:\t100\n")
        slice_dir = self.root / "user.slice"
        self.scope = slice_dir / f"user-{self.uid}.slice/user@{self.uid}.service/init.scope/cgroup.procs"
        self.scope.parent.mkdir(parents=True)
        self.scope.write_text("1234\n")
        self.code.update(UNIT=self.unit, KMS=self.helper, HOST=self.host, PROC=self.proc.parent,
                         USER_SLICE=slice_dir, RUN_USER=self.root / "run", LINGER=self.linger.parent)
        self.override = f"[Service]\nExecStart=\nExecStart={self.helper}\n"
        self.service = {"LoadState": "loaded", "NeedDaemonReload": "no", "FragmentPath": str(self.unit),
                        "DropInPaths": "", "ActiveState": "active", "MainPID": "2345"}
        self.command(self.host)
        self.target = {"Wants": "other.service polaris.service", "NeedDaemonReload": "no",
                       "LoadState": "loaded", "ActiveState": "active"}
        self.cap = "cap_sys_admin=ep"
        self.member = True
        self.helper_owner = 0
        self.calls = []
        real_lstat = Path.lstat

        def lstat(path):
            data = real_lstat(path)
            if path in (self.helper, self.unit, self.linger, self.private):
                return SimpleNamespace(st_mode=data.st_mode, st_gid=self.gid if path == self.helper else data.st_gid,
                                       st_uid=self.helper_owner if path == self.helper else
                                       (self.uid if path == self.private else 0))
            return data

        self.start(patch.object(Path, "lstat", lstat))
        self.euid = self.start(patch("os.geteuid", return_value=self.uid))
        self.by_uid = self.start(patch("pwd.getpwuid", return_value=self.account))
        self.by_name = self.start(patch("pwd.getpwnam", side_effect=KeyError))
        self.start(patch("grp.getgrnam", return_value=SimpleNamespace(gr_gid=self.gid, gr_mem=[])))
        self.mount = self.start(patch("os.statvfs", return_value=SimpleNamespace(f_flag=0)))
        self.groups = self.start(patch("os.getgrouplist", side_effect=lambda user, primary:
                                      [primary, self.gid] if self.member and user == "player" else [primary]))
        self.start(patch("subprocess.run", side_effect=self.query))

    def start(self, replacement):
        self.addCleanup(replacement.stop)
        return replacement.start()

    def command(self, binary):
        self.service["ExecStart"] = f"{{ path={binary} ; argv[]={binary} ; ignore_errors=no ; }}"

    def query(self, args, *, env, **kwargs):
        self.calls.append(args)
        self.assertEqual(env["DBUS_SESSION_BUS_ADDRESS"], f"unix:path={self.private}")
        self.assertEqual(env["XDG_RUNTIME_DIR"], str(self.private.parent.parent))
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
        if args == ("getcap", "-n", str(self.helper)):
            data = f"{self.helper} {self.cap}" if self.cap else ""
        elif args[:4] == ("systemctl", "--user", "--no-ask-password", "show"):
            self.assertEqual(len(args), 6)
            values = {"polaris.service": self.service, "default.target": self.target}[args[4]]
            props = args[5].removeprefix("--property=").split(",")
            data = "\n".join(f"{key}={values[key]}" for key in props if key in values)
        else:
            self.fail(f"Unexpected review command {args}")
        return subprocess.CompletedProcess(args, 0, stdout=data)

    def expect(self, kms="", boot=""):
        self.assertEqual(self.code["read_status"](), (kms, boot))

    def enable_kms(self):
        self.active.write_text("# Written by polaris --setup-host --enable-kms.\n" + self.override)
        self.command(self.helper)
        self.service["DropInPaths"] = str(self.active)
        (self.proc / "exe").symlink_to(self.helper)

    def enable_boot(self):
        self.want.symlink_to(self.unit)
        self.linger.touch()

    def test_fresh_or_package_only_never_contacts_the_manager(self):
        self.expect()
        self.assertEqual(self.calls, [])

    def test_pending_needs_the_exact_parked_override_and_next_login_membership(self):
        self.parked.write_text("# Parked by polaris --setup-host\n" + self.override)
        self.expect("Waiting for sign-in")
        self.groups.assert_called_with("player", 100)
        self.member = False
        self.expect()
        self.member = True
        self.parked.write_text(self.override.replace(str(self.helper), str(self.host)))
        self.expect()
        self.parked.write_text(self.override)
        self.active.symlink_to(self.root / "missing")
        self.expect()

    def test_parked_file_after_new_login_or_without_a_visible_manager(self):
        self.parked.write_text(self.override)
        self.manager_groups.write_text(self.manager_groups.read_text().replace("Groups:\t100", f"Groups:\t100 {self.gid}"))
        self.expect("Pending")
        self.scope.unlink()
        self.private.unlink()
        self.expect("Pending")

    def test_distinguishes_live_helper_from_loaded_config_and_old_executable(self):
        self.enable_kms()
        self.enable_boot()
        # A nondumpable service or a host with hidepid may hide the executable.
        with patch.object(Path, "samefile", side_effect=PermissionError):
            self.expect("Configured", "Already on")
        # The fixture stands in for the desktop user's /proc/PID when CI runs as root.
        with patch.object(Path, "stat", autospec=True, side_effect=self.process_stat(Path.stat)):
            self.expect("Already on", "Already on")
            (self.proc / "exe").unlink()
            (self.proc / "exe").symlink_to(self.host)
            self.expect("Configured", "Already on")
        self.service["ActiveState"] = "inactive"
        self.expect("Configured", "Configured")

    def process_stat(self, real_stat):
        def stat_path(path, *args, **kwargs):
            if path == self.proc:
                return SimpleNamespace(st_uid=self.uid)
            return real_stat(path, *args, **kwargs)
        return stat_path

    def test_mutable_and_userdb_membership_uses_nss_and_the_passwd_home(self):
        self.parked.write_text(self.override)
        self.enable_boot()
        alias = self.root / "var-home"
        alias.symlink_to(self.root / "home", target_is_directory=True)
        self.account.pw_dir = str(alias)
        with patch.dict(os.environ, {"SUDO_USER": "other", "HOME": "/nonexistent", "XDG_CONFIG_HOME": "/other"}):
            self.expect("Waiting for sign-in", "Already on")
        self.by_uid.assert_called_with(self.uid)
        self.by_name.assert_not_called()

    def test_other_account_cannot_supply_either_setting(self):
        self.enable_kms()
        self.enable_boot()
        other = self.root / "other"
        other.mkdir()
        self.euid.return_value = self.uid + 1
        self.by_uid.return_value = SimpleNamespace(pw_name="other", pw_uid=self.uid + 1, pw_gid=101, pw_dir=str(other))
        with patch.dict(os.environ, {"HOME": str(self.root / "home"), "SUDO_USER": "player",
                                     "DBUS_SESSION_BUS_ADDRESS": f"unix:path={self.private}"}):
            self.expect()
        self.assertEqual(self.calls, [])
        other_config = other / ".config"
        other_config.symlink_to(self.root / "home/.config", target_is_directory=True)
        self.expect()

    def test_review_preserves_files_and_wants_links(self):
        self.parked.write_text(self.override)
        self.enable_boot()

        def snapshot():
            return {p.relative_to(self.root): (os.lstat(p).st_ino, os.lstat(p).st_mtime_ns)
                    for p in self.root.rglob("*")}

        before = snapshot()
        self.expect("Waiting for sign-in", "Already on")
        self.expect("Waiting for sign-in", "Already on")
        self.assertEqual(before, snapshot())
        self.assertEqual(self.want.readlink(), self.unit)
        self.assertEqual(self.parked.read_text(), self.override)

    def test_root_reads_as_sudo_user_without_authentication(self):
        self.parked.write_text(self.override)
        self.euid.return_value = 0
        self.by_name.side_effect = None
        self.by_name.return_value = self.account
        with (patch.dict(os.environ, {"SUDO_USER": "player"}), patch("os.initgroups") as groups,
              patch("os.setgid") as gid, patch("os.setuid", side_effect=lambda uid: setattr(self.euid, "return_value", uid)) as uid):
            self.expect("Waiting for sign-in")
        self.by_name.assert_called_once_with("player")
        groups.assert_called_once_with("player", 100)
        gid.assert_called_once_with(100)
        uid.assert_called_once_with(self.uid)

    def test_private_manager_absent_or_symlink_never_opens_the_desktop_bus(self):
        self.enable_kms()
        self.enable_boot()
        self.private.unlink()
        self.expect()
        self.private.symlink_to(self.private.parent.parent / "bus")
        bus = socket.socket(socket.AF_UNIX)
        self.addCleanup(bus.close)
        bus.bind(str(self.private.parent.parent / "bus"))
        self.expect()
        self.assertFalse(any(call[0] == "systemctl" for call in self.calls))

    def test_unprivileged_or_missing_helper_keeps_independent_boot_status(self):
        self.enable_kms()
        self.enable_boot()
        for caps in ("", "cap_chown=ep", "cap_sys_admin=p", "cap_sys_admin=ep [rootid=1000]"):
            with self.subTest(caps=caps):
                self.cap = caps
                self.expect()
        self.cap = "cap_sys_admin=ep"
        self.mount.return_value.f_flag = os.ST_NOSUID
        self.expect()
        self.mount.return_value.f_flag = 0
        self.helper.chmod(0o755)
        self.expect()
        self.helper.chmod(0o750)
        self.helper_owner = self.uid
        self.expect()
        self.helper.unlink()
        self.expect()
        self.command(self.host)
        self.expect("", "Already on")

    def test_alternate_shadowed_or_stale_override_never_proves_kms(self):
        self.enable_kms()
        self.command(self.host)
        self.expect()
        self.command(self.helper)
        self.service["NeedDaemonReload"] = "yes"
        self.expect()
        self.service["NeedDaemonReload"] = "no"
        self.service["DropInPaths"] = str(self.root / "other.conf")
        self.expect()
        self.service["DropInPaths"] = str(self.active)
        self.service["ExecStart"] += " ; { path=/usr/bin/other ; argv[]=/usr/bin/other ; }"
        self.expect()
        self.command(self.helper)
        self.active.rename(self.root / "other.conf")
        self.active.symlink_to(self.root / "other.conf")
        self.expect()

    def test_linger_link_loaded_target_and_packaged_fragment_are_all_required(self):
        self.want.symlink_to(self.unit)
        self.expect()
        self.linger.touch()
        self.expect("", "Already on")
        self.target["Wants"] = "some-polaris.service"
        self.expect()
        self.target["Wants"] = "polaris.service"
        self.service["FragmentPath"] = str(self.root / "other.service")
        self.expect()
        self.service["FragmentPath"] = str(self.unit)
        self.want.unlink()
        self.want.symlink_to(self.host)
        self.expect()
        self.want.unlink()
        self.want.symlink_to(self.root / "missing")
        self.expect()


class ShellInterface(unittest.TestCase):
    def test_labels_are_advisory_and_failed_reads_clear_both(self):
        with tempfile.TemporaryDirectory() as directory:
            python = Path(directory) / "python3"
            python.write_text("#!/bin/sh\nprintf '%s\\n' \"$ANSWER\"\nexit \"$STATUS\"\n")
            python.chmod(0o755)
            script = ("set -eu\n" + SHELL_FUNCTION + "\nenable_kms=0 enable_headless=1 run_setup=0\n"
                      "read_host_option_status\nprintf '%s|%s|%s%s%s' \"$kms_status\" \"$boot_status\" "
                      "\"$enable_kms\" \"$enable_headless\" \"$run_setup\"\n")
            for answer, status, wanted in (("Already on|", "0", "Already on||010"),
                                           ("|Configured", "0", "|Configured|010"),
                                           ("stale|data", "1", "||010")):
                result = subprocess.run(["/bin/sh", "-c", script], text=True, capture_output=True, check=True,
                                        env={"PATH": directory, "ANSWER": answer, "STATUS": status})
                self.assertEqual(result.stdout, wanted)
                self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
