#!/usr/bin/env python3
"""Stateful command boundaries for the guided installer. No network or system writes."""
import base64
import json
import os
from pathlib import Path
import shutil
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["FIXTURE"])
state_file = root / "state.json"
state = json.loads(state_file.read_text())
repo = root / "data/flatpak/repo"
published = Path(__file__).resolve().with_name("nova.flatpakrepo")
feed = "https://updates.papi-ux.com/nova"
flathub = "https://dl.flathub.org/repo"
app = "com.papi_ux.Nova"
runtime = "runtime/org.kde.Platform/x86_64/6.10"
fp = "58017EDFFA9F803E07ED26F835F13F14FAAD15CC"
version = "1.5.0-1"
commit = "a" * 64


def record(filename):
    with (root / filename).open("a") as stream:
        stream.write(json.dumps([tool, *args]) + "\n")


def effect():
    record("effects")
    if state.get("fail") == [tool, args[0]]:
        print("fixture command failed")
        sys.exit(23)


def save():
    state_file.write_text(json.dumps(state))


def reject():
    sys.exit(f"Unexpected fixture command: {tool} {args}")


def inside(path, directory):
    value = Path(path).resolve()
    if directory.resolve() not in value.parents:
        reject()
    return value


owned_tmp = inside(os.environ["TMPDIR"], root)
record("calls")
if tool == "id":
    if args == ["-u"]:
        print(state.get("uid", 1000))
    elif args == ["-un"]:
        print("player")
    elif args == ["-u", "--", "player"]:
        print(1000)
    else:
        reject()
elif tool == "uname":
    if args == ["-m"]:
        print(state.get("arch", "x86_64"))
    elif args == ["-r"]:
        print("fixture-kernel")
    else:
        reject()
elif tool == "stat":
    if args == ["/run/ostree-booted"]:
        sys.exit(0 if state.get("ostree") else 1)
    if args == ["/usr/lib/modules/fixture-kernel/."]:
        sys.exit(1 if state.get("kernel_missing") else 0)
    reject()
elif tool == "cat":
    if args == ["/etc/os-release"]:
        sys.stdout.write((root / "os-release").read_text())
    elif args == ["/etc/pacman.conf"]:
        sys.stdout.write((root / "pacman.conf").read_text())
    elif args:
        for name in args:
            sys.stdout.buffer.write(inside(name, root).read_bytes())
    else:
        shutil.copyfileobj(sys.stdin.buffer, sys.stdout.buffer)
elif tool == "sudo":
    record("privilege")
    command = list(args)
    if command[:7] == ["-H", "-u", "player", "env", "XDG_RUNTIME_DIR=/run/user/1000",
                       "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus", "DISPLAY=:115"]:
        # Represent the player's session inside the fixture, including a
        # different config directory from the simulated root process.
        os.environ.update(XDG_CONFIG_HOME=str(root / "player-config"), XDG_RUNTIME_DIR=str(root / "runtime"))
        if command[7] not in ("sh", "python3"):
            reject()
        os.execv(str(root / "bin" / command[7]), command[7:])
    while command and command[0] in ("-n", "-H"):
        command.pop(0)
    if not command or command[0] not in {"install", "rpm", "rpm-ostree", "pacman", "pacman-key", "tee", "dnf", "polaris"}:
        reject()
    os.execv(str(root / "bin" / command[0]), command)
elif tool == "ss" and args[:2] == ["-H", "-ltnpe"]:
    port = state.get("console_port")
    if port and args[2] == f"sport = :{port}":
        group = state.get("listener_group", "/fixture/polaris.service")
        print(f"LISTEN 0 128 127.0.0.1:{port} *:* uid:1000 cgroup:{group}")
elif tool == "curl" and args[-1] == f"https://127.0.0.1:{state.get('console_port')}/api/configLocale":
    print(state.get("console_reply", '{"status":true,"locale":"en"}'))
elif tool == "curl":
    effect()
    if args[-1].endswith("/PUBLISHED_TAG"):
        print("v1.5.0")
    elif args[-1].endswith("/polaris.gpg"):
        if "--output" in args:
            inside(args[args.index("--output") + 1], owned_tmp).write_text("Polaris fixture key")
        else:
            print("Polaris fixture key")
    elif args[-1] == feed + "/nova.flatpakrepo":
        target = inside(args[args.index("--output") + 1], owned_tmp)
        target.write_bytes(b"bad descriptor" if state.get("bad_descriptor") else published.read_bytes())
    else:
        reject()
elif tool == "rpmkeys":
    inside(args[1], owned_tmp)
    if "--list" in args:
        print(state.get("rpm_fingerprint", fp).lower() + " issuer")
    elif "--import" not in args:
        reject()
elif tool == "rpm":
    packages = state["packages"]
    if (args[:3] == ["-q", "--qf", "%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\\n"]
            and args[3:] in (["polaris.x86_64", "polaris-kms.x86_64"], ["polaris", "polaris-kms"])):
        for name in ("polaris", "polaris-kms"):
            if name not in packages:
                sys.exit(1)
            evr = packages[name]
            print(name, (evr if ":" in evr else "0:" + evr) + ".x86_64")
    elif args[0] == "-q":
        if args[-1] not in packages:
            sys.exit(1)
        if "--quiet" not in args:
            print(packages[args[-1]])
    elif args[:3] == ["-qa", "--qf", "%{NEVRA}\\n"] and args[3:] in (["polaris"], ["polaris", "polaris-kms"]):
        if state.get("rpm_read_error"):
            sys.exit(2)
        for name in args[3:]:
            if name in packages:
                print(f"{name}-{packages[name]}.x86_64")
    elif args[:1] == ["-qa"]:
        print("\n".join(packages))
    elif args[0] == "--import":
        effect()
    elif args[0] == "-e":
        effect()
        if state.get("dependent"):
            sys.exit(11)
        for name in args[1:]:
            del packages[name]
        save()
    else:
        reject()
elif tool == "dnf" and args[:1] in (["install"], ["upgrade"]):
    effect()
    targets = {name: version for name in args[1:] if not name.startswith("-")}
    state["packages"].update(state.get("transaction_packages", targets))
    save()
elif tool == "install":
    effect()
    if args[-1] not in ("/etc/pki/rpm-gpg/RPM-GPG-KEY-polaris", "/etc/yum.repos.d/polaris.repo"):
        reject()
    shutil.copyfile(inside(args[-2], owned_tmp), root / Path(args[-1]).name)
elif tool == "polaris" and args == ["--setup-host", "--help"]:
    if state.get("image_userdb"):
        print("on rpm-ostree hosts through systemd's userdb")
elif tool == "polaris" and args == ["--setup-host"]:
    effect()
    print("Linux host setup complete.")
elif tool == "rpm-ostree":
    boot = {"checksum": "b" * 64, "booted": True, "staged": False, "osname": "default",
            "unlocked": "none", "requested-packages": [], **state.get("boot_fields", {})}
    staged = state.get("pending")
    if args == ["status", "--pending-exit-77"]:
        sys.exit(state.get("ostree_status", 77 if staged else 0))
    if args == ["status", "--json"]:
        if state.get("ostree_status"):
            sys.exit(state["ostree_status"])
        rows = ([staged] if staged else []) + [boot]
        print(json.dumps(state.get("status_json", {"deployments": rows, "transaction": None})))
    elif args == ["db", "list", boot["checksum"]] or (staged and args == ["db", "list", staged["checksum"]]):
        print("ostree commit:", args[2])
        packages = state["packages"] if args[2] == boot["checksum"] else state["pending_packages"]
        for name, evr in packages.items():
            if "-" not in evr:
                evr += "-1"
            print(f" {name}-{evr}.x86_64")
    elif args[:2] == ["install", "--idempotent"] and args[2:] in (["polaris"], ["polaris-kms"], ["polaris", "polaris-kms"]):
        effect()
        parent = staged or boot
        state["pending"] = {**parent, "booted": False, "staged": True, "checksum": "c" * 64,
                            "base-checksum": parent.get("base-checksum", parent["checksum"]),
                            "requested-packages": sorted(set(parent["requested-packages"]).union(args[2:])),
                            **state.get("stage_fields", {})}
        # The signed helper depends on the exact regular package version.
        solved = {name: version for name in {"polaris", *args[2:]}}
        state["pending_packages"] = {**state.get("pending_packages", state["packages"]),
                                     **solved, **state.get("layer_packages", {})}
        if state.get("missing_staged_rpm"):
            del state["pending_packages"]["polaris"]
        if state.get("missing_staged_kms"):
            del state["pending_packages"]["polaris-kms"]
        save()
    elif staged and args == ["db", "diff", "--format=json", boot["checksum"], staged["checksum"]]:
        changes = []
        before, after = state["packages"], state["pending_packages"]
        for name in sorted(before.keys() | after.keys()):
            if before.get(name) == after.get(name):
                continue
            details = {}
            if name in before:
                details["PreviousPackage"] = [name, before[name], "x86_64"]
            if name in after:
                details["NewPackage"] = [name, after[name], "x86_64"]
            kind = 0 if name not in before else (1 if name not in after else 2)
            changes.append([name, kind, details])
        print(json.dumps({"ostree-commit-from": boot["checksum"], "ostree-commit-to": staged["checksum"],
                          "pkgdiff": changes, **state.get("diff_fields", {})}))
        if state.get("switch_after_diff"):
            staged["checksum"] = "e" * 64
            save()
    elif staged and args == ["apply-live", "--target", staged["checksum"]]:
        effect()
        state["packages"] = {**state["pending_packages"], **state.get("live_packages", {})}
        state["boot_fields"] = {**boot, "live-replaced": staged["checksum"], "unlocked": "transient"}
        save()
    elif args[0] == "uninstall":
        effect()
        state["pending"] = True
        save()
    else:
        reject()
elif tool == "pacman":
    if args[:1] == ["-Q"]:
        for name in args[1:]:
            if name not in state["packages"]:
                sys.exit(1)
            print(name, state["packages"][name])
    elif args == ["-Qq"]:
        print("\n".join(state["packages"]))
    elif args[:1] == ["-R"]:
        effect()
        for name in args[2:]:
            del state["packages"][name]
        save()
    elif args[:1] == ["-Syu"]:
        effect()
        targets = {"polaris": version}
        if "polaris-kms" in state["packages"] or "polaris/polaris-kms" in args:
            targets["polaris-kms"] = version
        state["packages"].update(state.get("transaction_packages", targets))
        save()
    else:
        reject()
elif tool == "pacman-key":
    effect()
    if args == ["--add", "-"]:
        sys.stdin.buffer.read()
elif tool == "tee" and args == ["-a", "/etc/pacman.conf"]:
    effect()
    with (root / "pacman.conf").open("ab") as stream:
        shutil.copyfileobj(sys.stdin.buffer, stream)
elif tool == "systemctl" and args == ["--user", "is-active", "polaris.service"]:
    print(state.get("service", "inactive"))
    sys.exit(0 if state.get("service") == "active" else 3)
elif tool == "systemctl" and args == ["--user", "show", "polaris.service",
                                     "--property=ActiveState,MainPID,ExecStart,ControlGroup"]:
    print("ActiveState=active\nMainPID=27\nControlGroup=/fixture/polaris.service")
    print("ExecStart={ path=/usr/libexec/polaris/polaris-kms ; }")
elif tool == "systemctl" and args in (["--user", "daemon-reload"], ["--user", "enable", "polaris.service"], ["reboot"]):
    effect()
elif tool == "systemd-run" and args[:4] in (["--user", "--quiet", "--collect", "--"],
                                            ["--user", "--scope", "--quiet", "--"]):
    effect()
    if Path(args[4]).name not in ("xdg-open", "flatpak"):
        reject()
    os.execv(str(root / "bin" / Path(args[4]).name), args[4:])
elif tool == "setsid" and args[:1] == ["--wait"]:
    # Some developer hosts lack util-linux. The real Fedora lane uses setsid.
    os.setsid()
    os.execvp(args[1], args[1:])
elif tool == "xdg-open" or (tool == "flatpak" and args[:1] == ["run"]):
    effect()
    record("launches")
    if state.get("launch_failure"):
        sys.exit(19)
elif tool == "flatpak" and args == ["ps", "--columns=application"]:
    if state.get("ps_failed"):
        sys.exit(9)
    if state.get("client_running"):
        print(app)
elif tool == "flatpak":
    if "--user" not in args:
        reject()
    action = args[0]
    refs, remotes = state["refs"], state["remotes"]
    if action == "remotes":
        for name, row in remotes.items():
            print(name, *row, sep="\t")
    elif action == "list":
        kind = "app/" if "--app" in args else "runtime/"
        for ref, (origin, _) in refs.items():
            if ref.startswith(kind):
                fields = ref[len(kind):].split("/")
                if "--columns=application,arch,branch,origin" in args:
                    fields.append(origin)
                print(*fields, sep="\t")
    elif action == "info":
        ref = args[-1]
        if ref not in refs:
            sys.exit(1)
        origin, revision = refs[ref]
        fields = {"--show-origin": origin, "--show-commit": revision, "--show-ref": ref,
                  "--show-runtime": runtime.removeprefix("runtime/")}
        print(fields[args[2]])
    elif action == "remote-add":
        effect()
        name, source = args[-2:]
        if name in remotes:
            sys.exit(12)
        if name == "nova":
            local = inside(source, owned_tmp)
            if local.read_bytes() != published.read_bytes():
                reject()
            repo.mkdir(parents=True, exist_ok=True)
            config = '[remote "nova"]\nurl=' + feed + '/repo\ngpg-verify=true\ngpg-verify-summary=true\n'
            (repo / "config").write_text(config)
            key = local.read_text().split("GPGKey=")[1].strip()
            (repo / "nova.trustedkeys.gpg").write_bytes(base64.b64decode(key))
            remotes[name] = [feed + "/repo", ""]
        elif name == "flathub" and source == flathub + "/flathub.flatpakrepo":
            remotes[name] = [flathub, ""]
        else:
            reject()
        save()
    elif action in ("install", "update", "uninstall"):
        ref = args[-1]
        if ref not in (runtime, f"app/{app}/x86_64/stable", f"app/{app}/x86_64/beta"):
            reject()
        effect()
        if action == "uninstall":
            del refs[ref]
        elif action == "install":
            if ref.startswith("app/") and runtime not in refs:
                sys.exit(13)
            if not state.get("missing_app") or ref == runtime:
                refs[ref] = [args[-2], commit]
        elif action == "update":
            refs[ref][1] = commit
        save()
    else:
        reject()
else:
    reject()
