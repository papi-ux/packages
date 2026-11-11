#!/bin/sh
# Add the Polaris repository and install Polaris.
#
#   curl -fsSL https://repo.papi-ux.com/install.sh | sh
#
# It adds the repository and installs Polaris as docs/repositories.md does by
# hand, in the order that page gives, then runs host setup. On Arch and CachyOS
# that install is a full system upgrade, because Arch supports no other kind.
# Every step is safe to repeat: the pacman section is guarded, the keys are
# idempotent imports, and a package already installed at the version the
# repository serves is left alone by the package manager. That includes a beta
# of the release being served, so the end of the run says so and prints the
# reinstall command rather than reporting an install.
#
# Options, which need `sh -s --` because the script arrives on stdin:
#   curl -fsSL https://repo.papi-ux.com/install.sh | sh -s -- --dry-run
#
#   --dry-run   print every command instead of running it
#   --no-setup  skip `polaris --setup-host`, leaving it for you to run
#
# POSIX sh on purpose. This runs before Polaris exists on the host, on whatever
# /bin/sh the distribution ships, so it cannot assume bash.

set -eu

BASE_URL='https://repo.papi-ux.com'
FINGERPRINT='58017EDFFA9F803E07ED26F835F13F14FAAD15CC'
dry_run=0
run_setup=1

# Defined before the argument loop, because --help calls say. A function used above its
# definition is a runtime failure that sh -n does not see.
say() { printf '%s\n' "$*"; }
die() { printf 'polaris install: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --no-setup) run_setup=0 ;;
    -h|--help)
      say 'curl -fsSL https://repo.papi-ux.com/install.sh | sh'
      say '  --dry-run   print every command instead of running it'
      say '  --no-setup  skip polaris --setup-host'
      exit 0 ;;
    *) printf 'polaris install: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# Printed before it runs, so a piped script is never doing something unseen.
run() {
  printf '  $ %s\n' "$*"
  [ "$dry_run" -eq 1 ] && return 0
  "$@"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required and was not found"
}

# Root is reached through sudo rather than by demanding the whole script run as
# root: fewer commands run privileged, and it matches what the docs show.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=''
else
  command -v sudo >/dev/null 2>&1 ||
    die 'this needs root and sudo was not found. Re-run it as root.'
  SUDO='sudo'
fi
sudo_run() { run ${SUDO:+$SUDO} "$@"; }
setup_command="${SUDO:+$SUDO -H }polaris --setup-host"

# setup-host wants a root HOME so it does not write into the invoking user's.
# `sudo -H` does that; as root there is nothing to correct.
setup_host_run() {
  if [ -n "$SUDO" ]; then
    run "$SUDO" -H polaris --setup-host
  else
    run polaris --setup-host
  fi
}

[ -r /etc/os-release ] || die '/etc/os-release is missing, so the distribution cannot be identified'
# shellcheck disable=SC1091
. /etc/os-release
id_like="${ID_LIKE:-}"
distro="${ID:-unknown}"

matches() {
  for candidate in $distro $id_like; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

# The installed version-release of a package, or nothing. It runs inside a
# command substitution under set -e, so it always returns 0.
installed_version() {
  if matches fedora; then
    if rpm -q --quiet "$1" 2>/dev/null; then
      rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$1"
    fi
  elif matches arch; then
    if installed_line="$(pacman -Q "$1" 2>/dev/null)"; then
      printf '%s\n' "${installed_line#* }"
    fi
  fi
  return 0
}

# The release the repository serves, without its leading v, or nothing when it
# cannot be read. PUBLISHED_TAG is deployed with the packages, so it names the
# version they carry. Asking the package manager instead would mean dnf5 as the
# invoking user, which ignores the metadata root just fetched, builds a private
# cache and prompts for the key a second time.
served_version() {
  published_tag="$(curl -fsS --max-time 20 "$BASE_URL/PUBLISHED_TAG" 2>/dev/null)" || return 0
  case "$published_tag" in
    v[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "${published_tag#v}" ;;
  esac
  return 0
}

# An ostree host layers rather than installs, and rpm-ostree never asks about a
# key, so the import cannot be left to the package manager.
ostree=0
[ -f /run/ostree-booted ] && ostree=1

# The signing key is downloaded once, into a directory of its own, and that same
# file is checked and then imported. Removing the directory on exit covers every
# way the run can stop.
key_dir=''
remove_key_dir() {
  [ -z "$key_dir" ] || rm -rf -- "$key_dir"
}
trap remove_key_dir EXIT
trap 'exit 1' HUP INT TERM

# rpm imports every key a file holds, from as many armored blocks as it has, and
# printing the pinned fingerprint does not check anything. So rpm reads the
# download into an empty keyring under the temporary directory first, with the
# same parser the real import uses, and the run stops unless that keyring then
# holds exactly one key and it is the pinned one. This happens before any key is
# imported or any repository is added.
check_fedora_key() {
  command -v rpmkeys >/dev/null 2>&1 ||
    die "rpmkeys was not found, so the signing key cannot be checked before it is
trusted. It comes with the rpm package. This stopped before importing a key or
adding the repository, so nothing on this host was changed."
  need mktemp
  say "Checking the signing key. Pinned fingerprint: $FINGERPRINT"
  if [ "$dry_run" -eq 1 ]; then
    key_root="${TMPDIR:-/tmp}/polaris-key.XXXXXX"
  else
    key_dir="$(mktemp -d "${TMPDIR:-/tmp}/polaris-key.XXXXXX")" ||
      die 'could not create a temporary directory for the signing key. Nothing on this host was changed.'
    # rpm takes only an absolute --root, and TMPDIR can be relative.
    case "$key_dir" in /*) ;; *) key_dir="$PWD/$key_dir" ;; esac
    key_root="$key_dir"
  fi
  key_file="$key_root/polaris.gpg"
  run curl --location --fail --silent --show-error \
    --output "$key_file" "$BASE_URL/polaris.gpg" ||
    die "could not download $BASE_URL/polaris.gpg. This stopped before importing a
key or adding the repository, so nothing on this host was changed."
  run rpmkeys --root "$key_root" --noplugins --import "$key_file" ||
    die "rpm could not read a key from $BASE_URL/polaris.gpg, for the reason printed
above. This stopped before importing a key or adding the repository, so
nothing on this host was changed."
  printf '  $ %s\n' "rpmkeys --root $key_root --noplugins --list"
  if [ "$dry_run" -eq 1 ]; then
    say "  A real run stops here unless that lists exactly one key, $FINGERPRINT."
    return 0
  fi
  # One line per key: its fingerprint in lower case, then its user ID.
  key_list="$(rpmkeys --root "$key_root" --noplugins --list)" ||
    die "rpm could not list the key it read from $BASE_URL/polaris.gpg. This stopped
before importing a key or adding the repository, so nothing on this host was changed."
  key_count="$(printf '%s\n' "$key_list" | grep -c '[^[:space:]]' || true)"
  key_fingerprint="$(printf '%s\n' "$key_list" | sed -n '1s/[[:space:]].*//p' | tr '[:lower:]' '[:upper:]')"
  if [ "$key_count" -eq 0 ]; then
    die "$BASE_URL/polaris.gpg holds no key rpm can read. This stopped before
importing a key or adding the repository, so nothing on this host was changed."
  fi
  if [ "$key_count" -ne 1 ]; then
    die "$BASE_URL/polaris.gpg holds $key_count keys, and the Polaris signing key is a
single key. rpm would trust every key in the file, so this stopped before
importing any of them or adding the repository, and
nothing on this host was changed. Do not import that file by hand."
  fi
  if [ "$key_fingerprint" != "$FINGERPRINT" ]; then
    die "the key served at $BASE_URL/polaris.gpg has fingerprint
$key_fingerprint, and the Polaris signing key is
$FINGERPRINT. This stopped before importing it or adding the repository, so
nothing on this host was changed. Do not import that key by hand."
  fi
  say '  rpm reads one key, and its fingerprint is the pinned one.'
}

say 'Polaris installer'
say "  distribution: ${PRETTY_NAME:-$distro}"
[ "$ostree" -eq 1 ] && say '  image based:  yes, Polaris will be layered'
[ "$dry_run" -eq 1 ] && say '  dry run:      nothing will be changed'
say ''

install_fedora() {
  # Check the exact release before importing a key or changing repositories.
  # DNF/rpm-ostree resolves the shared repo file through its own $releasever,
  # so an OS upgrade selects the new ABI-matched pair without keeping a 44 pin.
  case "${VERSION_ID:-}" in
    44|45) ;;
    *) die "the repository serves Fedora 44 and 45 builds only, and this host is
${PRETTY_NAME:-$distro}, with VERSION_ID ${VERSION_ID:-unset}. This stopped before
importing the signing key or adding the repository. The hosts Polaris ships
packages for are listed at https://papi-ux.com/docs/quickstart/" ;;
  esac
  need curl
  # dnf offers the key from gpgkey= and waits for an answer. A script cannot
  # answer it, and repo_gpgcheck=1 means an unanswered prompt fails the metadata
  # check rather than installing anything, so the key goes in explicitly. The
  # import is the file just checked, not a second download.
  check_fedora_key
  say 'Importing the signing key.'
  sudo_run rpm --import "$key_file"
  say 'Adding the repository.'
  sudo_run curl --location --fail --silent --show-error \
    --output /etc/yum.repos.d/polaris.repo "$BASE_URL/fedora/polaris.repo"
  if [ "$ostree" -eq 1 ]; then
    say 'Layering Polaris.'
    sudo_run rpm-ostree install polaris
    say ''
    say 'Layered. Reboot to finish:  systemctl reboot'
    say 'After the reboot, run:      sudo -H polaris --setup-host'
    return 0
  fi
  # dnf5 install only checks that an installed package is present, so a host on
  # an older Polaris stays on it however new the repository is: a run over a
  # 1.4.12-1 package ended with 1.4.12-1. upgrade moves it, and does nothing
  # when it is current. polaris-kms requires the exact version of polaris beside
  # it, so it moves in the same transaction.
  if [ -z "$installed_before" ]; then
    say 'Installing Polaris.'
    sudo_run dnf install -y polaris
  elif [ -n "$(installed_version polaris-kms)" ]; then
    say 'Upgrading Polaris and polaris-kms.'
    sudo_run dnf upgrade -y polaris polaris-kms
  else
    say 'Upgrading Polaris.'
    sudo_run dnf upgrade -y polaris
  fi
}

# pacman ran with --noconfirm and stopped. $1 is the same step without it.
pacman_stopped() {
  die "pacman stopped, for the reason printed above. It ran
with --noconfirm, which takes the default answer to every question it asks, and
some of those defaults are no. The repository stays in /etc/pacman.conf, where a
re-run leaves it alone. To answer pacman's questions yourself, run:
  ${SUDO:+$SUDO }$1"
}

install_arch() {
  need curl
  say "Trusting the signing key. Fingerprint: $FINGERPRINT"
  # pacman has no gpgkey= equivalent in a repository section, so both of these
  # are required. polaris-keyring would remove them.
  if [ "$dry_run" -eq 1 ]; then
    printf '  $ curl -fsSL %s/polaris.gpg | %s pacman-key --add -\n' "$BASE_URL" "${SUDO:-}"
  else
    curl -fsSL "$BASE_URL/polaris.gpg" | ${SUDO:+$SUDO} pacman-key --add -
  fi
  sudo_run pacman-key --lsign-key "$FINGERPRINT"
  # Appending twice gives pacman a duplicated [polaris] repository, and pasting
  # the block again is exactly what someone does when a step looks like it
  # failed. The guard is why this script is safe to re-run.
  if grep -q '^\[polaris\]' /etc/pacman.conf 2>/dev/null; then
    say 'Repository already present in /etc/pacman.conf, leaving it alone.'
  else
    say 'Adding the repository to /etc/pacman.conf.'
    if [ "$dry_run" -eq 1 ]; then
      printf '  $ curl -fsSL %s/arch/polaris.conf | %s tee -a /etc/pacman.conf\n' "$BASE_URL" "${SUDO:-}"
    else
      curl -fsSL "$BASE_URL/arch/polaris.conf" | ${SUDO:+$SUDO} tee -a /etc/pacman.conf >/dev/null
    fi
  fi
  # -Syu, not -Sy. Refreshing the databases and installing one package on top is
  # a partial upgrade, which Arch does not support: Polaris and what it pulls in
  # come from the new databases while the rest of the system stays on the old
  # ones. With -Sy an audit run left ten system packages pending, systemd among
  # them. --noconfirm because stdin is this script when it arrives through a
  # pipe, so pacman has nobody to ask.
  if [ -z "$installed_before" ]; then
    say 'Installing Polaris. Arch supports only full upgrades, so pacman upgrades'
    say 'the rest of the system in the same step.'
    sudo_run pacman -Syu --noconfirm --needed polaris || pacman_stopped 'pacman -Syu polaris'
  else
    # A package named as a target is installed at the version the repository
    # carries, even over a newer one: a host on a later build, such as a beta of
    # the next release, went back to the served release, and pacman only warned.
    # The full upgrade alone moves Polaris and polaris-kms when the repository
    # has something newer and leaves a newer build where it is, as dnf upgrade
    # does. It also upgrades whatever else is pending, so a re-run is not always
    # a no-op.
    say 'Polaris is installed, so this upgrades the system, Polaris included.'
    say 'Arch supports only full upgrades.'
    sudo_run pacman -Syu --noconfirm || pacman_stopped 'pacman -Syu'
  fi
}

case "$distro" in
  steamos)
    die 'SteamOS is not served by a repository, and will not be: the rootfs is
read-only and pacman state does not survive a SteamOS update. Follow
https://papi-ux.com/docs/steamos/ instead.'
    ;;
esac

# By ID_LIKE as well as ID, so Mint, Pop!_OS and the rest of the family get the
# .deb pointer rather than the generic refusal below, which names neither.
if matches ubuntu || matches debian; then
  die 'Ubuntu, Debian and the distributions built on them are not served by a
repository yet. Polaris ships one .deb, built for Ubuntu 24.04 and tested only
there, and https://papi-ux.com/docs/ubuntu/ describes installing it. On any other
release, including ones built on Ubuntu 24.04, it is untested.'
fi

# Read before installing and again after, because the difference is the only
# record of what the package manager did: an install, an upgrade, or nothing.
installed_before="$(installed_version polaris)"

if matches fedora; then
  install_fedora
elif matches arch; then
  install_arch
else
  die "no repository for $distro. Fedora 44 and 45 (Bazzite and other ostree hosts
included), Arch and CachyOS are served; every other host installs a release
package from https://github.com/papi-ux/polaris/releases"
fi

if [ "$ostree" -eq 1 ]; then
  exit 0
fi

# A full upgrade can leave the running system unable to use what it installed
# until the next boot, and host setup cannot tell. When a kernel upgrade removes
# /usr/lib/modules/<running version>, a module that is not loaded yet cannot be
# loaded. Host setup loads uinput and uhid, treats a failed load as optional and
# reports success, while virtual input stays missing until a reboot. On Arch, a
# new nvidia-utils beside the NVIDIA module still loaded is the known driver and
# library mismatch. Either way the right order is reboot, then setup.
reboot_first=0
if [ "$dry_run" -eq 0 ]; then
  running_kernel="$(uname -r)"
  if [ ! -d "/usr/lib/modules/$running_kernel" ]; then
    reboot_first=1
    say ''
    say "The running kernel, $running_kernel, has no modules in /usr/lib/modules, so a"
    say 'module that is not loaded yet cannot load before the next boot. Host setup'
    say 'loads uinput and uhid, so it waits until after a reboot.'
  fi
  nvidia_loaded=''
  if [ -r /sys/module/nvidia/version ]; then
    nvidia_loaded="$(cat /sys/module/nvidia/version 2>/dev/null)" || nvidia_loaded=''
  fi
  nvidia_libraries="$(installed_version nvidia-utils)"
  nvidia_libraries="${nvidia_libraries#*:}"
  nvidia_libraries="${nvidia_libraries%-*}"
  if [ -n "$nvidia_loaded" ] && [ -n "$nvidia_libraries" ] &&
    [ "$nvidia_loaded" != "$nvidia_libraries" ]; then
    reboot_first=1
    say ''
    say "The NVIDIA driver loaded now is $nvidia_loaded, and the installed NVIDIA"
    say "libraries are $nvidia_libraries. They work only at the same version, and the"
    say 'installed driver loads at the next boot.'
  fi
fi

if [ "$run_setup" -eq 1 ] && [ "$reboot_first" -eq 0 ]; then
  say ''
  say 'Applying host setup.'
  # Not fatal. The package is installed either way, and setup-host can be
  # re-run; failing here would make a working install look like a failed one.
  setup_host_run || {
    say ''
    say 'Host setup did not finish. Polaris is installed; run this yourself:'
    say "  $setup_command"
  }
fi

say ''
# The closing lines report what the package manager did, read from the installed
# version before and after. PUBLISHED_TAG only explains a run that changed
# nothing: it and each repository's index are separate files on the CDN, each
# cached on its own clock, so the tag can name a release that the index the
# package manager just read does not carry yet.
if [ "$dry_run" -eq 1 ]; then
  say 'Nothing was changed. After a real run, start Polaris and open the console:'
else
  installed_after="$(installed_version polaris)"
  [ -n "$installed_after" ] ||
    die 'the package manager finished, but Polaris is not installed. Its output above says why.'
  if [ "$installed_after" != "$installed_before" ]; then
    if [ -z "$installed_before" ]; then
      say "Installed Polaris $installed_after."
    else
      say "Upgraded Polaris from $installed_before to $installed_after."
    fi
  else
    say "Polaris $installed_after was already installed, and the package manager left it as it is."
    served="$(served_version)"
    if [ -n "$served" ] && [ "${installed_after%-*}" = "$served" ]; then
      # A beta carries the version of the release it precedes: 1.4.13-beta.3 and
      # 1.4.13 are both 1.4.13-1, so the package manager sees nothing to do.
      reinstall_targets='polaris'
      [ -n "$(installed_version polaris-kms)" ] && reinstall_targets='polaris polaris-kms'
      if matches fedora; then
        reinstall="dnf reinstall $reinstall_targets"
      else
        reinstall="pacman -Syu $reinstall_targets"
      fi
      say 'That is the version the repository serves. A beta carries the version of the'
      say "release it precedes, so if this host runs a $served beta, it still does."
      say 'To replace it with the release, run this, then restart Polaris:'
      say "  ${SUDO:+$SUDO }$reinstall"
    elif [ -n "$served" ]; then
      if matches fedora; then
        refresh='dnf upgrade --refresh polaris'
      else
        refresh='pacman -Syu'
      fi
      say "The repository serves $served. If that is newer, the package manager read an"
      say 'older copy of its index; in a few minutes, run:'
      say "  ${SUDO:+$SUDO }$refresh"
    fi
  fi
  say ''
  if [ "$reboot_first" -eq 1 ]; then
    say 'Reboot first. After the reboot, set up the host, start Polaris and open the console:'
    say "  $setup_command"
  elif [ "$run_setup" -eq 0 ]; then
    say 'Set up the host, start Polaris and open the console:'
    say "  $setup_command"
  else
    say 'Start it and open the console:'
  fi
fi
say '  systemctl --user enable --now polaris'
say '  https://localhost:47990/#/welcome'
say ''
say 'Upgrades now come with the rest of the system.'
say 'DRM/KMS capture is a separate package if you use it:'
if matches fedora; then
  say '  sudo dnf install polaris-kms && sudo -H polaris --setup-host --enable-kms'
else
  say '  sudo pacman -S polaris-kms && sudo -H polaris --setup-host --enable-kms'
fi
# Only members of the polaris-kms group can run the helper. --enable-kms adds the
# user to it, and a session keeps the groups it logged in with. 1.4.13 points the
# service at the helper on that first run, and later releases wait for a run
# from a session that has the group, so running it again after the login is
# right on both. Each run says what comes next.
say 'The first time, --enable-kms adds you to the polaris-kms group, and a session'
say 'picks up its groups at login. Log out and back in, or reboot where lingering'
say 'is on (headless boot turns it on), then run it again and do what it prints.'
