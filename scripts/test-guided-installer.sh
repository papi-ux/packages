#!/usr/bin/env bash
# Execute the complete installer against os-release and read-only command fixtures.
# Only OS identity, the ostree marker and pacman.conf paths are substituted; the
# installer body is real. Commands that would change the host are stubs that
# record what they were asked to do. The signing-key cases also substitute
# FINGERPRINT with a throwaway key made here, and the real rpmkeys reads each
# served key, so this needs rpm and gpg: run it in a Fedora 44 or 45 container,
# as verify.yml does.
# $releasever, $basearch and $arch are literal in repository files.
# shellcheck disable=SC2016
set -euo pipefail
for tool in gpg rpmkeys; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'test-guided-installer: %s was not found. Run this in a Fedora 44 or 45 container, as verify.yml does.\n' "$tool" >&2
    exit 1
  }
done
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/polaris-installer-fixture.XXXXXX")"
# The key cases start a gpg-agent under the fixture directory; stop it with it.
trap 'GNUPGHOME="$fixture_dir/gnupg" gpgconf --kill all >/dev/null 2>&1 || true; rm -rf -- "$fixture_dir"' EXIT
mkdir "$fixture_dir/bin" "$fixture_dir/written"
# rpm -q answers from a marker the dnf stub leaves, so a real run can end in an
# install. rpm --import keeps a copy of what it was given and records the path.
cat > "$fixture_dir/bin/rpm" <<'STUB'
#!/bin/sh
printf '%s\n' "rpm $*" >> "$INSTALLER_COMMANDS"
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
cat > "$fixture_dir/bin/dnf" <<'STUB'
#!/bin/sh
printf '%s\n' "dnf $*" >> "$INSTALLER_COMMANDS"
[ -n "${INSTALLED_MARKER:-}" ] || exit 99
touch "$INSTALLED_MARKER"
STUB
cat > "$fixture_dir/bin/rpm-ostree" <<'STUB'
#!/bin/sh
printf '%s\n' "rpm-ostree $*" >> "$INSTALLER_COMMANDS"
[ -n "${INSTALLED_MARKER:-}" ] || exit 99
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
touch "$INSTALLED_MARKER"
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
    -e "s|/etc/pacman.conf|$fixture_dir/pacman.conf|g" site/install.sh > "$fixture_dir/install.sh"
failures=0
checked=0
fail() { cat "$fixture_dir/output"; printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
# The line number of the first output line matching an extended regex, or 0.
line_of() { grep -n -m 1 -E "$1" "$fixture_dir/output" | cut -d: -f1 || printf '0\n'; }
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
          [ "$(sed -n '/polaris\.repo will read:$/,/^  \$ /p' "$fixture_dir/output" | sed '1d;$d' | sed 's/^    //')" != "$(cat "$fixture_dir/expected.repo")" ]; then
          fail "Fedora $release $setup route"
        fi
        if [ "$setup" = no-setup ] && grep -E '^  \$ (sudo -H )?polaris --setup-host$' "$fixture_dir/output"; then failures=$((failures+1)); fi
        if [ "$setup" = default ] && [ "$distro" = fedora ] && ! grep -E '^  \$ (sudo -H )?polaris --setup-host$' "$fixture_dir/output" >/dev/null; then failures=$((failures+1)); fi
        if [ "$distro" = bazzite ] && ! grep -E '^  \$ (sudo )?rpm-ostree install polaris$' "$fixture_dir/output" >/dev/null; then failures=$((failures+1)); fi
        # The dry run shows the check, in order: download, read, list, then the
        # import of that same file, keeping it, and the repository file.
        download="$(line_of '^  \$ curl .* --output [^ ]*/polaris\.gpg https://repo\.papi-ux\.com/polaris\.gpg$')"
        read_key="$(line_of '^  \$ rpmkeys --root [^ ]+ --noplugins --import [^ ]*/polaris\.gpg$')"
        list_keys="$(line_of '^  \$ rpmkeys --root [^ ]+ --noplugins --list$')"
        import="$(line_of '^  \$ (sudo )?rpm --import [^ ]*/polaris\.gpg$')"
        keep="$(line_of "^  \\$ (sudo )?install -D -m 0644 [^ ]*/polaris\\.gpg $key_path\$")"
        repository="$(line_of '^  \$ (sudo )?install -m 0644 [^ ]*/polaris\.repo /etc/yum\.repos\.d/polaris\.repo$')"
        if [ "$download" = 0 ] || [ "$read_key" -le "$download" ] || [ "$list_keys" -le "$read_key" ] ||
          [ "$import" -le "$list_keys" ] || [ "$keep" -le "$import" ] || [ "$repository" -le "$keep" ] ||
          ! grep -F 'Pinned fingerprint: 58017EDFFA9F803E07ED26F835F13F14FAAD15CC' "$fixture_dir/output" >/dev/null ||
          grep -E 'rpm --import https?:|fedora/polaris\.repo' "$fixture_dir/output"; then
          fail "Fedora $release $setup dry run shows the key check before the import"
        fi
        ;;
      *)
        if [ "$result" = 0 ] || ! grep -F 'Fedora 44 and 45' "$fixture_dir/output" >/dev/null || grep -E 'Importing|Checking the signing key|Adding the repository|  \$ ' "$fixture_dir/output"; then
          fail "Fedora $release refused before trust changes"
        fi ;;
    esac
    if grep -Ev '^rpm -q ' "$INSTALLER_COMMANDS"; then failures=$((failures+1)); fi
    if [ -n "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'polaris-key.XXXXXX' 2>/dev/null)" ]; then
      fail "a dry run created the placeholder key directory"
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
    key_download="$(grep -E '^(sudo )?curl .*/polaris\.gpg$' "$INSTALLER_COMMANDS" || true)"
    if [ "$(printf '%s\n' "$key_download" | grep -c .)" != 1 ]; then
      fail "$distro $key: polaris.gpg downloaded exactly once"
    fi
    if grep -E 'polaris\.repo$|polaris\.conf$' "$INSTALLER_COMMANDS" | grep -E '^(sudo )?curl '; then
      fail "$distro $key: the served repository file is never fetched"
    fi
    if [ -n "$(ls -A "$TMPDIR_FOR_KEYS")" ]; then
      fail "$distro $key: the temporary key directory was removed"
    fi
    case "$key" in
      pinned|rerun|pinned-relative)
        downloaded_to="$(printf '%s\n' "$key_download" | sed -n 's/.* --output \([^ ]*\) .*/\1/p')"
        if [ "$result" != 0 ] || ! grep -Fx '  rpm reads one key, and its fingerprint is the pinned one.' "$fixture_dir/output" >/dev/null ||
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
        if [ "$distro" = bazzite ] && ! grep -Fx 'rpm-ostree install polaris' "$INSTALLER_COMMANDS" >/dev/null; then
          fail "$distro $key: the run ends in rpm-ostree install"
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
          grep -E 'Importing the signing key|Adding the repository|rpm --import' "$fixture_dir/output"; then
          fail "$distro $key: refused before the import"
        fi
        # Nothing was written: the only commands run are the installed-version
        # queries and the one download into the temporary directory.
        if grep -Ev '^rpm -q |^curl .* --output [^ ]*/polaris-key\.[^ /]*/polaris\.gpg https://repo\.papi-ux\.com/polaris\.gpg$' "$INSTALLER_COMMANDS" ||
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
  if grep -E '^(sudo )?curl .*polaris\.conf$' "$INSTALLER_COMMANDS"; then
    fail "arch $case_name: the served section is never fetched"
  fi
  checked=$((checked+1))
  printf 'checked arch %s (exit %s)\n' "$case_name" "$result"
done
[ "$failures" = 0 ] || { printf '%s installer fixture failures\n' "$failures" >&2; exit 1; }
printf '%s guided-installer fixtures PASS\n' "$checked"
