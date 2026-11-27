"""Run the shipped installer with an isolated user, fixture commands and a private PTY."""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "site/install.sh"
BOUNDARY = Path(__file__).resolve().parent / "fixtures/guided-installer/command.py"
APP = "app/com.papi_ux.Nova/x86_64/"
RUNTIME = "runtime/org.kde.Platform/x86_64/6.10"
OTHER = "app/org.example.Other/x86_64/stable"
ORIGINAL = {"packages": {"unrelated": "7"}, "refs": {OTHER: ["flathub", "f" * 64]}, "remotes": {}}
CHOOSER = "Choose a role"
REVIEW = "[q]  Quit"


class RoleInstaller(unittest.TestCase):
    def setUp(self):
        self.case = ROOT / self._testMethodName
        self.case.mkdir(mode=0o700)
        self.bin = self.case / "bin"
        for name in ("home", "config", "data", "tmp", "cache", "bin"):
            (self.case / name).mkdir()
        self.os_file = self.case / "os-release"
        self.os_file.write_text('ID=fedora\nVERSION_ID=45\nVARIANT="KDE Plasma Desktop"\nPRETTY_NAME="Fedora Linux 45"\n')
        (self.case / "state.json").write_text(json.dumps(ORIGINAL))
        (self.case / "pacman.conf").write_text("[core]\n")
        self.sentinels = [self.case / "config/polaris/library", self.case / "home/.var/app/com.papi_ux.Nova/data/pairing"]
        for path in self.sentinels:
            path.parent.mkdir(parents=True)
            path.write_text("fixture player data\n")
        for cmd in ("sh", "awk", "chmod", "cut", "date", "dd", "grep", "head", "mkdir", "mktemp",
                    "rm", "sed", "sha256sum", "sleep", "stty", "tail", "tr", "wc"):
            (self.bin / cmd).symlink_to(shutil.which(cmd))
        # Host status reads the real account home, manager and process table.
        # Model those facts alongside this fixture's package inventory.
        self.command_python = self.case / "command-python"
        self.command_python.symlink_to(sys.executable)
        python = self.bin / "python3"
        python.write_text(
            '#!/bin/sh\nif [ "$1" = -IB ] && [ "$2" = - ]; then\n'
            '  printf "%s\\n" "${FIXTURE_HOST_STATUS:-|}"\n'
            'else\n  exec ' + shlex.quote(str(self.command_python.absolute())) + ' "$@"\nfi\n'
        )
        python.chmod(0o755)
        for cmd in ("cat", "id", "uname", "stat", "sudo", "curl", "rpmkeys", "rpm", "dnf", "install",
                    "polaris", "rpm-ostree", "pacman", "pacman-key", "tee", "flatpak", "systemctl"):
            (self.bin / cmd).symlink_to(BOUNDARY)
        self.env = dict(PATH=str(self.bin), HOME=str(self.case / "home"),
                        XDG_CONFIG_HOME=str(self.case / "config"), XDG_DATA_HOME=str(self.case / "data"),
                        XDG_CACHE_HOME=str(self.case / "cache"), TMPDIR=str(self.case / "tmp"),
                        XDG_CURRENT_DESKTOP="KDE", TERM="dumb", LANG="C", LC_ALL="C", FIXTURE=str(self.case))
        self.invocations = 0

    def tearDown(self):
        for path in self.sentinels:
            self.assertEqual(path.read_text(), "fixture player data\n")
        self.assertEqual(self.state["packages"]["unrelated"], "7")
        self.assertEqual(self.state["refs"][OTHER], ["flathub", "f" * 64])
        for path in (self.case / "tmp").iterdir():
            self.assertTrue(path.is_file() and path.name.startswith("polaris-install-"), path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    @property
    def state(self):
        return json.loads((self.case / "state.json").read_text())

    def change(self, **changes):
        state = self.state
        state.update(changes)
        (self.case / "state.json").write_text(json.dumps(state))

    def records(self, name):
        path = self.case / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def capture(self, argv, kind):
        self.invocations += 1
        stem = self.case / f"{self.invocations:02d}-{kind}"
        stem.with_suffix(".argv").write_text(json.dumps(argv) + "\n")
        return stem

    def run_cli(self, *args, status=0):
        argv = [INSTALL_SH, str(SOURCE), *args]
        stem = self.capture(argv, "pipe")
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                                stdout=subprocess.PIPE, cwd=self.case, env=self.env, timeout=20)
        stem.with_suffix(".txt").write_bytes(result.stdout)
        stem.with_suffix(".exit").write_text(str(result.returncode) + "\n")
        text = result.stdout.decode()
        self.assertEqual(result.returncode, status, text)
        return text

    def terminal(self, steps, args=(), argv=None, status=0, size=None):
        effects_before = len(self.records("effects"))
        argv = argv or [INSTALL_SH, str(SOURCE), *args]
        stem = self.capture(argv, "tty")
        pid, fd = pty.fork()
        if pid == 0:
            if size is not None:
                columns, rows = size
                fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
            os.chdir(self.case)
            os.execve(argv[0], argv, self.env)
        transcript = bytearray()
        pos = 0
        pending = list(steps)
        inputs = []
        deadline = time.monotonic() + 25
        try:
            with stem.with_suffix(".txt").open("wb") as stream:
                while time.monotonic() < deadline:
                    if not select.select([fd], [], [], 0.2)[0]:
                        continue
                    try:
                        data = os.read(fd, 65536)
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
                        break
                    if not data:
                        break
                    stream.write(data)
                    stream.flush()
                    transcript.extend(data)
                    if pending:
                        prompt, answer, *changes = pending[0]
                        index = transcript.find(prompt.encode(), pos)
                        if index >= 0:
                            pending.pop(0)
                            pos = index + len(prompt)
                            if size is not None and not inputs:
                                actual = os.get_terminal_size(fd)
                                self.assertEqual(tuple(actual), size)
                                stem.with_suffix(".size").write_text(f"{actual.columns}x{actual.lines}\n")
                                stem.with_suffix(".opening").write_bytes(transcript)
                            inputs.append({"prompt": prompt, "keys": answer,
                                           "effectsSoFar": len(self.records("effects"))})
                            if changes:
                                change = changes[0]
                                if callable(change):
                                    change()
                                else:
                                    columns, rows = change
                                    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
                            os.write(fd, answer.encode())
                else:
                    os.killpg(pid, signal.SIGKILL)
                    self.fail(f"terminal timed out waiting for {pending!r}: {stem}")
        finally:
            os.close(fd)
            _, child_status = os.waitpid(pid, 0)
            code = os.waitstatus_to_exitcode(child_status)
            stem.with_suffix(".exit").write_text(str(code) + "\n")
            stem.with_suffix(".keys").write_text(json.dumps(inputs, indent=2) + "\n")
        view = transcript.decode().replace("\r\n", "\n")
        self.assertFalse(pending, f"missing keyboard prompt: {pending}: {view}")
        self.assertEqual(code, status, view)
        review_inputs = [row for row in inputs if not row["prompt"].startswith(("Finish [", "Restart this PC now"))]
        self.assertTrue(all(row["effectsSoFar"] == effects_before for row in review_inputs), inputs)
        return view

    def no_changes(self):
        self.assertEqual([], self.records("effects"))
        self.assertEqual([], self.records("privilege"))
        self.assertEqual([], list((self.case / "tmp").iterdir()))
        self.assertFalse((self.case / "data/flatpak").exists())
        self.assertEqual((self.case / "pacman.conf").read_text(), "[core]\n")

    def test_quit_before_apply(self):
        view = self.terminal([(CHOOSER, "3\n"), (REVIEW, "d\n"), (REVIEW, "q\n")])
        compact = view.split(REVIEW, 1)[0]
        self.assertIn("\nDo both\n", compact)
        self.assertIn("Administrator access", compact)
        self.assertIn("Your account", compact)
        self.assertNotIn("$ sudo", compact)
        self.assertNotIn("Host manager:", compact)
        self.assertIn("Nothing was changed.", view)
        self.assertIn("sudo dnf install -y polaris", view)
        self.assertIn(APP + "stable", view)
        self.no_changes()

    def test_arrow_only_host_options_review_and_cancel(self):
        down = "\x1b[B"
        up = "\x1b[A"
        opts = "Host options [Enter ="
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        view = self.terminal([
            (CHOOSER, "\n"), (REVIEW, "\n"),
            (opts, "\n"), (opts, down + " "), (opts, down + "\n"),
            (REVIEW, down * 2 + "\n"), (REVIEW, up + "\n"),
        ], args=["--reduced-motion"], size=(80, 24))
        self.assertIn("[x] Capture the host display (KMS)", view)
        self.assertIn("[x] Start Polaris before sign-in", view)
        self.assertIn("Enter = Apply.", view)
        self.assertIn("Enable KMS capture. Grant this user monitor access with a signed helper.", view)
        self.assertIn("Start Polaris before sign-in. Keep user services", view)
        self.assertIn("Nothing was changed.", view)
        self.no_changes()

    def test_piped_inline_checkboxes_keep_one_panel_and_both_choices(self):
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pipe = [INSTALL_SH, "-c", '/bin/cat "$1" | "$2"', "installer", str(SOURCE), INSTALL_SH]
        down = "\x1b[B"
        view = self.terminal([(CHOOSER, "\n\n " + down + " " + down + "\nq\n")],
                             argv=pipe, size=(80, 24))
        self.assertEqual(view.count("\nHost options\n"), 1)
        # At the bottom row a newline before a checkbox repaint would scroll the menu.
        footer = r"Space Toggle   Enter Select(?:\x1b\[K)?"
        self.assertRegex(view, footer + r"\r\x1b\[\d+A")
        self.assertNotRegex(view, footer + r"\n\r\x1b\[\d+A")
        self.assertIn("[x] Capture the host display (KMS)", view)
        self.assertIn("[x] Start Polaris before sign-in", view)
        self.assertIn("Let Polaris capture the monitor connected to this PC. You can enable it later.", view)
        self.assertIn("Enable KMS capture. Grant this user monitor access with a signed helper.", view)
        # The first review and its help both fit above the menu at 80x24.
        self.assertRegex(view, r"(?:\x1b\[A\x1b\[K){10,}\n\x1b\[1;36mStream games from this PC")
        self.assertIn("Start Polaris before sign-in. Keep user services", view)
        self.assertNotIn("Already on", view)
        self.assertIn("Nothing was changed.", view)
        self.assertNotIn("\x1b[?1049h", view)
        self.no_changes()

    def test_host_options_discard_and_switch_to_player(self):
        opts = "Host options [Enter ="
        view = self.terminal([
            (CHOOSER, "3\n"), (REVIEW, "o\n"), (opts, "2\n"), (opts, "b\n"),
            (REVIEW, "o\n"), (opts, "1\n"), (opts, "3\n"),
            (REVIEW, "b\n"), (CHOOSER, "2\n"), (REVIEW, "a\n"),
        ], args=["--plain"])
        self.assertIn("[x] Start Polaris before sign-in", view)
        self.assertIn("[x] Capture the host display (KMS)", view)
        self.assertNotIn("Start Polaris before sign-in. Keep user services", view)
        self.assertIn("Nova installation verified", view)
        self.assertEqual([], self.records("privilege"))

    def test_known_host_status_is_separate_from_this_runs_checkboxes(self):
        self.env["FIXTURE_HOST_STATUS"] = "Waiting for sign-in|Already on"
        view = self.terminal([(CHOOSER, "\n"), (REVIEW, "\n"),
                              ("Host options [Enter =", "3\n"), (REVIEW, "q\n")], args=["--plain"])
        self.assertIn("[ ] Capture the host display (KMS)  - Waiting for sign-in", view)
        self.assertIn("[ ] Start Polaris before sign-in  - Already on", view)
        self.assertNotIn("Enable KMS capture.", view)
        self.assertNotIn("Start Polaris before sign-in. Keep user services", view)
        self.no_changes()

    def waiting_kms_job(self):
        # Exercise the real review, lock and entry writer in a private account,
        # including when the fixture suite itself runs in a root CI container.
        self.change(ostree=True, packages={**ORIGINAL["packages"], "polaris": "1.5.0-1", "polaris-kms": "1.5.0-1"})
        self.command_python.unlink()
        self.command_python.write_text(f"""#!{sys.executable}
import os, sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
if sys.argv[1:3] == ['-I', '-'] and sys.argv[3] in ('review-kms', 'cancel-kms'):
    sys.argv = sys.argv[2:]
    with patch('os.geteuid', return_value=1000), patch('pwd.getpwuid', return_value=SimpleNamespace(pw_name='player')):
        code = sys.stdin.read().replace('POLARIS = "/usr/bin/polaris"', 'POLARIS = "polaris"')
        exec(compile(code, '<stdin>', 'exec'), {{'__name__': '__main__', '__file__': '<stdin>'}})
elif sys.argv[3:4] == ['finish-kms']:
    Path(os.environ['FIXTURE'], 'finish-request-token').write_text(sys.argv[4])
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
""")
        self.command_python.chmod(0o755)
        deployment = "b" * 64
        state = self.case / "home/.local/state/polaris-installer"
        state.mkdir(parents=True)
        (state / "finish.lock").touch()
        helper = state / "finish-host.py"
        source = SOURCE.read_text().split("<<'POLARIS_FINISH'\n", 1)[1].split("\nPOLARIS_FINISH\n", 1)[0]
        helper.write_text(source + "\n")
        helper.chmod(0o700)
        job = self.case / "config/autostart/com.papiux.PolarisInstaller.desktop"
        job.parent.mkdir()
        plan = dict(uid=1000, account="player", kms=True, headless=False,
                    wait_update={"osname": "default", "checksum": deployment})
        job.write_text("[Desktop Entry]\nType=Application\nName=Finish Polaris Setup\n"
                       f'Exec=/usr/bin/python3 -I "{helper}" login {deployment} 1\n'
                       f"Terminal=true\nX-Polaris-Installer=true\nX-Polaris-Deployment={deployment}\n"
                       f"X-Polaris-Setup={json.dumps(plan, separators=(',', ':'))}\n"
                       f"X-Polaris-Helper-SHA256={hashlib.sha256(helper.read_bytes()).hexdigest()}\n")
        job.chmod(0o600)
        return job, helper

    def test_piped_host_review_keeps_or_cancels_the_saved_kms_request_using_arrows(self):
        job, helper = self.waiting_kms_job()
        before = [p.read_bytes() for p in (job, helper)]
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pipe = [INSTALL_SH, "-c", '/bin/cat "$1" | "$2"', "installer", str(SOURCE), INSTALL_SH]
        down, enter = "\x1b[B", "\n"
        # Host review focuses Host options. Cancel request follows it. The
        # second panel defaults to Keep. Quit after returning to the review.
        view = self.terminal([(CHOOSER, enter + down + enter + enter + "q\n")], argv=pipe, size=(80, 24))
        self.assertIn("Waiting for a compatible Polaris update", view)
        self.assertIn("Keep request", view)
        self.assertEqual([p.read_bytes() for p in (job, helper)], before)
        self.no_changes()
        view = self.terminal([(CHOOSER, enter + down + enter + down + enter)], argv=pipe, size=(80, 24))
        self.assertIn("Saved KMS request cancelled.", view)
        self.assertFalse(job.exists() or helper.exists())
        self.no_changes()

    def test_cancel_confirmation_keeps_a_concurrently_replaced_login_request(self):
        job, helper = self.waiting_kms_job()
        before = job.read_bytes()
        def replace_request():
            new = job.with_suffix(".new")
            new.write_bytes(before)
            new.replace(job)
        view = self.terminal([(CHOOSER, "\n"), (REVIEW, "x\n"), ("KMS request [", "x\n", replace_request),
                              (REVIEW, "q\n")], args=["--plain"])
        self.assertIn("request changed", view)
        self.assertEqual(job.read_bytes(), before)
        self.assertTrue(helper.exists())
        self.no_changes()

    def test_compatible_update_offers_the_saved_request_in_the_normal_host_menu(self):
        self.waiting_kms_job()
        self.change(boot_fields={"checksum": "c" * 64}, image_userdb=True)
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        # The completion suite drives the native setup after this handoff.
        view = self.terminal([(CHOOSER, "\n\x1b[B\n")], size=(80, 24))
        self.assertIn("KMS capture is ready", view)
        self.assertIn("Finish request", view)
        self.assertNotIn("Waiting for a compatible Polaris update", view)
        self.assertRegex((self.case / "finish-request-token").read_text(), r"^[0-9a-f]{64}$")
        self.no_changes()

    def test_piped_arrow_keys_reach_both_desktop_finish_actions(self):
        self.finish_desktop(ready=True)
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pipe = [INSTALL_SH, "-c", '/bin/cat "$1" | "$2" -s -- --channel beta',
                "installer", str(SOURCE), INSTALL_SH]
        up, down = "\x1b[A", "\x1b[B"
        # Both, Apply, Open Polaris, then Open Nova. The second menu starts on Done.
        keys = down * 2 + "\n" + up + "\n" + down + "\n" + up + "\n"
        view = self.terminal([(CHOOSER, keys)], argv=pipe, size=(80, 24))
        self.assertIn("Nova installation verified", view)
        self.assertIn("Polaris console ready: https://127.0.0.1:50801/", view)
        self.assertEqual(self.records("launches"), [
            ["xdg-open", "https://127.0.0.1:50801/"],
            ["flatpak", "run", "--user", APP + "beta", "--standalone"],
        ])

    def test_player_review_and_details_return_to_apply(self):
        self.finish_desktop()
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pipe = [INSTALL_SH, "-c", '/bin/cat "$1" | "$2"', "installer", str(SOURCE), INSTALL_SH]
        down = "\x1b[B"
        view = self.terminal([(CHOOSER, down + "\n"), ("> [a]  Apply", down + "\n"),
                              ("> [a]  Apply", "\n\n")], argv=pipe, size=(80, 24))
        self.assertEqual(view.count("Host manager:"), 1)
        self.assertIn("Nova installation verified", view)
        self.assertNotIn("Nova process: absent", view)
        self.assertEqual(self.records("launches"), [["flatpak", "run", "--user", APP + "stable", "--standalone"]])
        self.assertEqual(self.records("privilege"), [])

    def test_player_removal_starts_on_details(self):
        view = self.terminal([(REVIEW, "\n"), (REVIEW, "q\n")],
                             args=["--role", "client", "--uninstall", "--plain"])
        self.assertIn("Enter = View details.", view)
        self.assertIn("Host manager:", view)
        self.no_changes()

    def test_review_distinguishes_plan_actions_and_navigation(self):
        self.change(packages={"unrelated": "7", "polaris": "1.5.0-1"})
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        for width, args in ((80, []), (65, []), (37, ["--plain"])):
            with self.subTest(width=width):
                view = self.terminal([(REVIEW, "q\n")], args=["--role", "host", *args], size=(width, 24))
                text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", view)
                self.assertRegex(text.replace("\n    ", " "), r"[•-] Check for updates to the installed host \(1\.5\.0-1\)")
                focus = "  " if args else "> "
                self.assertIn("optional.\n\nChoose an action\n"
                              f"  [a]  Apply\n{focus}[o]  Host options\n  [d]  View details\n\n"
                              "  [b]  Back to roles\n  [q]  Quit\n", text)
                if args:
                    self.assertNotIn("\x1b", view)
                    self.assertIn("  - Check for updates to the\n    installed host (1.5.0-1).", text)
                self.no_changes()

    def test_plain_review_announces_what_enter_will_select(self):
        self.env.update(TERM="xterm-256color", NO_COLOR="1", LC_ALL="C.UTF-8")
        view = self.terminal([("Enter = Host options.", "\x1b[B"), ("Enter = View details.", "\n"),
                              ("Host manager:", "q\n")], args=["--role", "host"], size=(72, 16))
        self.assertNotIn("> [", view)
        self.assertEqual(view.count("Host manager:"), 1)
        self.assertIn("Nothing was changed.", view)
        self.no_changes()

    def test_shrinking_review_keeps_every_shortcut_and_current_choice(self):
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        view = self.terminal([("or letter, then Enter", "\x1b[B", (37, 13)),
                              ("Enter = View details.", "q\n")], args=["--role", "host"], size=(80, 24))
        narrow = view.split("or letter, then Enter", 1)[1]
        self.assertIn("  [d]  View details", narrow)
        self.assertNotIn("> [", narrow)
        self.assertEqual(narrow.count("[q]  Quit"), 1)
        self.no_changes()

    def test_fitting_combined_review_replaces_the_host_options_help(self):
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        view = self.terminal([("> [o]  Host options", "\n"), ("Space Toggle", "d\n"),
                              ("> [a]  Apply", "q\n")], args=["--role", "both"], size=(80, 24))
        # The chooser and its help are retired before the combined review is redrawn.
        self.assertRegex(view, r"(?:\x1b\[A\x1b\[K){12,}\n\x1b\[1;36mDo both")
        self.no_changes()

    def test_host_review_preserves_details_and_wrapped_rows(self):
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        for width, open_details in ((64, False), (80, True)):
            with self.subTest(width=width, open_details=open_details):
                keys = "\n" + ("d\n" if open_details else "") + "o\n3\nq\n"
                view = self.terminal([(CHOOSER, keys)], size=(width, 24))
                self.assertNotRegex(view, r"(?:\x1b\[A\x1b\[K){10,}")
                self.assertIn("Nothing was changed.", view)
        self.no_changes()

    def test_resize_at_host_options_done_preserves_scrollback(self):
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        view = self.terminal([(CHOOSER, "\n\n"), ("Space Toggle   Enter Select", "d\n", (37, 13)),
                              (REVIEW, "q\n")], size=(80, 24))
        self.assertNotRegex(view, r"(?:\x1b\[A\x1b\[K){10,}")
        self.assertIn("Enter = Apply.", view)
        self.no_changes()

    def test_explicit_host_options_reject_incompatible_invocations(self):
        for flag in ("--enable-kms", "--enable-headless-boot"):
            for args in (("--role", "client"), ("--uninstall",), ("--no-setup",)):
                with self.subTest(flag=flag, args=args):
                    self.assertIn("Host options require", self.run_cli("--yes", flag, *args, status=1))
        self.change(uid=0)
        self.assertIn("desktop user", self.run_cli("--yes", "--enable-kms", status=1))
        self.no_changes()

    def test_select_start_before_sign_in_and_apply_with_enter(self):
        # The completion suite exercises real helper logic at this boundary.
        python = self.command_python
        python.unlink()
        python.write_text(f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
if len(sys.argv) > 2 and sys.argv[2].endswith('/finish-host.py'):
    Path(os.environ['FIXTURE'], 'finish-args.json').write_text(json.dumps(sys.argv[3:]))
    print('Polaris is set to start before sign-in for player.')
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
""")
        python.chmod(0o755)
        down = "\x1b[B"
        opts = "Host options [Enter ="
        view = self.terminal([
            (CHOOSER, "\n"), (REVIEW, "\n"), (opts, down + "\n"),
            (opts, down + "\n"), (REVIEW, "\n"),
        ], args=["--plain"])
        args = json.loads((self.case / "finish-args.json").read_text())
        self.assertEqual(args[0], "options-now")
        self.assertEqual(args[6:9], ["0", "1", "dnf"])
        self.assertNotIn("polaris-kms", self.state["packages"])
        self.assertNotIn("polaris (in your desktop session)", view)
        self.assertNotIn("\nOptional:\n", view)

    def mascot_frame(self, args=(), size=(80, 24), prompt="Choose a role [1/2/3, Enter = host, q = quit]: ",
                     argv=None, review=False):
        steps = [(prompt, "1\n"), (REVIEW, "q\n")] if review else [(prompt, "q\n")]
        self.assertIn("Nothing was changed.", self.terminal(steps, args, argv, size=size))
        self.no_changes()
        raw = (self.case / f"{self.invocations:02d}-tty.opening").read_bytes()
        self.assertTrue(raw.endswith(prompt.encode()))
        return raw.decode().replace("\r\n", "\n")

    def assert_mascot_trace(self, frame):
        # Pin the complete 25 x 11 cell trace of Polaris/polaris.png at b0fc120.
        # A label or a different drawing would lose the hand, visor/eyes or tail.
        plain = re.sub(r"\x1b\[[0-9;]*m", "", frame)
        rows = [line for line in plain.splitlines() if re.search(r"[\u2800-\u28ff]", line)]
        self.assertEqual(len(rows), 11, "the opening frame must show the traced Polaris figure")
        trace = "\n".join(rows) + "\n"
        self.assertIn(trace, plain[:plain.index("  1  Stream games from this PC")])
        self.assertEqual(hashlib.sha256(trace.encode()).hexdigest(),
                         "23889d780de29f095d73ec27c13dd756b9cfa5eb3852b76af856230c00ad22d1")
        self.assertNotIn("\x1b", plain)
        self.assertNotIn("\r", plain)

    def test_mascot_in_opening_role_frame(self):
        self.env.update(TERM="xterm-256color", LC_ALL="en_US.UTF-8")
        self.assert_mascot_trace(self.mascot_frame(prompt="Choose a role   ↑/↓ Move   Enter Select"))

    def test_mascot_plain_role_frames(self):
        for args, env in [(["--plain"], {}), (["--no-color"], {}), ([], {"NO_COLOR": "1"}),
                          ([], {"TERM": "dumb"}), ([], {"LC_ALL": "C"})]:
            with self.subTest(args=args, env=env):
                self.env.update(TERM="xterm-256color", LC_ALL="en_US.UTF-8")
                self.env.pop("NO_COLOR", None)
                self.env.update(env)
                frame = self.mascot_frame(args)
                self.assertIn("Polaris raises a hand.\n\n  1  Stream games from this PC - Polaris", frame)
                self.assertTrue(frame.isascii())
                if self.env["LC_ALL"] != "C":
                    self.assertNotIn("\x1b", frame)

    def test_mascot_narrow_role_frames(self):
        self.env.update(TERM="xterm-256color", LC_ALL="en_US.UTF-8")
        for columns in (24, 39, 40):
            with self.subTest(columns=columns):
                frame = self.mascot_frame(size=(columns, 14), prompt="Choose a role [1/2/3]: ", review=True)
                self.assertTrue(frame.endswith("Enter = host, q = quit\nChoose a role [1/2/3]: "))
                if columns == 40:
                    self.assert_mascot_trace(frame)
                else:
                    self.assertIn("Polaris raises a hand.", frame)
                    self.assertNotRegex(frame, r"[\u2800-\u28ff]")
                options = frame[frame.index("  1  "):]
                self.assertTrue(all(len(line) <= columns for line in options.splitlines()), options)
                if columns == 24:
                    self.assertIn("  1  Stream games from\n     this PC\n     Polaris", options)
                    self.assertIn("  2  Play games from\n     another PC\n     Nova", options)
                self.assertIn("  3  Do both", options)

    def test_mascot_reduced_motion_in_piped_role_frame(self):
        self.env.update(TERM="xterm-256color", LC_ALL="en_US.UTF-8")
        argv = [INSTALL_SH, "-c", '/bin/cat "$1" | "$2" -s -- --reduced-motion', "fixture", str(SOURCE), INSTALL_SH]
        self.assert_mascot_trace(self.mascot_frame(argv=argv, review=True))
        self.env["REDUCE_MOTION"] = "1"
        self.assert_mascot_trace(self.mascot_frame(review=True))

    def test_piped_entrypoint_edit_back_and_apply_both(self):
        # Same stdin topology as curl | sh. cat only supplies checked-in bytes.
        self.env.update(NO_COLOR="1", TERM="xterm-256color")
        view = self.terminal([(CHOOSER, "3\n"), (REVIEW, "d\n"), (REVIEW, "h\n"), (REVIEW, "b\n"),
                              (CHOOSER, "2\n"), (REVIEW, "c\n"), (REVIEW, "b\n"),
                              (CHOOSER, "3\n"), (REVIEW, "a\n")],
                             argv=[INSTALL_SH, "-c", '/bin/cat "$1" | "$2"', "fixture", str(SOURCE), INSTALL_SH])
        for label in ("Polaris raises a hand.", "Fedora Linux 45", "KDE Plasma Desktop", "Desktop: KDE",
                      "Host manager: dnf", "Manual player:", "Stream games from this PC", "Play games from another PC",
                      "User Flatpak (no sudo)", "Installed Polaris", "Installed Nova beta", "Manage this host",
                      "Open Nova: flatpak run --user " + APP + "beta --standalone"):
            self.assertIn(label, view)
        self.assertNotIn("\x1b", view)
        self.assertNotIn(["polaris", "--setup-host"], self.records("effects"))
        self.assertIn(APP + "beta", self.state["refs"])
        self.assertNotIn(APP + "stable", self.state["refs"])
        self.assertEqual(self.state["packages"]["polaris"], "1.5.0-1")
        self.assertEqual(1, len(list((self.case / "tmp").iterdir())))

    def test_client_only_on_ubuntu_without_sudo(self):
        self.os_file.write_text('ID=ubuntu\nVERSION_ID=24.04\n')
        (self.bin / "sudo").unlink()
        view = self.terminal([(CHOOSER, "1\n"), (CHOOSER, "2\n"), (REVIEW, "a\n")])
        self.assertIn("there is no guided repository here", view)
        self.assertIn("Installed Nova stable", view)
        self.assertNotIn("Installing Polaris", view)
        self.assertEqual([], self.records("privilege"))
        self.assertNotIn("polaris", self.state["packages"])

    def test_player_on_opensuse_without_awk(self):
        self.os_file.write_text('ID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\nPRETTY_NAME="openSUSE Tumbleweed"\n')
        (self.bin / "awk").unlink()
        before = self.run_cli("--role", "client", "--dry-run")
        self.assertIn("openSUSE Tumbleweed", before)
        self.assertEqual([], self.records("effects"))
        self.assertIn("Installed Nova stable", self.run_cli("--role", "client"))
        self.assertIn("already installed", self.run_cli("--role", "client"))
        self.assertIn("Removed " + APP + "stable", self.run_cli("--yes", "--uninstall", "--role", "client"))
        self.assertEqual([], self.records("privilege"))

    def test_legacy_unattended_host_then_upgrade_then_installed(self):
        self.assertIn("Installed Polaris 1.5.0-1.", self.run_cli())
        self.assertIn(["polaris", "--setup-host"], self.records("effects"))
        self.change(packages={"polaris": "1.4.0-1", "polaris-kms": "1.4.0-1", "unrelated": "7"})
        self.assertIn("Upgraded Polaris from 1.4.0-1 to 1.5.0-1.", self.run_cli("--no-setup"))
        self.assertIn(["dnf", "upgrade", "-y", "polaris", "polaris-kms"], self.records("effects"))
        self.assertIn("already installed", self.run_cli("--no-setup"))
        self.assertFalse(any(cmd[0] == "flatpak" for cmd in self.records("calls")))

    def test_client_fresh_update_installed_and_remove(self):
        self.assertIn("Installed Nova stable", self.run_cli("--role", "client"))
        refs = self.state["refs"]
        refs[APP + "stable"][1] = "b" * 64
        refs[APP + "beta"] = ["nova", "c" * 64]
        self.change(refs=refs)
        self.assertIn("Updated Nova stable", self.run_cli("--role", "client"))
        self.assertIn("Nova stable was already installed", self.run_cli("--role", "client"))
        offset = len(self.records("effects"))
        self.assertIn("Removed " + APP + "stable", self.run_cli("--yes", "--uninstall", "--role", "client"))
        self.assertEqual(self.records("effects")[offset:],
                         [["flatpak", "uninstall", "--user", "--noninteractive", "--no-related", APP + "stable"]])
        self.assertIn("already absent", self.run_cli("--yes", "--uninstall", "--role", "client"))
        self.assertIn(APP + "beta", self.state["refs"])
        self.assertIn(RUNTIME, self.state["refs"])
        self.assertEqual([], self.records("privilege"))

    def test_uninstall_apply_never_upgrades(self):
        self.change(packages={"polaris": "old", "polaris-kms": "old", "unrelated": "7"})
        view = self.terminal([(CHOOSER, "\n"), (REVIEW, "\n"), (REVIEW, "a\n")], args=["--uninstall"])
        self.assertIn("\nStream games from this PC\n", view)
        self.assertIn("Remove polaris polaris-kms. Keep settings, pairing and library.", view)
        self.assertEqual([["rpm", "-e", "polaris", "polaris-kms"]], self.records("effects"))
        self.assertEqual({"unrelated": "7"}, self.state["packages"])

    def test_uninstall_preserves_dependent_packages(self):
        self.change(packages={"polaris": "old", "unrelated": "7"}, dependent=True)
        self.assertIn("status 11", self.run_cli("--uninstall", "--yes", status=11))
        self.assertIn("polaris", self.state["packages"])
        self.assertEqual([["rpm", "-e", "polaris"]], self.records("effects"))

    def test_unattended_remove_needs_confirmation(self):
        self.assertIn("requires --yes", self.run_cli("--uninstall", status=1))
        self.no_changes()

    def test_arch_remove_exact_targets(self):
        self.os_file.write_text("ID=cachyos\nID_LIKE=arch\n")
        self.change(packages={"polaris": "old", "unrelated": "7"})
        self.run_cli("--yes", "--uninstall")
        self.assertEqual([["pacman", "-R", "--noconfirm", "polaris"]], self.records("effects"))

    def test_unsupported_arch_and_distro(self):
        self.change(arch="aarch64")
        for role in ("host", "client", "both"):
            self.assertIn("x86_64", self.run_cli("--role", role, "--dry-run", status=1))
        self.change(arch="x86_64")
        self.os_file.write_text("ID=fedora\nVERSION_ID=46\n")
        self.assertIn("Fedora 44 and 45 only", self.run_cli(status=1))
        self.os_file.write_text("ID=steamos\nID_LIKE=arch\n")
        self.assertIn("/docs/steamos/", self.run_cli(status=1))
        self.no_changes()

    def test_root_or_missing_flatpak_cannot_select_client(self):
        self.change(uid=0)
        self.assertIn("desktop user", self.run_cli("--role", "both", status=1))
        self.change(uid=1000)
        (self.bin / "flatpak").unlink()
        self.assertIn("flatpak is unavailable", self.run_cli("--role", "both", status=1))
        self.no_changes()

    def test_dry_run_both_ref_and_commands_only(self):
        self.env.update(TERM="xterm-256color", LC_ALL="en_US.UTF-8")
        view = self.run_cli("--dry-run", "--role", "both", "--channel", "beta")
        self.assertIn("sudo -n dnf install -y polaris", view)
        self.assertIn("flatpak install --user --noninteractive --no-deps --no-related nova " + APP + "beta", view)
        self.assertNotIn("Installed Nova", view)
        self.assertNotIn("Nova installation verified", view)
        self.assertNotIn(CHOOSER, view)
        self.assertNotIn("Polaris raises a hand.", view)
        self.assertNotRegex(view, r"[\u2800-\u28ff]")
        self.no_changes()

    def test_partial_both_stops_after_host_success(self):
        self.change(fail=["flatpak", "install"])
        view = self.terminal([(CHOOSER, "3\n"), (REVIEW, "a\n")], status=23)
        self.assertIn("Both stopped during the Nova step. Polaris: installed 1.5.0-1.", view)
        self.assertEqual("1.5.0-1", self.state["packages"]["polaris"])
        self.assertIn("nova", self.state["remotes"])
        self.assertNotIn(APP + "stable", self.state["refs"])
        self.assertNotIn("Installed Nova", view)
        self.assertNotIn("Nova installation verified", view)
        self.assertNotIn("Open Nova:", view)

    def test_both_first_command_failure_leaves_client_unattempted(self):
        self.change(fail=["dnf", "install"])
        view = self.run_cli("--role", "both", status=23)
        self.assertIn("Nova was not attempted", view)
        self.assertNotIn("polaris", self.state["packages"])
        self.assertFalse(any(cmd[0] == "flatpak" for cmd in self.records("effects")))

    def test_polaris_key_mismatch_before_import(self):
        self.change(rpm_fingerprint="9" * 40)
        self.assertIn("has fingerprint", self.run_cli(status=1))
        self.assertEqual(["curl"], [cmd[0] for cmd in self.records("effects")])
        self.assertFalse((self.case / "polaris.repo").exists())

    def test_modified_descriptor_rejected_before_flatpak(self):
        self.change(bad_descriptor=True)
        self.assertIn("checksum mismatch", self.run_cli("--role", "client", status=1))
        self.assertEqual(["curl"], [cmd[0] for cmd in self.records("effects")])

    def test_existing_nova_remote_trust(self):
        self.run_cli("--role", "client")
        n = len(self.records("effects"))
        repo = self.case / "data/flatpak/repo"
        config = repo / "config"
        original = config.read_text()
        for changed in (
                original.replace("gpg-verify=true", "gpg-verify=true\ngpg-verify=true"),
                original.replace('[remote "nova"]', '[remote "nova"]\n[remote "nova"]'),
                original.replace("gpg-verify=true", "gpg-verify=true\nunexpected-setting=true")):
            config.write_text(changed)
            self.assertIn("signature checks", self.run_cli("--role", "client", status=1))
        config.write_text(original.replace("gpg-verify-summary=true", "gpg-verify-summary=false"))
        self.assertIn("signature checks", self.run_cli("--role", "client", status=1))
        config.write_text(original)
        (repo / "nova.trustedkeys.gpg").write_bytes(b"other keyring")
        self.assertIn("keyring", self.run_cli("--role", "client", status=1))
        self.assertEqual(n, len(self.records("effects")))

    def test_missing_package_readback_is_failure(self):
        self.change(missing_app=True)
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        view = self.terminal([(CHOOSER, "2\na\n")], status=1)
        self.assertIn("could not be verified", view)
        self.assertNotIn("✦", view)
        self.assertNotIn("Nova installation verified", view)
        self.assertNotIn("Open Nova:", view)

    def capture_package_completion(self):
        # Package tests stop at the real installer's handoff to the separate
        # account setup suite. Inventory Python still runs normally.
        python = self.command_python
        python.unlink()
        python.write_text(f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
if len(sys.argv) > 2 and Path(sys.argv[2]).name == 'finish-host.py':
    with (Path(os.environ['FIXTURE']) / 'completion').open('a') as log:
        print(json.dumps(sys.argv[3:5]), file=log)
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
""")
        python.chmod(0o755)

    def test_kms_packages_fedora_fresh_existing_and_upgrade(self):
        self.capture_package_completion()
        for installed, action in [({}, "install"), ({"polaris": "1.4.13-1"}, "install"),
                                  ({"polaris": "1.4.13-1", "polaris-kms": "1.4.13-1"}, "upgrade")]:
            with self.subTest(installed=installed):
                self.change(packages={"unrelated": "7", **installed})
                offset = len(self.records("effects"))
                view = self.run_cli("--role", "host", "--enable-kms")
                transactions = [c for c in self.records("effects")[offset:] if c[0] == "dnf"]
                self.assertEqual(transactions, [["dnf", action, "-y", "--from-repo=polaris", "--no-allow-downgrade",
                                                 "polaris", "polaris-kms"]])
                self.assertIn("Verified polaris and polaris-kms at 0:1.5.0-1.x86_64", view)
                self.assertEqual(self.state["packages"], {"unrelated": "7", "polaris": "1.5.0-1", "polaris-kms": "1.5.0-1"})
        self.assertIn("gpgcheck=1\nrepo_gpgcheck=1\n", (self.case / "polaris.repo").read_text())

    def test_kms_packages_arch_and_cachyos_full_upgrade(self):
        self.capture_package_completion()
        for distro, installed, targets in [
                ("arch", {}, ["--needed", "polaris/polaris", "polaris/polaris-kms"]),
                ("cachyos", {"polaris": "1.4.13-1"}, ["--needed", "polaris/polaris>=1.4.13-1", "polaris/polaris-kms"]),
                ("arch", {"polaris": "1.4.13-1", "polaris-kms": "1.4.13-1"}, [])]:
            with self.subTest(distro=distro, installed=installed):
                self.os_file.write_text(f"ID={distro}\nID_LIKE=arch\n")
                self.change(packages={"unrelated": "7", **installed})
                offset = len(self.records("effects"))
                view = self.run_cli("--role", "host", "--enable-kms")
                self.assertIn("Verified polaris and polaris-kms at 1.5.0-1", view)
                self.assertEqual([c for c in self.records("effects")[offset:] if c[0] == "pacman"],
                                 [["pacman", "-Syu", "--noconfirm", *targets]])
                self.assertEqual(self.state["packages"]["polaris-kms"], self.state["packages"]["polaris"])
        self.assertIn("SigLevel = Required DatabaseRequired", (self.case / "pacman.conf").read_text())

    def test_kms_packages_readback_blocks_setup_and_player(self):
        self.capture_package_completion()
        for distro in ("fedora", "arch"):
            self.os_file.write_text(f"ID={distro}\nVERSION_ID=45\n")
            for helper in (None, "1:1.5.0-1"):
                with self.subTest(distro=distro, helper=helper):
                    transaction = {"polaris": "1.5.0-1"}
                    if helper:
                        transaction["polaris-kms"] = helper
                    self.change(packages={"unrelated": "7"}, transaction_packages=transaction)
                    view = self.run_cli("--role", "both", "--enable-kms", status=1)
                    self.assertIn("Host setup was skipped", view)
                    self.assertIn("Nova was not attempted", view)
                    self.assertEqual(self.records("completion"), [])
                    self.assertNotIn(APP + "stable", self.state["refs"])

    def test_kms_packages_dry_run_preserves_system(self):
        for distro, ostree, command in [
                ("fedora", False, "dnf install -y --from-repo=polaris --no-allow-downgrade polaris polaris-kms"),
                ("fedora", True, "rpm-ostree install --idempotent polaris polaris-kms"),
                ("arch", False, "pacman -Syu --noconfirm --needed polaris/polaris polaris/polaris-kms")]:
            with self.subTest(distro=distro, ostree=ostree):
                self.os_file.write_text(f"ID={distro}\nVERSION_ID=45\n")
                self.change(ostree=ostree)
                self.assertIn(command, self.run_cli("--role", "host", "--enable-kms", "--dry-run"))
                self.no_changes()

    def test_atomic_host_without_python_refuses_install_before_apply(self):
        self.change(ostree=True)
        # Keep the simulated system commands executable when Python is absent from PATH.
        boundary = self.case / "command.py"
        boundary.write_text(BOUNDARY.read_text().replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
        boundary.chmod(0o755)
        for command in self.bin.iterdir():
            if command.is_symlink() and command.resolve() == BOUNDARY:
                command.unlink()
                command.symlink_to(boundary)
        (self.bin / "python3").unlink()
        view = self.run_cli("--role", "host", "--yes", "--no-setup", status=1)
        self.assertIn("Python 3 is required to check the rpm-ostree deployment", view)
        self.assertEqual([], self.records("effects"))
        self.assertEqual([], self.records("privilege"))
        self.assertIn("already absent", self.run_cli("--role", "host", "--yes", "--uninstall"))

    def test_kms_packages_ostree_fresh_and_idempotent_live_pair(self):
        self.capture_package_completion()
        self.change(ostree=True, layer_packages={"runtime": "7-2"})
        view = self.run_cli("--role", "both", "--enable-kms")
        boot, target = "b" * 64, "c" * 64
        self.assertIn("polaris-1.5.0-1.x86_64 and polaris-kms-1.5.0-1.x86_64 installed on this boot", view)
        self.assertEqual(self.state["packages"], self.state["pending_packages"])
        self.assertEqual(self.state["pending"]["requested-packages"], ["polaris", "polaris-kms"])
        self.assertEqual([c for c in self.records("effects") if c[0] == "rpm-ostree"],
                         [["rpm-ostree", "install", "--idempotent", "polaris", "polaris-kms"],
                          ["rpm-ostree", "apply-live", "--target", target]])
        self.assertIn(APP + "stable", self.state["refs"])
        effects = self.records("effects")
        self.run_cli("--role", "host", "--enable-kms")
        self.assertEqual(self.records("effects"), effects)
        self.assertEqual(self.records("completion"), [["now", boot], ["now", boot]])

    def test_kms_packages_ostree_regular_present_layers_only_helper(self):
        self.capture_package_completion()
        self.change(ostree=True, packages={"unrelated": "7", "polaris": "1.5.0-1"})
        self.run_cli("--role", "host", "--enable-kms")
        self.assertEqual(self.state["pending"]["requested-packages"], ["polaris-kms"])
        self.assertEqual(self.state["packages"]["polaris-kms"], "1.5.0-1")
        self.assertEqual([c for c in self.records("effects") if c[0] == "rpm-ostree"],
                         [["rpm-ostree", "install", "--idempotent", "polaris-kms"],
                          ["rpm-ostree", "apply-live", "--target", self.state["pending"]["checksum"]]])
        self.assertEqual(self.records("completion"), [["now", "b" * 64]])

    def test_kms_packages_ostree_preserves_pending_base_requests_and_defers(self):
        self.capture_package_completion()
        self.change(packages={"unrelated": "7", "polaris": "1.5.0-1"})
        self.pending_update({"polaris": "1.5.0-1", "unrelated": "8", "player-layer": "4-1", "local-tool": "7-1"})
        self.run_cli("--role", "host", "--enable-kms")
        self.assertNotIn("polaris-kms", self.state["packages"])
        self.assertEqual(self.state["pending_packages"], {"polaris": "1.5.0-1", "polaris-kms": "1.5.0-1",
                                                         "unrelated": "8", "player-layer": "4-1", "local-tool": "7-1"})
        pending = self.state["pending"]
        self.assertEqual(pending["requested-packages"], ["player-layer", "polaris-kms"])
        self.assertEqual(pending["requested-local-packages"], ["local-tool-7-1.x86_64"])
        self.assertEqual(pending["base-checksum"], "f" * 64)
        self.assertEqual([c for c in self.records("effects") if c[0] == "rpm-ostree"],
                         [["rpm-ostree", "install", "--idempotent", "polaris-kms"]])
        effects = self.records("effects")
        self.run_cli("--role", "host", "--enable-kms")
        self.assertEqual(self.records("effects"), effects)
        self.assertEqual(self.records("completion"), [["after-reboot", pending["checksum"]]] * 2)

    def test_kms_packages_ostree_booted_or_previously_staged_pair(self):
        self.capture_package_completion()
        pair = {"polaris": "1.5.0-1", "polaris-kms": "1.5.0-1", "unrelated": "7"}
        self.change(ostree=True, packages=pair)
        self.run_cli("--role", "host", "--enable-kms")
        self.pending_update({**pair, "unrelated": "8"})
        self.run_cli("--role", "host", "--enable-kms")
        self.assertEqual(self.records("effects"), [])
        self.assertEqual(self.records("completion"), [["now", "b" * 64], ["after-reboot", "d" * 64]])

    def test_kms_packages_ostree_regular_replacement_waits_for_reboot(self):
        self.capture_package_completion()
        self.change(ostree=True, packages={"unrelated": "7", "polaris": "1.4.13-1"})
        view = self.run_cli("--role", "host", "--enable-kms")
        self.assertIn("staged for the next boot", view)
        self.assertNotIn("polaris-kms", self.state["packages"])
        self.assertEqual(self.records("completion"), [["after-reboot", "c" * 64]])
        self.assertFalse(any(c[:2] == ["rpm-ostree", "apply-live"] for c in self.records("calls")))

    def test_kms_packages_ostree_incomplete_target_or_unreviewed_changes(self):
        self.capture_package_completion()
        for changes, error in [
                ({"missing_staged_kms": True}, "without a verified staged Polaris RPM"),
                ({"layer_packages": {"polaris-kms": "1:1.5.0-1"}}, "different versions"),
                ({"stage_fields": {"requested-packages": ["polaris", "polaris-kms"]}}, "other package requests changed"),
                ({"stage_fields": {"base-checksum": "e" * 64}}, "base image"),
                ({"diff_fields": {"pkgdiff": []}}, "Could not identify a safe live target"),
                ({"switch_after_diff": True}, "deployment changed before live apply")]:
            with self.subTest(changes=changes):
                state = {**ORIGINAL, "packages": {"unrelated": "7", "polaris": "1.5.0-1"}, "ostree": True, **changes}
                (self.case / "state.json").write_text(json.dumps(state))
                self.assertIn(error, self.run_cli("--role", "both", "--enable-kms", status=1))
                self.assertNotIn("polaris-kms", self.state["packages"])
                self.assertNotIn(APP + "stable", self.state["refs"])
        self.assertFalse(any(c[:2] == ["rpm-ostree", "apply-live"] for c in self.records("calls")))
        self.assertEqual(self.records("completion"), [])

    def test_kms_packages_ostree_live_helper_mismatch_stops_setup(self):
        self.capture_package_completion()
        self.change(ostree=True, live_packages={"polaris-kms": "1:1.5.0-1"})
        view = self.run_cli("--role", "both", "--enable-kms", status=1)
        self.assertIn("could not be verified", view)
        self.assertEqual(self.records("completion"), [])
        self.assertNotIn(APP + "stable", self.state["refs"])

    def test_kms_packages_ostree_review_binds_boot_even_when_the_same_pair_is_staged(self):
        self.capture_package_completion()
        self.change(packages={"unrelated": "7", "polaris": "1.4.13-1"})
        self.pending_update({"polaris": "1.5.0-1", "polaris-kms": "1.5.0-1", "unrelated": "8"})
        view = self.terminal([(REVIEW, "a\n", lambda: self.change(packages={"unrelated": "7", "polaris": "1.4.12-1"})),
                              (REVIEW, "q\n")], args=["--role", "host", "--enable-kms"])
        self.assertIn("The plan changed", view)
        self.assertEqual(self.records("completion"), [])
        self.no_changes()

    def test_ostree_clean_install_is_live_and_signed(self):
        self.change(ostree=True, layer_packages={"runtime": "1-1"})
        view = self.run_cli("--role", "both", "--no-setup")
        self.assertEqual(self.state["packages"].get("polaris"), "1.5.0-1")
        self.assertEqual(self.state["packages"]["runtime"], "1-1")
        effects = self.records("effects")
        target = self.state["pending"]["checksum"]
        self.assertEqual([cmd for cmd in effects if cmd[0] == "rpm-ostree"],
                         [["rpm-ostree", "install", "--idempotent", "polaris"],
                          ["rpm-ostree", "apply-live", "--target", target]])
        self.assertLess(effects.index(next(cmd for cmd in effects if cmd[-1] == "/etc/yum.repos.d/polaris.repo")),
                        effects.index(["rpm-ostree", "install", "--idempotent", "polaris"]))
        repo = (self.case / "polaris.repo").read_text().splitlines()
        self.assertIn("gpgcheck=1", repo)
        self.assertIn("repo_gpgcheck=1", repo)
        self.assertIn("gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-polaris", repo)
        self.assertIn("Installed Nova stable", view)
        self.assertIn("Package only", view)
        self.assertNotIn(["polaris", "--setup-host"], effects)
        self.assertFalse(any(cmd[:2] == ["rpm", "--import"] for cmd in effects))
        self.assertTrue(all("flatpak" not in cmd for cmd in self.records("privilege")))
        self.assertIn("installed on this boot", self.run_cli("--no-setup"))
        self.assertIn("already pending", self.run_cli("--uninstall", "--yes", status=1))
        self.assertEqual(effects, self.records("effects"))

    def pending_update(self, packages):
        self.change(ostree=True, pending_packages=packages, pending={
            "booted": False, "staged": True, "osname": "default", "checksum": "d" * 64,
            "base-checksum": "f" * 64, "requested-packages": ["player-layer"],
            "requested-local-packages": ["local-tool-7-1.x86_64"],
        })

    def test_ostree_pending_update_is_kept_and_layered_offline(self):
        self.pending_update({"unrelated": "8", "player-layer": "1", "local-tool": "7-1"})
        view = self.run_cli("--no-setup")
        self.assertIn("staged for the next boot", view)
        self.assertNotIn("polaris", self.state["packages"])
        self.assertEqual(self.state["pending_packages"],
                         {"polaris": "1.5.0-1", "unrelated": "8", "player-layer": "1", "local-tool": "7-1"})
        self.assertEqual(self.state["pending"]["base-checksum"], "f" * 64)
        self.assertEqual(self.state["pending"]["requested-packages"], ["player-layer", "polaris"])
        self.assertEqual(self.state["pending"]["requested-local-packages"], ["local-tool-7-1.x86_64"])
        self.assertEqual([cmd for cmd in self.records("effects") if cmd[0] == "rpm-ostree"],
                         [["rpm-ostree", "install", "--idempotent", "polaris"]])
        effects = self.records("effects")
        self.assertIn("staged for the next boot", self.run_cli("--no-setup"))
        self.assertEqual(self.records("effects"), effects)

    def test_ostree_installed_and_staged_version_selection(self):
        self.change(ostree=True, packages={"polaris": "1.4-1", "unrelated": "7"})
        self.assertIn("polaris-1.4-1.x86_64 installed on this boot", self.run_cli("--no-setup"))
        self.pending_update({"polaris": "1.5-1", "unrelated": "8"})
        self.assertIn("polaris-1.5-1.x86_64 staged for the next boot", self.run_cli("--no-setup"))
        self.no_changes()

    def test_ostree_replacement_waits_for_reboot(self):
        self.change(ostree=True, layer_packages={"unrelated": "8"})
        self.assertIn("staged for the next boot", self.run_cli("--no-setup"))
        self.assertNotIn("polaris", self.state["packages"])
        self.assertIn("polaris", self.state["pending_packages"])
        self.assertFalse(any(cmd[:2] == ["rpm-ostree", "apply-live"] for cmd in self.records("calls")))

    def test_ostree_modified_boot_waits_for_reboot(self):
        self.change(ostree=True, boot_fields={"unlocked": "hotfix"})
        self.assertIn("staged for the next boot", self.run_cli("--no-setup"))
        self.assertNotIn("polaris", self.state["packages"])
        self.assertFalse(any(cmd[:2] == ["rpm-ostree", "apply-live"] for cmd in self.records("calls")))

    def test_ostree_unverified_stage_stops_before_live(self):
        self.change(ostree=True, missing_staged_rpm=True)
        self.assertIn("without a verified staged Polaris RPM", self.run_cli("--role", "both", status=1))
        self.assertNotIn("polaris", self.state["packages"])
        self.assertNotIn(APP + "stable", self.state["refs"])
        self.assertFalse(any(cmd[:2] == ["rpm-ostree", "apply-live"] for cmd in self.records("calls")))

    def test_ostree_concurrent_package_request_stops_before_live(self):
        self.change(ostree=True, stage_fields={"requested-packages": ["polaris", "other-layer"]})
        self.assertIn("other package requests changed", self.run_cli(status=1))
        self.assertFalse(any(cmd[:2] == ["rpm-ostree", "apply-live"] for cmd in self.records("calls")))

    def test_ostree_wrong_diff_commit_stops_before_live(self):
        self.change(ostree=True, diff_fields={"ostree-commit-to": "f" * 64})
        self.assertIn("Could not identify a safe live target", self.run_cli(status=1))
        self.assertFalse(any(cmd[:2] == ["rpm-ostree", "apply-live"] for cmd in self.records("calls")))

    def test_ostree_changed_target_stops_before_live(self):
        self.change(ostree=True, switch_after_diff=True)
        self.assertIn("deployment changed before live apply", self.run_cli(status=1))
        self.assertFalse(any(cmd[:2] == ["rpm-ostree", "apply-live"] for cmd in self.records("calls")))

    def test_ostree_live_readback_mismatch_stops_setup_and_nova(self):
        self.change(ostree=True, live_packages={"polaris": "other-2"})
        view = self.run_cli("--role", "both", status=1)
        self.assertIn("could not be verified", view)
        self.assertIn("Nova was not attempted", view)
        self.assertNotIn(["polaris", "--setup-host"], self.records("effects"))

    def test_ostree_booted_rpm_query_failure_precedes_writes(self):
        self.change(ostree=True, rpm_read_error=True)
        self.assertIn("Deployment state is unknown", self.run_cli(status=1))
        self.no_changes()

    def test_ostree_ambiguous_boot_and_active_transactions_precede_writes(self):
        boot = {"checksum": "b" * 64, "booted": True, "staged": False}
        for status in ({"deployments": [boot, boot], "transaction": None},
                       {"deployments": [boot], "transaction": ["Upgrade", "player", "/"]}):
            with self.subTest(status=status):
                self.change(ostree=True, status_json=status)
                self.assertIn("Deployment state is unknown", self.run_cli(status=1))
                self.no_changes()

    def test_ostree_keyboard_review_explains_live_and_edits_setup(self):
        self.change(ostree=True)
        view = self.terminal([(CHOOSER, "1\n"), (REVIEW, "d\n"), (REVIEW, "h\n"), (REVIEW, "q\n")])
        self.assertIn("rpm-ostree apply-live --target", view)
        self.assertIn("start the Polaris desktop service", view)
        self.assertIn("Package only", view)
        self.no_changes()

    def test_ostree_new_pending_while_reviewing_requires_new_review(self):
        self.change(ostree=True)
        view = self.terminal([(CHOOSER, "1\n"),
                              (REVIEW, "a\n", lambda: self.pending_update({"unrelated": "8"})),
                              (REVIEW, "d\n"), (REVIEW, "q\n")])
        self.assertIn("The plan changed", view)
        self.assertIn("Keep the pending deployment: " + "d" * 64, view)
        self.no_changes()

    def test_ostree_remove_waits_for_reboot(self):
        self.change(ostree=True, packages={"polaris": "old", "unrelated": "7"})
        self.assertIn("removal staged; reboot required", self.run_cli("--uninstall", "--yes"))
        self.assertIn("polaris", self.state["packages"])
        self.assertEqual([["rpm-ostree", "uninstall", "polaris"]], self.records("effects"))

    def test_ostree_failed_status_is_unknown(self):
        self.change(ostree=True, ostree_status=5)
        self.assertIn("Deployment state is unknown", self.run_cli(status=1))
        self.no_changes()

    def test_uninstall_both_keeps_other_channels_and_remotes(self):
        self.run_cli("--role", "both", "--no-setup")
        refs = self.state["refs"]
        refs[APP + "beta"] = ["nova", "e" * 64]
        self.change(refs=refs)
        remotes = self.state["remotes"]
        offset = len(self.records("effects"))
        view = self.run_cli("--uninstall", "--yes", "--role", "both")
        self.assertIn("Polaris: removed", view)
        self.assertIn("Removed " + APP + "stable", view)
        self.assertEqual(self.records("effects")[offset:],
                         [["rpm", "-e", "polaris"],
                          ["flatpak", "uninstall", "--user", "--noninteractive", "--no-related", APP + "stable"]])
        self.assertIn(APP + "beta", self.state["refs"])
        self.assertIn(RUNTIME, self.state["refs"])
        self.assertEqual(self.state["remotes"], remotes)

    def test_states_of_running_process_service_and_window(self):
        self.change(service="active", client_running=True)
        view = self.run_cli("--role", "both", "--non-interactive")
        self.assertIn("Polaris user service: active.", view)
        self.assertIn("Nova process: running", view)
        self.assertIn("branch and window unknown", view)
        self.assertIn("pairing readiness were not checked", view)
        self.assertFalse(any(c[0] == "systemctl" or c[:2] == ["flatpak", "run"]
                             for c in self.records("effects")))
        self.assertTrue(all(c[1] == "-n" for c in self.records("privilege")))

    def test_other_origin_left_alone(self):
        self.run_cli("--role", "client")
        refs = self.state["refs"]
        refs[APP + "stable"][0] = "another-source"
        self.change(refs=refs)
        offset = len(self.records("effects"))
        self.assertIn("another origin", self.run_cli("--role", "client", status=1))
        self.assertIn("another origin", self.run_cli("--role", "client", "--uninstall", "--yes", status=1))
        self.assertEqual(offset, len(self.records("effects")))

    def test_host_setup_warning_and_user_service_unknown(self):
        self.change(fail=["polaris", "--setup-host"])
        (self.bin / "systemctl").unlink()
        text = self.run_cli()
        self.assertIn("Host setup did not finish", text)
        self.assertIn("Installed Polaris", text)
        self.assertIn("Polaris user service: unknown.", text)

    def test_unattended_channel_without_client_refuses(self):
        self.assertIn("--channel requires", self.run_cli("--channel", "beta", status=1))
        self.no_changes()

    def test_review_changes_while_waiting_for_apply(self):
        def external_upgrade():
            self.change(packages={"unrelated": "7", "polaris": "old", "polaris-kms": "old"})

        view = self.terminal([(CHOOSER, "1\n"), (REVIEW, "a\n", external_upgrade), (REVIEW, "d\n"), (REVIEW, "q\n")])
        self.assertIn("The plan changed.", view)
        self.assertIn("dnf upgrade -y polaris polaris-kms", view)
        self.no_changes()

    def test_temp_path_words_match_real_command_arguments(self):
        temp = self.case / "player's temp"
        temp.mkdir()
        self.env["TMPDIR"] = str(temp)
        view = self.run_cli("--role", "client", "--dry-run")
        shown = next(line.split("$ ", 1)[1] for line in view.splitlines() if "$ curl " in line)
        words = shlex.split(shown)
        self.assertEqual(words[words.index("--output") + 1], str(temp / "nova-install.XXXXXX/nova.flatpakrepo"))
        self.assertIn("Installed Nova stable", self.run_cli("--role", "client"))
        self.assertTrue(all(p.name.startswith("polaris-install-") for p in temp.iterdir()))

    def test_no_supported_role_exits_without_keyboard(self):
        self.change(arch="riscv64")
        view = self.terminal([], status=1)
        self.assertIn("No supported role", view)
        self.assertNotIn("Choose a role", view)
        self.no_changes()

    def test_eof_cancels_review(self):
        view = self.terminal([(CHOOSER, "1\n"), (REVIEW, "\x04")])
        self.assertIn("Nothing was changed.", view)
        self.no_changes()

    def test_arch_install_upgrade_and_reboot_before_setup(self):
        self.os_file.write_text("ID=arch\n")
        self.change(kernel_missing=True)
        view = self.run_cli()
        self.assertIn("Reboot first", view)
        self.assertIn(["pacman", "-Syu", "--noconfirm", "--needed", "polaris"], self.records("effects"))
        self.assertNotIn(["polaris", "--setup-host"], self.records("effects"))
        self.run_cli("--no-setup")
        self.assertIn(["pacman", "-Syu", "--noconfirm"], self.records("effects"))

    def test_quit_with_plain_output_and_reduced_motion(self):
        self.env.update(TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
        view = self.terminal([(CHOOSER, "q\n")], args=["--plain", "--reduced-motion"])
        self.assertNotIn("\x1b", view)
        self.assertNotIn("\r", view)
        self.no_changes()

    def test_reduced_motion_preserves_keyboard_and_static_progress(self):
        self.env.update(TERM="xterm", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
        view = self.terminal([(CHOOSER, "1\n"), (REVIEW, "a\n")], args=["--reduced-motion"])
        self.assertNotIn("\r", view)
        self.assertNotIn("\x1b[K", view)
        self.assertIn("Installed Polaris", view)

    def test_verified_player_glint_settles_and_keeps_typeahead(self):
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        # Send Apply with the role, before inventory or the highlight can finish.
        view = self.terminal([(CHOOSER, "2\na\n")], args=["--channel", "beta"], size=(80, 24))
        role = "Play games from another PC"
        self.assertIn(f"\x1b[1;36m{role}\x1b[0m\r\x1b[K\x1b[1m{role}\x1b[0m", view)
        self.assertEqual(view.count("✦"), 1)
        self.assertLess(view.index("Installed Nova beta"), view.index("✦"))
        self.assertIn("✦\x1b[0m\r\x1b[32m✓\x1b[0m Nova installation verified", view)
        self.assertIn("Open Nova: flatpak run --user " + APP + "beta --standalone", view)
        log, = (self.case / "tmp").iterdir()
        self.assertIn("Nova installation verified", log.read_text())
        self.assertNotRegex(log.read_text(), r"[✦\x1b\r]|through sudo")

    def test_verified_player_static_modes(self):
        for args, env in [(["--plain"], {}), (["--reduced-motion"], {}), ([], {"REDUCE_MOTION": "1"}),
                          ([], {"NO_COLOR": "1"}), ([], {"TERM": "dumb"})]:
            with self.subTest(args=args, env=env):
                self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
                self.env.pop("REDUCE_MOTION", None)
                self.env.pop("NO_COLOR", None)
                self.env.update(env)
                view = self.terminal([(CHOOSER, "2\na\n")], args=args)
                self.assertIn("Nova installation verified", view)
                self.assertIn("Open Nova:", view)
                self.assertNotRegex(view, r"[✦\r]")
                self.assertNotIn("\x1b[K", view)

    def test_combined_role_glints_once_on_final_success(self):
        # The Python completion suite verifies the listener. Exercise its CLI
        # boundary here so the combined shell flow can finish both products.
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        self.change(ostree=True, packages={"polaris": "1.5-1", "unrelated": "7"})
        python = self.command_python
        python.unlink()
        python.write_text(f"""#!{sys.executable}
import os, sys
if len(sys.argv) > 2 and sys.argv[2].endswith('/finish-host.py'):
    star, check = sys.argv[7:9]
    print(star + check + 'Polaris console ready')
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
""")
        python.chmod(0o755)
        view = self.terminal([(CHOOSER, "3\na\n")], size=(80, 24))
        self.assertLess(view.index("Polaris console ready"), view.index("✦"))
        self.assertLess(view.index("✦"), view.index("Nova installation verified"))
        self.assertEqual(view.count("✦"), 1)

    def test_invalid_review_shows_reason_without_apply(self):
        self.change(ostree=True, ostree_status=5)
        view = self.terminal([(CHOOSER, "1\n"), (REVIEW, "q\n")])
        self.assertIn("Deployment state is unknown", view)
        self.assertNotIn("[a]  Apply", view)
        self.assertNotIn("Nova installation verified", view)
        self.no_changes()

    def finish_desktop(self, ready=False, sudo=False):
        self.env.update(DISPLAY=":115", XDG_RUNTIME_DIR=str(self.case / "runtime"))
        (self.case / "runtime").mkdir()
        for cmd in ("ss", "xdg-open", "setsid"):
            real = shutil.which("setsid") if cmd == "setsid" else None
            (self.bin / cmd).symlink_to(real or BOUNDARY)
        if sudo:
            self.env["SUDO_USER"] = "player"
            self.change(uid=0)
        if ready:
            config = self.case / ("player-config" if sudo else "config") / "polaris/polaris.conf"
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text("port = 50800\n")
            self.change(console_port=50801)

    def test_finish_opens_each_selected_nova_branch(self):
        self.finish_desktop()
        for branch in ("stable", "beta"):
            with self.subTest(branch=branch):
                if branch == "beta":
                    (self.bin / "systemd-run").symlink_to(BOUNDARY)
                    runtime = self.case / "runtime/systemd"
                    runtime.mkdir()
                    # Bind a relative path to fit the AF_UNIX name limit.
                    original = Path.cwd()
                    try:
                        os.chdir(runtime)
                        with socket.socket(socket.AF_UNIX) as manager:
                            manager.bind("private")
                    finally:
                        os.chdir(original)
                view = self.terminal([(REVIEW, "a\n"), ("Finish [", "\n")],
                                     args=["--role", "client", "--channel", branch])
                self.assertIn("Nova launch requested", view)
        self.assertEqual(self.records("launches"), [
            ["flatpak", "run", "--user", APP + branch, "--standalone"] for branch in ("stable", "beta")])
        self.assertIn(["systemd-run", "--user", "--scope", "--quiet", "--", *self.records("launches")[1]],
                      self.records("effects"))
        self.assertFalse(self.records("privilege"))

    def test_finish_both_consumes_only_the_chosen_action(self):
        self.finish_desktop(ready=True)
        view = self.terminal([(REVIEW, "a\n"), ("Finish [", "\x1b[B\n"), ("Finish [", "n\n")],
                             args=["--role", "both", "--channel", "beta"])
        self.assertIn("Polaris console ready: https://127.0.0.1:50801/", view)
        self.assertNotIn("47990", view)
        self.assertEqual(self.records("launches"), [
            ["xdg-open", "https://127.0.0.1:50801/"], ["flatpak", "run", "--user", APP + "beta", "--standalone"]])
        self.assertEqual(view.count("p = Open Polaris"), 1)

    def test_finish_done_and_eof_keep_verified_installation(self):
        self.finish_desktop()
        for key, cooked in (("d\n", False), ("\x04", False), ("\x04", True)):
            if cooked:
                (self.bin / "dd").unlink()
            view = self.terminal([(REVIEW, "a\n"), ("Finish [", key)], args=["--role", "client"])
            self.assertIn("Nova installation verified", view)
            self.assertNotIn("Nothing was changed.", view)
            self.assertFalse(self.records("launches"))

    def test_finish_rechecks_targets_and_reports_launch_failure(self):
        self.finish_desktop(ready=True)
        self.change(launch_failure=True)
        view = self.terminal([(REVIEW, "a\n"), ("Finish [", "n\n"),
                              ("Finish [", "p\n", lambda: self.change(console_reply="<html/>"))],
                             args=["--role", "both"])
        self.assertIn("Could not launch Nova", view)
        self.assertIn("flatpak run --user " + APP + "stable --standalone", view)
        self.assertIn("Polaris could not be verified again at https://127.0.0.1:50801/", view)
        self.assertEqual(self.records("launches"), [["flatpak", "run", "--user", APP + "stable", "--standalone"]])

    def test_finish_rechecks_the_verified_nova_commit(self):
        self.finish_desktop()

        def external_update():
            refs = self.state["refs"]
            refs[APP + "beta"][1] = "e" * 64
            self.change(refs=refs)

        view = self.terminal([(REVIEW, "a\n"), ("Finish [", "n\n", external_update)],
                             args=["--role", "client", "--channel", "beta"])
        self.assertIn("Could not confirm the installed Nova commit", view)
        self.assertFalse(self.records("launches"))

    def test_finish_sudo_host_uses_the_players_console_and_opener(self):
        self.finish_desktop(ready=True, sudo=True)
        view = self.terminal([(REVIEW, "a\n"), ("Finish [", "\n")], args=["--role", "host"])
        self.assertIn("Browser launch requested", view)
        self.assertEqual(self.records("launches"), [["xdg-open", "https://127.0.0.1:50801/"]])
        prefix = ["sudo", "-H", "-u", "player", "env", "XDG_RUNTIME_DIR=/run/user/1000",
                  "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus", "DISPLAY=:115"]
        self.assertEqual([cmd[len(prefix)] for cmd in self.records("privilege") if cmd[:len(prefix)] == prefix],
                         ["python3", "python3", "sh"])

    def test_finish_requires_polaris_listener_and_response(self):
        self.finish_desktop(ready=True)
        for changes in (dict(listener_group="/some/other.service"), dict(listener_group="/fixture/polaris.service",
                                                                       console_reply='{"status":false}')):
            self.change(**changes)
            view = self.terminal([(REVIEW, "a\n")], args=["--role", "host"])
            self.assertNotIn("Finish [", view)
            self.assertNotIn("Polaris console ready", view)
            self.assertIn("https://localhost:50801/", view)
        self.assertFalse(self.records("launches"))

    def test_finish_skips_ssh_package_only_and_reboot(self):
        self.finish_desktop(ready=True)
        self.env["SSH_TTY"] = "/dev/pts/9"
        ssh = self.terminal([(REVIEW, "a\n")], args=["--role", "both"])
        del self.env["SSH_TTY"]
        package_only = self.terminal([(REVIEW, "a\n")], args=["--role", "host", "--no-setup"])
        self.change(kernel_missing=True)
        reboot = self.terminal([(REVIEW, "a\n")], args=["--role", "both"])
        self.assertIn("Reboot first", reboot)
        for view in (ssh, package_only, reboot, self.run_cli("--role", "client", "--yes"),
                     self.run_cli("--role", "client", "--dry-run")):
            self.assertNotIn("Finish [", view)
        self.assertFalse(self.records("launches"))

    def test_finish_keeps_one_bazzite_opener_and_offers_a_failed_open_again(self):
        self.finish_desktop(ready=True)
        self.change(ostree=True, packages={"polaris": "1.5-1", "unrelated": "7"})
        (self.bin / "systemd-run").symlink_to(BOUNDARY)
        # Run the actual desktop helper with its installed executable and uid
        # mapped into the fixture. The user manager and both openers are recorded.
        python = self.command_python
        python.unlink()
        python.write_text(f"""#!{sys.executable}
import os, sys
from pathlib import Path
if len(sys.argv) > 2 and Path(sys.argv[2]).name == 'finish-host.py':
    sys.argv = sys.argv[2:]
    source = Path(sys.argv[0]).read_text().replace('POLARIS = "/usr/bin/polaris"', 'POLARIS = "{self.bin / "polaris"}"')
    exec(compile(source.replace('uid = os.geteuid()', 'uid = 1000'), sys.argv[0], 'exec'))
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
""")
        python.chmod(0o755)
        view = self.terminal([(REVIEW, "a\n"), ("Finish [", "d\n")], args=["--role", "both"])
        self.assertNotIn("p = Open Polaris", view)
        self.assertEqual(self.records("launches"), [["xdg-open", "https://localhost:50801/"]])
        self.change(fail=["systemd-run", "--user"])
        retry = self.terminal([(REVIEW, "a\n"), ("Finish [", "p\n")], args=["--role", "host"])
        self.assertIn("Open https://localhost:50801/ in your desktop browser.", retry)
        self.assertEqual(self.records("launches")[-1], ["xdg-open", "https://127.0.0.1:50801/"])

    def test_finish_pending_deployment_keeps_the_restart_choice(self):
        self.finish_desktop()
        self.pending_update({"unrelated": "8"})
        self.capture_package_completion()
        prompt = "Restart this PC now to finish Polaris setup?"
        eof = self.terminal([(REVIEW, "a\n"), (prompt, "\x04")], args=["--role", "both", "--plain"])
        self.assertIn("Enter = Later.", eof)
        self.assertNotIn("Nothing was changed.", eof)
        self.assertNotIn("Finish [", eof)
        self.assertNotIn(["systemctl", "reboot"], self.records("effects"))
        # Apply can be queued before the rich review is drawn. Enter on the
        # restart footer should retain Later and Up from Later selects Restart.
        self.env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        for keys in ("\n", "\x1b[A\n"):
            view = self.terminal([("Polaris + Nova installer", "a\n"), (prompt, keys)],
                                 args=["--role", "both"], size=(80, 24))
            self.assertNotIn("Finish [", view)
            self.assertNotIn("Enter = Later.", view)
            self.assertIn("> Later", view)
        self.assertEqual(self.records("effects").count(["systemctl", "reboot"]), 1)
        self.assertFalse(self.records("launches"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, help="new directory in which to retain each isolated case")
    parser.add_argument("--shell", default="/bin/sh", help="POSIX sh to run the installer")
    opts, tests = parser.parse_known_args()
    INSTALL_SH = opts.shell
    os.umask(0o077)
    with tempfile.TemporaryDirectory() as temporary:
        ROOT = opts.output or Path(temporary)
        if opts.output:
            ROOT.mkdir(mode=0o700)
        unittest.main(argv=[sys.argv[0], "-v", "-f", *tests])
