#!/bin/sh
# Choose a Polaris host, Nova player, or both on a Linux PC.
#   curl -fsSL https://repo.papi-ux.com/install.sh | sh
#   curl -fsSL https://repo.papi-ux.com/install.sh | sh -s -- --help
# A terminal reviews the selected role before Apply. Unattended invocations
# without a role retain the original Polaris host behavior. POSIX sh.

# The review deliberately sets dry_run only in its subshell.
# shellcheck disable=SC2030,SC2031
set -eu

BASE_URL='https://repo.papi-ux.com'
FINGERPRINT='58017EDFFA9F803E07ED26F835F13F14FAAD15CC'
# Where Fedora keeps the checked key, beside its own, for gpgkey= to name.
KEY_PATH='/etc/pki/rpm-gpg/RPM-GPG-KEY-polaris'
NOVA_FEED='https://updates.papi-ux.com/nova'
# Exact publisher descriptor, including the feed URL and exported signing key.
NOVA_REPO_SHA256='c49f6e03546c35b92350d51d64b12355fbfabadb6cbe3060e0f653ce848d2f75'
NOVA_FINGERPRINT='58017EDFFA9F803E07ED26F835F13F14FAAD15CC'
NOVA_KEY_SHA256='0ae5085fb5582b5cdb18f64df6b4b41cafe66960b733f4aba855475e054320c2'
NOVA_APP='com.papi_ux.Nova'
NOVA_RUNTIME='runtime/org.kde.Platform/x86_64/6.10'
FLATHUB_REPO='https://dl.flathub.org/repo/flathub.flatpakrepo'
dry_run=0
run_setup=1
enable_kms=0
enable_headless=0
role=host
selected_role=0
channel=stable
selected_channel=0
operation=install
unattended=0
plain=0
motion=1
review_only=0
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
    --role)
      case "${2:-}" in host|client|both) role="$2"; selected_role=1; shift ;;
        *) echo 'Use --role host, client or both.' >&2; exit 2 ;; esac ;;
    --channel)
      case "${2:-}" in stable|beta) channel="$2"; selected_channel=1; shift ;;
        *) echo 'Use --channel stable or beta.' >&2; exit 2 ;; esac ;;
    --uninstall) operation=uninstall ;;
    --yes|--non-interactive) unattended=1 ;;
    --plain|--no-color) plain=1 ;;
    --reduced-motion) motion=0 ;;
    --dry-run) dry_run=1 ;;
    --no-setup) run_setup=0 ;;
    --enable-kms) enable_kms=1 ;;
    --enable-headless-boot) enable_headless=1 ;;
    -h|--help)
      say 'curl -fsSL https://repo.papi-ux.com/install.sh | sh'
      say 'Add options with sh -s -- --role host|client|both'
      say '  --channel stable|beta    Nova signed Flatpak branch (default stable)'
      say '  --uninstall              remove only the selected products; keep user data'
      say '  --yes, --non-interactive apply without keyboard input (default role: host)'
      say '  --plain, --reduced-motion  use static terminal output'
      say '  --dry-run   print every command instead of running it'
      say '  --no-setup  skip polaris --setup-host'
      say '  --enable-kms             install the KMS helper and grant this account display capture'
      say '  --enable-headless-boot   start Polaris at boot, before this account signs in'
      exit 0 ;;
    *) printf 'polaris install: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

host_options_selected() { [ "$enable_kms" -eq 1 ] || [ "$enable_headless" -eq 1 ]; }
if host_options_selected; then
  [ "$role" != client ] && [ "$operation" = install ] ||
    die 'Host options require a host or combined installation.'
  [ "$run_setup" -eq 1 ] || die 'Host options require host setup. Remove --no-setup to use them.'
fi

# Colour, symbols and the live status line need a terminal. Anything else, and
# NO_COLOR or TERM=dumb, gets the same lines as plain words, so they read the
# same in a log, in a pipe or through a screen reader. The symbols fall back to
# ASCII outside a UTF-8 locale.
live=0
fancy=0
if [ -t 1 ] && [ "$plain" -eq 0 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
  fancy=1
  [ -n "${REDUCE_MOTION:-}" ] || live="$motion"
fi
utf8=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) utf8=1 ;;
esac
esc="$(printf '\033')"
cr="$(printf '\r')"
lf='
'
c_dim='' c_bold='' c_focus='' c_ok='' c_bad='' c_warn='' c_off=''
review_bullet='-'
mark_done='' mark_failed='' mark_skipped='' spinner='' bar='|' sep='-' arrow='->'
if [ "$fancy" -eq 1 ]; then
  c_dim="${esc}[2m" c_bold="${esc}[1m" c_focus="${esc}[1;36m" c_ok="${esc}[32m" c_bad="${esc}[31m" c_warn="${esc}[33m" c_off="${esc}[0m"
  if [ "$utf8" -eq 1 ]; then
    mark_done='✓' mark_failed='✗' mark_skipped='–' bar='│' sep='·' arrow='→'
    review_bullet='•'
    spinner='⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏'
  else
    spinner='. o O o'
  fi
fi

# Lines under a step: a note, a command, and the contents of a file it writes.
note() { printf '      %s\n' "$*"; log_line "      $*"; }
show_command() { printf '      %s$ %s%s\n' "$c_dim" "$*" "$c_off"; log_line "      \$ $*"; }
# Preserve argv boundaries when, for example, TMPDIR contains a space or quote.
command_words() {
  space=''
  for word do
    printf '%s' "$space"
    case "$word" in
      ''|*[!a-zA-Z0-9_./:=,+@%-]*)
        printf "'"
        while [ "${word#*\'}" != "$word" ]; do
          printf '%s%s' "${word%%\'*}" "'\\''"
          word="${word#*\'}"
        done
        printf "%s'" "$word" ;;
      *) printf '%s' "$word" ;;
    esac
    space=' '
  done
}
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
  log_line "Operation: $operation; role: $role; Nova branch (when selected): $channel"
  if has_host && host_options_selected; then
    log_line "Host options requested: KMS capture=$enable_kms, start before sign-in=$enable_headless"
  fi
  log_line "Host: ${PRETTY_NAME:-$distro}${VERSION_ID:+ (VERSION_ID $VERSION_ID)}"
  log_line "Run as: $(id -un 2>/dev/null || id -u)$([ "$run_setup" -eq 1 ] || printf ', with --no-setup')"
  printf '%sLog: %s%s\n' "$c_dim" "$log_file" "$c_off"
}
show_log_path() {
  [ -n "$log_file" ] || return 0
  printf '%sFull log: %s%s\n' "$c_dim" "$log_file" "$c_off"
  log_path_shown=1
}

# Width of the terminal used for progress and the role picker.
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
  show_failure "$command_status" "$last_output" "$(command_words "$@")"
  return "$command_status"
}

# Printed before it runs, so a piped script is never doing something unseen.
live_next=0
run() {
  run_live="$live_next"
  live_next=0
  show_command "$(command_words "$@")"
  [ "$dry_run" -eq 1 ] && return 0
  logged "$run_live" "$@"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required and was not found"
}

# With curl | sh, stdin is program text. Read the foreground user's answers
# from the controlling terminal, never from the script or an automation pipe.
guided=0
if [ "$dry_run" -eq 0 ] && [ "$unattended" -eq 0 ] && [ -z "${CI:-}" ] && [ -t 1 ] && [ -t 2 ]; then
  if [ -t 0 ]; then
    guided=1
  else
    case "${0##*/}" in sh|dash|bash|ash) [ ! -p /dev/stdin ] || guided=1 ;; esac
  fi
fi

# Root is reached through sudo rather than by demanding the whole script run as
# root: fewer commands run privileged, and it matches what the docs show.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=''
else
  SUDO='sudo'
  [ "$guided" -eq 1 ] || SUDO='sudo -n'
fi
sudo_run() { run ${SUDO:+$SUDO} "$@"; }
# The same, for a package manager: its long output gets the live status line.
sudo_run_live() { live_next=1; run ${SUDO:+$SUDO} "$@"; }
setup_command="${SUDO:+$SUDO -H }polaris --setup-host"

# setup-host wants a root HOME so it does not write into the invoking user's.
# `sudo -H` does that; as root there is nothing to correct.
setup_host_run() {
  if [ -n "$SUDO" ]; then
    # SUDO is one of two fixed prefixes: sudo, or sudo -n for automation.
    # shellcheck disable=SC2086
    run $SUDO -H polaris --setup-host
  else
    run polaris --setup-host
  fi
}

# Read data instead of evaluating os-release as shell code. Keep the desktop
# name separate from the distribution's edition (a KDE session can run on either).
os_release="$(cat /etc/os-release 2>/dev/null || cat /usr/lib/os-release 2>/dev/null)" ||
  die 'Linux os-release is unavailable. See https://papi-ux.com/docs/quickstart/'
os_field() (
  while IFS= read -r line; do
    case "$line" in
      "$1="*)
        value=${line#*=}
        case "$value" in
          \"*\"|\'*\') value=${value#?}; value=${value%?} ;;
        esac
        printf '%s\n' "$value"
        return
        ;;
    esac
  done <<OS_RELEASE
$os_release
OS_RELEASE
)
distro="$(os_field ID)"
id_like="$(os_field ID_LIKE)"
VERSION_ID="$(os_field VERSION_ID)"
PRETTY_NAME="$(os_field PRETTY_NAME)"
edition="$(os_field VARIANT)"
[ -n "$edition" ] || edition="$(os_field VARIANT_ID)"
arch="$(uname -m)"

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

# An ostree host layers rather than installs. rpm-ostree takes the key from the
# repository file's gpgkey= line by itself and never asks about it.
ostree=0
stat /run/ostree-booted >/dev/null 2>&1 && ostree=1

# The signing key is downloaded once, into a directory of its own, and that same
# file is checked and then imported. Removing the directory on exit covers every
# way the run can stop. A run that stops with a log names it last, unless the
# failure that stopped it already did.
key_dir=''
nova_tmp=''
phase=''
host_result=''
installer_restart_pending=0
probe_finish_console=0
finish_setup_deferred=0
finish_nova_ref=''
finish_console_url=''
choice_tty=''
restore_choice_tty() {
  if [ -n "$choice_tty" ]; then stty "$choice_tty" <&5; choice_tty=''; fi
}
remove_key_dir() {
  [ -z "$key_dir" ] || rm -rf -- "$key_dir"
}
on_exit() {
  exit_status=$?
  restore_choice_tty || :
  remove_key_dir || :
  [ -z "$nova_tmp" ] || rm -rf -- "$nova_tmp"
  if [ "$exit_status" -ne 0 ] && [ "$phase" = client ] && [ "$dry_run" -eq 0 ]; then
    say "Check the selected user installation: flatpak info --user $nova_ref"
  fi
  if [ "$exit_status" -ne 0 ] && [ "$role" = both ] && [ "$dry_run" -eq 0 ]; then
    case "$phase" in
      host) say 'Both stopped during the Polaris step. Nova was not attempted.' ;;
      client) say "Both stopped during the Nova step. Polaris: $host_result."
        say 'Completed changes were retained. Review the Nova step before retrying that role.' ;;
    esac
  fi
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
  show_command "$(command_words rpmkeys --root "$key_root" --noplugins --list)"
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

# The same file scripts/build-package-repos.sh serves as fedora/polaris.repo,
# except that gpgkey= names the key this run checked.
fedora_repo_file() {
  printf '%s\n' '[polaris]' 'name=Polaris' \
    "baseurl=$BASE_URL/fedora/\$releasever/\$basearch" \
    'enabled=1' 'gpgcheck=1' 'repo_gpgcheck=1' \
    "gpgkey=file://$KEY_PATH" 'metadata_expire=6h'
}

# Read one rpm-ostree snapshot. The first deployment is the boot default;
# older entries below the booted one are rollbacks, never install targets.
read_ostree_target() {
  need python3
  ostree_state="$(python3 -I - "${enable_kms:-0}" <<'PY'
import hashlib
import json
import re
import subprocess
import sys

def output(*cmd):
    return subprocess.check_output(cmd, text=True)

def checksum(value):
    if not isinstance(value, str) or not re.fullmatch("[0-9a-f]{64}", value):
        raise ValueError("invalid deployment checksum")
    return value

selected = ("polaris", "polaris-kms") if sys.argv[1] == "1" else ("polaris",)

def selected_rpms(packages):
    matches = {}
    for package in packages:
        name, version, release_arch = package.rsplit("-", 2)
        if not name or not version or "." not in release_arch:
            raise ValueError("incomplete RPM inventory entry")
        if name in selected:
            evra = f"{version.removeprefix('0:')}-{release_arch}"
            if name in matches or not re.fullmatch(r"[\w.+:~^%]+-[\w.+~^%]+\.x86_64", evra):
                raise ValueError(f"ambiguous {name} RPM identity")
            matches[name] = evra
    return matches

def identity(packages, name):
    return f"{name}-{packages[name]}" if name in packages else "-"

try:
    status = json.loads(output("rpm-ostree", "status", "--json"))
    if status["transaction"] is not None:
        raise ValueError("another rpm-ostree transaction is active")
    deployments = status["deployments"]
    boot, = [d for d in deployments if d["booted"] is True]
    target = deployments[0]
    waiting = target is not boot
    if (any(type(d[k]) is not bool for d in deployments for k in ("staged", "booted"))
            or [d for d in deployments if d["staged"]] != ([target] if waiting else [])
            or (waiting and deployments[1] is not boot) or target["osname"] != boot["osname"]):
        raise ValueError("cannot identify a single staged deployment for this boot")
    if boot.get("live-inprogress") or target.get("finalization-locked"):
        raise ValueError("a live change is in progress or the staged deployment is locked")
    boot_id, target_id = checksum(boot["checksum"]), checksum(target["checksum"])
    pristine = boot["unlocked"] == "none" and not boot.get("live-replaced")
    # Querying all matching RPMs succeeds with zero rows for an absent package.
    # A failed database read must never be interpreted as permission to install.
    installed = output("rpm", "-qa", "--qf", "%{NEVRA}\\n", *selected).splitlines()
    live = selected_rpms(installed)
    if len(installed) != len(live):
        raise ValueError("could not identify the booted Polaris RPMs")
    staged = {}
    if waiting:
        # The unfiltered list reads package metadata from this immutable commit.
        rows = output("rpm-ostree", "db", "list", target_id).splitlines()
        if len(rows) < 2 or rows[0] != "ostree commit: " + target_id:
            raise ValueError("could not read the staged RPM inventory")
        staged = selected_rpms(row.strip() for row in rows[1:])
    target_rpms = staged if waiting else live
    missing = [name for name in selected if name not in target_rpms]
    if missing:
        action = "layer"
    elif len(set(target_rpms.values())) != 1:
        raise ValueError("polaris and polaris-kms have different versions in the target deployment")
    elif waiting and (staged != live or ("polaris-kms" in selected and boot.get("live-replaced") != target_id)):
        # A previously staged update owns the next boot. A verified live apply
        # of that exact commit can already use its packages on this boot.
        action = "after-reboot"
    else:
        action = "now"

    # Bind both the reviewed request set and the exact additions authorized by
    # this layer. A base-image package needs no new direct package request.
    context = {k: v for k, v in target.items() if k.startswith(("requested-", "initramfs-")) or
               k in ("osname", "origin", "container-image-reference", "regenerate-initramfs", "cliwrap")}
    requested = target["requested-packages"]
    if (not isinstance(requested, list) or not all(isinstance(p, str) for p in requested)
            or len(set(requested)) != len(requested)):
        raise ValueError("invalid package requests")
    context["base"] = checksum(target.get("base-checksum", target_id))
    def binding(requests):
        context["requested-packages"] = sorted(requests)
        return hashlib.sha256(json.dumps(context, sort_keys=True).encode()).hexdigest()
    fields = (boot_id, target_id if waiting else "-", identity(live, "polaris"), identity(staged, "polaris"),
              identity(live, "polaris-kms"), identity(staged, "polaris-kms"), int(pristine), action,
              binding(requested), binding(set(requested).union(missing)), *missing)
    review = json.dumps((fields, boot["unlocked"], boot.get("live-replaced"))).encode()
    print(hashlib.sha256(review).hexdigest(), *fields)
except (OSError, subprocess.SubprocessError, ValueError, TypeError, KeyError, IndexError) as exc:
    sys.exit(f"Could not verify the rpm-ostree deployment: {exc}")
PY
)" || die 'Deployment state is unknown. Polaris installation stopped.'
  read -r deployment_review boot_checksum pending_checksum boot_rpm pending_rpm boot_kms pending_kms pristine_boot \
    ostree_action layer_base expected_layer_base missing_packages <<EOF
$ostree_state
EOF
  boot_packages="$boot_rpm" pending_packages="$pending_rpm"
  [ "$boot_kms" = - ] || boot_packages="$boot_rpm and $boot_kms"
  [ "$pending_kms" = - ] || pending_packages="$pending_rpm and $pending_kms"
}

# Use explicit commit arguments. Without both, db diff can compare a rollback
# or emit a human-readable diff depending on deployment state and CLI version.
ostree_live_plan() {
  rpm_diff="$(rpm-ostree db diff --format=json "$boot_checksum" "$pending_checksum")" || return 1
  printf '%s\n' "$rpm_diff" | python3 -I -c '
import json, sys
try:
    diff = json.load(sys.stdin)
    if (diff["ostree-commit-from"], diff["ostree-commit-to"]) != tuple(sys.argv[1:3]):
        raise ValueError("unexpected diff endpoints")
    changes = diff["pkgdiff"]
    additions_only = True
    before = sys.argv[3:5]
    after = sys.argv[5:7]
    names = {rpm.rsplit("-", 2)[0] for rpm in after if rpm != "-"}
    required = [new for old, new in zip(before, after) if old == "-" and new != "-"]
    selected_additions = []
    for name, kind, details in changes:
        if type(kind) is not int or kind not in (0, 1, 2, 3):
            raise ValueError("unknown RPM change")
        if kind == 0:
            pkg, evr, arch = details["NewPackage"]
            if (not all(isinstance(s, str) and s for s in (pkg, evr, arch))
                    or pkg != name or "PreviousPackage" in details):
                raise ValueError("invalid package addition")
            if pkg in names:
                evr = evr.removeprefix("0:")
                selected_additions.append(f"{pkg}-{evr}.{arch}")
        else:
            additions_only = False
    if sorted(required) != sorted(selected_additions):
        raise ValueError("the diff does not add the selected staged RPMs")
    if additions_only:
        for old, new in zip(before, after):
            if old != "-" and old != new:
                raise ValueError("an installed RPM changed in an additions-only diff")
    print("live" if additions_only else "reboot")
except (ValueError, TypeError, KeyError) as exc:
    sys.exit(f"Could not verify the staged package changes: {exc}")
' "$boot_checksum" "$pending_checksum" "$boot_rpm" "$boot_kms" "$pending_rpm" "$pending_kms"
}

complete_ostree_package() {
  if [ "$1" = now ]; then
    host_result="$boot_packages installed on this boot"
    set -- now "$boot_checksum"
  else
    host_result="$pending_packages staged for the next boot"
  fi
  say "Polaris: $host_result."
  if [ "$run_setup" -eq 0 ]; then
    say 'Package only. Host setup and desktop startup are skipped.'
    return 0
  fi
  step 4 'Host setup'
  finish_ostree_host "$@" || exit "$?"
}

layer_ostree_package() {
  step 3 'Packages' "layering $missing_packages"
  reviewed_state="$ostree_state"
  if [ "$dry_run" -eq 0 ]; then
    read_ostree_target
    [ "$ostree_state" = "$reviewed_state" ] || die 'The deployment changed before layering. Review the installer again.'
  fi
  before_boot="$boot_checksum" before_pending="$pending_checksum" expected_base="$expected_layer_base" before_pristine="$pristine_boot"
  before_packages="$boot_packages"
  # The deployment reader emits only missing names from its fixed package list.
  # shellcheck disable=SC2086
  sudo_run_live rpm-ostree install --idempotent $missing_packages
  if [ "$dry_run" -eq 1 ]; then
    if [ "$before_pending" = - ] && [ "$pristine_boot" -eq 1 ]; then
      note 'For additions only, apply the verified staged commit to this boot:'
      show_command "${SUDO:+$SUDO }rpm-ostree apply-live --target <verified staged checksum>"
      note 'Verify that the installed Polaris RPMs match the staged RPMs.'
    else
      note 'Keep the pending changes for the next boot.'
    fi
    [ "$run_setup" -eq 1 ] || return 0
    step 4 'Host setup'
    finish_ostree_host now || exit "$?"
    return
  fi

  read_ostree_target
  [ "$before_boot" = "$boot_checksum" ] && [ "$before_packages" = "$boot_packages" ] ||
    die 'The booted deployment changed during layering. Review the installer again.'
  [ "$pending_checksum" != - ] && [ "$ostree_action" != layer ] ||
    die 'The layering transaction returned without a verified staged Polaris RPM for every selected package.'
  [ "$expected_base" = "$layer_base" ] ||
    die 'The base image or other package requests changed during layering. Review the pending deployment before continuing.'
  step_done "$pending_packages staged"
  if [ "$ostree_action" = now ]; then
    complete_ostree_package now
    return
  fi
  if [ "$before_pending" = - ] && [ "$before_pristine" -eq 1 ] && [ "$pristine_boot" -eq 1 ]; then
    live_plan="$(ostree_live_plan)" || die 'Could not identify a safe live target. The deployment was kept for inspection.'
    if [ "$live_plan" = live ]; then
      verified_state="$ostree_state" verified_commit="$pending_checksum" verified_packages="$pending_packages"
      read_ostree_target
      [ "$ostree_state" = "$verified_state" ] || die 'The staged deployment changed before live apply. Review the installer again.'
      sudo_run_live rpm-ostree apply-live --target "$verified_commit"
      read_ostree_target
      [ "$boot_checksum" = "$before_boot" ] && [ "$pending_checksum" = "$verified_commit" ] &&
        [ "$layer_base" = "$expected_base" ] && [ "$pending_packages" = "$verified_packages" ] &&
        [ "$boot_packages" = "$verified_packages" ] || die "Live apply returned, but the booted system and staged $verified_packages could not be verified."
      complete_ostree_package now
      return
    fi
    note 'The transaction also replaces or removes packages. It takes effect on the next boot.'
  fi
  complete_ostree_package after-reboot "$pending_checksum"
}

# A successful transaction alone does not prove the optional helper can be
# used. Read both installed packages from the same local database query.
verify_kms_packages() {
  [ "$dry_run" -eq 0 ] || return 0
  if matches fedora; then
    pair="$(rpm -q --qf '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' polaris.x86_64 polaris-kms.x86_64)" ||
      die 'Could not verify both installed Polaris RPMs. Host setup was skipped.'
  else
    pair="$(pacman -Q polaris polaris-kms)" || die 'Could not verify both installed Polaris packages. Host setup was skipped.'
  fi
  pair_version="$(printf '%s\n' "$pair" | awk '
    NF == 2 && $1 == "polaris"     { host = $2 }
    NF == 2 && $1 == "polaris-kms" { kms = $2 }
    END { if (NR != 2 || host == "" || host != kms) exit 1; print host }
  ')" || die 'The installed polaris and polaris-kms packages do not match. Host setup was skipped.'
  note "Verified polaris and polaris-kms at $pair_version."
}

install_fedora() {
  need curl
  # dnf offers the key from gpgkey= and waits for an answer. A script cannot
  # answer it, and repo_gpgcheck=1 means an unanswered prompt fails the metadata
  # check rather than installing anything, so the key goes in explicitly. The
  # import is the file just checked, not a second download.
  check_fedora_key
  # rpm keeps its database under /usr, which an ostree host mounts read-only, so
  # rpm --import fails there ("can't create transaction lock ... Read-only file
  # system"). rpm-ostree does not need it: it reads gpgkey= from the repository
  # file written below, which names the key kept at KEY_PATH, and checks the
  # repository metadata and every package against that key itself.
  [ "$ostree" -eq 1 ] || sudo_run rpm --import "$key_file"
  # The repository file is written here, not downloaded. A served one could
  # turn gpgcheck off, or point gpgkey= at a key nobody checked, which dnf -y
  # then fetches and imports without asking. This one names the checked key by
  # its local path, so dnf never fetches a key, and its baseurl is BASE_URL's.
  # It overwrites the file an earlier run downloaded, as every run always has.
  sudo_run install -D -m 0644 "$key_file" "$KEY_PATH"
  if [ "$ostree" -eq 1 ]; then
    step_done "kept at $KEY_PATH, where rpm-ostree reads it"
  else
    step_done "imported, and kept at $KEY_PATH"
  fi
  [ "$dry_run" -eq 1 ] || fedora_repo_file > "$key_root/polaris.repo"
  step 2 'Repository' '/etc/yum.repos.d/polaris.repo'
  note '/etc/yum.repos.d/polaris.repo will read:'
  fedora_repo_file | show_file
  sudo_run install -m 0644 "$key_root/polaris.repo" /etc/yum.repos.d/polaris.repo
  step_done 'written'
  if [ "$ostree" -eq 1 ]; then
    layer_ostree_package
    return
  fi
  # dnf5 install only checks that an installed package is present, so a host on
  # an older Polaris stays on it however new the repository is: a run over a
  # 1.4.12-1 package ended with 1.4.12-1. upgrade moves it, and does nothing
  # when it is current. polaris-kms requires the exact version of polaris beside
  # it, so it moves in the same transaction.
  if [ "${enable_kms:-0}" -eq 1 ]; then
    if [ -n "$installed_before" ] && [ -n "$(installed_version polaris-kms)" ]; then
      dnf_action=upgrade
    else
      dnf_action=install
    fi
    step 3 'Packages' "$dnf_action polaris and polaris-kms"
    sudo_run_live dnf "$dnf_action" -y --from-repo=polaris --no-allow-downgrade polaris polaris-kms || return "$?"
    verify_kms_packages
  elif [ -z "$installed_before" ]; then
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
  printf '%s\n' "$pacman_conf" | awk '
    { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
    line ~ /^\[/ { in_polaris = (line == "[polaris]"); next }
    !in_polaris || line == "" || line ~ /^#/ { next }
    { sub(/[[:space:]]*=[[:space:]]*/, " = ", line); gsub(/[[:space:]]+/, " ", line); print line }
  '
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
  pacman_conf="$(cat /etc/pacman.conf)" || die 'Could not read /etc/pacman.conf.'
  if printf '%s\n' "$pacman_conf" | grep -q '^[[:space:]]*\[polaris\][[:space:]]*$'; then
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
  if [ "${enable_kms:-0}" -eq 1 ] && { [ -z "$installed_before" ] || [ -z "$(installed_version polaris-kms)" ]; }; then
    # Qualify the new targets with the signed repository. If Polaris is
    # already installed, the exact-version helper must not pull it backwards.
    set -- "polaris/polaris${installed_before:+>=$installed_before}" polaris/polaris-kms
    step 3 'Packages' 'installing Polaris and polaris-kms with a full system upgrade'
    sudo_run_live pacman -Syu --noconfirm --needed "$@" || pacman_stopped "$(command_words pacman -Syu "$@")"
  elif [ -z "$installed_before" ]; then
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
  if [ "${enable_kms:-0}" -eq 1 ]; then verify_kms_packages; fi
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
    step_done 'host setup finished'
  fi
}

# Labelled lines at the end: a command to run, with what it is for.
#   $1 the label, $2 the label width, $3 the command or text, $4 its style
labelled() {
  printf "  %s%-$2s%s  %s%s%s\n" "$c_dim" "$1" "$c_off" "${4:-}" "$3" "${4:+$c_off}"
  log_line "$(printf "  %-$2s  %s" "$1" "$3")"
}

install_host() {
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
    return 0
  fi

  # Where the package manager's output begins in the log.
  package_output="$last_output"
  installed_after=''
  if [ "$dry_run" -eq 0 ]; then
    installed_after="$(installed_version polaris)"
    if [ -n "$installed_after" ]; then
      step_done "$(package_summary "$package_output")"
    else
      die 'the package manager finished, but Polaris is not installed. Host setup was skipped.'
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
    if ! stat "/usr/lib/modules/$running_kernel/." >/dev/null 2>&1; then
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

  if host_options_selected; then
    if [ "$reboot_first" -eq 1 ]; then
      finish_ostree_host options-after-reboot || return "$?"
    else
      finish_ostree_host options-now || return "$?"
    fi
  elif [ "$run_setup" -eq 1 ] && [ "$reboot_first" -eq 0 ]; then
    # Not fatal. The package is installed either way, and setup-host can be
    # re-run; failing here would make a working install look like a failed one.
    if setup_host_run; then
      probe_finish_console=1
      if [ -n "$log_file" ]; then
        summarize_setup "$last_output"
      else
        step_done 'host setup finished'
      fi
    else
      finish_setup_deferred=1
      note 'Host setup did not finish. Polaris is installed; run this yourself:'
      note "  $setup_command"
    fi
  elif [ "$reboot_first" -eq 1 ]; then
    step_skipped 'reboot first'
  else
    step_skipped 'left for you, as --no-setup asked'
  fi

  [ "$review_only" -eq 0 ] || return 0
  say ''
  # The closing lines report what the package manager did, read from the installed
  # version before and after. PUBLISHED_TAG only explains a run that changed
  # nothing: it and each repository's index are separate files on the CDN, each
  # cached on its own clock, so the tag can name a release that the index the
  # package manager just read does not carry yet.
  if [ "$dry_run" -eq 1 ]; then
    if host_options_selected; then say 'Nothing was changed. Open the console once host setup finishes.'
    else say 'Nothing was changed. After a real run, start Polaris and open the console:'; fi
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
    if [ "$reboot_first" -eq 1 ] && host_options_selected; then
      say 'After the restart, sign in to this account to finish the selected host options.'
    elif [ "$reboot_first" -eq 1 ]; then
      say 'Reboot first. After the reboot, set up the host, start Polaris and open the console:'
      labelled 'Set up' 8 "$setup_command"
    elif [ "$run_setup" -eq 0 ]; then
      say 'Set up the host, start Polaris and open the console:'
      labelled 'Set up' 8 "$setup_command"
    fi
  fi
  collect_finish_console
  if [ -n "$finish_console_url" ]; then
    say "Polaris console ready: $finish_console_url"
  else
    if ! host_options_selected; then labelled 'Start Polaris' 13 'polaris (in your desktop session)'; fi
    if [ -z "$installed_before" ]; then console_route=welcome; else console_route=login; fi
    say "Manage this host - open Polaris: https://localhost:${finish_console_port:-47990}/#/$console_route"
  fi
  say 'Open Nova on the playing device. Request pairing there, then approve it in Polaris.'
  if [ "$dry_run" -eq 0 ]; then host_service_state; fi
  say 'Browser window and pairing readiness were not checked.'
  say ''
  say 'Upgrades now come with the rest of the system.'
  if [ "$enable_headless" -eq 0 ] || [ -n "$seat_command" ]; then say 'Optional:'; fi
  [ "$enable_headless" -eq 1 ] || labelled 'Background host' 15 'systemctl --user enable --now polaris'
  if [ "$guided" -eq 0 ] && ! host_options_selected; then
    if matches fedora; then
      labelled 'DRM/KMS capture' 15 'sudo dnf install polaris-kms'
    else
      labelled 'DRM/KMS capture' 15 'sudo pacman -S polaris-kms'
    fi
    labelled '' 15 'sudo -H polaris --setup-host --enable-kms'
    labelled '' 15 'Run it again after you next log in, and do what it prints.' "$c_dim"
    log_line 'Log out and back in, or reboot where lingering keeps the user manager running, to pick up the new group.'
  fi
  if [ "$guided" -eq 0 ] && [ "$enable_headless" -eq 0 ] && [ "$headless_hint" -eq 1 ]; then
    labelled 'Headless boot' 15 'sudo -H polaris --setup-host --enable-headless-boot'
  fi
  [ -z "$seat_command" ] ||
    labelled 'Seat isolation' 15 "$seat_command, then log out and back in"
  host_result="installed $installed_after"
}

deployment_status() {
  status=0
  rpm-ostree status --pending-exit-77 >/dev/null || status=$?
  case "$status" in 0) pending=0 ;; 77) pending=1 ;;
    *) die "rpm-ostree status failed ($status). Deployment state is unknown." ;; esac
}

# Use the local package database for removal. rpm -e and plain pacman -R
# refuse a transaction with dependent packages outside the named targets.
host_targets() {
  if matches fedora; then
    inventory="$(rpm -qa --qf '%{NAME}\n')" || die 'Could not read the RPM inventory.'
  else
    inventory="$(pacman -Qq)" || die 'Could not read the pacman inventory.'
  fi
  targets=''
  for pkg in polaris polaris-kms; do
    if printf '%s\n' "$inventory" | grep -Fxq "$pkg"; then targets="${targets:+$targets }$pkg"; fi
  done
}

remove_host() {
  host_targets
  if [ -z "$targets" ]; then
    host_result='already absent from the booted system'
    say "Polaris: $host_result."
    return 0
  fi
  open_log
  step_title='Remove Polaris'
  # targets consists only of the two literal IDs in host_targets.
  # shellcheck disable=SC2086
  set -- $targets
  if [ "$ostree" -eq 1 ]; then
    sudo_run_live rpm-ostree uninstall "$@"
    [ "$dry_run" -eq 0 ] || return 0
    deployment_status
    [ "$pending" -eq 1 ] || die 'Removal returned without a pending deployment. Check rpm-ostree status.'
    host_result='removal staged; reboot required'
  else
    if matches fedora; then sudo_run_live rpm -e "$@"; else sudo_run_live pacman -R --noconfirm "$@"; fi
    [ "$dry_run" -eq 0 ] || return 0
    host_targets
    [ -z "$targets" ] || die "Removal returned but these packages remain: $targets"
    host_result='removed'
  fi
  say "Polaris: $host_result. Repository, keys and user data were kept."
}

host_reason=''
manager=''
host_manual='https://papi-ux.com/docs/repositories/'
if [ "$distro" = steamos ]; then
  host_manual='https://papi-ux.com/docs/steamos/'
  host_reason='SteamOS has a read-only root; it does not use the Polaris package repository.'
elif matches fedora; then
  if [ "$ostree" -eq 1 ]; then manager=rpm-ostree; host_manual="${host_manual}#bazzite-and-other-ostree-hosts"
  else manager=dnf; host_manual="${host_manual}#fedora"; fi
  case "$VERSION_ID" in 44|45) ;; *) host_reason="The repository serves Fedora 44 and 45 only (detected ${VERSION_ID:-unknown})." ;; esac
elif matches arch; then
  manager=pacman
  host_manual="${host_manual}#arch-and-cachyos"
  case "$distro" in arch|cachyos) ;; *) host_reason="The guided Arch repository supports Arch Linux and CachyOS; detected $distro." ;; esac
elif matches debian || matches ubuntu; then
  host_manual='https://papi-ux.com/docs/ubuntu/'
  host_reason='The separate .deb is tested on Ubuntu 24.04 only; there is no guided repository here.'
else
  host_manual='https://papi-ux.com/docs/quickstart/'
  host_reason="No Polaris repository for $distro."
fi
if [ "$arch" != x86_64 ]; then host_reason="No Polaris repository for $arch; x86_64 is required."; fi
if [ -z "$host_reason" ]; then
  if matches fedora; then
    if [ "$operation" = uninstall ]; then host_tools='rpm'; else host_tools='rpm rpmkeys curl'; fi
    if [ "$ostree" -eq 1 ] || [ "$operation" = install ]; then host_tools="$host_tools $manager"; fi
  else
    host_tools=pacman
    [ "$operation" = uninstall ] || host_tools='pacman pacman-key curl'
  fi
  for tool in ${SUDO:+sudo} $host_tools; do
    command -v "$tool" >/dev/null 2>&1 || host_reason="$tool is unavailable for this host operation."
  done
  if [ -z "$host_reason" ] && [ "$manager" = rpm-ostree ] && [ "$operation" = install ] && ! command -v python3 >/dev/null 2>&1; then
    host_reason='Python 3 is required to check the rpm-ostree deployment before installing Polaris.'
  fi
fi

nova_reason=''
nova_manual='https://papi-ux.com/downloads/'
if [ "$arch" != x86_64 ]; then
  nova_reason="The desktop and Deck channels here require x86_64 (detected $arch). Frame uses its own Beta guide."
elif [ -z "$SUDO" ]; then
  nova_reason='Run as the desktop user to manage a per-user Flatpak. Do not run the whole installer with sudo.'
else
  if [ "$operation" = install ]; then nova_tools='flatpak curl sha256sum'; else nova_tools=flatpak; fi
  for tool in $nova_tools; do
    command -v "$tool" >/dev/null 2>&1 || nova_reason="$tool is unavailable for the per-user signed Flatpak."
  done
fi
host_action='Stream games from this PC'
play_action='Play games from another PC'
both_action='Do both'
role_separator=' - '
if [ "$fancy" -eq 1 ] && [ "$utf8" -eq 1 ]; then
  role_separator=' — '
fi
host_label="$host_action${role_separator}Polaris"
play_label="$play_action${role_separator}Nova"
both_label="$both_action${role_separator}Polaris + Nova"

# Only the foreground guided terminal gets the brief North Star. Pass these
# same frames to the host's completion helper, which can also run at login.
ready_star='' ready_check='[ok] '
if [ "$fancy" -eq 1 ] && [ "$utf8" -eq 1 ]; then
  ready_check="${c_ok}✓${c_off} "
  if [ "$guided" -eq 1 ] && [ "$live" -eq 1 ]; then ready_star="${esc}[1;36m✦${c_off}"; fi
fi

verified_ready() {
  if [ -n "$ready_star" ]; then
    printf '%s' "$ready_star"
    sleep 0.08 2>/dev/null || :
    printf '\r'
  fi
  printf '%s%s\n' "$ready_check" "$1"
  log_line "$1"
}

has_host() { [ "$role" = host ] || [ "$role" = both ]; }
has_client() { [ "$role" = client ] || [ "$role" = both ]; }

host_options_reason=''
if [ -z "$SUDO" ]; then
  if [ -z "${SUDO_USER:-}" ] || ! desktop_uid="$(id -u -- "$SUDO_USER" 2>/dev/null)" || [ "$desktop_uid" -eq 0 ]; then
    host_options_reason='Run as the desktop user to choose options for that account.'
  fi
fi
if [ -z "$host_options_reason" ] && ! command -v python3 >/dev/null 2>&1; then
  host_options_reason='Python 3 is needed to finish these options at sign-in.'
fi
if host_options_selected && [ -n "$host_options_reason" ]; then die "$host_options_reason"; fi

read_host_option_status() {
  kms_status='' boot_status=''
  [ -z "${host_options_reason:-}" ] || return 0
  kms_status="$(python3 -IB - 2>/dev/null <<'POLARIS_OPTION_STATUS'
import grp
import os
from pathlib import Path
import pwd
import stat
import subprocess

UNIT = Path("/usr/lib/systemd/user/polaris.service")
HOST = Path("/usr/bin/polaris")
KMS = Path("/usr/libexec/polaris/polaris-kms")
LINGER = Path("/var/lib/systemd/linger")
RUN_USER = Path("/run/user")
PROC = Path("/proc")
USER_SLICE = Path("/sys/fs/cgroup/user.slice")


def output(*args, env):
    try:
        result = subprocess.run(args, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=1)
        return result.stdout.strip() if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        return ""


def service_properties(name, properties, env):
    # Connect only to this account's already-running manager. Even systemctl's
    # session-bus fallback must never open a socket-activated desktop bus here.
    private = Path(env["XDG_RUNTIME_DIR"]) / "systemd/private"
    try:
        info = private.lstat()
    except OSError:
        return {}
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid() or private.resolve() != private:
        return {}
    data = output("systemctl", "--user", "--no-ask-password", "show", name,
                  f"--property={properties}", env=env)
    return dict(line.split("=", 1) for line in data.splitlines() if "=" in line)


def exact_override(path, uid):
    with open(path, opener=lambda p, flags: os.open(p, flags | os.O_NOFOLLOW | os.O_NONBLOCK)) as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, uid) or info.st_size > 4096:
            return False
        lines = [line.strip() for line in file.read(4097).splitlines()
                 if line.strip() and not line.lstrip().startswith(("#", ";"))]
    return lines == ["[Service]", "ExecStart=", f"ExecStart={KMS}"]


def parked_label(uid, group):
    # A parked file can outlive the login it was waiting for. Only the
    # selected account's actual service manager can prove it still lacks access.
    scope = USER_SLICE / f"user-{uid}.slice/user@{uid}.service/init.scope/cgroup.procs"
    try:
        for pid in scope.read_text().split():
            process = PROC / pid
            argv = (process / "cmdline").read_bytes().split(b"\0")
            if argv[0].rsplit(b"/", 1)[-1] != b"systemd" or b"--user" not in argv[1:]:
                continue
            fields = dict(line.split(":", 1) for line in (process / "status").read_text().splitlines())
            if ([int(n) for n in fields["Uid"].split()] == [uid] * 4
                    and group not in map(int, (fields["Gid"] + " " + fields["Groups"]).split())):
                return "Waiting for sign-in"
    except (OSError, KeyError, ValueError):
        pass
    return "Pending"


def kms_label(active, parked, account, service, env):
    if active.parent.resolve() != active.parent:
        return ""
    pending = os.path.lexists(parked)
    if pending == os.path.lexists(active) or not exact_override(parked if pending else active, account.pw_uid):
        return ""
    # getgrouplist asks NSS what the next login receives, including userdb on
    # rpm-ostree. The installer's own process groups can predate enrollment.
    group = grp.getgrnam("polaris-kms").gr_gid
    info = KMS.lstat()
    if (info.st_mode != (stat.S_IFREG | 0o750) or info.st_uid != 0 or info.st_gid != group
            or os.statvfs(KMS).f_flag & (os.ST_NOSUID | os.ST_NOEXEC)
            or group not in os.getgrouplist(account.pw_name, account.pw_gid)
            or output("getcap", "-n", str(KMS), env=env) != f"{KMS} cap_sys_admin=ep"):
        return ""
    if pending:
        if any(active.parent.glob("*.conf")) or (service and not uses_command(service, HOST)):
            return ""
        return parked_label(account.pw_uid, group)
    if not uses_command(service, KMS) or not any(
            Path(path).resolve() == active for path in service.get("DropInPaths", "").split()):
        return ""
    pid = service.get("MainPID", "")
    if service.get("ActiveState") == "active" and pid.isdecimal() and int(pid) > 0:
        try:
            proc = PROC / pid
            if proc.stat().st_uid == account.pw_uid and (proc / "exe").samefile(KMS):
                return "Already on"
        except OSError:
            pass  # The capability-bearing executable can be hidden from its own account.
    return "Configured"


def uses_command(service, binary):
    command = service.get("ExecStart", "")
    return (service.get("LoadState") == "loaded" and service.get("FragmentPath") == str(UNIT)
            and service.get("NeedDaemonReload") == "no"
            and command.startswith(f"{{ path={binary} ; argv[]={binary} ;") and command.count("{ path=") == 1)


def boot_label(link, account, service, env, kms):
    marker = (LINGER / account.pw_name).lstat()
    if (not stat.S_ISREG(marker.st_mode) or marker.st_uid != 0 or link.parent.resolve() != link.parent
            or not link.is_symlink() or link.resolve(strict=True) != UNIT):
        return ""
    if kms not in ("Already on", "Configured") and not (
            uses_command(service, HOST) and HOST.is_file() and os.access(HOST, os.X_OK)):
        return ""
    target = service_properties("default.target", "Wants,LoadState,ActiveState,NeedDaemonReload", env)
    if (target.get("LoadState") == "loaded" and target.get("NeedDaemonReload") == "no"
            and UNIT.name in target.get("Wants", "").split()):
        if target.get("ActiveState") == service.get("ActiveState") == "active":
            return "Already on"
        return "Configured"
    return ""


def read_status():
    uid = os.geteuid()
    if uid == 0:
        account = pwd.getpwnam(os.environ.get("SUDO_USER", ""))
        if account.pw_uid == 0:
            return "", ""
        # Read desktop-owned paths and talk to the manager as its owner. This
        # only drops credentials in this process. No sudo, PAM or login session.
        os.initgroups(account.pw_name, account.pw_gid)
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)
    else:
        account = pwd.getpwuid(uid)
    info = UNIT.lstat()
    home = Path(account.pw_dir)
    if not home.is_absolute() or not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        return "", ""
    config = home.resolve(strict=True) / ".config/systemd/user"
    active = config / "polaris.service.d/20-polaris-kms.conf"
    parked = active.with_suffix(".conf.disabled-until-relogin")
    link = config / "default.target.wants/polaris.service"
    if not any(os.path.lexists(path) for path in (active, parked, link)):
        return "", ""
    runtime = RUN_USER / str(account.pw_uid)
    env = {"PATH": "/usr/bin:/usr/sbin", "LC_ALL": "C", "XDG_RUNTIME_DIR": str(runtime),
           "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime}/systemd/private"}
    service = service_properties(UNIT.name, "LoadState,FragmentPath,NeedDaemonReload,ExecStart,"
                                 "ActiveState,MainPID,DropInPaths", env)
    kms = boot = ""
    try:
        kms = kms_label(active, parked, account, service, env)
    except (OSError, KeyError, ValueError, RuntimeError):
        pass
    try:
        boot = boot_label(link, account, service, env, kms)
    except (OSError, ValueError, RuntimeError):
        pass
    return kms, boot


if __name__ == "__main__":
    print("|".join(read_status()))
POLARIS_OPTION_STATUS
)" || kms_status='|'
  boot_status=${kms_status#*|}
  kms_status=${kms_status%%|*}
}

host_options_summary() {
  if [ "$enable_kms" -eq 1 ]; then
    say "  ${1:-}Enable KMS capture. Grant this user monitor access with a signed helper."
  fi
  if [ "$enable_headless" -eq 1 ]; then
    say "  ${1:-}Start Polaris before sign-in. Keep user services running after sign-out."
  fi
}

# The user installation can be empty. Avoid initializing its repo just to draw
# the review. Every mutating command selects --user explicitly.
user_flatpak="${FLATPAK_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/flatpak}"
flathub_url='https://dl.flathub.org/repo'
nova_launch() { printf 'flatpak run --user %s --standalone' "$nova_ref"; }

# Flatpak creates this remote from the pinned descriptor below. A name or URL
# alone is insufficient evidence for reusing an existing remote. Accept the
# standard local config + pinned public key; unusual trust stores use Get Nova.
nova_trust_config() (
  config_file="$user_flatpak/repo/config"
  [ -f "$config_file" ] || return 1
  in_remote=0 groups=0 urls=0 commits=0 summaries=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '[remote "nova"]') in_remote=1; groups=$((groups + 1)); continue ;;
      '['*) in_remote=0; continue ;;
    esac
    [ "$in_remote" -eq 1 ] || continue
    case "$line" in
      "url=$NOVA_FEED/repo") urls=$((urls + 1)) ;;
      gpg-verify=true) commits=$((commits + 1)) ;;
      gpg-verify-summary=true) summaries=$((summaries + 1)) ;;
      *) printf '%s\n' "$line" | grep -Eq '^[[:space:]]*([#;]|$)|^xa\.(title|comment|homepage|icon|description|default-branch)(-is-set)?=' || return 1 ;;
    esac
  done < "$config_file" || return 1
  [ "$groups" -eq 1 ] && [ "$urls" -eq 1 ] && [ "$commits" -eq 1 ] && [ "$summaries" -eq 1 ]
)

flatpak_tab=$(printf '\t')

# Match literal leading columns, including the following tab. This keeps dots
# in an application ID literal and preserves empty fields for cut.
flatpak_rows() {
  while IFS= read -r row; do
    case "$row" in "$1$flatpak_tab"*) printf '%s\n' "$row" ;; esac
  done
}

read_remotes() {
  remotes="$(flatpak remotes --user --show-disabled --columns=name,url,options)" ||
    die 'Could not read Flatpak remotes. Check the user installation.'
}

# Writes the URL and options of the named remote to shell variables. Flatpak
# emits tab-separated columns without a header when stdout is a pipe.
remote_row() {
  remote_rows="$(printf '%s\n' "$remotes" | flatpak_rows "$1")"
  remote_url="$(printf '%s\n' "$remote_rows" | cut -s -f2)"
  remote_options="$(printf '%s\n' "$remote_rows" | cut -s -f3)"
  if [ -n "$remote_url" ]; then
    [ "${remote_url%/}" = "$2" ] || die "The user remote $1 points elsewhere. See $nova_manual"
    case "$remote_options" in *no-gpg-verify*|*disabled*) die "The user remote $1 is disabled or unsigned. See $nova_manual" ;; esac
  fi
}

check_nova_remote() {
  remote_row nova "$NOVA_FEED/repo"
  [ -n "$remote_url" ] || die 'The Nova remote is missing.'
  nova_trust_config || die "Could not confirm Nova commit and summary signature checks. See $nova_manual"
  ring="$user_flatpak/repo/nova.trustedkeys.gpg"
  sum="$(sha256sum < "$ring")" || die "Could not check Nova's configured key. See $nova_manual"
  if [ "${sum%% *}" != "$NOVA_KEY_SHA256" ]; then
    # GnuPG may re-serialize the import. An already available gpg can identify
    # all primary keys without reading or writing the desktop user's keyring.
    command -v gpg >/dev/null 2>&1 || die "Could not verify the local Nova keyring. See $nova_manual"
    [ "$dry_run" -eq 0 ] || { note 'Apply will verify the local Nova keyring before any Flatpak transaction.'; return 0; }
    make_nova_tmp
    (umask 077; mkdir -p "$nova_tmp/gnupg")
    keys="$(gpg --no-options --homedir "$nova_tmp/gnupg" --no-autostart --batch --quiet --with-colons --show-keys "$ring")" ||
      die 'Could not read the local Nova signing keyring.'
    # A subkey may also have a fingerprint. Only the first fingerprint for
    # the one primary public key can establish the publisher.
    public_count="$(printf '%s\n' "$keys" | grep -Ec '^pub(:|$)')" &&
      [ "$public_count" = 1 ] &&
      primary="$(printf '%s\n' "$keys" | sed -n '/^pub:/,/^sub:/{ /^fpr:/p; }' | head -n 1 | cut -s -d: -f10)" &&
      [ "$primary" = "$NOVA_FINGERPRINT" ] ||
      die 'The local Nova keyring does not contain exactly the pinned publisher key.'
  fi
}

make_nova_tmp() {
  [ -n "$nova_tmp" ] || nova_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nova-install.XXXXXX")" || die 'Could not create a private Nova download directory.'
}

nova_inventory() {
  nova_ref="app/$NOVA_APP/x86_64/$channel"
  nova_before='' runtime_present=0 remotes=''
  [ -d "$user_flatpak/repo" ] || return 0
  apps="$(flatpak list --user --app --columns=application,arch,branch)" || die 'Could not read installed user Flatpaks.'
  component='[A-Za-z0-9._-]+'
  malformed="$(printf '%s\n' "$apps" | LC_ALL=C sed -E "/^$/d; /^$component$flatpak_tab$component$flatpak_tab$component\$/d")" ||
    die 'Could not interpret the installed user Flatpak inventory.'
  [ -z "$malformed" ] || die 'Could not interpret the installed user Flatpak inventory.'
  app_row="$NOVA_APP${flatpak_tab}x86_64$flatpak_tab$channel"
  installed="$(printf '%s\n' "$apps" | grep -Fxc "$app_row")" || [ "$?" -eq 1 ] ||
    die 'Could not interpret the installed user Flatpak inventory.'
  case "$installed" in 0|1) ;; *) die 'Could not interpret the installed user Flatpak inventory.' ;; esac
  if [ "$installed" -eq 1 ]; then
    nova_before="$(flatpak info --user --show-commit "$nova_ref")" || die 'Could not read the installed Nova commit.'
    valid_commit "$nova_before" || die 'The installed Nova commit is unknown.'
  fi
  if [ -n "$nova_before" ]; then
    origin="$(flatpak info --user --show-origin "$nova_ref")" || die 'Could not read the installed Nova origin.'
    [ "$origin" = nova ] || die "The installed $nova_ref belongs to another origin. See $nova_manual"
  fi
  [ "$operation" = install ] || return 0
  read_remotes
  runtimes="$(flatpak list --user --runtime --columns=application,arch,branch,origin)" || die 'Could not read installed user runtimes.'
  runtime_columns="$(printf '%s' "${NOVA_RUNTIME#runtime/}" | tr '/' '\t')"
  runtime_origin="$(printf '%s\n' "$runtimes" | flatpak_rows "$runtime_columns" | cut -s -f4)"
  case "$runtime_origin" in flathub) runtime_present=1 ;; '') ;; *) die 'KDE 6.10 is installed from another origin. Use Get Nova.' ;; esac
}
valid_commit() {
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 64 ]
}

manage_nova() {
  nova_inventory
  step_title='Nova'
  [ "$review_only" -eq 0 ] || say "Nova $channel in this user installation: ${nova_before:-absent}."
  if [ "$operation" = uninstall ]; then
    if [ -z "$nova_before" ]; then say "Nova: $nova_ref is already absent for this user."; return 0; fi
    open_log
    run flatpak uninstall --user --noninteractive --no-related "$nova_ref"
    [ "$dry_run" -eq 0 ] || return 0
    nova_inventory
    [ -z "$nova_before" ] || die "Removal returned but $nova_ref remains installed."
    say "Removed $nova_ref for this user. Application data, runtimes and remotes were kept."
    return 0
  fi
  remote_row flathub "$flathub_url"
  add_flathub=0
  [ -n "$remote_url" ] || add_flathub=1
  remote_row nova "$NOVA_FEED/repo"
  if [ -n "$remote_url" ]; then
    check_nova_remote
  else
    [ ! -e "$user_flatpak/repo/nova.trustedkeys.gpg" ] || die "A Nova keyring already exists without its remote. See $nova_manual"
    open_log
    if [ "$dry_run" -eq 1 ]; then nova_download="${TMPDIR:-/tmp}/nova-install.XXXXXX"
    else make_nova_tmp; nova_download="$nova_tmp"; fi
    descriptor="$nova_download/nova.flatpakrepo"
    run curl --disable --fail --silent --show-error --output "$descriptor" "$NOVA_FEED/nova.flatpakrepo"
    show_command "sha256sum < $(command_words "$descriptor")"
    note "Require SHA-256 $NOVA_REPO_SHA256 (publisher URL and embedded key)."
    if [ "$dry_run" -eq 0 ]; then
      sum="$(sha256sum < "$descriptor")" || die 'Could not verify the downloaded Nova descriptor.'
      [ "${sum%% *}" = "$NOVA_REPO_SHA256" ] || die 'Nova descriptor checksum mismatch. No Flatpak remote was added.'
    fi
    run flatpak remote-add --user nova "$descriptor"
    if [ "$dry_run" -eq 0 ]; then read_remotes; check_nova_remote; fi
  fi
  open_log
  if [ "$add_flathub" -eq 1 ]; then
    run flatpak remote-add --user flathub "$FLATHUB_REPO"
    if [ "$dry_run" -eq 0 ]; then
      read_remotes
      remote_row flathub "$flathub_url"
      [ -n "$remote_url" ] || die 'Could not verify the added Flathub remote.'
    fi
  fi
  if [ "$runtime_present" -eq 0 ]; then
    run flatpak install --user --noninteractive flathub "$NOVA_RUNTIME"
  fi
  if [ -z "$nova_before" ]; then
    run flatpak install --user --noninteractive --no-deps --no-related nova "$nova_ref"
  else
    run flatpak update --user --noninteractive --no-deps --no-related "$nova_ref"
  fi
  [ "$dry_run" -eq 0 ] || return 0
  after="$(flatpak info --user --show-commit "$nova_ref")" || die 'Flatpak returned but Nova could not be verified.'
  valid_commit "$after" || die 'Flatpak returned an invalid Nova commit.'
  read_remotes
  check_nova_remote
  remote_row flathub "$flathub_url"
  [ -n "$remote_url" ] || die 'Could not confirm Flathub after the transaction.'
  [ "$(flatpak info --user --show-ref "$nova_ref")" = "$nova_ref" ] &&
    [ "$(flatpak info --user --show-origin "$nova_ref")" = nova ] &&
    [ "$(flatpak info --user --show-runtime "$nova_ref")" = "${NOVA_RUNTIME#runtime/}" ] &&
    [ "$(flatpak info --user --show-origin "$NOVA_RUNTIME")" = flathub ] ||
    die 'Nova ref, origin or runtime verification failed. Inspect the per-user installation.'
  if [ -z "$nova_before" ]; then say "Installed Nova $channel ($after)."
  elif [ "$after" = "$nova_before" ]; then say "Nova $channel was already installed at $after."
  else say "Updated Nova $channel from $nova_before to $after."; fi
  nova_process_state
  finish_nova_ref=$nova_ref
  finish_nova_commit=$after
  verified_ready 'Nova installation verified'
  say "Open Nova: $(nova_launch)"
  say 'In Nova, choose the PC you want to play from.'
}

# Use the same console reader from the finish picker, setup and next login.
# The original script may have arrived through curl and have no pathname.
host_completion_program() {
  cat <<'POLARIS_FINISH'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import time
import tty

POLARIS = "/usr/bin/polaris"
KMS = "/usr/libexec/polaris/polaris-kms"
UNIT = "polaris.service"
MARKER = "X-Polaris-Installer=true"
DEPLOYMENT = "X-Polaris-Deployment="
PLAN = "X-Polaris-Setup="
# Earlier guided menus wrote the same entry format without a helper digest.
LEGACY_IMAGE_HELPERS = {
    "5de9939c0ba83491a3542cf2d5174b6bc0803c92b54341f8e77d6d300612df0b",
    "6159cea74ba2a2eebd37bd3f5ee2936f5147b0dd55b72941cadd72a0e5ea95e9",
    "bbe548641b5a5132aa4cbd04093b9ff96fd71cb21d7cb5224ec29c63c7310734",
}
HELPER_HASH = "X-Polaris-Helper-SHA256="
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
WAITING = "Waiting for a compatible Polaris update"
mode, target, guided = sys.argv[1:4]
log_path = sys.argv[4] if len(sys.argv) > 4 else ""
interactive = guided == "1"
star, check = sys.argv[5:7] if len(sys.argv) >= 7 else ("", "[ok] ")
kms, headless, manager = sys.argv[7:10] if len(sys.argv) >= 10 else ("0", "0", "")
next_deployment = sys.argv[10] if len(sys.argv) > 10 else "-"
uid = os.geteuid()
if mode in ("review-kms", "cancel-kms") and uid == 0:
    # A sudo invocation reviews and cancels as its caller, without opening a
    # login session or following root's HOME or XDG directories.
    try:
        account = pwd.getpwnam(os.environ.get("SUDO_USER", ""))
    except KeyError:
        sys.exit("Choose host options as the desktop account that will stream.")
    if not account.pw_uid:
        sys.exit("Choose host options as the desktop account that will stream.")
    os.initgroups(account.pw_name, account.pw_gid)
    os.setgid(account.pw_gid)
    os.setuid(account.pw_uid)
    uid = account.pw_uid
    os.environ["HOME"] = account.pw_dir
    for key in ("XDG_CONFIG_HOME", "XDG_STATE_HOME"):
        os.environ.pop(key, None)
home = Path.home()
user_config = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
user_state = Path(os.environ.get("XDG_STATE_HOME") or home / ".local/state") / "polaris-installer"
default_desktop = user_config / "autostart" / "com.papiux.PolarisInstaller.desktop"
default_helper = user_state / "finish-host.py"
desktop, helper = default_desktop, default_helper
restart_pending = False
finish_action = "deferred"


def run(*args, check=True):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and result.returncode:
        raise RuntimeError(result.stdout.strip() or f"{args[0]} exited with status {result.returncode}")
    return result


def atomic_write(path, data, permissions):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temp:
        try:
            temp.write(data)
            temp.flush()
            os.fchmod(temp.fileno(), permissions)
            os.replace(temp.name, path)
        finally:
            Path(temp.name).unlink(missing_ok=True)


def append_log(text):
    if log_path:
        try:
            with open(log_path, "a") as stream:
                stream.write(text)
        except OSError:
            # A full or removed log must not prevent setup or opening the console.
            pass


def desktop_exec(deployment, program):
    if not program.is_absolute() or any(ord(ch) < 32 for ch in str(program)):
        raise ValueError("The desktop state directory must be an absolute path without control characters.")
    # Desktop Entry Exec quoting is processed after general string escapes.
    argument = "".join("\\" + ch if ch in ('"', "\\", "$", chr(96)) else ch for ch in str(program))
    argument = argument.replace("\\", "\\\\").replace("%", "%%")
    return f'Exec=/usr/bin/python3 -I "{argument}" login {deployment} 1'


def queued_job(entry=None, program=None):
    entry = entry or desktop
    program = program or helper
    if not entry.is_symlink() and entry.is_file():
        lines = entry.read_text().splitlines()
        if MARKER in lines:
            deployment = next((line[len(DEPLOYMENT):] for line in lines if line.startswith(DEPLOYMENT)), None)
            if not deployment or [line for line in lines if line.startswith("Exec=")] != [desktop_exec(deployment, program)]:
                return None, {}
            data = next((line[len(PLAN):] for line in lines if line.startswith(PLAN)), "{}")
            plan = json.loads(data)
            if not isinstance(plan, dict):
                raise ValueError("The saved Polaris host options could not be read.")
            if plan and (plan.get("uid") != uid or plan.get("account") != pwd.getpwuid(uid).pw_name):
                raise RuntimeError("These host options belong to a different account.")
            for key in ("wait_update", "finish_in_terminal"):
                if key in plan and not valid_image_identity(plan[key]):
                    raise ValueError("Could not verify the deployment saved for this KMS request.")
            if plan.get("kms") and re.fullmatch(r"[0-9a-f]{64}", deployment):
                bound = any(line.startswith(HELPER_HASH) for line in lines)
                if not owned_image_request(entry, program, deployment, plan, bound):
                    return None, {}
            return deployment, plan
    return None, {}


def clear_login_job(completed, plan):
    if queued_job() == (completed, plan):
        desktop.unlink()
        if our_helper():
            helper.unlink()


def our_helper(program=None):
    program = program or helper
    return not program.is_symlink() and program.is_file() and (
        f'MARKER = "{MARKER}"'.encode() in program.read_bytes().splitlines())


def select_job(deployment, plan):
    global desktop, helper
    # Old jobs and the ordinary one-job case keep their original locations. If
    # two real deployments still have work, neither may consume the other's options.
    other_entry = desktop.with_name(f"com.papiux.PolarisInstaller-{deployment}.desktop")
    other_helper = helper.with_name(f"finish-host-{deployment}.py")
    if mode == "login":
        if Path(__file__).name == other_helper.name:
            desktop, helper = other_entry, other_helper
        return
    previous, saved = queued_job()
    if previous == deployment or (saved and saved.get("next_deployment") == deployment):
        return
    if other_entry.exists() or (previous and (saved or plan)):
        desktop, helper = other_entry, other_helper


def entry_bytes(deployment, plan, program, bind_helper=True):
    text = ("[Desktop Entry]\nType=Application\nName=Finish Polaris Setup\n"
            f"{desktop_exec(deployment, program)}\n"
            f"Terminal=true\n{MARKER}\n{DEPLOYMENT}{deployment}\n"
            f"{PLAN}{json.dumps(plan, separators=(',', ':'))}\n")
    if bind_helper and plan.get("kms") and re.fullmatch(r"[0-9a-f]{64}", deployment):
        text += f"{HELPER_HASH}{hashlib.sha256(program.read_bytes()).hexdigest()}\n"
    return text.encode()


def owned_image_request(entry, program, deployment, plan, bound):
    fields = {"kms", "headless", "account", "uid", "next_deployment", "wait_update",
              "wait_manager", "wait_boot", "headless_done", "finish_in_terminal"}
    if plan["kms"] is not True or type(plan.get("headless")) is not bool or set(plan) - fields:
        return False
    if "headless_done" in plan and (plan["headless_done"] is not True or not plan["headless"]):
        return False
    if entry.stat().st_uid != os.getuid() or not our_helper(program) or program.stat().st_uid != os.getuid():
        return False
    if not bound and hashlib.sha256(program.read_bytes()).hexdigest() not in LEGACY_IMAGE_HELPERS:
        return False
    return entry.read_bytes() == entry_bytes(deployment, plan, program, bind_helper=bound)


def queue_for_login(deployment, plan):
    previous, saved = queued_job()
    if os.path.lexists(desktop) and previous is None:
        raise RuntimeError(f"A different desktop entry already exists at {desktop}.")
    if os.path.lexists(helper) and not our_helper():
        raise RuntimeError(f"A different file already exists at {helper}.")
    if not previous and helper.exists() and plan.get("kms") and re.fullmatch(r"[0-9a-f]{64}", deployment):
        orphan = helper.read_bytes()
        if orphan != Path(__file__).read_bytes() and hashlib.sha256(orphan).hexdigest() not in LEGACY_IMAGE_HELPERS:
            raise RuntimeError(f"A different file already exists at {helper}.")
    if saved and not plan:
        # Plain desktop setup is already part of the pinned image job. Even if
        # today's shell has no user bus, keep its deployment and option bits.
        return
    # A narrower rerun applies only its own selection now. The existing approval
    # lives on in the login entry until that remaining option also completes.
    if saved and any(saved[key] and not plan[key] for key in ("kms", "headless")):
        plan = {**saved, **plan,
                "kms": saved["kms"] or plan.get("kms", False),
                "headless": saved["headless"] or plan.get("headless", False)}
    atomic_write(helper, Path(__file__).read_bytes(), 0o700)
    atomic_write(desktop, entry_bytes(deployment, plan, helper), 0o600)


def image_requests():
    # Only consider the exact files written for this user. A different login
    # entry, a newer plan format or another account's file is not ours to edit.
    for entry in sorted(default_desktop.parent.glob("com.papiux.PolarisInstaller*.desktop")):
        suffix = entry.stem.removeprefix(default_desktop.stem)
        if suffix and not re.fullmatch(r"-[0-9a-f]{64}", suffix):
            continue
        program = default_helper.with_name(f"finish-host{suffix}.py")
        try:
            deployment, plan = queued_job(entry, program)
            if (not deployment or not re.fullmatch(r"[0-9a-f]{64}", deployment)
                    or (suffix and suffix != "-" + deployment)
                    or not plan.get("kms")):
                continue
            yield entry, program, deployment, plan
        except (OSError, RuntimeError, ValueError):
            continue


def image_state():
    status = json.loads(run("rpm-ostree", "status", "--json").stdout)
    deployments = status["deployments"]
    boot, = [row for row in deployments if row["booted"] is True]
    if (status["transaction"] is not None or boot.get("live-inprogress")
            or not re.fullmatch(r"[0-9a-f]{64}", boot["checksum"])):
        raise RuntimeError("Could not verify the booted Polaris deployment.")
    return deployments, boot


def valid_image_identity(value):
    return (isinstance(value, dict) and set(value) == {"osname", "checksum"}
            and isinstance(value["osname"], str) and value["osname"]
            and isinstance(value["checksum"], str) and re.fullmatch(r"[0-9a-f]{64}", value["checksum"]))


def image_identity(boot):
    identity = {"osname": boot["osname"], "checksum": boot.get("live-replaced") or boot["checksum"]}
    if boot["unlocked"] != "none" or not valid_image_identity(identity):
        raise RuntimeError("Could not verify the immutable deployment for KMS setup.")
    return identity


def image_supports_kms(boot, plan):
    # Match the local RPMs to this exact image, including a verified live
    # replacement. Probe the packaged binary as the caller, before any sudo.
    commit = image_identity(boot)["checksum"]
    version = check_packages(boot["checksum"], plan).removeprefix("0:")
    rows = run("rpm-ostree", "db", "list", commit).stdout.splitlines()
    pair = sorted(line.strip() for line in rows[1:] if
                  line.strip().rsplit("-", 2)[0] in ("polaris", "polaris-kms"))
    if (rows[:1] != ["ostree commit: " + commit] or not version.endswith(".x86_64")
            or pair != sorted([f"polaris-{version}", f"polaris-kms-{version}"])):
        raise RuntimeError("The installed Polaris package pair does not match the booted deployment.")
    help_text = run(POLARIS, "--setup-host", "--help").stdout
    if image_identity(image_state()[1]) != image_identity(boot):
        raise RuntimeError("The Polaris deployment changed during the KMS check.")
    return "on rpm-ostree hosts through systemd's userdb" in " ".join(help_text.split())


def on_selected_boot(boot, deployment, plan):
    return boot["checksum"] in (deployment, plan.get("next_deployment"))


def review_request():
    jobs = list(image_requests())
    if not jobs:
        return None
    _, boot = image_state()
    # Prefer the request bound to the running image if several jobs exist.
    jobs.sort(key=lambda job: not on_selected_boot(boot, job[2], job[3]))
    for entry, program, deployment, plan in jobs:
        wait = plan.get("wait_update")
        kind = "waiting"
        if wait:
            if wait.get("osname") != boot["osname"]:
                continue
            identity = image_identity(boot)
            if wait != identity:
                try:
                    if image_supports_kms(boot, plan):
                        kind = "ready"
                except (OSError, ValueError, RuntimeError, KeyError):
                    pass  # Missing or unverifiable replacement. The request can still be cancelled.
            if kind == "waiting" and plan.get("finish_in_terminal") == identity and plan["headless"]:
                kind = "headless"
        elif not on_selected_boot(boot, deployment, plan) or plan.get("wait_boot") or plan.get("wait_manager"):
            continue
        elif image_supports_kms(boot, plan):
            # A shipped job may already be on its reviewed, compatible boot
            # when the earlier sign-in could not authorize native setup.
            kind = "ready"
        # A second Apply may replace even a byte-identical request. Bind the
        # confirmation to the exact entry and helper that the player reviewed.
        binding = (deployment, plan, kind, boot["checksum"], boot.get("live-replaced"))
        token = hashlib.sha256(json.dumps(binding, sort_keys=True).encode())
        for path in (entry, program):
            info = path.stat()
            token.update(str((path, info.st_dev, info.st_ino, info.st_ctime_ns)).encode())
        return token.hexdigest(), entry, program, deployment, plan, kind
    return None


def control_kms_request():
    global desktop, helper
    # The shipped menu creates this lock before arming a job. Take a stable
    # snapshot without creating files or blocking the menu on another prompt.
    reviewing = mode == "review-kms"
    try:
        lock = (user_state / "finish.lock").open("r")
    except FileNotFoundError:
        if reviewing:
            return
        raise RuntimeError("The saved KMS request changed. Review it again.")
    with lock:
        if reviewing:
            try:
                fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return
        else:
            fcntl.flock(lock, fcntl.LOCK_EX)
        request = review_request()
        if reviewing:
            if request:
                token, _, _, deployment, plan, kind = request
                if kind == "ready" and plan["headless"]:
                    kind = "ready-both"
                print(token, deployment[:12], kind)
            return
        if not request or request[0] != target:
            raise RuntimeError("The saved KMS request changed. Review it again.")
        _, entry, program, deployment, plan, kind = request
        if mode == "finish-kms":
            if kind not in ("ready", "headless"):
                raise RuntimeError("The saved KMS request is still waiting for a compatible update.")
            desktop, helper = entry, program
            finish(deployment, plan)
            return
        if plan["headless"] and not plan.get("headless_done"):
            remaining = {key: plan[key] for key in ("account", "uid", "headless", "next_deployment") if key in plan}
            remaining["kms"] = False
            atomic_write(entry, entry_bytes(deployment, remaining, program), 0o600)
        else:
            entry.unlink()
            program.unlink()
        print("Saved KMS request cancelled.")


def refresh_image_request(deployment):
    # An old menu left its own Python program in the user's home. A normal
    # confirmed Host rerun upgrades that exact continuation, even without a
    # new KMS selection. Never run its account options on the plain Apply.
    jobs = list(image_requests())
    if not jobs:
        return
    _, boot = image_state()
    for entry, program, previous, saved in jobs:
        selected_boot = on_selected_boot(boot, previous, saved)
        if not selected_boot and deployment not in (previous, saved.get("next_deployment")):
            continue
        # Upgrade only the earlier menu's own file. An already-bound helper
        # can be newer than the installer currently in the terminal.
        if hashlib.sha256(program.read_bytes()).hexdigest() in LEGACY_IMAGE_HELPERS:
            atomic_write(program, Path(__file__).read_bytes(), 0o700)
            atomic_write(entry, entry_bytes(previous, saved, program), 0o600)
        if selected_boot and not any(saved.get(key) for key in ("wait_update", "wait_boot", "wait_manager")):
            try:
                if image_supports_kms(boot, saved):
                    continue
            except (OSError, ValueError, RuntimeError, KeyError):
                # The refreshed helper will verify the pair on login. An
                # incomplete KMS pair must not block regular Host Apply.
                continue
            saved["wait_update"] = image_identity(boot)
            atomic_write(entry, entry_bytes(previous, saved, program), 0o600)


class SetupCommandFailed(RuntimeError):
    pass


def admin_setup(*options):
    # Plasma may provide graphical authentication to its autostart service
    # even without a controlling terminal. Preserve that sign-in prompt.
    sudo = ["sudo"] if interactive else ["sudo", "-n"]
    # sudo reads its password from the controlling terminal, including under curl | sh.
    # Only elevate the package's absolute entry point, never this saved login program.
    result = run(*sudo, "-H", POLARIS, "--setup-host", *options, check=False)
    if result.returncode:
        raise SetupCommandFailed(result.stdout.strip() or f"Host setup exited with status {result.returncode}.")
    return result.stdout


def setup_input():
    result = run(POLARIS, "--setup-host", check=False)
    if result.returncode == 0:
        return result.stdout
    if os.geteuid() == 0 or "host setup requires root" not in result.stdout.lower():
        raise RuntimeError(result.stdout.strip() or "Polaris could not check host input.")
    print("Applying the packaged input rules.", flush=True)
    return admin_setup()


def console_port():
    config = user_config / "polaris" / "polaris.conf"
    if config.is_file():
        with config.open(errors="replace") as stream:
            for line in stream:
                match = re.fullmatch(r"\s*port\s*=\s*(\d+)\s*(?:#.*)?", line.rstrip())
                if match and 1024 <= int(match[1]) <= 65534:
                    return int(match[1]) + 1
    return 47990


def kms_service_socket():
    unit = run("systemctl", "--user", "show", UNIT,
               "--property=ActiveState,MainPID,ExecStart,ControlGroup", check=False)
    properties = dict(line.split("=", 1) for line in unit.stdout.splitlines() if "=" in line)
    group = properties.get("ControlGroup", "")
    pid = properties.get("MainPID", "")
    if (unit.returncode == 0 and properties.get("ActiveState") == "active"
            and properties.get("ExecStart", "").startswith("{ path=/usr/libexec/polaris/polaris-kms ;")
            and group.startswith("/") and group != "/" and pid.isdecimal() and int(pid) > 0):
        return f"cgroup:{group}", pid
    return None


def console_ready(port):
    # Polaris generates its own host certificate. This unauthenticated
    # readiness request stays on loopback and never follows redirects.
    listeners = run("ss", "-H", "-ltnpe", f"sport = :{port}", check=False)
    if listeners.returncode:
        return None
    packaged = (Path(POLARIS), Path("/usr/libexec/polaris/polaris-kms"))
    kms = kms_service_socket() if "cgroup:" in listeners.stdout else None
    polaris_listeners = []
    for line in listeners.stdout.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        pids = re.findall(r"\bpid=(\d+)", line)
        # File capabilities can hide the KMS socket's owning PID from its desktop user.
        # The kernel's socket cgroup still identifies the active packaged service.
        if kms and kms[0] in fields[5:] and (not pids or pids == [kms[1]]):
            polaris_listeners.append(fields[3].rsplit(":", 1)[0])
            continue
        for pid in pids:
            try:
                if mode == "console-target" and Path(f"/proc/{pid}").stat().st_uid != uid:
                    continue
                exe = Path(f"/proc/{pid}/exe").resolve(strict=True)
                if any(binary.is_file() and binary.resolve() == exe for binary in packaged):
                    polaris_listeners.append(fields[3].rsplit(":", 1)[0])
            except OSError:
                continue
    for address, binds in (("127.0.0.1", ("*", "0.0.0.0", "127.0.0.1")),
                           ("[::1]", ("*", "[::]", "[::1]"))):
        if not any(bind in binds for bind in polaris_listeners):
            continue
        url = f"https://{address}:{port}/api/configLocale"
        response = run("curl", "--disable", "--noproxy", "*", "--insecure", "--fail",
                       "--silent", "--max-time", "1", "--max-filesize", "4096", url, check=False)
        if response.returncode == 0:
            try:
                data = json.loads(response.stdout)
            except ValueError:
                continue
            if isinstance(data, dict) and data.get("status") is True and isinstance(data.get("locale"), str):
                return address
    return None


def start_desktop(deployment, plan, keep_job=False):
    global finish_action
    port = console_port()
    if console_ready(port):
        # An instance launched by the player may already be streaming.
        run("systemctl", "--user", "enable", UNIT)
    else:
        run("systemctl", "--user", "enable", "--now", UNIT)
        limit = time.monotonic() + 25
        while not console_ready(port):
            if time.monotonic() >= limit:
                raise RuntimeError(f"The Polaris console did not answer on local port {port}.")
            time.sleep(0.5)
    url = f"https://localhost:{port}/"
    if not keep_job:
        completed = deployment
        if mode == "now" and not plan and queued_job() == ("desktop", {}):
            completed = "desktop"
        clear_login_job(completed, plan)
    if star and sys.stdout.isatty():
        print(star, end="", flush=True)
        time.sleep(0.08)
        print("\r", end="")
    print(f"{check}Polaris console ready\n  {url}", flush=True)
    append_log(f"Polaris console ready\n  {url}\n")
    if not keep_job:
        finish_action = "check-console"
    opener = shutil.which("xdg-open")
    local_display = os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY", "").startswith((":", "unix:", "unix/:"))
    remote_shell = any(os.environ.get(k) for k in ("SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"))
    if interactive and opener and local_display and not remote_shell:
        # A desktop terminal or the one-shot login job can close as soon as we finish.
        # Give the browser its own lifetime in the signed-in user's service manager.
        try:
            launch = run("systemd-run", "--user", "--quiet", "--collect", "--", opener, url, check=False)
        except OSError:
            launch = None
        if launch is None or launch.returncode:
            print(f"Open {url} in your desktop browser.")
        elif not keep_job:
            finish_action = "browser-requested"
            print(f"Browser launch requested. If needed, open {url}")


def service_state():
    result = run("systemctl", "--user", "show", UNIT,
                 "--property=LoadState,ActiveState,MainPID,ExecStart,InvocationID")
    props = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if props.get("LoadState") != "loaded" or not props.get("ActiveState"):
        raise RuntimeError("The Polaris user service is unavailable or masked.")
    return props


def current_helper(props, proof):
    if props.get("ActiveState") != "active" or not props.get("MainPID", "").isdigit() or int(props["MainPID"]) == 0:
        return False
    try:
        return os.readlink(f"/proc/{props['MainPID']}/exe") == KMS
    except PermissionError:
        # Only a positive packaged observation or a new invocation of the already
        # reloaded unit can vouch for an executable hidden by file capabilities.
        return proof
    except FileNotFoundError:
        return False


def confirm_restart():
    if not interactive:
        return False
    try:
        with open("/dev/tty", "r+b", buffering=0) as terminal:
            fd = terminal.fileno()
            saved = termios.tcgetattr(fd)
            restart = False
            typed = b""
            try:
                tty.setcbreak(fd, termios.TCSANOW)
                terminal.write(b"Restarting Polaris to use the DRM/KMS helper disconnects any active stream.\n"
                               b"Choose Keep streaming to finish setup after your next PC restart and sign-in.\n"
                               b"Up/Down to select, Enter to confirm (y/N).\n> Keep streaming    Restart Polaris\n")
                while True:
                    key = terminal.read(1)
                    if key in (b"\r", b"\n"):
                        return typed in (b"y", b"yes") if typed else restart
                    if key in (b"", b"\x04"):
                        return False
                    if key == b"\x1b":
                        if not select.select([fd], [], [], 0.2)[0] or terminal.read(1) not in (b"[", b"O"):
                            return False
                        if not select.select([fd], [], [], 0.2)[0] or terminal.read(1) not in (b"A", b"B", b"C", b"D"):
                            continue
                    elif key != b"\t":
                        if key.isalpha():
                            typed = (typed + key.lower())[:4]
                            terminal.write(key)
                        elif key in (b"\x7f", b"\x08"):
                            typed = typed[:-1]
                        continue
                    restart = not restart
                    typed = b""
                    terminal.write(b"> Restart Polaris\n" if restart else b"> Keep streaming\n")
            finally:
                termios.tcsetattr(fd, termios.TCSANOW, saved)
                terminal.write(b"\n")
    except (OSError, termios.error):
        return False


def manager_invocation():
    value = run("systemctl", "show", f"user@{uid}.service", "-p", "InvocationID", "--value",
                check=False)
    return value.stdout.strip() if value.returncode == 0 and re.fullmatch(r"[0-9a-f]{32}", value.stdout.strip()) else ""


def wants_link(account_home):
    return account_home / ".config/systemd/user/default.target.wants" / UNIT


def packaged_want(link):
    return link.is_symlink() and link.is_file() and link.resolve() in (
        Path("/usr/lib/systemd/user") / UNIT, Path("/usr/local/lib/systemd/user") / UNIT,
        Path("/etc/systemd/user") / UNIT)


def kms_files(account_home):
    active = account_home / ".config/systemd/user/polaris.service.d/20-polaris-kms.conf"
    return active, active.with_suffix(".conf.disabled-until-relogin")


def helper_drop_in(path):
    if path.is_symlink() or not path.is_file():
        return False
    # Both the active and parked package files contain the same service override.
    lines = [line.strip() for line in path.read_text().splitlines()
             if line.strip() and not line.lstrip().startswith(("#", ";"))]
    return lines == ["[Service]", "ExecStart=", f"ExecStart={KMS}"]


def lingering():
    result = run("loginctl", "show-user", str(uid), "-p", "Linger", "--value", check=False)
    return result.returncode == 0 and result.stdout.strip() == "yes"


def check_mutable_boot(deployment):
    release = os.uname().release
    if not Path(f"/usr/lib/modules/{release}").is_dir():
        raise RuntimeError(f"The running kernel {release} still has no installed modules. "
                           "Setup will retry after you boot the installed kernel and sign in.")
    nvidia = Path("/sys/module/nvidia/version")
    if not nvidia.is_file():
        return
    query = (["pacman", "-Q", "nvidia-utils"] if deployment == "pacman" else
             ["rpm", "-q", "--qf", "%{VERSION}-%{RELEASE}", "nvidia-utils"])
    libraries = run(*query, check=False)
    if libraries.returncode == 0:
        fields = libraries.stdout.split()
        if not fields:
            raise RuntimeError("Could not identify the installed NVIDIA driver libraries.")
        version = fields[-1].split(":")[-1].rsplit("-", 1)[0]
        if version != nvidia.read_text().strip():
            raise RuntimeError("The loaded NVIDIA driver and installed libraries still differ. "
                               "Setup will retry after the matching driver boots and you sign in.")


def apply_options(deployment, plan):
    account_home = Path(pwd.getpwuid(uid).pw_dir)
    active, parked = kms_files(account_home)
    link = wants_link(account_home)
    if plan["kms"]:
        for path in (active, parked):
            if os.path.lexists(path) and not helper_drop_in(path):
                raise RuntimeError(f"A different service override already exists at {path}.")
    if plan["headless"] and os.path.lexists(link) and not packaged_want(link):
        raise RuntimeError(f"A different boot-start entry already exists at {link}.")
    # Arm before sudo: a cancelled password, partial command or lost terminal can be
    # recovered by this account, even after the downloaded installer disappears.
    queue_for_login(deployment, plan)
    flags = []
    if plan["kms"]:
        flags.append("--enable-kms")
    if plan["headless"]:
        flags.append("--enable-headless-boot")
    print(f"Applying host options for {plan['account']}.", flush=True)
    details = admin_setup(*flags)
    append_log(details)
    for line in details.splitlines():
        if re.search(r"\]: (Warning|Error|Fatal): ", line):
            print(line)
    if plan["headless"]:
        if not packaged_want(link) or not lingering():
            raise RuntimeError("Could not verify lingering and the Polaris boot-start link for this account.")
    if plan["kms"] and not (helper_drop_in(parked) ^ helper_drop_in(active)):
        raise RuntimeError("The package did not leave a verifiable active or pending DRM/KMS service override.")
    return details


def activate_options(deployment, plan, mutable, details):
    global restart_pending, finish_action
    account_home = Path(pwd.getpwuid(uid).pw_dir)
    active, parked = kms_files(account_home)
    pending = plan["kms"] and helper_drop_in(parked)
    if plan["headless"]:
        wants = run("systemctl", "--user", "show", "default.target", "-p", "Wants", "--value")
        if UNIT not in wants.stdout.split():
            raise RuntimeError("The user manager did not load the Polaris boot-start link.")
        print(f"Polaris is set to start before sign-in for {plan['account']}.")
    if pending:
        plan["wait_manager"] = manager_invocation()
        queue_for_login(deployment, plan)
        if plan["headless"] or lingering():
            restart_pending = True
            print("DRM/KMS is waiting for a new login group. Restart when ready, then sign in.")
        else:
            print("DRM/KMS is waiting for a new login group. Sign out of all sessions, then sign back in.")
            print("If another session stays open, restart when ready and sign in.")
        print("Polaris will finish the change automatically.")
        if mutable and not plan["headless"]:
            return
    props = service_state()
    # Desktop autostart or the boot want can already be bringing up Polaris
    # (its packaged ExecStartPre sleeps five seconds). Let that job settle.
    limit = time.monotonic() + 25
    while props["ActiveState"] in ("activating", "deactivating", "reloading") and time.monotonic() < limit:
        time.sleep(0.5)
        props = service_state()
    state = props["ActiveState"]
    use_helper = plan["kms"] and not pending
    if use_helper and not props.get("ExecStart", "").startswith(f"{{ path={KMS} ;"):
        raise RuntimeError(f"The user manager did not load {active}. Check other Polaris service overrides.")
    native_current = f"The polaris user service already runs {KMS} (" in details
    started = False
    if state == "active" and use_helper and not current_helper(props, native_current):
        if not confirm_restart():
            if not mutable:
                run("systemctl", "--user", "enable", UNIT)
            print("The current Polaris session will keep running. Restart the PC when ready "
                  "and sign in to finish switching to the DRM/KMS helper.")
            plan["wait_boot"] = BOOT_ID.read_text().strip()
            queue_for_login(deployment, plan)
            return
        run("systemctl", "--user", "restart", UNIT)
        started = True
    elif state in ("inactive", "failed"):
        if run("ss", "-H", "-ltn", f"sport = :{console_port()}").stdout.strip():
            if not mutable:
                run("systemctl", "--user", "enable", UNIT)
            print("The console port is already in use. Polaris will retry at the next desktop "
                  "login so the current session can continue.")
            return
        run("systemctl", "--user", "start", UNIT)
        started = True
    elif state != "active":
        print(f"The Polaris service is {state}. Setup will retry at the next desktop login.")
        return
    after = service_state()
    if (after["ActiveState"] != "active" or not after.get("MainPID", "").isdigit()
            or int(after["MainPID"]) == 0
            or (use_helper and not after.get("ExecStart", "").startswith(f"{{ path={KMS} ;"))):
        raise RuntimeError("Could not confirm that the selected Polaris service started.")
    if use_helper:
        invocation = after.get("InvocationID", "")
        new_instance = (started and re.fullmatch(r"[0-9a-f]{32}", invocation)
                        and invocation != props.get("InvocationID"))
        same_instance = (after.get("InvocationID") == props.get("InvocationID")
                         and after["MainPID"] == props["MainPID"])
        if not current_helper(after, new_instance or (native_current and same_instance)):
            raise RuntimeError("Could not verify that the running service switched to the packaged DRM/KMS helper.")
        print("The Polaris service is running with the DRM/KMS helper.")
    if not mutable:
        start_desktop(deployment, plan, keep_job=pending)
    elif not pending:
        clear_login_job(deployment, plan)
        finish_action = "check-console"
    return not pending


def check_packages(deployment, plan):
    names = ["polaris", "polaris-kms"] if plan.get("kms") else ["polaris"]
    if not plan:
        result = run("rpm", "-q", "--quiet", "polaris", check=False)
        if result.returncode:
            if mode == "login":
                clear_login_job(deployment, plan)
            raise RuntimeError("The selected Polaris package is unavailable on this boot.")
        return
    query = (["pacman", "-Q"] if deployment == "pacman" else
             ["rpm", "-q", "--qf", "%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\\n"])
    result = run(*query, *names)
    rows = [line.split() for line in result.stdout.splitlines()]
    if (len(rows) != len(names) or any(len(row) != 2 for row in rows)
            or {row[0] for row in rows} != set(names) or len({row[1] for row in rows}) != 1):
        raise RuntimeError(f"Could not verify matching installed versions for {', '.join(names)}.")
    return rows[0][1]


def finish(deployment, plan):
    mutable = deployment in ("dnf", "pacman")
    if deployment == "desktop" and plan:
        raise ValueError("Saved host options require a package manager or deployment.")
    image_kms = not mutable and plan.get("kms")
    wait = plan.get("wait_update")
    parked_plan = None
    recovering = False
    if deployment != "desktop" and not mutable and (mode == "login" or image_kms):
        deployments, boot = image_state()
        if wait and wait["osname"] != boot["osname"]:
            return
        if not on_selected_boot(boot, deployment, plan) and not wait:
            if mode != "login":
                raise RuntimeError("The selected Polaris deployment is no longer booted.")
            if any(row.get("staged") and on_selected_boot(row, deployment, plan) for row in deployments):
                print("The Polaris deployment is still waiting for a restart.")
            else:
                clear_login_job(deployment, plan)
                print("The selected Polaris deployment was replaced. Setup was cancelled.")
            return
    if plan:
        if not all(type(plan.get(key)) is bool for key in ("kms", "headless")) or not (plan["kms"] or plan["headless"]):
            raise ValueError("Invalid saved host options.")
        if plan.get("wait_boot") == BOOT_ID.read_text().strip():
            print("Polaris setup is waiting for a restart. It will resume when you sign back in.")
            return
        if plan.get("wait_manager") and plan["wait_manager"] == manager_invocation():
            print("The account still has the same service manager. Restart when ready, "
                  "then sign in to finish DRM/KMS setup.")
            return
        if mutable and mode == "login":
            check_mutable_boot(deployment)
    if image_kms:
        identity = image_identity(boot)
        if mode == "login" and plan.get("finish_in_terminal") == identity:
            print("Open Host review in the installer to finish the saved request.")
            return
        if wait and not on_selected_boot(boot, deployment, plan):
            # Another deployment can have its own approved login job. Let
            # that job finish before carrying an older request onto its boot.
            if any(entry != desktop and on_selected_boot(boot, other, saved)
                   for entry, _, other, saved in image_requests()):
                return
        blocked = wait == identity
        if not blocked:
            blocked = not image_supports_kms(boot, plan)
            if blocked:
                plan["wait_update"] = identity
                queue_for_login(deployment, plan)
            elif wait:
                # Keep the request discoverable until the packaged setup has
                # succeeded. A Plasma autostart unit often has no password TTY.
                plan["next_deployment"] = boot["checksum"]
                recovering = True
        if blocked:
            print(f"KMS capture: {WAITING}.")
            if not plan["headless"] or plan.get("headless_done"):
                return
            # Startup before sign-in is independent of image-managed KMS
            # enrollment. Keep the full request until startup is verified.
            parked_plan = plan
            plan = {**plan, "kms": False}
            check_packages(deployment, plan)
    else:
        check_packages(deployment, plan)
    if plan:
        try:
            details = apply_options(deployment, plan)
        except SetupCommandFailed as error:
            if mode != "login" or not image_kms:
                raise
            saved = parked_plan or plan
            saved["finish_in_terminal"] = identity
            queue_for_login(deployment, saved)
            append_log(f"{error}\n")
            print(f"{error}\nOpen Host review in the installer to finish the saved request.")
            return
        if recovering or (image_kms and not parked_plan and "finish_in_terminal" in plan):
            for key in ("wait_update", "finish_in_terminal", "headless_done"):
                plan.pop(key, None)
            queue_for_login(deployment, plan)
    else:
        details = setup_input()
        append_log(details)
        for line in details.splitlines():
            if line.startswith("Start Polaris directly with `polaris`"):
                continue
            if log_path and re.match(r"^\[\d{4}-\d\d-\d\d [\d:.]+\]: Info: ", line):
                continue
            print(line)
        print("Host input setup complete.")
    if uid == 0:
        print("System setup finished. Sign in as the desktop user to start Polaris.")
        return
    reload = run("systemctl", "--user", "daemon-reload", check=False)
    if reload.returncode:
        if any(reason in reload.stdout.lower() for reason in ("connect to", "no medium", "not been booted")):
            legacy_desktop = not plan and mode == "now" and helper.name == "finish-host.py"
            queue_for_login("desktop" if legacy_desktop else deployment, plan)
            print("Polaris will finish setup at your next desktop login.")
            return
        raise RuntimeError(reload.stdout.strip() or "The desktop service manager is unavailable.")
    if plan:
        if activate_options(deployment, plan, mutable, details) and not plan["kms"] and plan["headless"]:
            previous, saved = queued_job()
            if saved.get("wait_update") and deployment in (previous, saved.get("next_deployment")):
                saved["headless_done"] = True
                saved.pop("finish_in_terminal", None)
                atomic_write(desktop, entry_bytes(previous, saved, helper), 0o600)
    else:
        start_desktop(deployment, plan)


def main():
    global target, log_path
    if mode in ("review-kms", "cancel-kms", "finish-kms"):
        control_kms_request()
        return
    if mode == "console-target":
        port = console_port()
        try:
            address = console_ready(port)
        except OSError:
            address = None
        print(port, address or "unavailable")
        return
    if mode in ("options-now", "options-after-reboot") and not target and manager in ("dnf", "pacman"):
        target = manager
    if mode not in ("now", "after-reboot", "login", "options-now", "options-after-reboot") or (
        target not in ("dnf", "pacman", "desktop") and
        not (mode == "now" and not target) and not re.fullmatch(r"[a-f0-9]{64}", target)
    ) or (mode != "login" and mode.startswith("options-") != (target in ("dnf", "pacman"))):
        raise ValueError("Unexpected host setup destination.")
    if kms not in ("0", "1") or headless not in ("0", "1"):
        raise ValueError("Invalid host options.")
    if mode == "now" and (kms, headless) != ("0", "0") and not re.fullmatch(r"[0-9a-f]{64}", target):
        raise ValueError("Host options on this image require the reviewed deployment checksum.")
    if uid == 0:
        if mode == "login" or (kms, headless) != ("0", "0"):
            raise RuntimeError("Run host options as the desktop account that will stream.")
        if mode == "after-reboot":
            print("Host package staged. Run the installer as the desktop user to set up that account.")
            return
        finish(target or "desktop", {})
    else:
        user_state.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (user_state / "finish.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            plan = {}
            if mode == "login":
                select_job(target, {})
                if Path(__file__) != helper:
                    return
                saved_target, plan = queued_job()
                if saved_target != target:
                    return
                if plan:
                    log_path = str(user_state / "finish.log")
            elif (kms, headless) != ("0", "0"):
                plan = dict(uid=uid, account=pwd.getpwuid(uid).pw_name, kms=kms == "1", headless=headless == "1")
                if mode == "now" and re.fullmatch(r"[0-9a-f]{64}", next_deployment):
                    plan["next_deployment"] = next_deployment
            if mode != "login":
                if re.fullmatch(r"[0-9a-f]{64}", target) and kms == "0":
                    refresh_image_request(target)
                select_job(target or "desktop", plan)
                if plan.get("kms") and re.fullmatch(r"[0-9a-f]{64}", target):
                    previous, saved = queued_job()
                    if saved.get("wait_update") and target in (previous, saved.get("next_deployment")):
                        plan.update({key: saved[key] for key in ("wait_update", "headless_done") if key in saved})
            if mode in ("after-reboot", "options-after-reboot"):
                if mode == "options-after-reboot":
                    plan["wait_boot"] = BOOT_ID.read_text().strip()
                queue_for_login(target, plan)
                print("Restart when you are ready. Polaris will finish setup when you sign back in.")
            else:
                finish(target or "desktop", plan)


try:
    main()
    if restart_pending and mode in ("now", "options-now"):
        sys.exit(75)  # The shell offers its normal Later / Restart choice.
    if sys.argv[11:] == ["finish-actions"]:
        if finish_action == "check-console":
            sys.exit(76)  # Check the console before offering a browser.
        if finish_action == "deferred":
            sys.exit(77)  # Keep the existing login or boot handoff.
except (OSError, ValueError, RuntimeError, KeyError) as error:
    append_log(f"Polaris setup could not finish. {error}\n")
    sys.exit(f"Polaris setup could not finish. {error}")
POLARIS_FINISH
}

kms_request() {
  host_completion_program | python3 -I - "$1" "${2:-}" 0
}

finish_ostree_host() {
  case "${enable_kms:-0}:${enable_headless:-0}" in
    0:0) case "$1" in options-*) return 0 ;; esac ;;
    0:1|1:0|1:1) ;;
    *) die 'Invalid host options.' ;;
  esac
  if [ "$dry_run" -eq 1 ]; then
    case "$1" in
      options-*) note 'Apply the selected host options for your account.' ;;
      *) note 'Set up input, start the Polaris desktop service and check its local console.' ;;
    esac
    if [ "${enable_kms:-0}${enable_headless:-0}" != 00 ]; then
      set -- /usr/bin/polaris --setup-host
      [ "${enable_kms:-0}" -eq 0 ] || set -- "$@" --enable-kms
      [ "${enable_headless:-0}" -eq 0 ] || set -- "$@" --enable-headless-boot
      if [ "$guided" -eq 1 ]; then show_command "sudo -H $(command_words "$@")"
      else show_command "sudo -n -H $(command_words "$@")"; fi
    fi
    note 'If a reboot is needed, finish automatically at the next desktop login.'
    return 0
  fi
  if [ -z "$key_dir" ]; then
    key_dir="$(mktemp -d)" || die 'Could not prepare host setup.'
  fi
  finish_program="$key_dir/finish-host.py"
  host_completion_program > "$finish_program" || die 'Could not prepare host setup.'
  case "$1" in after-reboot|options-after-reboot) installer_restart_pending=1 ;; esac
  # A combined install reports the verified host immediately and saves its
  # one glint for the verified player at the end.
  host_star="$ready_star"
  if has_client; then host_star=''; fi
  finish_status=0
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    desktop_uid="$(id -u -- "$SUDO_USER")" || die 'Could not find the desktop user.'
    [ "$desktop_uid" != 0 ] || die 'Host options need a non-root desktop account.'
    # A user-owned copy can also become the next-login helper.
    as_desktop_user sh -c '
      set -eu
      umask 077
      program="$(mktemp)"
      trap '\''rm -f -- "$program"'\'' EXIT
      cat > "$program"
      python3 -I "$program" "$@"
    ' sh "$1" "${2:-}" "$guided" "" "$host_star" "$ready_check" "${enable_kms:-0}" "${enable_headless:-0}" "$manager" "${pending_checksum:--}" finish-actions < "$finish_program" || finish_status=$?
  else
    python3 -I "$finish_program" "$1" "${2:-}" "$guided" "$log_file" "$host_star" "$ready_check" "${enable_kms:-0}" "${enable_headless:-0}" "$manager" "${pending_checksum:--}" finish-actions || finish_status=$?
  fi
  case "$finish_status" in
    75) installer_restart_pending=1 ;;
    76) probe_finish_console=1 ;;
    77) finish_setup_deferred=1 ;;
    *) return "$finish_status" ;;
  esac
}

# A user unit and a Flatpak process are observations about different things.
# Neither establishes an open window, a listening console or a working pair.
host_service_state() {
  if [ -n "$SUDO" ] && command -v systemctl >/dev/null 2>&1; then
    service="$(systemctl --user is-active polaris.service 2>/dev/null)" || :
    case "$service" in
      active|inactive|failed|activating|deactivating)
        say "Polaris user service: $service."
        return 0 ;;
    esac
  fi
  say 'Polaris user service: unknown.'
}

nova_process_state() {
  if apps_running="$(flatpak ps --columns=application 2>/dev/null)"; then
    if printf '%s\n' "$apps_running" | grep -Fxq "$NOVA_APP"; then
      say 'Nova process: running (Flatpak app ID observed; branch and window unknown).'
    elif [ "$guided" -eq 0 ]; then
      say 'Nova process: absent from the Flatpak process list.'
    else
      log_line 'Nova process: absent from the Flatpak process list.'
    fi
  else
    say 'Nova process: unknown.'
  fi
}

run_selection() {
  if has_host; then
    phase=host
    if [ "$operation" = uninstall ]; then
      if [ "$ostree" -eq 1 ]; then
        deployment_status
        [ "$pending" -eq 0 ] || die 'A deployment is already pending. Review rpm-ostree status and boot it before changing Polaris.'
      fi
      remove_host
    elif [ "$manager" = rpm-ostree ]; then
      read_ostree_target
      if [ -n "${reviewed_ostree_state:-}" ] && [ "$ostree_state" != "$reviewed_ostree_state" ]; then
        die 'The deployment changed after review. Review the installer again.'
      fi
      if [ "$pending_checksum" = - ]; then
        note "Booted deployment: $boot_checksum (Polaris: $boot_packages)."
      else
        note "Keep the pending deployment: $pending_checksum (Polaris: $pending_packages)."
      fi
      if [ "${enable_kms:-0}" -eq 1 ] && [ "$review_only" -eq 1 ]; then
        # Apply compares the two command previews. Even when both would defer
        # to the same stage, a changed boot or request set requires review.
        note "Deployment review ID: $deployment_review"
      fi
      case "$ostree_action" in
        now) complete_ostree_package now ;;
        after-reboot) complete_ostree_package after-reboot "$pending_checksum" ;;
        layer) install_fedora ;;
      esac
    else
      installed_before="$(installed_version polaris)"
      [ "$review_only" -eq 0 ] || say "Polaris in the booted system: ${installed_before:-absent}."
      install_host
    fi
  fi
  if has_client; then phase=client; manage_nova; fi
  phase=''
}

role_reason() {
  if has_host && [ -n "$host_reason" ]; then printf '%s Manual: %s\n' "$host_reason" "$host_manual"; fi
  if has_client && [ -n "$nova_reason" ]; then printf '%s Manual: %s\n' "$nova_reason" "$nova_manual"; fi
  return 0
}

plan_summary() {
  say ''
  case "$role" in host) title="$host_label" ;; client) title="$play_label" ;; both) title="$both_label" ;; esac
  if [ "$operation" = uninstall ]; then action=Uninstall; else action='Install or update'; fi
  say "$action | $title"
  if has_host; then
    if [ "$operation" = uninstall ]; then
      say 'System packages (administrator): remove installed polaris and polaris-kms only.'
      say 'Keep the repository, signing keys, settings, pairing keys and library.'
      [ "$manager" != pacman ] || say 'The Arch package removal hook also removes its Spaces security setup when present.'
      [ "$ostree" -eq 0 ] || say 'A layered package removal takes effect after reboot.'
    else
      if [ "$manager" = rpm-ostree ]; then
        say "System packages (administrator): layer Polaris from $BASE_URL if needed."
        say 'A fresh install applies additions live. Existing pending changes and replacements wait for a restart.'
        if [ "$run_setup" -eq 1 ]; then
          say 'Set up host input, start the Polaris desktop service and check https://localhost:47990/.'
          say 'When a restart is required, finish setup at the next desktop login.'
        else
          say 'Package only. Host setup and desktop startup are skipped.'
        fi
      else
        say "System packages (administrator): polaris from $BASE_URL. Keep polaris-kms in sync if already installed."
        if [ "$manager" = pacman ]; then say 'Arch requires a full system upgrade; other installed packages may also be updated.'; fi
        if [ "$run_setup" -eq 1 ]; then say "Host setup: apply packaged input rules / load input modules with $setup_command when the booted kernel is usable."
        else say "Host setup: leave $setup_command for later."; fi
        say 'Manage this host - start Polaris, then open https://localhost:47990/'
      fi
      host_options_summary
    fi
  fi
  if has_client; then
    nova_ref="app/$NOVA_APP/x86_64/$channel"
    say "User Flatpak (no sudo): $nova_ref"
    if [ "$operation" = uninstall ]; then
      say 'Keep other branches, the system installation, runtimes, remotes, pairing and app data.'
    else
      say "Channel: $channel; publisher: $NOVA_FEED/repo"
      say "Runtime: $NOVA_RUNTIME from Flathub, per user. Flatpak may install matching runtime extensions."
      say 'Nova can use network, display, GPU, input and audio. It can read Moonlight settings and access Steam userdata and Documents/Nova reports.'
      say 'Missing user sources are added. Installing a second branch can change the desktop default.'
      say "Play on this PC - open Nova: $(nova_launch)"
    fi
  fi
}

# Draw the short review from the exact package inventory used by the dry run.
review_note() { say "  $review_bullet $*"; }

short_review() {
  if has_host; then
    if [ "$operation" = uninstall ]; then
      say "Polaris $sep All users $sep Administrator access"
      if [ -n "$targets" ]; then review_note "Remove $targets. Keep settings, pairing and library."
      else review_note 'Already absent. Keep settings, pairing and library.'; fi
      [ "$manager" != pacman ] || review_note 'The package hook also removes its Spaces security setup if present.'
      [ "$ostree" -eq 0 ] || [ -z "$targets" ] || review_note 'Removal takes effect after a restart.'
    else
      say "Polaris $sep All users $sep Administrator access for system changes"
      if [ "$manager" = rpm-ostree ]; then
        if [ "$ostree_action" = after-reboot ]; then
          review_note 'Polaris is staged. Restart to use the new deployment.'
        elif [ "$ostree_action" = now ]; then
          review_note 'Use Polaris on the current boot.'
        elif [ "${enable_kms:-0}" -eq 1 ]; then
          review_note "Layer the signed packages needed for DRM/KMS capture: $missing_packages."
          if [ "$pending_checksum" != - ] || [ "$pristine_boot" -eq 0 ]; then
            review_note 'Restart to use the new deployment.'
          else
            review_note 'Apply additions live when possible.'
          fi
        elif [ "$pending_checksum" != - ] || [ "$pristine_boot" -eq 0 ]; then
          review_note 'Layer the signed host package for the next boot. Restart required.'
        else
          review_note 'Install the signed host package. Apply additions live when possible.'
        fi
        if [ "$run_setup" -eq 1 ]; then
          review_note 'Set up input and start the Polaris desktop service.'
          review_note 'If a restart is needed, setup resumes at the next desktop login.'
        else review_note 'Package only. Leave host setup for later.'; fi
      else
        if [ -n "$installed_before" ]; then review_note "Check for updates to the installed host ($installed_before)."
        else review_note 'Install the signed host package.'; fi
        [ "$manager" != pacman ] || review_note 'Arch requires a full system upgrade, including other installed packages.'
        if [ "$run_setup" -eq 1 ]; then review_note 'Set up host input when the running kernel is ready.'
        else review_note 'Package only. Leave host setup for later.'; fi
      fi
      if host_options_selected; then host_options_summary "$review_bullet "
      elif [ -z "$host_options_reason" ]; then review_note 'KMS capture and startup before sign-in are optional.'
      else review_note "Host options: $host_options_reason"; fi
    fi
  fi
  if has_client; then
    if has_host; then say ''; fi
    case "$channel" in stable) channel_label=Stable ;; beta) channel_label=Beta ;; esac
    say "Nova $channel_label $sep Your account $sep No administrator access"
    if [ "$operation" = uninstall ]; then
      if [ -n "$nova_before" ]; then review_note 'Remove this branch. Keep other branches, settings and pairing.'
      else review_note 'Already absent for this account. Keep settings and pairing.'; fi
    else
      if [ -n "$nova_before" ]; then review_note 'Check for updates to the installed player.'
      else review_note 'Install signed Nova. A second branch can change the desktop default.'; fi
      [ "$runtime_present" -eq 1 ] || review_note 'Add the KDE runtime from Flathub. Add missing user sources as needed.'
      review_note 'Uses display, GPU, controllers, audio, network and local gaming files.'
    fi
  fi
}

settle_review_heading() {
  if [ "$highlight" -eq 1 ]; then printf '\r%s[K' "$esc"; fi
  printf '%s%s%s\n' "$c_bold" "$review_title" "$c_off"
}

# Keep words together and indent the continuation of a plan bullet.
print_review_summary() (
  set -f
  while IFS= read -r line; do
    if [ "${#line}" -lt "$review_width" ]; then printf '%s\n' "$line"; continue; fi
    row=''
    indent=''
    case "$line" in
      "  $review_bullet "*) row="  $review_bullet "; indent='    '; line=${line#"$row"} ;;
    esac
    space=''
    for word in $line; do
      if [ -n "$space" ] && [ $((${#row} + 1 + ${#word})) -ge "$review_width" ]; then
        printf '%s\n' "$row"
        row=$indent
        space=''
      fi
      row="$row$space$word"
      space=' '
    done
    printf '%s\n' "$row"
  done <<REVIEW_SUMMARY
$1
REVIEW_SUMMARY
)

# Only count single terminal rows. Counting bytes is conservative for wide glyphs.
fitting_text_rows() (
  if [ -z "$1" ]; then printf '0\n'; return; fi
  LC_ALL=C
  export LC_ALL
  width=${1#* }
  rows=0
  while IFS= read -r line; do
    if [ "${#line}" -ge "$width" ]; then printf '0\n'; return; fi
    case "$line" in *[[:cntrl:]]*) printf '0\n'; return ;; esac
    rows=$((rows + 1))
  done <<REVIEW_TEXT
$2
REVIEW_TEXT
  printf '%s\n' "$rows"
)

review_commands() (
  dry_run=1
  review_only=1
  run_selection || exit "$?"
  if [ "${1:-}" = preview ]; then
    summary="$(short_review)" || exit "$?"
    settle_review_heading >&3
    print_review_summary "$summary" >&3
    # The final record is the height of the displayed review. The caller keeps
    # the preceding command output for Details and the pre-Apply comparison.
    printf '\n'
    fitting_text_rows "$review_size" "$lf$review_title$lf$summary"
  fi
)

cancel() {
  say 'Nothing was changed.'
  exit 0
}
# Read one byte from the controlling terminal. The suffix preserves Enter in
# command substitution so an actual end of input can still cancel the menu.
menu_key() {
  packet="$(dd bs=1 count=1 <&5 2>/dev/null && printf .)" || return 1
  key=${packet%.}
  [ -n "$key" ]
}

# Only move the cursor over rows we drew ourselves and know did not wrap.
panel_fits() {
  [ "$live" -eq 1 ] || return 1
  panel_size="$(stty size <&5 2>/dev/null)" || return 1
  panel_height=${panel_size% *}
  panel_width=${panel_size#* }
  case "$panel_height:$panel_width" in *[!0-9:]*|:*|*:) return 1 ;; esac
  panel_rows=$#
  panel_margin=4
  if [ "$panel_kind" = review ]; then
    panel_rows=$((panel_rows + 3))  # heading and gaps above actions and navigation
    panel_margin=9                 # focus marker, shortcut and spacing
  fi
  [ "$panel_height" -ge $((panel_rows + 2)) ] && [ "$panel_width" -ge 48 ] || return 1
  for panel_item do
    panel_label=${panel_item#*|}
    [ $((${#panel_label} + panel_margin)) -lt "$panel_width" ] || return 1
  done
}

# Leave the cursor on the footer while changing a checkbox. A newline at the
# bottom of the screen would scroll every option one row above the player.
paint_panel() {
  panel_up=$1
  shift
  panel_frame=''
  panel_clear=''
  if [ "$panel_up" -gt 0 ]; then
    panel_frame="$cr${esc}[${panel_up}A"
    panel_clear="${esc}[K"
  fi
  if [ "$panel_kind" = review ]; then
    panel_frame="$panel_frame$panel_clear$lf${c_bold}Choose an action$c_off$panel_clear$lf"
  fi
  for panel_item do
    panel_key=${panel_item%%|*}
    panel_label=${panel_item#*|}
    if [ "$panel_kind" = review ]; then
      if [ "$panel_key" = b ]; then panel_frame="$panel_frame$panel_clear$lf"; fi
      panel_label="[$panel_key]  $panel_label"
    fi
    if [ "$panel_key" = "$active" ] && { [ "$panel_kind" != review ] || [ "$panel_active" -eq 1 ]; }; then
      panel_line="$c_focus> $panel_label$c_off"
    else
      panel_line="  $panel_label"
    fi
    panel_frame="$panel_frame$panel_line$panel_clear$lf"
  done
  printf '%s%s%s' "$panel_frame" "$panel_hint" "$panel_clear"
}

# Small and plain terminals show the same review actions, one per line.
plain_action_prompt() {
  if [ "$panel_kind" = review ]; then
    panel_hint="$prompt"
    paint_panel 0 "$@"
    printf ' '
  else
    printf '%s ' "$prompt"
  fi
}

panel_shortcut() {
  if [ -n "$typed" ]; then printf '\r%s[KShortcut  %.18s   Enter Select' "$esc" "$typed"
  else printf '\r%s[K%s' "$esc" "$panel_hint"; fi
}

# Retire just these controls before the next step. Previous results stay in
# scrollback and only the current menu shows a highlighted row.
clear_panel_rows() {
  panel_clear="$cr${esc}[K"
  rows_left=$1
  while [ "$rows_left" -gt 0 ]; do
    panel_clear="$panel_clear${esc}[A${esc}[K"
    rows_left=$((rows_left - 1))
  done
  printf '%s' "$panel_clear"
}

# Same choices and return value as answer. The plain prompt also works when
# stdin contains the installer itself or cursor addressing is unavailable.
panel_previous=0
panel_kind=actions
action_answer() {
  panel_requested=1
  if answer "$@"; then panel_result=0; else panel_result=1; fi
  panel_requested=0
  return "$panel_result"
}

# The arguments after the initial selection are key|label pairs in tab order.
# Keep letter/number shortcuts line-based so pasted input stays with its menu.
answer() {
  prompt=$1
  initial=$2
  shift 2
  active=$initial
  panel_active=0
  closed_panel_size=''
  choice=''
  choice_tty="$(stty -g <&5 2>/dev/null)" || choice_tty=''
  if [ -z "$choice_tty" ] || ! command -v dd >/dev/null 2>&1 ||
      ! stty -icanon -echo min 1 time 0 <&5 2>/dev/null; then
    restore_choice_tty
    [ "$panel_previous" -eq 0 ] || printf '\n'
    panel_previous=0
    if [ "${panel_requested:-0}" -eq 1 ] && [ "$panel_kind" != review ]; then
      for item do printf '  %s\n' "${item#*|}"; done
    fi
    plain_action_prompt "$@"
    IFS= read -r choice <&5 || return 1
    choice=${choice:-$initial}
    return 0
  fi
  cursor=1
  position=0
  for item do
    position=$((position + 1))
    if [ "${item%%|*}" = "$initial" ]; then cursor=$position; fi
  done
  typed=''
  move_keys='Up/Down'
  [ "$utf8" -eq 0 ] || move_keys='↑/↓'
  case "$panel_kind" in
    role) panel_hint="Choose a role   $move_keys Move   Enter Select" ;;
    checkboxes) panel_hint="$move_keys Move   Space Toggle   Enter Select" ;;
    review) panel_hint="$move_keys or letter, then Enter" ;;
    *) panel_hint="$move_keys Move   Enter Select" ;;
  esac
  if [ "${panel_requested:-0}" -eq 1 ] && panel_fits "$@"; then
    panel_active=1
    if [ "$panel_kind" = review ] && { [ "$panel_size" != "$review_size" ] ||
        [ $((review_rows + panel_rows + 1)) -gt "$panel_height" ]; }; then
      review_rows=0
    fi
    if [ "$panel_previous" -eq "$panel_rows" ] &&
        [ "${panel_last_size:-}" = "$panel_size" ]; then
      paint_panel "$panel_previous" "$@"
    else
      if [ "$panel_previous" -ne 0 ]; then review_rows=0; printf '\n'; fi
      paint_panel 0 "$@"
    fi
    panel_last_size=$panel_size
  else
    plain_action_prompt "$@"
  fi
  panel_previous=0
  selection_drawn=0
  while menu_key; do
    case "$key" in
      "$lf"|"$cr") choice=${typed:-$active}; break ;;
      ' ') case "$panel_kind:$active:$typed" in checkboxes:k:|checkboxes:s:) choice=$active; break ;; esac
        continue ;;
      "$menu_eof") restore_choice_tty; printf '\n'; return 1 ;;
      "$menu_erase"|"$menu_bs")
        if [ -n "$typed" ]; then
          typed=${typed%?}
          if [ "$panel_active" -eq 1 ]; then panel_shortcut; else printf '\b \b'; fi
        fi
        continue ;;
      "$esc")
        # A lone Escape must not block waiting for a terminal escape sequence.
        stty min 0 time 1 <&5
        direction=''
        if menu_key; then
          case "$key" in '['|O) if menu_key; then direction=$key; fi ;; esac
        fi
        stty min 1 time 0 <&5
        case "$direction" in A) cursor=$((cursor - 1)) ;; B) cursor=$((cursor + 1)) ;; *) continue ;; esac ;;
      "$menu_tab") cursor=$((cursor + 1)) ;;
      [a-zA-Z0-9])
        typed="$typed$key"
        if [ "$panel_active" -eq 1 ]; then panel_shortcut; else printf '%s' "$key"; fi
        continue ;;
      *) continue ;;
    esac
    if [ "$cursor" -lt 1 ]; then cursor=$#; elif [ "$cursor" -gt "$#" ]; then cursor=1; fi
    position=0
    for item do
      position=$((position + 1))
      if [ "$cursor" -eq "$position" ]; then
        active=${item%%|*}
        typed=''
        if [ "$panel_active" -eq 1 ]; then
          if panel_fits "$@"; then
            if [ "$panel_size" = "$panel_last_size" ]; then paint_panel "$panel_rows" "$@"
            else review_rows=0; printf '\n'; paint_panel 0 "$@"; fi
            panel_last_size=$panel_size
            break
          fi
          # Rows may have reflowed. Leave the old frame in scrollback.
          panel_active=0
          review_rows=0
          printf '\n'
          if [ "$panel_kind" = review ]; then prompt="Enter = ${item#*|}."; fi
          plain_action_prompt "$@"
          [ "$panel_kind" != review ] || break
        fi
        if [ "$selection_drawn" -eq 1 ]; then printf '\r%s[K' "$esc"
        else printf '\n'; fi
        if [ "$panel_kind" = review ]; then selection_line="Enter = ${item#*|}."
        else selection_line="  > ${item#*|}"; fi
        printf '%s ' "$selection_line"
        # A wrapped hint spans multiple terminal rows and cannot be erased as one line.
        selection_drawn=0
        if [ "$live" -eq 1 ] && [ $((${#selection_line} + 1)) -lt "$(term_columns)" ]; then selection_drawn=1; fi
        break
      fi
    done
  done
  restore_choice_tty
  if [ "$panel_active" -eq 1 ] && [ "$panel_kind" = checkboxes ]; then
    case "$choice" in 1|2|k|K|s|S) panel_previous=$#; return 0 ;; esac
  fi
  if [ "$panel_active" -eq 1 ] && panel_fits "$@" && [ "$panel_last_size" = "$panel_size" ]; then
    clear_panel_rows "$panel_rows"
    closed_panel_size=$panel_size
  else
    printf '\n'
  fi
  [ -n "$choice" ]
}

host_options_help() {
  say ''
  say 'Host options'
  say 'Check the options to apply on this run. Unchecked items keep their settings.'
  say 'Let Polaris capture the monitor connected to this PC. You can enable it later.'
  say 'Starting before sign-in keeps account services running after sign-out.'
  [ "$run_setup" -eq 1 ] || say 'Selecting either option also includes host input setup.'
  if [ "$manager" = rpm-ostree ]; then
    say 'On image-based hosts, KMS needs a newer host package than Polaris 1.5.0.'
  fi
}

host_options() {
  kms_choice=$enable_kms
  boot_choice=$enable_headless
  read_host_option_status
  focus=k
  panel_kind=checkboxes
  help_text="$(host_options_help)"
  review_width="$(term_columns)"
  print_review_summary "$help_text"
  help_rows="$(fitting_text_rows "$review_size" "$help_text")"
  if [ "$closed_panel_size" != "$review_size" ] || [ "$help_rows" -eq 0 ]; then review_rows=0; fi
  while :; do
    kms_mark=' '; boot_mark=' '
    [ "$kms_choice" -eq 0 ] || kms_mark=x
    [ "$boot_choice" -eq 0 ] || boot_mark=x
    kms_label="[$kms_mark] Capture the host display (KMS)${kms_status:+  $sep $kms_status}"
    boot_label="[$boot_mark] Start Polaris before sign-in${boot_status:+  $sep $boot_status}"
    set -- "k|$kms_label" "s|$boot_label" 'd|Done' 'b|Back without edits' 'q|Quit'
    if ! panel_fits "$@"; then
      review_rows=0
      [ "$panel_previous" -eq 0 ] || printf '\n'
      panel_previous=0
      say "  1  $kms_label"
      say "  2  $boot_label"
      say '  3  Done'
      say 'Up/Down to choose. Enter or Space toggles an option. Done returns to review.'
    elif [ "$panel_size" != "$review_size" ] || [ $((review_rows + help_rows + $# + 1)) -gt "$panel_height" ]; then
      # Some of the old review may have scrolled off or reflowed.
      review_rows=0
    fi
    case "$focus" in k) focus_label='KMS capture' ;; s) focus_label='startup before sign-in' ;; d) focus_label=Done ;; esac
    action_answer "Host options [Enter = $focus_label, 1/2/3, b = back, q = quit]:" "$focus" "$@" || cancel
    case "$choice" in
      1|k|K) kms_choice=$((1 - kms_choice)); focus=k ;;
      2|s|S) boot_choice=$((1 - boot_choice)); focus=s ;;
      3|d|D|done) enable_kms=$kms_choice; enable_headless=$boot_choice
        if host_options_selected; then run_setup=1; fi
        review_focus=a; break ;;
      b|B|back) break ;;
      q|Q|quit) cancel ;;
    esac
  done
  if [ "$review_rows" -gt 0 ] && [ -n "$review_size" ] && [ "$closed_panel_size" = "$review_size" ]; then
    clear_panel_rows $((review_rows + help_rows))
  fi
  panel_kind=actions
}

role_option() {
  line="  $1  $2$role_separator$3${4:+ (unavailable)}"
  if [ "${#line}" -le "$role_columns" ]; then say "$line"; return; fi
  line="  $1 "
  for word in $2; do
    if [ $(( ${#line} + 1 + ${#word} )) -gt "$role_columns" ]; then
      say "$line"
      line='    '
    fi
    line="$line $word"
  done
  say "$line"
  say "     $3"
  if [ -n "$4" ]; then say '     (unavailable)'; fi
}

choose_role() {
  role_columns="$(term_columns)"
  say ''
  say 'What do you want to do on this PC?'
  if [ "$fancy" -eq 1 ] && [ "$utf8" -eq 1 ] && [ "$role_columns" -ge 40 ]; then
    # Static 25-column trace of the raised-hand figure in Polaris/polaris.png.
    printf '%s\n' '  ⢀⣴⣦
   ⠘⠁⢀⡀  ⠠         ⣀⣀⣤⣤⣀
  ⣀  ⢘⣷⡀        ⡀⢊⣉⣁⣀ ⠉⣿⡇
     ⣾⣿⣿⢀⠤⣒⣉⣉⠙⠛⢿⡅   ⢹⠇⢠⡿⠁
     ⠈⢿⣿⢣⣿⠛⣿⠿⣿⣆ ⢳⡀ ⢠⠏⣠⠟
      ⠘⣿⢸⣷⣾⣿⣠⣿⡿⢠⠋⣧ ⠁⠞⠁
  ⢀⡴⢃⡄ ⠙⣷⣍⣛⠛⠛⢉⣠⡾⠞⠃
 ⣠⠞⢡⡎   ⡇⢿⣿⣿⣿⣿⣿⣶⣶⣤⣤⣦⣤⣤⣀
⣰⡏ ⢿⣄⣀⣀ ⢿⡌⢿⣿⣿⣟⠿⢿⣿⣿⣿⣿⣿⢿⣿⣿⣆
⢿⣧⣀⣀⣈⣡⠤ ⠈⢿⣦⣌⠻⠿⣿⣷⣶⣿⣿⠿⢿⣷⣎⢻⣿
 ⠉⠉⠉⠁     ⠙⠻⠿⣷⣶⣾⡭⠔  ⠼⠿⠟⠸⠋'
  else
    say 'Polaris raises a hand.'
  fi
  while :; do
    say ''
    why="${host_reason}${nova_reason}"
    role_prompt="Choose a role [1/2/3, Enter = $role, q = quit]:"
    if [ "$role_columns" -le "${#role_prompt}" ]; then
      role_prompt='Choose a role [1/2/3]:'
    fi
    case "$role" in host) initial_role=1 ;; client) initial_role=2 ;; both) initial_role=3 ;; esac
    set -- "1| 1  $host_label${host_reason:+ (unavailable)}" "2| 2  $play_label${nova_reason:+ (unavailable)}" \
      "3| 3  $both_label${why:+ (unavailable)}" 'q| q  Quit'
    if [ "$utf8" -eq 1 ] && panel_fits "$@"; then
      [ -z "$host_reason" ] || note "$host_reason"
      [ -z "$nova_reason" ] || note "$nova_reason"
      panel_kind=role
      action_answer "$role_prompt" "$initial_role" "$@" || cancel
      panel_kind=actions
    else
      role_option 1 "$host_action" Polaris "$host_reason"
      [ -z "$host_reason" ] || note "$host_reason"
      role_option 2 "$play_action" Nova "$nova_reason"
      [ -z "$nova_reason" ] || note "$nova_reason"
      role_option 3 "$both_action" 'Polaris + Nova' "$why"
      say 'Up/Down to select.'
      if [ "$role_prompt" = 'Choose a role [1/2/3]:' ]; then say "Enter = $role, q = quit"; fi
      answer "$role_prompt" "$initial_role" "$@" || cancel
    fi
    case "$choice" in
      1|host) role=host ;; 2|client) role=client ;; 3|both) role=both ;;
      q|Q|quit) cancel ;; '') ;; *) continue ;;
    esac
    why="$(role_reason)"
    if [ -z "$why" ]; then
      if ! has_host; then enable_kms=0; enable_headless=0; fi
      return 0
    fi
    say "$why"
  done
}

reviewed_ostree_state=''
interactive_review() {
  review_focus=''
  if [ "$selected_role" -eq 0 ]; then choose_role; fi
  while :; do
    reviewed_ostree_state=''
    review_rows=0
    review_size=''
    if panel_fits; then review_size=$panel_size; fi
    why="$(role_reason)"
    if [ -n "$why" ]; then say "$why"; choose_role; continue; fi
    case "$role" in host) review_title="$host_action" ;; client) review_title="$play_action" ;; both) review_title="$both_action" ;; esac
    review_width="$(term_columns)"
    say ''
    highlight=0
    if [ "$live" -eq 1 ] && [ "$review_width" -gt "${#review_title}" ]; then
      # Borrow only the time already spent reading package state. Typeahead
      # stays with the terminal, even when the next key is entered immediately.
      highlight=1
      printf '%s%s%s' "${esc}[1;36m" "$review_title" "$c_off"
    fi
    valid=1
    if plan="$(review_commands preview 2>&1)"; then
      review_rows=${plan##*"$lf"}
      plan="$(printf '%s' "${plan%"$lf"*}")"
    else
      valid=0
      settle_review_heading
      printf '%s\n' "$plan"
      say 'Resolve the issue above or choose another role.'
    fi
    set -- 'd|View details'
    details_open=0
    default_focus=d
    reviewed_kms=''
    if [ "$operation" = install ] && has_host && [ "$manager" = rpm-ostree ] && [ -z "$host_options_reason" ]; then
      reviewed_kms="$(kms_request review-kms 2>/dev/null)" || reviewed_kms=''
      if [ -n "$reviewed_kms" ]; then
        request_info=${reviewed_kms#* }
        request_image=${request_info% *}
        request_kind=${request_info##* }
        case "$request_kind" in
          ready) request_note='KMS capture is ready. Choose Finish request to apply it.' ;;
          ready-both) request_note='Finish your saved request for KMS capture and startup before sign-in.' ;;
          *) request_note='KMS capture: Waiting for a compatible Polaris update.' ;;
        esac
        print_review_summary "  $review_bullet $request_note"
        review_rows=0
        set -- 'x|Cancel request' "$@"
        case "$request_kind" in
          ready|ready-both) set -- 'f|Finish request' "$@" ;;
          headless) set -- 'f|Finish startup before sign-in' "$@" ;;
        esac
      fi
    fi
    if [ "$valid" -eq 1 ] && [ "$operation" = install ] && [ "$role" = client ]; then default_focus=a; fi
    if [ "$operation" = install ] && has_host && [ -z "$host_options_reason" ]; then
      if [ "$valid" -eq 1 ]; then
        set -- 'o|Host options' "$@"
        default_focus=o
      else
        set -- "$@" 'o|Host options'
      fi
    fi
    if [ "$valid" -eq 1 ]; then set -- 'a|Apply' "$@"
    else review_focus=''; fi
    if [ "$review_focus" != a ]; then review_focus=$default_focus; fi
    case "$review_focus" in o) enter_label='Host options' ;; a) enter_label=Apply ;; *) enter_label='View details' ;; esac
    while :; do
      panel_kind=review
      action_answer "Enter = $enter_label." "$review_focus" "$@" 'b|Back to roles' 'q|Quit' || cancel
      panel_kind=actions
      case "$choice" in
        a|A|apply|Apply)
          [ "$valid" -eq 1 ] || continue
          if [ "$operation" = install ] && has_host && [ "$manager" = rpm-ostree ]; then
            reviewed_ostree_state="$(read_ostree_target && printf '%s\n' "$ostree_state")" || break
          fi
          current="$(review_commands 2>&1)" && [ "$current" = "$plan" ] && return 0
          say 'The plan changed. Review it again before applying.'
          break ;;
        d|D|details)
          review_rows=0
          system_details
          plan_summary
          printf '%s\n' "$plan"
          if [ "$operation" = install ] && has_host; then
            say 'h = edit host setup'
            [ "$details_open" -eq 1 ] || set -- "$@" 'h|Change host input setup'
          fi
          if has_client; then
            say "c = edit Nova channel (currently $channel)"
            [ "$details_open" -eq 1 ] || set -- "$@" 'c|Change Nova channel'
          fi
          details_open=1 ;;
        o|O) if [ "$operation" = install ] && has_host && [ -z "$host_options_reason" ]; then host_options; break; fi ;;
        f|F)
          [ -n "$reviewed_kms" ] || continue
          case "$request_kind" in ready|ready-both|headless) ;; *) continue ;; esac
          if finish_ostree_host finish-kms "${reviewed_kms%% *}"; then exit 0; fi
          break ;;
        x|X)
          [ -n "$reviewed_kms" ] || continue
          say "Cancel the saved KMS request for deployment $request_image?"
          action_answer 'KMS request [k = Keep request, x = Cancel request]:' k \
            'k|Keep request' 'x|Cancel request' || cancel
          if [ "$choice" = x ] || [ "$choice" = X ]; then
            if kms_request cancel-kms "${reviewed_kms%% *}"; then exit 0; fi
          fi
          break ;;
        b|B|back) review_focus=''; choose_role; break ;;
        h|H) if [ "$operation" = install ] && has_host; then
            run_setup=$((1 - run_setup))
            if [ "$run_setup" -eq 0 ]; then enable_kms=0; enable_headless=0; fi
            review_focus=''; break
          fi ;;
        c|C) if has_client; then
            if [ "$channel" = stable ]; then channel=beta; else channel=stable; fi
            break
          fi ;;
        q|Q|quit) cancel ;;
      esac
    done
  done
}

system_details() {
  say "Edition: ${edition:-unknown} | Desktop: ${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-unknown}} | Architecture: $arch"
  say "Host manager: ${manager:-no supported route} | Polaris repository: $BASE_URL"
  [ -z "$host_reason" ] || say "Host route unavailable: $host_reason"
  if command -v flatpak >/dev/null 2>&1; then flatpak_status=detected; else flatpak_status=unavailable; fi
  say "Player manager: Flatpak ($flatpak_status, per user) | Signed channel: $NOVA_FEED"
  say "Manual host: $host_manual"
  say "Manual player: $nova_manual"
}

local_finish_desktop() {
  [ "$guided" -eq 1 ] && [ "$dry_run" -eq 0 ] && [ "$operation" = install ] &&
    [ "$installer_restart_pending" -eq 0 ] && [ "$finish_setup_deferred" -eq 0 ] && [ "${reboot_first:-0}" -eq 0 ] &&
    [ "${ostree_action:-}" != after-reboot ] &&
    [ -z "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ] || return 1
  if [ -z "$SUDO" ]; then
    [ -n "${SUDO_USER:-}" ] && [ -n "${desktop_uid:-}" ] && [ "$desktop_uid" != 0 ] || return 1
  fi
  [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
  case "${DISPLAY:-}" in :*|unix:*|unix/:*) return 0 ;; *) return 1 ;; esac
}

# Console configuration, the user manager and the opener belong to the player.
# A root invocation can manage Polaris for the account that invoked sudo.
as_desktop_user() {
  if [ -n "$SUDO" ]; then "$@"; return; fi
  [ -n "${desktop_uid:-}" ] && [ "$desktop_uid" != 0 ] || return 1
  if [ -n "${DISPLAY:-}" ]; then set -- "DISPLAY=$DISPLAY" "$@"; fi
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then set -- "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" "$@"; fi
  if [ -n "${XAUTHORITY:-}" ]; then set -- "XAUTHORITY=$XAUTHORITY" "$@"; fi
  if [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]; then
    set -- "SSH_CONNECTION=${SSH_CONNECTION:-}" "SSH_CLIENT=${SSH_CLIENT:-}" "SSH_TTY=${SSH_TTY:-}" "$@"
  fi
  sudo -H -u "$SUDO_USER" env XDG_RUNTIME_DIR="/run/user/$desktop_uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$desktop_uid/bus" "$@"
}

collect_finish_console() {
  finish_console_url='' finish_console_port=''
  [ "$probe_finish_console" -eq 1 ] && local_finish_desktop || return 0
  target="$(host_completion_program | as_desktop_user python3 -I - console-target '' 0 2>/dev/null)" || return 0
  port=${target%% *}
  case "$port" in ''|*[!0-9]*) return 0 ;; esac
  finish_console_port=$port
  case "${target#* }" in
    '127.0.0.1'|'[::1]') finish_console_url="https://${target#* }:$port/" ;;
  esac
}

launch_finish_app() {
  # Drop the controlling terminal and its descriptors. When a user manager is
  # available, also move the app out of the terminal's service cgroup while
  # preserving this desktop's display and per-user Flatpak environment.
  as_desktop_user sh -c '
    if [ -S "${XDG_RUNTIME_DIR:-}/systemd/private" ] && command -v systemd-run >/dev/null 2>&1; then
      set -- systemd-run --user --scope --quiet -- "$@"
    fi
    setsid --wait "$@" </dev/null >/dev/null 2>&1 5<&- &
    launch_pid=$!
    sleep 0.5
    kill -0 "$launch_pid" 2>/dev/null || wait "$launch_pid"
  ' sh "$@"
}

finish_actions() {
  if [ "$manager" = rpm-ostree ]; then collect_finish_console; fi
  finish_default=''
  while [ -n "$finish_nova_ref$finish_console_url" ]; do
    set --
    shortcuts=''
    if [ -n "$finish_nova_ref" ]; then
      set -- 'n|Open Nova'
      shortcuts='n = Open Nova, '
    fi
    if [ -n "$finish_console_url" ]; then
      set -- "$@" 'p|Open Polaris'
      shortcuts="${shortcuts}p = Open Polaris, "
    fi
    action_answer "Finish [${shortcuts}d = Done]:" "${finish_default:-${1%%|*}}" "$@" 'd|Done' || return 0
    case "$choice" in
      n|N)
        [ -n "$finish_nova_ref" ] || continue
        if [ "$(flatpak info --user --show-commit "$finish_nova_ref" 2>/dev/null)" != "$finish_nova_commit" ]; then
          say 'Could not confirm the installed Nova commit. Run the installer again to verify it.'
        elif launch_finish_app flatpak run --user "$finish_nova_ref" --standalone; then
          say "Nova launch requested. If it does not appear, run: $(nova_launch)"
        else
          say "Could not launch Nova. Run in your desktop terminal: $(nova_launch)"
        fi
        finish_nova_ref='' ;;
      p|P)
        [ -n "$finish_console_url" ] || continue
        selected_url=$finish_console_url
        collect_finish_console
        if [ "$finish_console_url" != "$selected_url" ]; then
          say "Polaris could not be verified again at $selected_url. Check that Polaris is running."
        elif launch_finish_app xdg-open "$selected_url"; then
          say "Browser launch requested. If needed, open $selected_url"
        else
          say "Could not launch the browser. Open $selected_url in your desktop browser."
        fi
        finish_console_url='' ;;
      d|D|done|Done|q|Q) return 0 ;;
      *) continue ;;
    esac
    finish_default=d
  done
}

banner='Polaris + Nova installer'
if [ "$guided" -eq 0 ] && [ "$role" = host ]; then banner='Polaris installer'; fi
printf '%s%s%s %s %s\n' "$c_bold" "$banner" "$c_off" "$sep" "${PRETTY_NAME:-$distro}"
if [ "$guided" -eq 0 ] || { [ -n "$host_reason" ] && [ -n "$nova_reason" ]; }; then system_details; fi
[ "$dry_run" -eq 0 ] || say 'Dry run: nothing will be changed.'

if [ "$guided" -eq 1 ]; then
  [ -z "$host_reason" ] || [ -z "$nova_reason" ] || die "No supported role. $host_reason $nova_reason"
  if ( : </dev/tty ) 2>/dev/null; then exec 5</dev/tty; else die 'No keyboard terminal. Use --dry-run or --yes with an explicit role.'; fi
  if [ "$selected_role" -eq 0 ] && [ -n "$host_reason" ] && [ -z "$nova_reason" ]; then role=client; fi
  # Initialize key bytes before a resize can interrupt the menu reader.
  menu_eof="$(printf '\004')" menu_erase="$(printf '\177')" menu_bs="$(printf '\010')" menu_tab="$flatpak_tab"
  # A resize can reflow scrollback even when the original size is restored.
  trap 'review_size=""; review_rows=0' WINCH
  interactive_review 3>&1
  trap - WINCH
  exec 5<&-
else
  why="$(role_reason)"
  [ -z "$why" ] || die "$why"
  if [ "$selected_channel" -eq 1 ] && ! has_client; then die '--channel requires --role client or --role both.'; fi
  if [ "$operation" = uninstall ] && [ "$dry_run" -eq 0 ] && [ "$unattended" -eq 0 ]; then
    die 'Unattended removal requires --yes. Review it with --dry-run first.'
  fi
  plan_summary
fi
run_selection </dev/null
show_log_path
if [ "$installer_restart_pending" -eq 1 ] && [ "$guided" -eq 1 ]; then
  if ( : </dev/tty ) 2>/dev/null; then
    exec 5</dev/tty
    restart_question='Restart this PC now to finish Polaris setup?'
    if panel_fits 'n|Later' 'y|Restart now'; then say "$restart_question"; fi
    action_answer "$restart_question [y/N] Up/Down to choose, Enter = Later." n \
      'n|Later' 'y|Restart now' || choice=n
    exec 5<&-
    case "$choice" in y|Y|yes|Yes) systemctl reboot ;; esac
  fi
elif local_finish_desktop && ( : </dev/tty ) 2>/dev/null; then
  exec 5</dev/tty
  finish_actions
  exec 5<&-
fi
