#!/usr/bin/env bash
# Execute the complete installer against os-release and read-only command fixtures.
# Only OS identity, the ostree marker, the pacman.conf and kernel module paths are
# substituted; the installer body is real. Commands that would change the host are stubs that
# record what they were asked to do. The signing-key cases also substitute
# FINGERPRINT with a throwaway key made here, and the real rpmkeys reads each
# served key, so this needs rpm and gpg: run it in a Fedora 44 or 45 container,
# as verify.yml does. The terminal cases run the installer in a pseudo-terminal,
# which needs python3.
# $releasever, $basearch and $arch are literal in repository files.
# shellcheck disable=SC2016
set -euo pipefail
# The role suite drives the shipped file directly. Its command boundaries
# work on macOS as well as the Fedora lane with the real key parser below.
if [ "${1:-}" = --roles-only ]; then
  shift
  exec python3 -I scripts/test-installer-roles.py "$@"
fi
for tool in gpg rpmkeys python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'test-guided-installer: %s was not found. Run this in a Fedora 44 or 45 container, as verify.yml does.\n' "$tool" >&2
    exit 1
  }
done
python3 -I scripts/test-installer-roles.py
python3 -I scripts/test-host-option-status.py
python3 -I scripts/test-ostree-completion.py
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/polaris-installer-fixture.XXXXXX")"
# The key cases start a gpg-agent under the fixture directory; stop it with it.
trap 'GNUPGHOME="$fixture_dir/gnupg" gpgconf --kill all >/dev/null 2>&1 || true; rm -rf -- "$fixture_dir"' EXIT
mkdir "$fixture_dir/bin" "$fixture_dir/written" "$fixture_dir/tmp-default" "$fixture_dir/modules"
# Logs and key directories stay inside the fixture, which the trap removes.
export TMPDIR="$fixture_dir/tmp-default"
export HOME="$fixture_dir/home" XDG_CONFIG_HOME="$fixture_dir/config" XDG_DATA_HOME="$fixture_dir/data" XDG_CACHE_HOME="$fixture_dir/cache"
mkdir "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
# rpm -q answers from a marker the dnf stub leaves, so a real run can end in an
# install. rpm --import keeps a copy of what it was given and records the path.
cat > "$fixture_dir/bin/rpm" <<'STUB'
#!/bin/sh
printf '%s\n' "rpm $*" >> "$INSTALLER_COMMANDS"
if [ "$1" = -qa ] && [ "$4" = polaris ]; then
  [ ! -e "${INSTALLED_MARKER:-/nonexistent}" ] || printf 'polaris-9.8.7-1.x86_64\n'
  exit 0
fi
if [ "$1" = -q ]; then
  for last; do :; done
  [ "$last" = polaris ] && [ -e "${INSTALLED_MARKER:-/nonexistent}" ] || exit 1
  [ "$2" = --quiet ] || printf '9.8.7-1\n'
  exit 0
fi
if [ "$1" = --import ] && [ "$#" -eq 2 ] && [ -n "${IMPORTED_KEY:-}" ]; then
  cp "$2" "$IMPORTED_KEY"
  exit 0
fi
exit 99
STUB
# curl serves KEY_FIXTURE as polaris.gpg, to --output or to stdout. It answers
# the served repository file and pacman section with hostile ones, which the
# installer must never ask for; everything is recorded and nothing else served.
cat > "$fixture_dir/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "curl $*" >> "$INSTALLER_COMMANDS"
output=''
while [ "$#" -gt 1 ]; do
  [ "$1" = --output ] && output="$2"
  shift
done
case "$1" in
  */polaris.gpg) [ -n "${KEY_FIXTURE:-}" ] || exit 99; served="$KEY_FIXTURE" ;;
  */fedora/polaris.repo) served="$HOSTILE_DIR/polaris.repo" ;;
  */arch/polaris.conf) served="$HOSTILE_DIR/polaris.conf" ;;
  *) exit 99 ;;
esac
if [ -n "$output" ]; then cp "$served" "$output"; else cat "$served"; fi
STUB
# install keeps a copy of each file under written/, named for its destination,
# so /etc is never touched.
cat > "$fixture_dir/bin/install" <<'STUB'
#!/bin/sh
printf '%s\n' "install $*" >> "$INSTALLER_COMMANDS"
for last; do :; done
[ -n "${WRITTEN_DIR:-}" ] || exit 99
while [ "$#" -gt 2 ]; do shift; done
cp "$1" "$WRITTEN_DIR/$(printf '%s' "$last" | tr / _)"
STUB
# dnf, rpm-ostree and pacman print TOOL_OUTPUT when it is set, as the real ones
# print their transaction, and exit with TOOL_STATUS instead of installing when
# that is set.
cat > "$fixture_dir/bin/dnf" <<'STUB'
#!/bin/sh
printf '%s\n' "dnf $*" >> "$INSTALLER_COMMANDS"
[ -n "${INSTALLED_MARKER:-}" ] || exit 99
[ -z "${TOOL_OUTPUT:-}" ] || cat "$TOOL_OUTPUT"
[ -z "${TOOL_STATUS:-}" ] || exit "$TOOL_STATUS"
touch "$INSTALLED_MARKER"
STUB
# The layer belongs to the next deployment until apply-live makes its RPM visible.
cat > "$fixture_dir/bin/rpm-ostree" <<'STUB'
#!/bin/sh
printf '%s\n' "rpm-ostree $*" >> "$INSTALLER_COMMANDS"
boot=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
next=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
case "$*" in
  'status --json')
    printf '{"transaction":null,"deployments":['
    if [ -z "${NOTHING_PENDING:-}" ] && grep -q '^rpm-ostree install ' "$INSTALLER_COMMANDS"; then
      printf '{"osname":"default","staged":true,"booted":false,"checksum":"%s","base-checksum":"%s","requested-packages":["polaris"]},' "$next" "$boot"
    fi
    printf '{"osname":"default","booted":true,"staged":false,"checksum":"%s","unlocked":"none","requested-packages":[]}]}\n' "$boot" ;;
  "db list $next")
    printf 'ostree commit: %s\n polaris-9.8.7-1.x86_64\n' "$next" ;;
  "db diff --format=json $boot $next")
    printf '{"ostree-commit-from":"%s","ostree-commit-to":"%s","pkgdiff":[["polaris",0,{"NewPackage":["polaris","9.8.7-1","x86_64"]}]]}\n' "$boot" "$next" ;;
  'install --idempotent polaris') [ -n "${INSTALLED_MARKER:-}" ] ;;
  "apply-live --target $next") touch "$INSTALLED_MARKER" ;;
  *) exit 99 ;;
esac
STUB
cat > "$fixture_dir/bin/pacman" <<'STUB'
#!/bin/sh
printf '%s\n' "pacman $*" >> "$INSTALLER_COMMANDS"
if [ "$1" = -Q ]; then
  [ "$2" = polaris ] && [ -e "${INSTALLED_MARKER:-/nonexistent}" ] || exit 1
  printf 'polaris 9.8.7-1\n'
  exit 0
fi
[ -n "${INSTALLED_MARKER:-}" ] || exit 99
[ -z "${TOOL_OUTPUT:-}" ] || cat "$TOOL_OUTPUT"
[ -z "${TOOL_STATUS:-}" ] || exit "$TOOL_STATUS"
touch "$INSTALLED_MARKER"
STUB
# polaris --setup-host prints SETUP_OUTPUT and exits with SETUP_STATUS.
cat > "$fixture_dir/bin/polaris" <<'STUB'
#!/bin/sh
printf '%s\n' "polaris $*" >> "$INSTALLER_COMMANDS"
[ -z "${SETUP_OUTPUT:-}" ] || cat "$SETUP_OUTPUT"
exit "${SETUP_STATUS:-0}"
STUB
cat > "$fixture_dir/bin/pacman-key" <<'STUB'
#!/bin/sh
printf '%s\n' "pacman-key $*" >> "$INSTALLER_COMMANDS"
[ -n "${WRITTEN_DIR:-}" ] || exit 99
[ "$*" != '--add -' ] || cat > "$WRITTEN_DIR/pacman-key-added"
STUB
# Only reached when this runs as a regular user.
cat > "$fixture_dir/bin/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "sudo $*" >> "$INSTALLER_COMMANDS"
while [ "${1:-}" = -n ] || [ "${1:-}" = -H ]; do shift; done
exec "$@"
STUB
chmod +x "$fixture_dir/bin/"*
export INSTALLER_COMMANDS="$fixture_dir/commands"
export HOSTILE_DIR="$fixture_dir/hostile"
mkdir "$HOSTILE_DIR"
# What a hostile origin would serve: no signature checks, a key nobody checked,
# a foreign mirror.
printf '%s\n' '[polaris]' 'name=Polaris' 'baseurl=https://mirror.example.invalid/fedora/$releasever/$basearch' \
  'enabled=1' 'gpgcheck=0' 'repo_gpgcheck=0' 'gpgkey=https://keys.example.invalid/other.gpg' > "$HOSTILE_DIR/polaris.repo"
printf '%s\n' '[polaris]' 'SigLevel = Never' 'Server = https://mirror.example.invalid/arch/$arch' > "$HOSTILE_DIR/polaris.conf"
export PATH="$fixture_dir/bin:$PATH"
sed -e "s|/etc/os-release|$fixture_dir/os-release|g" \
    -e "s|/run/ostree-booted|$fixture_dir/ostree-booted|g" \
    -e "s|/etc/pacman.conf|$fixture_dir/pacman.conf|g" \
    -e "s|/usr/lib/modules|$fixture_dir/modules|g" site/install.sh > "$fixture_dir/install.sh"
failures=0
checked=0
fail() { cat "$fixture_dir/output"; printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
# The line number of the first output line matching an extended regex, or 0.
line_of() { grep -n -m 1 -E "$1" "$fixture_dir/output" | cut -d: -f1 || printf '0\n'; }
# A run that started a step names one log at the start and again at the end or
# with its failure, and that log is mode 0600 in TMPDIR ($2). It is removed once
# checked, so each case finds only its own.
log_check() {
  first_log="$(sed -n 's/^Log: //p' "$fixture_dir/output" | head -n 1)"
  last_log="$(sed -n 's/^ *Full log: //p' "$fixture_dir/output" | tail -n 1)"
  if [ -z "$first_log" ] || [ "$first_log" != "$last_log" ] || [ ! -f "$first_log" ] ||
    [ "$(stat -c %a "$first_log")" != 600 ] || [ "$(cd "$(dirname "$first_log")" && pwd -P)" != "$(cd "$2" && pwd -P)" ]; then
    fail "$1: one log, named first and last, mode 0600, in TMPDIR"
  fi
  [ -z "$first_log" ] || cp "$first_log" "$fixture_dir/last.log"
  [ -z "$first_log" ] || rm -f -- "$first_log"
}
# A refusal before the first step leaves no log and names none.
no_log_check() {
  if [ -n "$(find "$2" -mindepth 1 -maxdepth 1 -name 'polaris-install-*')" ] ||
    grep -E '^ *(Full )?[Ll]og: ' "$fixture_dir/output"; then
    fail "$1: a refusal before any step makes no log"
  fi
}
key_path=/etc/pki/rpm-gpg/RPM-GPG-KEY-polaris
written_key="$fixture_dir/written/_etc_pki_rpm-gpg_RPM-GPG-KEY-polaris"
written_repo="$fixture_dir/written/_etc_yum.repos.d_polaris.repo"

# The repository file and pacman section the installer writes must be the ones
# the builder serves, except that gpgkey= names the checked key's local path.
served_template() {
  sed -n "/cat > \"\$output_dir\/${1//\//\\/}\" <<EOF/,/^EOF\$/p" scripts/build-package-repos.sh | sed '1d;$d' |
    sed -e 's|\$base_url|https://repo.papi-ux.com|g' -e 's|\\\$|$|g'
}
served_template fedora/polaris.repo |
  sed "s|^gpgkey=.*|gpgkey=file://$key_path|" > "$fixture_dir/expected.repo"
served_template arch/polaris.conf > "$fixture_dir/expected-section.conf"
if ! grep -Fx 'gpgcheck=1' "$fixture_dir/expected.repo" >/dev/null ||
  ! grep -Fx 'repo_gpgcheck=1' "$fixture_dir/expected.repo" >/dev/null ||
  ! grep -Fx 'SigLevel = Required DatabaseRequired' "$fixture_dir/expected-section.conf" >/dev/null; then
  printf 'could not read the served repository templates from scripts/build-package-repos.sh\n' >&2
  exit 1
fi

for distro in fedora bazzite; do
  rm -f "$fixture_dir/ostree-booted"
  [ "$distro" != bazzite ] || touch "$fixture_dir/ostree-booted"
for release in 44 45 43 46 45.1; do
  printf 'ID=%s\nID_LIKE=fedora\nVERSION_ID=%s\nPRETTY_NAME="%s %s fixture"\n' "$distro" "$release" "$distro" "$release" > "$fixture_dir/os-release"
  for setup in default no-setup; do
    : > "$INSTALLER_COMMANDS"
    args=(--dry-run)
    [ "$setup" = default ] || args+=(--no-setup)
    result=0
    sh "$fixture_dir/install.sh" "${args[@]}" > "$fixture_dir/output" 2>&1 || result=$?
    case "$release" in
      44|45)
        # The file the dry run shows is the served one, gpgkey= aside.
        if [ "$result" != 0 ] ||
          [ "$(sed -n '/polaris\.repo will read:$/,/^ *\$ /p' "$fixture_dir/output" | sed '1d;$d' | sed 's/^        //')" != "$(cat "$fixture_dir/expected.repo")" ]; then
          fail "Fedora $release $setup route"
        fi
        if [ "$setup" = no-setup ] && grep -E '^ +\$ (sudo (-n )?-H )?polaris --setup-host$' "$fixture_dir/output"; then failures=$((failures+1)); fi
        if [ "$setup" = default ] && [ "$distro" = fedora ] && ! grep -E '^ +\$ (sudo (-n )?-H )?polaris --setup-host$' "$fixture_dir/output" >/dev/null; then failures=$((failures+1)); fi
        if [ "$distro" = bazzite ] && ! grep -E '^ +\$ (sudo (-n )?)?rpm-ostree install --idempotent polaris$' "$fixture_dir/output" >/dev/null; then failures=$((failures+1)); fi
        # The dry run shows the check, in order: download, read, list, then the
        # import of that same file, keeping it, and the repository file.
        download="$(line_of '^ +\$ curl .* --output [^ ]*/polaris\.gpg https://repo\.papi-ux\.com/polaris\.gpg$')"
        read_key="$(line_of '^ +\$ rpmkeys --root [^ ]+ --noplugins --import [^ ]*/polaris\.gpg$')"
        list_keys="$(line_of '^ +\$ rpmkeys --root [^ ]+ --noplugins --list$')"
        import="$(line_of '^ +\$ (sudo (-n )?)?rpm --import [^ ]*/polaris\.gpg$')"
        keep="$(line_of "^ +\\$ (sudo (-n )?)?install -D -m 0644 [^ ]*/polaris\\.gpg $key_path\$")"
        repository="$(line_of '^ +\$ (sudo (-n )?)?install -m 0644 [^ ]*/polaris\.repo /etc/yum\.repos\.d/polaris\.repo$')"
        # rpm --import cannot write on an ostree host, whose rpm database is under the
        # read-only /usr; rpm-ostree reads the kept key through gpgkey= instead. So a
        # Bazzite run shows no import, and keeps the key straight after the check.
        if [ "$distro" = bazzite ]; then
          import_in_order=$([ "$import" = 0 ] && [ "$keep" -gt "$list_keys" ] && echo yes || echo no)
        else
          import_in_order=$([ "$import" -gt "$list_keys" ] && [ "$keep" -gt "$import" ] && echo yes || echo no)
        fi
        if [ "$download" = 0 ] || [ "$read_key" -le "$download" ] || [ "$list_keys" -le "$read_key" ] ||
          [ "$import_in_order" != yes ] || [ "$repository" -le "$keep" ] ||
          ! grep -F 'pinned fingerprint 58017EDFFA9F803E07ED26F835F13F14FAAD15CC' "$fixture_dir/output" >/dev/null ||
          grep -E 'rpm --import https?:|fedora/polaris\.repo' "$fixture_dir/output"; then
          fail "Fedora $release $setup dry run shows the key check before the import"
        fi
        ;;
      *)
        if [ "$result" = 0 ] || ! grep -F 'Fedora 44 and 45' "$fixture_dir/output" >/dev/null || grep -E '^\[[0-9]/4\]|will read:|^ +\$ ' "$fixture_dir/output"; then
          fail "Fedora $release refused before trust changes"
        fi ;;
    esac
    if grep -Ev '^rpm -q |^rpm -qa --qf %\{NEVRA\}\\n polaris$|^rpm-ostree status --json$' "$INSTALLER_COMMANDS"; then failures=$((failures+1)); fi
    if [ -n "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'polaris-key.XXXXXX' 2>/dev/null)" ]; then
      fail "a dry run created the placeholder key directory"
    fi
    # A dry run and a refusal change nothing, a log file included.
    if [ -n "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'polaris-install-*' 2>/dev/null)" ] || grep -E '^(Full )?[Ll]og: ' "$fixture_dir/output"; then
      fail "Fedora $release $setup made no log"
    fi
    checked=$((checked+1))
    printf 'checked %s %s %s (exit %s)\n' "$distro" "$release" "$setup" "$result"
  done
done
done

# Signing-key cases: real runs, with the key served by the curl stub and read by
# the real rpmkeys. Throwaway keys only; the vendor key is never involved.
export GNUPGHOME="$fixture_dir/gnupg"
mkdir -m 700 "$GNUPGHOME"
for name in pinned other; do
  gpg --batch --quiet --passphrase '' --quick-generate-key \
    "Installer fixture $name <$name@example.invalid>" rsa2048 sign 0 2>/dev/null
  gpg --batch --armor --export "$name@example.invalid" > "$fixture_dir/$name.asc"
done
pinned_fingerprint="$(gpg --batch --with-colons --fingerprint pinned@example.invalid |
  awk -F: '$1 == "fpr" { print $10; exit }')"
[ -n "$pinned_fingerprint" ]
gpg --batch --armor --export pinned@example.invalid other@example.invalid > "$fixture_dir/two-keys.asc"
: > "$fixture_dir/empty.asc"
printf '<html><body>404 Not Found</body></html>\n' > "$fixture_dir/garbage.asc"
sed "s|^FINGERPRINT='.*'$|FINGERPRINT='$pinned_fingerprint'|" "$fixture_dir/install.sh" > "$fixture_dir/install-key.sh"
[ "$(grep -c "^FINGERPRINT='$pinned_fingerprint'$" "$fixture_dir/install-key.sh")" = 1 ] ||
  { printf 'could not substitute the throwaway fingerprint into the test copy\n' >&2; exit 1; }
TMPDIR_FOR_KEYS="$fixture_dir/tmp"
mkdir "$TMPDIR_FOR_KEYS"
export INSTALLED_MARKER="$fixture_dir/installed"
export IMPORTED_KEY="$fixture_dir/imported.asc"
export WRITTEN_DIR="$fixture_dir/written"

for distro in fedora bazzite; do
  rm -f "$fixture_dir/ostree-booted"
  release=44
  if [ "$distro" = bazzite ]; then touch "$fixture_dir/ostree-booted"; release=45; fi
  printf 'ID=%s\nID_LIKE=fedora\nVERSION_ID=%s\nPRETTY_NAME="%s %s fixture"\n' "$distro" "$release" "$distro" "$release" > "$fixture_dir/os-release"
  # pinned-relative serves the pinned key with a relative TMPDIR, which rpm
  # would refuse as a --root unless the installer makes it absolute. rerun is a
  # second run over the install pinned left behind.
  rm -f "$INSTALLED_MARKER"
  for key in pinned rerun pinned-relative other two-keys empty garbage; do
    : > "$INSTALLER_COMMANDS"
    [ "$key" = rerun ] || rm -f "$INSTALLED_MARKER"
    rm -f "$IMPORTED_KEY" "$WRITTEN_DIR"/*
    result=0
    key_tmpdir="$TMPDIR_FOR_KEYS"
    [ "$key" != pinned-relative ] || key_tmpdir=tmp
    case "$key" in rerun|pinned-relative) served=pinned ;; *) served="$key" ;; esac
    (cd "$fixture_dir" && KEY_FIXTURE="$fixture_dir/$served.asc" TMPDIR="$key_tmpdir" \
      sh "$fixture_dir/install-key.sh" --no-setup) > "$fixture_dir/output" 2>&1 || result=$?
    if [ "$distro/$key" = bazzite/rerun ]; then
      if [ "$result" != 0 ] || ! grep -F 'polaris-9.8.7-1.x86_64 installed on this boot' "$fixture_dir/output" >/dev/null ||
        grep -Ev '^rpm -qa --qf %\{NEVRA\}\\n polaris$|^rpm-ostree status --json$' "$INSTALLER_COMMANDS"; then
        fail 'bazzite rerun: already installed on this boot, no package writes'
      fi
      no_log_check "$distro $key" "$TMPDIR_FOR_KEYS"
      checked=$((checked+1))
      printf 'checked %s on bazzite 45 (exit %s)\n' "$key" "$result"
      continue
    fi
    key_download="$(grep -E '^(sudo (-n )?)?curl .*/polaris\.gpg$' "$INSTALLER_COMMANDS" || true)"
    if [ "$(printf '%s\n' "$key_download" | grep -c .)" != 1 ]; then
      fail "$distro $key: polaris.gpg downloaded exactly once"
    fi
    if grep -E 'polaris\.repo$|polaris\.conf$' "$INSTALLER_COMMANDS" | grep -E '^(sudo (-n )?)?curl '; then
      fail "$distro $key: the served repository file is never fetched"
    fi
    if [ -n "$(find "$TMPDIR_FOR_KEYS" -mindepth 1 -maxdepth 1 -name 'polaris-key.*')" ]; then
      fail "$distro $key: the temporary key directory was removed"
    fi
    # Every run that started a step leaves its log, mode 0600, named first and last.
    log_check "$distro $key" "$TMPDIR_FOR_KEYS"
    case "$key" in
      pinned|rerun|pinned-relative)
        downloaded_to="$(printf '%s\n' "$key_download" | sed -n 's/.* --output \([^ ]*\) .*/\1/p')"
        if [ "$distro" = bazzite ]; then
          # An ostree host imports nothing into rpm; the kept key is what rpm-ostree reads.
          if [ "$result" != 0 ] || ! grep -Fx '      rpm reads one key, and its fingerprint is the pinned one.' "$fixture_dir/output" >/dev/null ||
            grep -E '^rpm --import ' "$INSTALLER_COMMANDS" || [ -e "$IMPORTED_KEY" ]; then
            fail "$distro $key: the pinned key passes and nothing is imported into rpm"
          fi
        elif [ "$result" != 0 ] || ! grep -Fx '      rpm reads one key, and its fingerprint is the pinned one.' "$fixture_dir/output" >/dev/null ||
          ! grep -Fx "rpm --import $downloaded_to" "$INSTALLER_COMMANDS" >/dev/null ||
          [ "$(sha256sum < "$IMPORTED_KEY")" != "$(sha256sum < "$fixture_dir/pinned.asc")" ]; then
          fail "$distro $key: the pinned key passes and that same file is imported"
        fi
        # The checked key is kept for gpgkey=, and the repository file written
        # is the served one with gpgkey= naming it, whatever the origin serves.
        if [ "$(sha256sum < "$written_key")" != "$(sha256sum < "$fixture_dir/pinned.asc")" ] ||
          [ "$(cat "$written_repo")" != "$(cat "$fixture_dir/expected.repo")" ]; then
          fail "$distro $key: the checked key and the generated repository file are written"
        fi
        if [ "$distro" = fedora ] && [ "$key" = rerun ] &&
          { ! grep -Fx 'dnf upgrade -y polaris' "$INSTALLER_COMMANDS" >/dev/null ||
            ! grep -Fx 'Polaris 9.8.7-1 was already installed, and the package manager left it as it is.' "$fixture_dir/output" >/dev/null; }; then
          fail "$distro $key: a re-run upgrades and reports that nothing changed"
        elif [ "$distro" = fedora ] && [ "$key" != rerun ] && ! grep -Fx 'Installed Polaris 9.8.7-1.' "$fixture_dir/output" >/dev/null; then
          fail "$distro $key: the run ends in an install"
        fi
        if [ "$distro" = bazzite ] && ! grep -Fx 'rpm-ostree install --idempotent polaris' "$INSTALLER_COMMANDS" >/dev/null; then
          fail "$distro $key: the run ends in rpm-ostree install"
        fi
        if [ "$distro" = bazzite ] && { ! grep -F 'polaris-9.8.7-1.x86_64 installed on this boot' "$fixture_dir/output" >/dev/null ||
          ! grep -Eq '^rpm-ostree apply-live --target c{64}$' "$INSTALLER_COMMANDS"; }; then
          fail "$distro $key: apply only the signed staged commit and verify its booted RPM"
        fi
        ;;
      *)
        case "$key" in
          other) reason="has fingerprint" ;;
          two-keys) reason="holds 2 keys" ;;
          *) reason="rpm could not read a key from https://repo.papi-ux.com/polaris.gpg" ;;
        esac
        if [ "$result" = 0 ] || ! grep -F "$reason" "$fixture_dir/output" >/dev/null ||
          ! grep -F 'nothing on this host was changed' "$fixture_dir/output" >/dev/null ||
          grep -E '^\[2/4\]|polaris\.repo will read|rpm --import' "$fixture_dir/output"; then
          fail "$distro $key: refused before the import"
        fi
        # Nothing was written: the only commands run are the installed-version
        # queries and the one download into the temporary directory.
        if grep -Ev '^rpm -q |^rpm -qa --qf %\{NEVRA\}\\n polaris$|^rpm-ostree status --json$|^curl .* --output [^ ]*/polaris-key\.[^ /]*/polaris\.gpg https://repo\.papi-ux\.com/polaris\.gpg$' "$INSTALLER_COMMANDS" ||
          [ -e "$IMPORTED_KEY" ] || [ -e "$INSTALLED_MARKER" ] || [ -n "$(ls -A "$WRITTEN_DIR")" ]; then
          fail "$distro $key: nothing written"
        fi
        if [ "$key" = other ] && ! grep -F "$(gpg --batch --with-colons --fingerprint other@example.invalid |
          awk -F: '$1 == "fpr" { print $10; exit }')" "$fixture_dir/output" >/dev/null; then
          fail "$distro $key: the refusal names the key it found"
        fi
        ;;
    esac
    checked=$((checked+1))
    printf 'checked key %s on %s %s (exit %s)\n' "$key" "$distro" "$release" "$result"
  done
done

# An installed RPM needs no transaction. An install that leaves neither a
# staged RPM nor a booted RPM cannot finish host setup.
for case_name in already-layered nothing-layered; do
  : > "$INSTALLER_COMMANDS"
  rm -f "$IMPORTED_KEY" "$WRITTEN_DIR"/*
  if [ "$case_name" = already-layered ]; then touch "$INSTALLED_MARKER"; else rm -f "$INSTALLED_MARKER"; fi
  result=0
  (cd "$fixture_dir" && KEY_FIXTURE="$fixture_dir/pinned.asc" TMPDIR="$TMPDIR_FOR_KEYS" NOTHING_PENDING=1 \
    sh "$fixture_dir/install-key.sh" --no-setup) > "$fixture_dir/output" 2>&1 || result=$?
  if ! grep -Fx 'rpm-ostree status --json' "$INSTALLER_COMMANDS" >/dev/null; then
    fail "bazzite $case_name: read the deployment status"
  fi
  if [ "$case_name" = already-layered ]; then
    no_log_check "bazzite $case_name" "$TMPDIR_FOR_KEYS"
    if [ "$result" != 0 ] || ! grep -F 'polaris-9.8.7-1.x86_64 installed on this boot' "$fixture_dir/output" >/dev/null ||
      grep -E '^rpm-ostree (install|apply-live)' "$INSTALLER_COMMANDS"; then
      fail "bazzite $case_name: a second run keeps the installed package"
    fi
  else
    log_check "bazzite $case_name" "$TMPDIR_FOR_KEYS"
    if [ "$result" = 0 ] || ! grep -F 'without a verified staged Polaris RPM' "$fixture_dir/output" >/dev/null ||
      grep -E '^rpm-ostree apply-live' "$INSTALLER_COMMANDS"; then
      fail "bazzite $case_name: the run stops when nothing was layered"
    fi
  fi
  checked=$((checked+1))
  printf 'checked %s on bazzite 45 (exit %s)\n' "$case_name" "$result"
done

# Arch: pacman.conf gets the section this script writes, and a [polaris] section
# already there is left alone only when it is exactly that. Anything weaker stops
# the run before any key is trusted or pacman runs, with pacman.conf untouched.
rm -f "$fixture_dir/ostree-booted"
printf 'ID=arch\nPRETTY_NAME="Arch fixture"\n' > "$fixture_dir/os-release"
base_conf="$fixture_dir/pacman.conf.base"
printf '%s\n' '[options]' 'SigLevel = Required DatabaseOptional' '' '[core]' 'Include = /etc/pacman.d/mirrorlist' > "$base_conf"
section() { printf '\n[polaris]\n'; printf '%s\n' "$@"; }
good_siglevel='SigLevel = Required DatabaseRequired'
good_server='Server = https://repo.papi-ux.com/arch/$arch'
for case_name in fresh rerun old-script-host reformatted never trustall extra-never foreign-server include; do
  : > "$INSTALLER_COMMANDS"
  rm -f "$WRITTEN_DIR"/*
  case "$case_name" in
    fresh) cp "$base_conf" "$fixture_dir/pacman.conf"; rm -f "$INSTALLED_MARKER" ;;
    rerun) ;; # pacman.conf and the install as fresh left them
    # Exactly the arch/polaris.conf the builder serves, appended by the old installer.
    old-script-host) { cat "$base_conf"; cat "$fixture_dir/expected-section.conf"; } > "$fixture_dir/pacman.conf" ;;
    reformatted) { cat "$base_conf"; section '# signed' 'SigLevel=Required   DatabaseRequired' "  $good_server  "; } > "$fixture_dir/pacman.conf" ;;
    never) { cat "$base_conf"; section 'SigLevel = Never' "$good_server"; } > "$fixture_dir/pacman.conf" ;;
    trustall) { cat "$base_conf"; section 'SigLevel = Required DatabaseRequired TrustAll' "$good_server"; } > "$fixture_dir/pacman.conf" ;;
    extra-never) { cat "$base_conf"; section "$good_siglevel" "$good_server" 'SigLevel = PackageNever'; } > "$fixture_dir/pacman.conf" ;;
    foreign-server) { cat "$base_conf"; section "$good_siglevel" 'Server = https://mirror.example.invalid/arch/$arch'; } > "$fixture_dir/pacman.conf" ;;
    include) { cat "$base_conf"; section "$good_siglevel" "$good_server" 'Include = /etc/pacman.d/polaris-mirrors'; } > "$fixture_dir/pacman.conf" ;;
  esac
  case "$case_name" in old-script-host|reformatted) touch "$INSTALLED_MARKER" ;; never|trustall|extra-never|foreign-server|include) rm -f "$INSTALLED_MARKER" ;; esac
  conf_before="$(sha256sum < "$fixture_dir/pacman.conf")"
  result=0
  KEY_FIXTURE="$fixture_dir/pinned.asc" sh "$fixture_dir/install.sh" --no-setup > "$fixture_dir/output" 2>&1 || result=$?
  case "$case_name" in
    fresh)
      if [ "$result" != 0 ] ||
        [ "$(cat "$fixture_dir/pacman.conf")" != "$(cat "$base_conf"; printf '\n'; cat "$fixture_dir/expected-section.conf")" ] ||
        ! grep -Fx 'pacman-key --lsign-key 58017EDFFA9F803E07ED26F835F13F14FAAD15CC' "$INSTALLER_COMMANDS" >/dev/null ||
        ! grep -Fx 'pacman -Syu --noconfirm --needed polaris' "$INSTALLER_COMMANDS" >/dev/null ||
        ! grep -Fx 'Installed Polaris 9.8.7-1.' "$fixture_dir/output" >/dev/null; then
        fail "arch $case_name: the generated section is appended and Polaris installed"
      fi ;;
    rerun|old-script-host|reformatted)
      if [ "$result" != 0 ] || [ "$(sha256sum < "$fixture_dir/pacman.conf")" != "$conf_before" ] ||
        ! grep -F 'leaving it alone' "$fixture_dir/output" >/dev/null ||
        ! grep -Fx 'pacman -Syu --noconfirm' "$INSTALLER_COMMANDS" >/dev/null; then
        fail "arch $case_name: an existing section that matches is left alone and the system upgraded"
      fi ;;
    *)
      if [ "$result" = 0 ] || [ "$(sha256sum < "$fixture_dir/pacman.conf")" != "$conf_before" ] ||
        ! grep -F 'nothing on this host was changed' "$fixture_dir/output" >/dev/null ||
        grep -Ev '^pacman -Q ' "$INSTALLER_COMMANDS" || [ -n "$(ls -A "$WRITTEN_DIR")" ]; then
        fail "arch $case_name: a section that does not match is refused before anything is trusted"
      fi ;;
  esac
  if grep -E '^(sudo (-n )?)?curl .*polaris\.conf$' "$INSTALLER_COMMANDS"; then
    fail "arch $case_name: the served section is never fetched"
  fi
  case "$case_name" in
    fresh|rerun|old-script-host|reformatted) log_check "arch $case_name" "$TMPDIR" ;;
    *) no_log_check "arch $case_name" "$TMPDIR" ;;
  esac
  checked=$((checked+1))
  printf 'checked arch %s (exit %s)\n' "$case_name" "$result"
done

# Presentation. The package manager's and host setup's output goes to the log,
# not the screen; the same words are printed with or without a terminal; colour
# and symbols appear only on a terminal that allows them, and only ASCII outside
# a UTF-8 locale. A failure shows the end of the command's output and the log.
# Host setup runs in these cases, so the running kernel has modules.
mkdir -p "$fixture_dir/modules/$(uname -r)"
# Runs a command in a 100x40 pseudo-terminal: terminal.py OUTPUT COMMAND...
cat > "$fixture_dir/terminal.py" <<'PTY'
import fcntl, os, pty, struct, sys, termios
out, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 100, 0, 0))
data = b''
while True:
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        break
    if not chunk:
        break
    data += chunk
_, status = os.waitpid(pid, 0)
open(out, 'wb').write(data)
sys.exit(os.waitstatus_to_exitcode(status))
PTY
# dnf5's output on a real Fedora 45 install, cut down.
cat > "$fixture_dir/dnf-output" <<'OUT'
Updating and loading repositories:
 Polaris                                100% | 360.2 KiB/s |   2.2 KiB |  00m00s
Repositories loaded.
Package                       Arch   Version           Repository      Size
Installing:
 polaris                      x86_64 0:9.8.7-1         polaris     49.6 MiB
Installing dependencies:
 labwc                        x86_64 0:0.20.2-2.fc45   fedora     871.7 KiB

Transaction Summary:
 Installing:        27 packages

Total size of inbound packages is 20 MiB. Need to download 16 MiB.
After this operation, 58 MiB extra will be used (install 58 MiB, remove 0 B).
Warning: A pending offline transaction initiated by the following command will be invalidated: dnf5daemon-server
[ 1/27] labwc-0:0.20.2-2.fc45.x86_64    100% |   0.0   B/s |   0.0   B |  00m00s
[27/27] polaris-0:9.8.7-1.x86_64        100% |  90.6 MiB/s |  15.8 MiB |  00m00s
Running transaction
[27/29] Installing polaris-0:9.8.7-1.x8 100% |  25.7 MiB/s |  49.6 MiB |  00m02s
Complete!
OUT
# polaris --setup-host on that host, verbatim.
cat > "$fixture_dir/setup-output" <<'OUT'
[2026-11-11 10:24:57.969]: Info: Linux host setup: udev rules is provided by the package at ["/usr/lib/udev/rules.d/60-polaris.rules"]; nothing to install
[2026-11-11 10:24:58.165]: Info: Linux host setup: load uinput with [modprobe uinput]
Linux host setup complete.
The udev rules and modules-load configuration came from the package, so nothing was written to /etc.
Everything this step applied is also applied automatically at boot; it is only needed to avoid a reboot after install.
Existing virtual gamepad nodes keep their previous access policy until recreated; stop active streams and restart Polaris after changing client gamepad seat isolation.
Start Polaris directly with `polaris`, or opt into background autostart with `systemctl --user enable --now polaris`.
For a host that boots with no monitor or desktop login (Game Mode consoles, dedicated streaming boxes), re-run with --enable-headless-boot.
Mirror Desktop and Host Virtual Display still need a desktop session there; with no monitor, turn on automatic login in the display manager (SDDM on KDE Plasma).

Client gamepad and keyboard/mouse seat isolation additionally need [papi] to be in the [input] group; isolated devices get no logind ACL, so the group is the only way Polaris and the streamed game can open them. Run [sudo usermod -aG input papi] and log out and back in. Leaving seat isolation disabled needs nothing.
[2026-11-11 10:24:58.216]: Info: Linux host setup: skipping cap_sys_admin. Re-run with --enable-kms only if you need DRM/KMS capture.
OUT
# The same with a warning and advice this installer does not know, which must
# reach the screen as they are. Its logger runs on a thread of its own, and a
# record can land before another line's newline, as one did on a real run.
{
  sed -n '1,2p' "$fixture_dir/setup-output"
  printf '%s\n' '[2026-11-11 10:24:58.171]: Warning: Linux host setup optional command [modprobe uhid] returned [1]'
  sed -n '3,$p' "$fixture_dir/setup-output" |
    sed 's|re-run with --enable-headless-boot\.$|&[2026-11-11 16:49:31.694]: Info: Linux host setup: skipping cap_sys_admin. Re-run with --enable-kms only if you need DRM/KMS capture.|'

  printf '%s\n' 'Still overriding the packaged file: /etc/udev/rules.d/60-polaris.rules. See the warning above; unless you edited it yourself,'
} > "$fixture_dir/setup-output-warn"
fedora_host() {
  rm -f "$fixture_dir/ostree-booted" "$INSTALLED_MARKER" "$IMPORTED_KEY" "$WRITTEN_DIR"/*
  printf 'ID=fedora\nID_LIKE=fedora\nVERSION_ID=45\nPRETTY_NAME="Fedora 45 fixture"\n' > "$fixture_dir/os-release"
  : > "$INSTALLER_COMMANDS"
}
esc="$(printf '\033')"
cr="$(printf '\r')"
# The terminal output with the pty's line endings made plain: what is left of
# each line after its last carriage return, which is what stays on screen.
screen_text() { sed "s/$cr\$//" "$fixture_dir/raw" | sed "s/.*$cr//" | sed "s/$esc\\[[0-9;]*[mK]//g"; }
admin_prefix=""
setup_prefix=""
if [ "$(id -u)" -ne 0 ]; then
  admin_prefix="sudo -n "
  setup_prefix="sudo -n -H "
fi
presentation() { checked=$((checked+1)); printf 'checked presentation %s (exit %s)\n' "$1" "$result"; }

# Without a terminal: plain ASCII lines, no escape sequences, the tool output in
# the log only, and host setup's advice reduced to the commands it names.
fedora_host
result=0
LC_ALL=C.UTF-8 KEY_FIXTURE="$fixture_dir/pinned.asc" TOOL_OUTPUT="$fixture_dir/dnf-output" \
  SETUP_OUTPUT="$fixture_dir/setup-output" sh "$fixture_dir/install-key.sh" > "$fixture_dir/output" 2>&1 || result=$?
if [ "$result" != 0 ] || grep -q "[$esc$cr]" "$fixture_dir/output" ||
  LC_ALL=C grep -q '[^[:print:][:space:]]' "$fixture_dir/output" ||
  [ "$(grep -cE '^\[[1-4]/4\] (Signing key|Repository|Packages|Host setup)' "$fixture_dir/output")" != 4 ] ||
  [ "$(grep -c '^      done  ' "$fixture_dir/output")" != 4 ] ||
  ! grep -Fx '      done  Polaris 9.8.7-1 installed (27 packages, 58 MiB); 1 warning in the log' "$fixture_dir/output" >/dev/null ||
  ! grep -Fx '      done  host setup finished' "$fixture_dir/output" >/dev/null ||
  ! grep -Fx "      $ ${setup_prefix}polaris --setup-host" "$fixture_dir/output" >/dev/null ||
  grep -E 'Transaction Summary|Complete!|Linux host setup|Info:|isolation additionally need|Mirror Desktop' "$fixture_dir/output" ||
  ! grep -Fx 'Installed Polaris 9.8.7-1.' "$fixture_dir/output" >/dev/null ||
  ! grep -Fx '  Headless boot    sudo -H polaris --setup-host --enable-headless-boot' "$fixture_dir/output" >/dev/null ||
  ! grep -Fx '  Seat isolation   sudo usermod -aG input papi, then log out and back in' "$fixture_dir/output" >/dev/null ||
  ! tail -n 1 "$fixture_dir/output" | grep -q '^Full log: '; then
  fail "presentation: plain lines without a terminal, tool output in the log"
fi
log_check "presentation plain" "$TMPDIR"
# The log keeps everything the screen left out, after the command that printed it.
if ! grep -Fx "      $ ${admin_prefix}dnf install -y polaris" "$fixture_dir/last.log" >/dev/null ||
  ! grep -Fx 'Transaction Summary:' "$fixture_dir/last.log" >/dev/null ||
  [ "$(grep -n -m 1 -F 'Transaction Summary:' "$fixture_dir/last.log" | cut -d: -f1)" -le "$(grep -n -m 1 -F "$ ${admin_prefix}dnf install -y polaris" "$fixture_dir/last.log" | cut -d: -f1)" ] ||
  ! grep -F 'Client gamepad and keyboard/mouse seat isolation additionally need [papi]' "$fixture_dir/last.log" >/dev/null ||
  ! grep -F 'Mirror Desktop and Host Virtual Display' "$fixture_dir/last.log" >/dev/null ||
  ! grep -F 'Log out and back in, or reboot where lingering' "$fixture_dir/last.log" >/dev/null; then
  fail "presentation: the log keeps the tool output and the advice"
fi
presentation plain

# Host setup's warnings, and advice this does not recognise, stay on screen.
fedora_host
result=0
KEY_FIXTURE="$fixture_dir/pinned.asc" SETUP_OUTPUT="$fixture_dir/setup-output-warn" \
  sh "$fixture_dir/install-key.sh" > "$fixture_dir/output" 2>&1 || result=$?
if [ "$result" != 0 ] ||
  ! grep -Fx '      Warning: Linux host setup optional command [modprobe uhid] returned [1]' "$fixture_dir/output" >/dev/null ||
  ! grep -Fx '      Still overriding the packaged file: /etc/udev/rules.d/60-polaris.rules. See the warning above; unless you edited it yourself,' "$fixture_dir/output" >/dev/null ||
  ! grep -Fx '      done  with the warnings above' "$fixture_dir/output" >/dev/null ||
  ! grep -Fx '  Headless boot    sudo -H polaris --setup-host --enable-headless-boot' "$fixture_dir/output" >/dev/null ||
  grep -E 'headless-boot\.\[|Info:' "$fixture_dir/output"; then
  fail "presentation: host setup warnings and unknown advice are shown"
fi
log_check "presentation setup warnings" "$TMPDIR"
presentation setup-warnings

# Host setup failing is not fatal, as before, and shows what it printed.
fedora_host
result=0
KEY_FIXTURE="$fixture_dir/pinned.asc" SETUP_OUTPUT="$fixture_dir/setup-output" SETUP_STATUS=3 \
  sh "$fixture_dir/install-key.sh" > "$fixture_dir/output" 2>&1 || result=$?
if [ "$result" != 0 ] ||
  ! grep -Fx "      failed  Host setup: ${setup_prefix}polaris --setup-host exited with status 3" "$fixture_dir/output" >/dev/null ||
  ! grep -F '| Client gamepad and keyboard/mouse seat isolation additionally need [papi]' "$fixture_dir/output" >/dev/null ||
  ! grep -Fx '      Host setup did not finish. Polaris is installed; run this yourself:' "$fixture_dir/output" >/dev/null ||
  ! grep -Fx 'Installed Polaris 9.8.7-1.' "$fixture_dir/output" >/dev/null; then
  fail "presentation: a host setup failure is shown and the run goes on"
fi
log_check "presentation setup failure" "$TMPDIR"
presentation setup-failure

# A failing package manager: the step, the last 30 lines of its output, the log,
# and the run still ends with the package manager's own status.
seq 1 40 | sed 's/^/dnf fixture line /' > "$fixture_dir/dnf-failure"
printf 'Error: fixture failure\n' >> "$fixture_dir/dnf-failure"
fedora_host
result=0
KEY_FIXTURE="$fixture_dir/pinned.asc" TOOL_OUTPUT="$fixture_dir/dnf-failure" TOOL_STATUS=7 \
  sh "$fixture_dir/install-key.sh" > "$fixture_dir/output" 2>&1 || result=$?
if [ "$result" != 7 ] || [ -e "$INSTALLED_MARKER" ] ||
  ! grep -Fx "      failed  Packages: ${admin_prefix}dnf install -y polaris exited with status 7" "$fixture_dir/output" >/dev/null ||
  [ "$(grep -c '^      | ' "$fixture_dir/output")" != 30 ] ||
  ! grep -Fx '      | dnf fixture line 12' "$fixture_dir/output" >/dev/null ||
  grep -F 'dnf fixture line 11' "$fixture_dir/output" ||
  ! grep -Fx '      | Error: fixture failure' "$fixture_dir/output" >/dev/null ||
  grep -E 'Installed Polaris|\[4/4\]' "$fixture_dir/output"; then
  fail "presentation: a failing package manager shows its last 30 lines and the log"
fi
log_check "presentation dnf failure" "$TMPDIR"
if [ "$(grep -c '^dnf fixture line ' "$fixture_dir/last.log")" != 40 ]; then
  fail "presentation: the log keeps all of the failing output"
fi
presentation dnf-failure

# pacman's --noconfirm stop still reaches the user: the question it answered by
# default, even once it has scrolled out of the last 30 lines, its errors, and
# the command to answer it yourself. The repository stays, as before.
{
  printf '%s\n' ':: Synchronizing package databases...' ':: Starting full system upgrade...' \
    ':: libfoo and libfoo-git are in conflict. Remove libfoo-git? [y/N] '
  seq 1 35 | sed 's/^/pacman fixture line /'
  printf '%s\n' 'error: unresolvable package conflicts detected' \
    'error: failed to prepare transaction (conflicting dependencies)'
} > "$fixture_dir/pacman-stop"
for terminal in pipe pty; do
  rm -f "$fixture_dir/ostree-booted" "$INSTALLED_MARKER"
  printf 'ID=arch\nPRETTY_NAME="Arch fixture"\n' > "$fixture_dir/os-release"
  cp "$base_conf" "$fixture_dir/pacman.conf"
  : > "$INSTALLER_COMMANDS"
  result=0
  if [ "$terminal" = pipe ]; then
    KEY_FIXTURE="$fixture_dir/pinned.asc" TOOL_OUTPUT="$fixture_dir/pacman-stop" TOOL_STATUS=1 \
      sh "$fixture_dir/install.sh" > "$fixture_dir/output" 2>&1 || result=$?
  else
    TERM=xterm-256color LC_ALL=C.UTF-8 KEY_FIXTURE="$fixture_dir/pinned.asc" TOOL_OUTPUT="$fixture_dir/pacman-stop" TOOL_STATUS=1 \
      python3 -I "$fixture_dir/terminal.py" "$fixture_dir/raw" sh "$fixture_dir/install.sh" --yes || result=$?
    screen_text > "$fixture_dir/output"
  fi
  if [ "$result" != 1 ] ||
    ! grep -F "failed  Packages: ${admin_prefix}pacman -Syu --noconfirm --needed polaris exited with status 1" "$fixture_dir/output" >/dev/null ||
    ! grep -F 'It answered these questions with their default:' "$fixture_dir/output" >/dev/null ||
    ! grep -F ':: libfoo and libfoo-git are in conflict. Remove libfoo-git? [y/N]' "$fixture_dir/output" >/dev/null ||
    ! grep -F 'error: unresolvable package conflicts detected' "$fixture_dir/output" >/dev/null ||
    ! grep -F 'polaris install: pacman stopped, for the reason printed above. It ran' "$fixture_dir/output" >/dev/null ||
    ! grep -Fx "  ${admin_prefix}pacman -Syu polaris" "$fixture_dir/output" >/dev/null ||
    ! grep -Fx '[polaris]' "$fixture_dir/pacman.conf" >/dev/null; then
    fail "presentation: pacman's --noconfirm stop reaches the user ($terminal)"
  fi
  log_check "presentation pacman stop ($terminal)" "$TMPDIR"
  presentation "pacman-stop-$terminal"
done

# A colour terminal: colour, symbols and the words, one live status line for
# the package manager that leaves none of its output on screen, and the same
# steps and results as without a terminal.
fedora_host
result=0
TERM=xterm-256color LC_ALL=C.UTF-8 KEY_FIXTURE="$fixture_dir/pinned.asc" TOOL_OUTPUT="$fixture_dir/dnf-output" \
  SETUP_OUTPUT="$fixture_dir/setup-output" python3 -I "$fixture_dir/terminal.py" "$fixture_dir/raw" sh "$fixture_dir/install-key.sh" --yes || result=$?
screen_text > "$fixture_dir/output"
if [ "$result" != 0 ] || ! grep -qF "${esc}[32m" "$fixture_dir/raw" || ! grep -qF "${esc}[2m" "$fixture_dir/raw" ||
  ! grep -qF "${cr}${esc}[K" "$fixture_dir/raw" || ! grep -qF '[27/29] Installing polaris-0:9.8.7-1.x8' "$fixture_dir/raw" ||
  [ "$(grep -c '^    ✓ done  ' "$fixture_dir/output")" != 4 ] ||
  ! grep -Fx 'Polaris installer · Fedora 45 fixture' "$fixture_dir/output" >/dev/null ||
  grep -E 'Transaction Summary|Complete!|Installing polaris|Linux host setup' "$fixture_dir/output" ||
  ! grep -Fx 'Installed Polaris 9.8.7-1.' "$fixture_dir/output" >/dev/null; then
  fail "presentation: colour, symbols and one status line on a terminal"
fi
log_check "presentation colour terminal" "$TMPDIR"
presentation colour

# NO_COLOR and TERM=dumb on a terminal: the same words, no colour, no symbols.
# A dumb terminal gets no escape sequences or redrawn lines at all.
for variant in no-color dumb; do
  fedora_host
  result=0
  if [ "$variant" = no-color ]; then
    NO_COLOR=1 TERM=xterm-256color LC_ALL=C.UTF-8 KEY_FIXTURE="$fixture_dir/pinned.asc" TOOL_OUTPUT="$fixture_dir/dnf-output" \
      python3 -I "$fixture_dir/terminal.py" "$fixture_dir/raw" sh "$fixture_dir/install-key.sh" --yes --no-setup || result=$?
  else
    TERM=dumb LC_ALL=C.UTF-8 KEY_FIXTURE="$fixture_dir/pinned.asc" TOOL_OUTPUT="$fixture_dir/dnf-output" \
      python3 -I "$fixture_dir/terminal.py" "$fixture_dir/raw" sh "$fixture_dir/install-key.sh" --yes --no-setup || result=$?
  fi
  screen_text > "$fixture_dir/output"
  if [ "$result" != 0 ] || grep -qE "$esc\\[[0-9;]*m" "$fixture_dir/raw" ||
    LC_ALL=C grep -q '[^[:print:][:space:][:cntrl:]]' "$fixture_dir/raw" ||
    [ "$(grep -c '^      done  ' "$fixture_dir/output")" != 3 ] ||
    ! grep -Fx '      skipped  left for you, as --no-setup asked' "$fixture_dir/output" >/dev/null ||
    { [ "$variant" = dumb ] && grep -q "$esc" "$fixture_dir/raw"; } ||
    { [ "$variant" = dumb ] && sed "s/$cr\$//" "$fixture_dir/raw" | grep -q "$cr"; }; then
    fail "presentation: $variant gets words without colour or symbols"
  fi
  log_check "presentation $variant" "$TMPDIR"
  presentation "$variant"
done

# Outside a UTF-8 locale a colour terminal keeps its colour, with ASCII symbols.
fedora_host
result=0
TERM=xterm-256color LC_ALL=C LANG=C KEY_FIXTURE="$fixture_dir/pinned.asc" TOOL_OUTPUT="$fixture_dir/dnf-output" \
  python3 -I "$fixture_dir/terminal.py" "$fixture_dir/raw" sh "$fixture_dir/install-key.sh" --yes --no-setup || result=$?
screen_text > "$fixture_dir/output"
if [ "$result" != 0 ] || ! grep -qF "${esc}[32m" "$fixture_dir/raw" ||
  LC_ALL=C grep -q '[^[:print:][:space:][:cntrl:]]' "$fixture_dir/raw" ||
  [ "$(grep -c '^      done  ' "$fixture_dir/output")" != 3 ] ||
  ! grep -Fx 'Polaris installer - Fedora 45 fixture' "$fixture_dir/output" >/dev/null; then
  fail "presentation: ASCII symbols outside a UTF-8 locale"
fi
log_check "presentation ascii" "$TMPDIR"
presentation ascii

# A dry run lists every command, on a terminal too, and runs and logs nothing.
for family in fedora arch; do
  for terminal in pipe pty; do
    rm -f "$fixture_dir/ostree-booted" "$INSTALLED_MARKER"
    if [ "$family" = fedora ]; then
      printf 'ID=fedora\nID_LIKE=fedora\nVERSION_ID=44\nPRETTY_NAME="Fedora 44 fixture"\n' > "$fixture_dir/os-release"
      expected=('curl --location --fail --silent --show-error --output [^ ]*/polaris\.gpg https://repo\.papi-ux\.com/polaris\.gpg'
        'rpmkeys --root [^ ]+ --noplugins --import [^ ]*/polaris\.gpg' 'rpmkeys --root [^ ]+ --noplugins --list'
        'rpm --import [^ ]*/polaris\.gpg' "install -D -m 0644 [^ ]*/polaris\\.gpg $key_path"
        'install -m 0644 [^ ]*/polaris\.repo /etc/yum\.repos\.d/polaris\.repo' 'dnf install -y polaris' 'polaris --setup-host')
    else
      printf 'ID=arch\nPRETTY_NAME="Arch fixture"\n' > "$fixture_dir/os-release"
      cp "$base_conf" "$fixture_dir/pacman.conf"
      expected=('curl -fsSL https://repo\.papi-ux\.com/polaris\.gpg \| pacman-key --add -'
        'pacman-key --lsign-key 58017EDFFA9F803E07ED26F835F13F14FAAD15CC'
        'tee -a [^ ]*pacman\.conf, given a blank line and the lines above'
        'pacman -Syu --noconfirm --needed polaris' 'polaris --setup-host')
    fi
    conf_before="$(sha256sum < "$fixture_dir/pacman.conf")"
    : > "$INSTALLER_COMMANDS"
    result=0
    if [ "$terminal" = pipe ]; then
      sh "$fixture_dir/install.sh" --dry-run > "$fixture_dir/output" 2>&1 || result=$?
    else
      TERM=xterm-256color LC_ALL=C.UTF-8 python3 -I "$fixture_dir/terminal.py" "$fixture_dir/raw" sh "$fixture_dir/install.sh" --dry-run || result=$?
      screen_text > "$fixture_dir/output"
    fi
    missing_command=''
    for command_line in "${expected[@]}"; do
      case "$command_line" in
        'polaris --setup-host') command_line="$setup_prefix$command_line" ;;
        'curl -fsSL '*) command_line="${command_line/pacman-key/${admin_prefix}pacman-key}" ;;
        'curl '*|'rpmkeys '*) ;;
        *) command_line="$admin_prefix$command_line" ;;
      esac
      grep -qE "^ +\\$ $command_line\$" "$fixture_dir/output" || missing_command="$command_line"
    done
    if [ "$result" != 0 ] || [ -n "$missing_command" ] ||
      ! grep -Fx 'Dry run: nothing will be changed.' "$fixture_dir/output" >/dev/null ||
      grep -E ' done  |failed  ' "$fixture_dir/output" ||
      grep -Ev '^(rpm -q|pacman -Q) ' "$INSTALLER_COMMANDS" ||
      [ "$(sha256sum < "$fixture_dir/pacman.conf")" != "$conf_before" ]; then
      fail "presentation: a $family dry run lists every command and runs none ($terminal${missing_command:+, missing $missing_command})"
    fi
    no_log_check "presentation $family dry run ($terminal)" "$TMPDIR"
    presentation "dry-run-$family-$terminal"
  done
done
[ "$failures" = 0 ] || { printf '%s installer fixture failures\n' "$failures" >&2; exit 1; }
printf '%s guided-installer fixtures PASS\n' "$checked"
