#!/bin/sh
# Add the Polaris repository and install Polaris.
#
#   curl -fsSL https://repo.papi-ux.com/install.sh | sh
#
# It does what docs/repositories.md documents by hand, in the order that page
# gives, and nothing else. Every step is safe to repeat: the pacman section is
# guarded, the keys are idempotent imports, and a package already installed is
# left alone by the package manager.
#
# Options, which need `sh -s --` because the script arrives on stdin:
#   curl -fsSL https://repo.papi-ux.com/install.sh | sh -s -- --dry-run
#
#   --dry-run   print every command instead of running it
#   --no-setup  skip `polaris --setup-host`, leaving udev rules unapplied
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

# An ostree host layers rather than installs, and rpm-ostree never asks about a
# key, so the import cannot be left to the package manager.
ostree=0
[ -f /run/ostree-booted ] && ostree=1

say 'Polaris installer'
say "  distribution: ${PRETTY_NAME:-$distro}"
[ "$ostree" -eq 1 ] && say '  image based:  yes, Polaris will be layered'
[ "$dry_run" -eq 1 ] && say '  dry run:      nothing will be changed'
say ''

install_fedora() {
  need curl
  # dnf offers the key from gpgkey= and waits for an answer. A script cannot
  # answer it, and repo_gpgcheck=1 means an unanswered prompt fails the metadata
  # check rather than installing anything, so the key goes in explicitly.
  say "Importing the signing key. Fingerprint: $FINGERPRINT"
  sudo_run rpm --import "$BASE_URL/polaris.gpg"
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
  say 'Installing Polaris.'
  sudo_run dnf install -y polaris
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
  say 'Installing Polaris.'
  # --needed so a re-run is a no-op rather than a reinstall. Without it pacman
  # happily rebuilds an up-to-date package, which makes the second run of an
  # installer look like it did something it did not need to.
  sudo_run pacman -Sy --noconfirm --needed polaris
}

case "$distro" in
  steamos)
    die 'SteamOS is not served by a repository, and will not be: the rootfs is
read-only and pacman state does not survive a SteamOS update. Follow
https://papi-ux.com/docs/steamos/ instead.'
    ;;
  ubuntu|debian)
    die 'Ubuntu and Debian are not served by a repository yet. Install the .deb
from https://github.com/papi-ux/polaris/releases instead.'
    ;;
esac

if matches fedora; then
  install_fedora
elif matches arch; then
  install_arch
else
  die "no repository for $distro. Fedora, Bazzite and other ostree hosts, Arch
and CachyOS are served; every other host installs a release package from
https://github.com/papi-ux/polaris/releases"
fi

if [ "$ostree" -eq 1 ]; then
  exit 0
fi

if [ "$run_setup" -eq 1 ]; then
  say ''
  say 'Applying host setup.'
  # Not fatal. The package is installed either way, and setup-host can be
  # re-run; failing here would make a working install look like a failed one.
  setup_host_run || {
    say ''
    say 'Host setup did not finish. Polaris is installed; run this yourself:'
    say '  sudo -H polaris --setup-host'
  }
fi

say ''
say 'Installed. Start it and open the console:'
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
