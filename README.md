# papi-ux packages

Signed dnf and pacman repositories for [Polaris](https://github.com/papi-ux/polaris),
served at **https://repo.papi-ux.com**.

Setup instructions live with the project:
[docs/repositories.md](https://github.com/papi-ux/polaris/blob/master/docs/repositories.md).

```bash
sudo dnf upgrade          # Fedora, Bazzite
sudo pacman -Syu          # Arch, CachyOS
```

## Why this is a separate repository

GitHub reserves `<user-domain>/<repo-name>` for any repository with a Pages
site. Publishing from `papi-ux/polaris` therefore took over
`papi-ux.com/polaris/`, which is a real page on the docs site — replacing it
with a 404, and then with a 301 once a custom domain was added. A custom domain
does not avoid the collision; it only changes what the collision returns.

Publishing from a repository whose name collides with nothing does avoid it.
`papi-ux.com/packages/` is unused, and the deploy asserts the docs site's routes
still return 200 afterwards.

It also means no cross-repository credential exists. Polaris releases are
public, so the assets need no auth, and Pages deploys with this repository's own
`GITHUB_TOKEN`.

## What is published

Nothing is rebuilt. Each repository serves the package the Polaris release
published and its CI tested; the repository copy only gains a signature. The
published asset in the release is left untouched, so a package installed by
hand and one installed from a repository are the same build.

```
repo.papi-ux.com/
  CNAME
  PUBLISHED_TAG                     the release currently served
  polaris.gpg                       public signing key
  fedora/polaris.repo               Fedora 44/45, follows $releasever
  fedora/x86_64/                    legacy Fedora 44 copy + signed repodata
  fedora/44/x86_64/                 Fedora 44 packages + signed repodata
  fedora/45/x86_64/                 Fedora 45 packages + signed repodata
  arch/polaris.conf                 append to /etc/pacman.conf
  arch/x86_64/                      packages + database, both signed
```

The repository carries the latest release only. Rolling back means installing an
older release package by hand from the
[releases page](https://github.com/papi-ux/polaris/releases).

## How it runs

`.github/workflows/publish.yml` runs hourly and on manual dispatch.
The scheduled run compares the latest Polaris release against `PUBLISHED_TAG`
and does nothing when they match, so it only rebuilds when there is something
new.

Hourly is a trade. Polaris' Update Center offers `dnf upgrade polaris` as soon
as a release appears on GitHub, and until this repository catches up that
command correctly does nothing — which to anyone running it looks like the
feature is broken. Checking every fifteen minutes would shrink that window, but
96 runs a day turns the Actions tab into a wall of green checkmarks where a real
failure goes unnoticed. Releases land a few times a week; a release worth having
immediately is one dispatch away.

Only stable releases are published. The resolve job rejects malformed tags,
drafts, and prereleases before assembling or deploying any repository content.
An explicit tag also requires the independently approved, full Polaris merge
SHA and fails before publication if that SHA is not the tag target.

Polaris cannot trigger this directly — that would need a token able to write
here, which is a worse thing to own than fifteen minutes. Publishing a release
and wanting it immediately is a one-liner:

```bash
gh workflow run publish.yml --repo papi-ux/packages \
  -f tag=v1.3.14 -f approved_sha=0123456789abcdef0123456789abcdef01234567
```

After Pages reports a successful deployment, the workflow reads the public
repository back before it can finish green. It waits for the exact
`PUBLISHED_TAG`, checks the public key fingerprint, both repository and package
signatures, exact package metadata, and provenance against the GitHub release
assets. It also rechecks the product and documentation routes on papi-ux.com.

## Secrets

| Secret | Value |
|---|---|
| `POLARIS_REPO_GPG_KEY_ID` | signing key fingerprint |
| `POLARIS_REPO_GPG_PRIVATE_KEY` | armored secret key |

The key must be RSA. `rpmsign` exits 0 on an Ed25519 key and signs nothing at
all, which is why `scripts/build-package-repos.sh` verifies the signature after
signing rather than trusting the exit code.

### Choose what this PC does

Run the installer as your desktop user. At a terminal, including with the
one-command pipe, it asks what you want to do on this PC. Use Up and Down to
move the highlight, then Enter to choose. Tab moves to the next action.
Number and letter shortcuts also work.

| Role | What Apply changes | What to open afterwards |
| --- | --- | --- |
| Stream games from this PC | The signed `polaris` system package and the host options you select. An installed `polaris-kms` stays in step on upgrade. | On Bazzite with host setup selected, the installer starts Polaris and opens the local web console. On Fedora or Arch, startup before sign-in starts the service for you. For a basic installation, start Polaris in the desktop session. Approve the playing device in the console. |
| Play games from another PC | The desktop user's signed Nova Stable or Beta Flatpak and KDE 6.10 runtime. | Select **Open Nova** on this desktop and choose the streaming PC in the channel you installed. The completion also gives the launch command. |
| Do both | The reviewed host operation followed by the reviewed player operation. | The Polaris console manages the host. Nova opens the player. |

The review repeats your choice and shows what will change, who it affects, and
when a restart may be needed. Open **Details and options** with `d` for the
commands, sources, package IDs, access and manual guides. Use `h` to change
host setup, `c` to change the Nova branch, `b` for roles and `q` to quit.
Select **Apply** and press Enter, or use `a`.
For **Play games from another PC**, the install review highlights **Apply**.
Opening Details returns the highlight to **Apply** when the plan is ready.

On **Stream games from this PC** or **Do both**, select **Host options**.
Toggle either choice with Enter or Space, then choose **Done** to review it.
When the edited summary fits the terminal, it replaces the previous review.
The checkmarks show what this run will apply. The status alongside an option
describes the current host setup when the installer can verify it.
**Back without edits** discards the changes in this menu.

| Host option | What Apply does |
| --- | --- |
| Capture the host display (KMS) | Installs the matching signed `polaris-kms` helper and asks the packaged setup tool to grant this account direct display capture. If the new group needs another login, the installer carries the choice forward. |
| Start Polaris before sign-in | Enables the Polaris user service at boot and enables lingering for this account. Its service manager can keep running after sign-out. |

Enter the administrator password when requested. If new KMS permissions need
a fresh login, sign out of all sessions and sign back into the same account.
A restart also works when another session or lingering keeps the old groups
alive. Polaris finishes the selected setup at sign-in. On rpm-ostree,
KMS account setup requires a Polaris build with support for image-managed groups.
If the installed build lacks that support, Host review shows **Waiting for a
compatible Polaris update**. The installer saves your KMS choice for a compatible
deployment. Startup before sign-in can still finish if you selected it. To stop
waiting, select **Cancel request** in Host review and confirm. If an older
installer saved the request, a normal Host **Apply** updates its sign-in helper.
After a compatible update, choose **Finish request** in Host review if the
sign-in helper needs your administrator password.
Automation can explicitly request these options with `--enable-kms` and
`--enable-headless-boot`. Both require host setup.

The role picker shows the Polaris mascot raising a hand. The figure is still
and the picker accepts input immediately. Narrow terminals (under 40 columns),
non-UTF-8 locales and plain mode show a short text description. Use `--plain`,
`NO_COLOR=1` or `TERM=dumb` for plain output. `--reduced-motion` also keeps
installation progress still. In an interactive UTF-8 terminal a North Star glints once
when the Polaris console answers or Nova verifies. The verified player result
includes the **Open Nova** command for the branch you installed.

```sh
curl -fsSL https://repo.papi-ux.com/install.sh | sh
curl -fsSL https://repo.papi-ux.com/install.sh | sh -s -- --dry-run --role both
curl -fsSL https://repo.papi-ux.com/install.sh | sh -s -- --yes --role client --channel stable
```

A redirected invocation without a role retains the historical host operation.
`--yes` or `--non-interactive` also bypasses keyboard review on a terminal.
Unattended administrative steps use `sudo -n` and require existing authority.
A dry run only reads local state and prints the plan.

**Host support.** The published repository targets x86_64 Fedora 44/45,
including compatible rpm-ostree deployments, and Arch/CachyOS. Arch installation
includes a full system upgrade. On rpm-ostree hosts, the installer preserves
an update already staged for the next boot and adds Polaris to that deployment
if needed. The installer uses Python 3 to check the deployment before you
apply the installation. A stock Fedora CoreOS image needs this prerequisite.
To remove Polaris while an update is pending, boot into that deployment first.

On Bazzite, choose **Stream games from this PC** and **Apply**. For a compatible
first install, the installer activates the package on the current boot, checks
controller input, enables the desktop service, and opens the console after it
answers. A first-time user creates their console login there. A returning user
gets their existing console. The same curl command also finishes setup if
Polaris is already installed.

If an update needs a reboot, the installer offers to restart now or later.
After you sign back in to the selected deployment, it resumes setup and opens
the console. You can leave the screen locked during package installation.
`--no-setup` installs the package only. Running the installer over SSH prints
the console address for the desktop user.

**Player support.** The signed desktop/Deck route needs x86_64 Linux and an
existing Flatpak command. Run it as the player. It checks the publisher's
`nova.flatpakrepo` bytes before adding the `nova` user remote, checks
the remote URL, signature settings and keyring, and uses a signature-checking
Flathub remote for `runtime/org.kde.Platform/x86_64/6.10`. It verifies the
installed ref, commit, origin and runtime after the transaction. Always launch
the full reviewed ref, for example
`flatpak run --user app/com.papi_ux.Nova/x86_64/stable --standalone`.
System installations, other branches and managed Steam shortcuts have their
own scope. Use Get Nova for managed launcher migration, Steam Frame, or an
existing trust configuration the installer cannot verify. An already installed
`gpg` can identify re-serialized public keys. A publisher descriptor or key
rotation requires review of the pins in this script.
[Get Nova](https://papi-ux.com/downloads/) · [Signed Linux channels](https://github.com/papi-ux/nova/blob/4d6c40f573989a6abc7088a94af9696df05094be/docs/linux-updates.md)

**Removal.** Review `--uninstall --role host|client|both`. Unattended removal
requires `--yes`. Host removal targets only the installed `polaris` and
`polaris-kms` packages. rpm and pacman enforce dependent-package checks.
rpm-ostree stages removal for the next boot. Nova removal targets only the
reviewed user ref and keeps its data, other branches, runtimes and remotes.
A failed second operation leaves the first operation in place.

A user-service status or a Flatpak process listing is reported when available.
After a successful guided desktop install, the finish menu offers the available
host console or Nova player. Choose an action and press Enter, or select **Done**
to stay in the terminal. Pairing happens in the app. The private log path and
manual launch instructions stay in the terminal history. To exercise the shipped script locally
with command fixtures and a private PTY, run
`bash scripts/test-guided-installer.sh --roles-only`. Add `--output DIR` to
retain transcripts, inputs, command records and exit codes in a new directory.
The default Fedora suite also covers the original real rpmkeys parser checks.

### Fedora release trees

The shared `fedora/polaris.repo` uses
`baseurl=https://repo.papi-ux.com/fedora/$releasever/$basearch`. DNF/rpm-ostree
selects the installed release's `fedora/44/x86_64/` or `fedora/45/x86_64/`, so
an OS upgrade follows the new package family. The guided installer accepts
exactly `VERSION_ID=44` or `45` and writes that same repo file; other releases
stop before key import or repository changes, including in a dry run.

The guided installer trusts only the pinned key, `FINGERPRINT`, and takes
nothing that decides trust from the server. On Fedora it downloads `polaris.gpg`
once into a temporary directory and has `rpmkeys` read it into an empty keyring
there, with the same parser `rpm --import` uses. Unless that keyring holds
exactly one key and its fingerprint is `FINGERPRINT`, it stops before importing
any key or writing anything. Otherwise it imports that same file, keeps it as
`/etc/pki/rpm-gpg/RPM-GPG-KEY-polaris`, and writes `/etc/yum.repos.d/polaris.repo`
itself instead of downloading it. The file it writes is the served
`fedora/polaris.repo` except that `gpgkey=` names that local key, so dnf never
fetches a key on its own. dnf and rpm-ostree hosts both take these steps, and
`--dry-run` prints them. On Arch, `pacman-key --lsign-key` trusts only
`FINGERPRINT`, and the installer writes the `[polaris]` section itself, the same
as the served `arch/polaris.conf`. A `[polaris]` section already in
`/etc/pacman.conf` is left alone only if it is exactly that section, spacing and
comments aside; otherwise the run stops before trusting a key or running pacman.
`scripts/test-guided-installer.sh` checks both files against the templates in
`scripts/build-package-repos.sh`, so the two cannot drift apart.

The Polaris install runs four steps covering signing key, repository, packages and host
setup. Each command is printed under its step before it runs, in a dry run as
well. What dnf, rpm-ostree, pacman and `polaris --setup-host` print goes to a
mode-0600 log, `polaris-install-<time>-<random>.log` in `$TMPDIR` or `/tmp`,
whose path is printed at the start and at the end. A failing command shows its
last 30 lines and the log path before the installer's own error. pacman
questions that `--noconfirm` answered are shown as well. Host setup's warnings,
and advice the installer does not recognise, stay on screen. The input group
and headless boot commands it names are listed at the end. A terminal gets
colour, symbols and one live status line. A pipe, a file, `NO_COLOR` or
`TERM=dumb` gets the same words without them, and only ASCII is used outside
a UTF-8 locale.

A host installed by an earlier installer keeps its downloaded repo file, whose
`gpgkey=` is the HTTPS URL, until the guided installer runs again; that run
replaces the file and adds the local key. An Arch host keeps its section, which
already matches.

**Before upgrading a host from Fedora 44 to 45, re-fetch `fedora/polaris.repo`
or re-run the guided installer if it was installed with the old pinned repo
file.** Existing old repo files still work through the byte-identical legacy
Fedora 44 tree at `fedora/x86_64/`, but cannot follow an OS upgrade on their own.

Publishing requires both Fedora release families (`Polaris[-kms]-fedora44-x86_64.rpm`
and `Polaris[-kms]-fedora45-x86_64.rpm`), with the historical pre-1.4.13 KMS
exception unchanged. Missing assets stop assembly before either Fedora tree is
written. A historical tag with no Fedora 45 assets therefore cannot be republished
through this two-family lane. Both trees use the existing repository signing key
and signed metadata/provenance; the public read-back verifies both pairs.

Local checks, in their documented Fedora/Arch containers:
`bash scripts/test-guided-installer.sh` (Fedora, for `rpmkeys`, `gpg` and
`python3`, which runs the terminal cases in a pseudo-terminal),
`bash scripts/test-public-repository-fixture.sh fedora` and
`bash scripts/test-public-repository-fixture.sh arch`. The builder's existing
`--base-url` renders the served installer for a lab URL, without an installer CLI
override or a production trust change. `--dry-run` does not install packages or
prove the real signing key and public deployment.
