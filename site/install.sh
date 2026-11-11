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
# The run is four steps, and every command is printed under its step before it
# runs. What the package manager and host setup print goes to a log file, mode
# 0600, named at the start and at the end; a command that fails shows the end
# of its output right there. Colour, symbols and a live status line are only
# for a terminal: a pipe, a file, TERM=dumb or NO_COLOR gets the same words.
#
# POSIX sh on purpose. This runs before Polaris exists on the host, on whatever
# /bin/sh the distribution ships, so it cannot assume bash.

set -eu

BASE_URL='https://repo.papi-ux.com'
FINGERPRINT='58017EDFFA9F803E07ED26F835F13F14FAAD15CC'
# Where Fedora keeps the checked key, beside its own, for gpgkey= to name.
KEY_PATH='/etc/pki/rpm-gpg/RPM-GPG-KEY-polaris'
dry_run=0
run_setup=1
# Where what each command prints goes. It is made when the first step starts,
# so a refusal leaves nothing behind, and a dry run never makes one. Without it
# commands print to the terminal, as they always did.
log_file=''

# Never fails, so a full /tmp cannot stop an install that is otherwise fine.
log_line() {
  [ -z "$log_file" ] || { printf '%s\n' "$*" >> "$log_file"; } 2>/dev/null || :
}

# Defined before the argument loop, because --help calls say. A function used above its
# definition is a runtime failure that sh -n does not see.
say() { printf '%s\n' "$*"; log_line "$*"; }
die() {
  printf 'polaris install: %s\n' "$*" >&2
  log_line "polaris install: $*"
  exit 1
}

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

# Colour, symbols and the live status line need a terminal. Anything else, and
# NO_COLOR or TERM=dumb, gets the same lines as plain words, so they read the
# same in a log, in a pipe or through a screen reader. The symbols fall back to
# ASCII outside a UTF-8 locale.
live=0
fancy=0
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != dumb ]; then
  live=1
  [ -n "${NO_COLOR:-}" ] || fancy=1
fi
utf8=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) utf8=1 ;;
esac
esc="$(printf '\033')"
cr="$(printf '\r')"
c_dim='' c_bold='' c_ok='' c_bad='' c_warn='' c_off=''
mark_done='' mark_failed='' mark_skipped='' spinner='' bar='|' sep='-' arrow='->'
if [ "$fancy" -eq 1 ]; then
  c_dim="${esc}[2m" c_bold="${esc}[1m" c_ok="${esc}[32m" c_bad="${esc}[31m" c_warn="${esc}[33m" c_off="${esc}[0m"
  if [ "$utf8" -eq 1 ]; then
    mark_done='✓' mark_failed='✗' mark_skipped='–' bar='│' sep='·' arrow='→'
    spinner='⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏'
  else
    spinner='. o O o'
  fi
fi

# Lines under a step: a note, a command, and the contents of a file it writes.
note() { printf '      %s\n' "$*"; log_line "      $*"; }
show_command() { printf '      %s$ %s%s\n' "$c_dim" "$*" "$c_off"; log_line "      \$ $*"; }
show_file() {
  while IFS= read -r file_line; do
    printf '        %s%s%s\n' "$c_dim" "$file_line" "$c_off"
    log_line "        $file_line"
  done
}

step_title=''
# Starts step $1 of four, named $2, with $3 an optional note beside the name.
step() {
  open_log
  [ "$1" -ne 1 ] || say ''
  step_title="$2"
  printf '%s[%s/4]%s %s%s%s%s\n' "$c_dim" "$1" "$c_off" "$c_bold" "$2" "$c_off" "${3:+  $c_dim$3$c_off}"
  log_line "[$1/4] $2${3:+  $3}"
}
# The line that ends a step says done, failed or skipped in words, whatever the
# colour and the symbol say. A dry run does nothing, so it reports no done.
step_result() {
  if [ -n "$2" ]; then
    printf '    %s%s %s%s%s\n' "$1" "$2" "$3" "$c_off" "${4:+  $4}"
  else
    printf '      %s%s%s%s\n' "$1" "$3" "${1:+$c_off}" "${4:+  $4}"
  fi
  log_line "      $3${4:+  $4}"
}
step_done() { [ "$dry_run" -eq 1 ] || step_result "$c_ok" "$mark_done" 'done' "$*"; }
step_failed() { step_result "$c_bad" "$mark_failed" failed "$*"; }
step_skipped() { step_result "$c_warn" "$mark_skipped" skipped "$*"; }

log_tried=0
log_path_shown=0
# The log is private to whoever runs this, because package manager output can
# name the account and the host's packages. mktemp makes it 0600.
open_log() {
  { [ "$dry_run" -eq 0 ] && [ "$log_tried" -eq 0 ]; } || return 0
  log_tried=1
  log_stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)" || log_stamp=''
  made="$(mktemp "${TMPDIR:-/tmp}/polaris-install-$log_stamp-XXXXXX.log" 2>/dev/null)" ||
    made="$(mktemp "${TMPDIR:-/tmp}/polaris-install-$log_stamp.XXXXXX" 2>/dev/null)" || made=''
  # A mktemp that only fills in trailing Xs takes the first name literally.
  case "$made" in *XXXXXX*) rm -f -- "$made"; made="$(mktemp "${TMPDIR:-/tmp}/polaris-install-$log_stamp.XXXXXX" 2>/dev/null)" || made='' ;; esac
  if [ -z "$made" ]; then
    say 'No log file could be made, so every command prints here as it runs.'
    return 0
  fi
  case "$made" in /*) ;; *) made="$PWD/$made" ;; esac
  chmod 600 "$made" 2>/dev/null || :
  log_file="$made"
  log_line "Polaris installer log, $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || :)"
  log_line "Host: ${PRETTY_NAME:-$distro}${VERSION_ID:+ (VERSION_ID $VERSION_ID)}"
  log_line "Run as: $(id -un 2>/dev/null || id -u)${SUDO:+, through sudo}$([ "$run_setup" -eq 1 ] || printf ', with --no-setup')"
  printf '%sLog: %s%s\n' "$c_dim" "$log_file" "$c_off"
}
show_log_path() {
  [ -n "$log_file" ] || return 0
  printf '%sFull log: %s%s\n' "$c_dim" "$log_file" "$c_off"
  log_path_shown=1
}

# The width the live status line is cut to, so it never wraps onto a second line.
term_columns() {
  columns="$({ stty size < /dev/tty; } 2>/dev/null)" || columns=''
  columns="${columns#* }"
  case "$columns" in '' | *[!0-9]*) columns="$(tput cols 2>/dev/null)" || columns='' ;; esac
  case "$columns" in '' | 0 | *[!0-9]*) columns=80 ;; esac
  printf '%s\n' "$columns"
}

# Reads what a command prints. Every line goes to the log as it is, and the
# latest one is redrawn in place as a single status line. It is drawn only once
# output arrives, so a sudo password prompt is never written over.
live_lines() {
  live_width=$(( $(term_columns) - 9 ))
  [ "$live_width" -ge 10 ] || live_width=10
  # shellcheck disable=SC2086
  set -- $spinner
  while IFS= read -r live_line || [ -n "$live_line" ]; do
    { printf '%s\n' "$live_line" >> "$log_file"; } 2>/dev/null || :
    # What a carriage return would leave on screen, without escape sequences.
    live_line="${live_line##*"$cr"}"
    case "$live_line" in '' | *"$esc"*) continue ;; esac
    # dnf's percentage, rate and size columns.
    live_line="${live_line% [0-9]*% |*}"
    frame=' '
    if [ "$#" -gt 0 ]; then frame="$1"; shift; set -- "$@" "$frame"; fi
    printf "\\r%s[K      %s%s%s %.${live_width}s" "$esc" "$c_dim" "$frame" "$c_off" "$live_line"
  done
  printf '\r%s[K' "$esc"
}

# A command failed. This shows the step, the end of what the command printed
# and where the rest is, before the caller adds its own explanation or set -e
# ends the run with the command's status. A question a --noconfirm run took the
# default answer to is usually why it stopped, so one that scrolled out of the
# window is shown too.
last_output=1
show_failure() {
  # Counted first: the failed line below goes to the log too.
  output_end="$(wc -l < "$log_file")"
  step_failed "$step_title: $3 exited with status $1"
  output_from=$(( output_end - 29 ))
  [ "$output_from" -ge "$2" ] || output_from="$2"
  if [ "$output_from" -gt "$2" ]; then
    asked="$(sed -n "$2,$(( output_from - 1 ))p" "$log_file" | grep '\[[Yy]/[Nn]\]' || :)"
    if [ -n "$asked" ]; then
      note 'It answered these questions with their default:'
      printf '%s\n' "$asked" | while IFS= read -r asked_line; do
        printf '      %s%s%s %s\n' "$c_dim" "$bar" "$c_off" "$asked_line"
      done
      note 'The end of its output:'
    fi
  fi
  if [ "$output_end" -ge "$output_from" ]; then
    sed -n "$output_from,${output_end}p" "$log_file" | while IFS= read -r tail_line || [ -n "$tail_line" ]; do
      printf '      %s%s%s %s\n' "$c_dim" "$bar" "$c_off" "$tail_line"
    done
  else
    note 'It printed nothing.'
  fi
  printf '      '
  show_log_path
}

# Runs "$@" with its output going to the log, after the caller has printed it.
# $1 is 1 for a long command that gets the live status line on a terminal. A
# failure is shown, and the command's own status is returned for the caller,
# exactly as running it directly would.
logged() {
  wants_live="$1"
  shift
  if [ -z "$log_file" ]; then
    "$@"
    return
  fi
  # Each command's output starts on a line of its own, so counting lines finds it.
  [ -z "$(tail -c 1 "$log_file" 2>/dev/null)" ] || log_line ''
  last_output=$(( $(wc -l < "$log_file") + 1 ))
  command_status=0
  if [ "$wants_live" -eq 1 ] && [ "$live" -eq 1 ]; then
    # The command's status comes back on fd 4, past the status line reading its
    # output, and fd 3 is the terminal. The command itself gets neither.
    exec 3>&1
    command_status="$( { { s=0; "$@" 2>&1 3>&- 4>&- || s=$?; printf '%s' "$s" >&4; } |
      live_lines >&3; } 4>&1 )" || :
    exec 3>&-
    case "$command_status" in '' | *[!0-9]*) command_status=1 ;; esac
  else
    "$@" >> "$log_file" 2>&1 || command_status=$?
  fi
  [ -z "$(tail -c 1 "$log_file" 2>/dev/null)" ] || log_line ''
  [ "$command_status" -ne 0 ] || return 0
  show_failure "$command_status" "$last_output" "$*"
  return "$command_status"
}

# Printed before it runs, so a piped script is never doing something unseen.
live_next=0
run() {
  run_live="$live_next"
  live_next=0
  show_command "$*"
  [ "$dry_run" -eq 1 ] && return 0
  logged "$run_live" "$@"
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
# The same, for a package manager: its long output gets the live status line.
sudo_run_live() { live_next=1; run ${SUDO:+$SUDO} "$@"; }
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
# way the run can stop. A run that stops with a log names it last, unless the
# failure that stopped it already did.
key_dir=''
remove_key_dir() {
  [ -z "$key_dir" ] || rm -rf -- "$key_dir"
}
on_exit() {
  exit_status=$?
  remove_key_dir || :
  # An interrupt can leave the live status line half drawn.
  [ "$exit_status" -eq 0 ] || [ "$live" -eq 0 ] || printf '\r%s[K' "$esc"
  if [ "$exit_status" -ne 0 ] && [ -n "$log_file" ] && [ "$log_path_shown" -eq 0 ]; then
    show_log_path || :
  fi
}
trap on_exit EXIT
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
  step 1 'Signing key' "pinned fingerprint $FINGERPRINT"
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
  show_command "rpmkeys --root $key_root --noplugins --list"
  if [ "$dry_run" -eq 1 ]; then
    note "A real run stops here unless that lists exactly one key, $FINGERPRINT."
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
  note 'rpm reads one key, and its fingerprint is the pinned one.'
}

printf '%sPolaris installer%s %s %s\n' "$c_bold" "$c_off" "$sep" "${PRETTY_NAME:-$distro}"
[ "$ostree" -eq 1 ] && say 'Image based: Polaris will be layered.'
[ "$dry_run" -eq 1 ] && say 'Dry run: nothing will be changed.'

# The same file scripts/build-package-repos.sh serves as fedora/polaris.repo,
# except that gpgkey= names the key this run checked.
fedora_repo_file() {
  printf '%s\n' '[polaris]' 'name=Polaris' \
    "baseurl=$BASE_URL/fedora/\$releasever/\$basearch" \
    'enabled=1' 'gpgcheck=1' 'repo_gpgcheck=1' \
    "gpgkey=file://$KEY_PATH" 'metadata_expire=6h'
}

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
  sudo_run rpm --import "$key_file"
  # The repository file is written here, not downloaded. A served one could
  # turn gpgcheck off, or point gpgkey= at a key nobody checked, which dnf -y
  # then fetches and imports without asking. This one names the checked key by
  # its local path, so dnf never fetches a key, and its baseurl is BASE_URL's.
  # It overwrites the file an earlier run downloaded, as every run always has.
  sudo_run install -D -m 0644 "$key_file" "$KEY_PATH"
  step_done "imported, and kept at $KEY_PATH"
  [ "$dry_run" -eq 1 ] || fedora_repo_file > "$key_root/polaris.repo"
  step 2 'Repository' '/etc/yum.repos.d/polaris.repo'
  note '/etc/yum.repos.d/polaris.repo will read:'
  fedora_repo_file | show_file
  sudo_run install -m 0644 "$key_root/polaris.repo" /etc/yum.repos.d/polaris.repo
  step_done 'written'
  if [ "$ostree" -eq 1 ]; then
    step 3 'Packages' 'layering Polaris'
    sudo_run_live rpm-ostree install polaris
    step_done 'layered, for the next boot'
    step 4 'Host setup'
    step_skipped 'it runs after the reboot'
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
    step 3 'Packages' 'installing Polaris'
    sudo_run_live dnf install -y polaris
  elif [ -n "$(installed_version polaris-kms)" ]; then
    step 3 'Packages' 'upgrading Polaris and polaris-kms'
    sudo_run_live dnf upgrade -y polaris polaris-kms
  else
    step 3 'Packages' 'upgrading Polaris'
    sudo_run_live dnf upgrade -y polaris
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

# The section scripts/build-package-repos.sh serves as arch/polaris.conf, less
# its header. Without SigLevel pacman would fall back to the global default,
# which does not require a signed database.
arch_section_lines() {
  printf '%s\n' 'SigLevel = Required DatabaseRequired' "Server = $BASE_URL/arch/\$arch"
}

# The settings in every [polaris] section of pacman.conf, one per line, comments
# and blank lines dropped and the spacing around = made uniform, as pacman reads
# them.
arch_section_present() {
  awk '
    { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
    line ~ /^\[/ { in_polaris = (line == "[polaris]"); next }
    !in_polaris || line == "" || line ~ /^#/ { next }
    { sub(/[[:space:]]*=[[:space:]]*/, " = ", line); gsub(/[[:space:]]+/, " ", line); print line }
  ' /etc/pacman.conf
}

# A [polaris] section already in pacman.conf is left alone, as it always was, but
# pacman uses it as it stands. So it must be exactly what this script writes:
# signatures required on the database and the packages, from BASE_URL. Anything
# else, an Include among it, stops the run before any key is trusted.
check_arch_section() {
  present="$(arch_section_present)"
  unexpected="$(printf '%s\n' "$present" | grep -Fvx "$(arch_section_lines)" | grep . || true)"
  missing="$(arch_section_lines | grep -Fvx "$present" || true)"
  [ -z "$unexpected" ] && [ -z "$missing" ] && return 0
  die "/etc/pacman.conf already has a [polaris] section, and pacman would use it as
it stands. It does not match what this installer writes, so this stopped before
trusting the key or running pacman, and nothing on this host was changed.
${unexpected:+Settings it has that this installer does not write:
$(printf '%s\n' "$unexpected" | sed 's/^/  /')
}${missing:+Settings it lacks:
$(printf '%s\n' "$missing" | sed 's/^/  /')
}Replace that section with these lines and run this again:
  [polaris]
$(arch_section_lines | sed 's/^/  /')"
}

# pacman has no gpgkey= equivalent in a repository section, so both of these
# are required. polaris-keyring would remove them.
arch_add_key() {
  curl -fsSL "$BASE_URL/polaris.gpg" | ${SUDO:+$SUDO} pacman-key --add -
}
# The blank line keeps the header off a last line that has no newline.
arch_append_section() {
  { printf '\n[polaris]\n'; arch_section_lines; } | ${SUDO:+$SUDO} tee -a /etc/pacman.conf >/dev/null
}

install_arch() {
  need curl
  # Appending twice gives pacman a duplicated [polaris] repository, and pasting
  # the block again is exactly what someone does when a step looks like it
  # failed. The guard is why this script is safe to re-run.
  arch_section_exists=0
  if grep -q '^[[:space:]]*\[polaris\][[:space:]]*$' /etc/pacman.conf 2>/dev/null; then
    arch_section_exists=1
    need awk
    check_arch_section
  fi
  step 1 'Signing key' "pinned fingerprint $FINGERPRINT"
  show_command "curl -fsSL $BASE_URL/polaris.gpg | ${SUDO:+$SUDO }pacman-key --add -"
  [ "$dry_run" -eq 1 ] || logged 0 arch_add_key
  sudo_run pacman-key --lsign-key "$FINGERPRINT"
  step_done 'added, and signed locally so pacman trusts it'
  step 2 'Repository' '/etc/pacman.conf'
  if [ "$arch_section_exists" -eq 1 ]; then
    step_skipped 'already present in /etc/pacman.conf, as this installer writes it; leaving it alone'
  else
    # Written here rather than downloaded, so a served file cannot set SigLevel
    # = Never or TrustAll, or point Server somewhere else.
    note '/etc/pacman.conf gets this section:'
    { printf '[polaris]\n'; arch_section_lines; } | show_file
    show_command "${SUDO:+$SUDO }tee -a /etc/pacman.conf, given a blank line and the lines above"
    [ "$dry_run" -eq 1 ] || logged 0 arch_append_section
    step_done 'section added'
  fi
  # -Syu, not -Sy. Refreshing the databases and installing one package on top is
  # a partial upgrade, which Arch does not support: Polaris and what it pulls in
  # come from the new databases while the rest of the system stays on the old
  # ones. With -Sy an audit run left ten system packages pending, systemd among
  # them. --noconfirm because stdin is this script when it arrives through a
  # pipe, so pacman has nobody to ask.
  if [ -z "$installed_before" ]; then
    step 3 'Packages' 'installing Polaris'
    note 'Arch supports only full upgrades, so pacman upgrades the rest of the'
    note 'system in the same step.'
    sudo_run_live pacman -Syu --noconfirm --needed polaris || pacman_stopped 'pacman -Syu polaris'
  else
    # A package named as a target is installed at the version the repository
    # carries, even over a newer one: a host on a later build, such as a beta of
    # the next release, went back to the served release, and pacman only warned.
    # The full upgrade alone moves Polaris and polaris-kms when the repository
    # has something newer and leaves a newer build where it is, as dnf upgrade
    # does. It also upgrades whatever else is pending, so a re-run is not always
    # a no-op.
    step 3 'Packages' 'upgrading the system, Polaris included'
    note 'Polaris is installed, and Arch supports only full upgrades.'
    sudo_run_live pacman -Syu --noconfirm || pacman_stopped 'pacman -Syu'
  fi
}

# The package step's done line: what happened to Polaris, then how big the
# transaction was where the package manager printed that in English. dnf5
# totals each kind of change and pacman lists the packages; a summary this
# cannot read is left out rather than guessed.
package_summary() {
  if [ -z "$installed_before" ]; then
    summary="Polaris $installed_after installed"
  elif [ "$installed_after" != "$installed_before" ]; then
    summary="Polaris $installed_before $arrow $installed_after"
  else
    summary="Polaris $installed_after, unchanged"
  fi
  if [ -n "$log_file" ]; then
    transaction="$(sed -n "$1,\$p" "$log_file")"
    package_count=0
    for counted in $(printf '%s\n' "$transaction" | sed -n \
      -e 's/^ *Installing: *\([0-9][0-9]*\) packages*$/\1/p' \
      -e 's/^ *Upgrading: *\([0-9][0-9]*\) packages*$/\1/p' \
      -e 's/^ *Reinstalling: *\([0-9][0-9]*\) packages*$/\1/p' \
      -e 's/^ *Downgrading: *\([0-9][0-9]*\) packages*$/\1/p' \
      -e 's/^Packages (\([0-9][0-9]*\)).*/\1/p'); do
      package_count=$(( package_count + counted ))
    done
    package_size="$(printf '%s\n' "$transaction" | sed -n \
      -e 's/^After this operation, \(.*[^ ]\) extra will be used.*/\1/p' \
      -e 's/^Total Installed Size: *\(.*[^ ]\) *$/\1/p' | head -n 1)"
    details=''
    case "$package_count" in
      0) ;;
      1) details='1 package' ;;
      *) details="$package_count packages" ;;
    esac
    [ -z "$package_size" ] || details="${details:+$details, }$package_size"
    [ -z "$details" ] || summary="$summary ($details)"
    warnings="$(printf '%s\n' "$transaction" | grep -c '^[Ww]arning:' || :)"
    case "$warnings" in
      0) ;;
      1) summary="$summary; 1 warning in the log" ;;
      *) summary="$summary; $warnings warnings in the log" ;;
    esac
  fi
  printf '%s\n' "$summary"
}

# What host setup printed, sorted. Its log lines and its standing advice go to
# the log only. The input group command is kept for the closing lines, and so is
# the headless boot option. Anything else, a warning or advice this does not
# recognise, is shown under the step as it is, so nothing new is ever hidden.
# Its log records are written by a thread of their own and can land in the
# middle of another line, before that line's newline, so a record that starts
# mid-line is moved onto a line of its own first.
headless_hint=0
seat_command=''
setup_warnings=0
setup_state=''
summarize_setup() {
  setup_output="$(sed -n "$1,\$p" "$log_file" |
    sed 's/\(.\)\(\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9.]*\]: \)/\1\
\2/g')"
  # shellcheck disable=SC2016
  while IFS= read -r setup_line; do
    case "$setup_line" in
      '' | '['*']: Info: '*) ;;
      '['*']: '*)
        printf '      %s%s%s\n' "$c_warn" "${setup_line#*]: }" "$c_off"
        log_line "      ${setup_line#*]: }"
        setup_warnings=$(( setup_warnings + 1 )) ;;
      'Linux host setup complete.') setup_state=complete ;;
      'Linux host setup: nothing to do.') setup_state=nothing ;;
      'The udev rules and modules-load configuration came from the package'* | \
      'Everything this step applied is also applied automatically at boot'* | \
      'Existing virtual gamepad nodes keep their previous access policy'* | \
      'Start Polaris directly with `polaris`'* | \
      'Mirror Desktop and Host Virtual Display still need a desktop session'* | \
      'The package provides the udev rules and modules-load configuration, and /dev/uinput' | \
      'and /dev/uhid are already usable by ['*']. Re-run with --enable-kms only if you' | \
      'need DRM/KMS capture.') ;;
      'For a host that boots with no monitor or desktop login'*'--enable-headless-boot.') headless_hint=1 ;;
      'Client gamepad and keyboard/mouse seat isolation additionally need ['*)
        found="$(printf '%s\n' "$setup_line" | sed -n 's/.* Run \[\(.*\)\] and log out and back in\..*/\1/p')"
        if [ -n "$found" ]; then
          seat_command="$found"
        else
          note "$setup_line"
        fi ;;
      *) note "$setup_line" ;;
    esac
  done <<EOF
$setup_output
EOF
  if [ "$setup_warnings" -gt 0 ]; then
    step_done 'with the warnings above'
  elif [ "$setup_state" = nothing ]; then
    step_done 'nothing to do; input devices are already usable'
  else
    step_done 'host ready, no reboot needed'
  fi
}

# Labelled lines at the end: a command to run, with what it is for.
#   $1 the label, $2 the label width, $3 the command or text, $4 its style
labelled() {
  printf "  %s%-$2s%s  %s%s%s\n" "$c_dim" "$1" "$c_off" "${4:-}" "$3" "${4:+$c_off}"
  log_line "$(printf "  %-$2s  %s" "$1" "$3")"
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
  if [ -n "$log_file" ]; then
    say ''
    show_log_path
  fi
  exit 0
fi

# Where the package manager's output begins in the log.
package_output="$last_output"
installed_after=''
if [ "$dry_run" -eq 0 ]; then
  installed_after="$(installed_version polaris)"
  if [ -n "$installed_after" ]; then
    step_done "$(package_summary "$package_output")"
  else
    step_failed 'the package manager finished, but Polaris is not installed'
  fi
fi

step 4 'Host setup'
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
    note "The running kernel, $running_kernel, has no modules in /usr/lib/modules, so a"
    note 'module that is not loaded yet cannot load before the next boot. Host setup'
    note 'loads uinput and uhid, so it waits until after a reboot.'
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
    note "The NVIDIA driver loaded now is $nvidia_loaded, and the installed NVIDIA"
    note "libraries are $nvidia_libraries. They work only at the same version, and the"
    note 'installed driver loads at the next boot.'
  fi
fi

if [ "$run_setup" -eq 1 ] && [ "$reboot_first" -eq 0 ]; then
  # Not fatal. The package is installed either way, and setup-host can be
  # re-run; failing here would make a working install look like a failed one.
  if setup_host_run; then
    if [ -n "$log_file" ]; then
      summarize_setup "$last_output"
    else
      step_done 'host setup finished'
    fi
  else
    note 'Host setup did not finish. Polaris is installed; run this yourself:'
    note "  $setup_command"
  fi
elif [ "$reboot_first" -eq 1 ]; then
  step_skipped 'reboot first'
else
  step_skipped 'left for you, as --no-setup asked'
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
  [ -n "$installed_after" ] ||
    die "the package manager finished, but Polaris is not installed. Its output${log_file:+, in the log,} says why."
  if [ "$installed_after" != "$installed_before" ]; then
    if [ -z "$installed_before" ]; then
      headline="Installed Polaris $installed_after."
    else
      headline="Upgraded Polaris from $installed_before to $installed_after."
    fi
    printf '%s%s%s\n' "$c_bold" "$headline" "$c_off"
    log_line "$headline"
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
      say ''
    elif [ -n "$served" ]; then
      if matches fedora; then
        refresh='dnf upgrade --refresh polaris'
      else
        refresh='pacman -Syu'
      fi
      say "The repository serves $served. If that is newer, the package manager read an"
      say 'older copy of its index; in a few minutes, run:'
      say "  ${SUDO:+$SUDO }$refresh"
      say ''
    fi
  fi
  if [ "$reboot_first" -eq 1 ]; then
    say 'Reboot first. After the reboot, set up the host, start Polaris and open the console:'
    labelled 'Set up' 8 "$setup_command"
  elif [ "$run_setup" -eq 0 ]; then
    say 'Set up the host, start Polaris and open the console:'
    labelled 'Set up' 8 "$setup_command"
  fi
fi
labelled 'Start it' 8 'systemctl --user enable --now polaris'
labelled 'Open' 8 'https://localhost:47990/#/welcome'
say ''
say 'Upgrades now come with the rest of the system.'
say 'Optional:'
if matches fedora; then
  labelled 'DRM/KMS capture' 15 'sudo dnf install polaris-kms'
else
  labelled 'DRM/KMS capture' 15 'sudo pacman -S polaris-kms'
fi
labelled '' 15 'sudo -H polaris --setup-host --enable-kms'
# Only members of the polaris-kms group can run the helper. --enable-kms adds the
# user to it, and a session keeps the groups it logged in with. 1.4.13 points the
# service at the helper on that first run, and later releases wait for a run
# from a session that has the group, so running it again after the login is
# right on both. Each run says what comes next.
labelled '' 15 'Run it again after you next log in, and do what it prints.' "$c_dim"
log_line 'The first time, --enable-kms adds you to the polaris-kms group, and a session'
log_line 'picks up its groups at login. Log out and back in, or reboot where lingering'
log_line 'is on (headless boot turns it on), then run it again and do what it prints.'
[ "$headless_hint" -eq 0 ] ||
  labelled 'Headless boot' 15 'sudo -H polaris --setup-host --enable-headless-boot'
[ -z "$seat_command" ] ||
  labelled 'Seat isolation' 15 "$seat_command, then log out and back in"
if [ -n "$log_file" ]; then
  say ''
  show_log_path
fi
