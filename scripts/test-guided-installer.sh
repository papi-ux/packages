#!/usr/bin/env bash
# Execute the complete installer against os-release and read-only command fixtures.
# Only OS identity/ostree marker paths are substituted; the installer body is real.
# The signing-key cases also substitute FINGERPRINT with a throwaway key made here,
# and the real rpmkeys reads each served key, so this needs rpm and gpg: run it in
# a Fedora 44 or 45 container, as verify.yml does.
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
mkdir "$fixture_dir/bin"
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
# curl serves KEY_FIXTURE as polaris.gpg and records everything else without
# writing it, so /etc/yum.repos.d is never touched.
cat > "$fixture_dir/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "curl $*" >> "$INSTALLER_COMMANDS"
output=''
while [ "$#" -gt 1 ]; do
  [ "$1" = --output ] && output="$2"
  shift
done
case "$1" in
  */polaris.gpg)
    [ -n "${KEY_FIXTURE:-}" ] && [ -n "$output" ] || exit 99
    cp "$KEY_FIXTURE" "$output" ;;
  */fedora/polaris.repo) [ -n "${KEY_FIXTURE:-}" ] || exit 99 ;;
  *) exit 99 ;;
esac
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
# Only reached when this runs as a regular user.
cat > "$fixture_dir/bin/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "sudo $*" >> "$INSTALLER_COMMANDS"
exec "$@"
STUB
chmod +x "$fixture_dir/bin/"*
export INSTALLER_COMMANDS="$fixture_dir/commands"
export PATH="$fixture_dir/bin:$PATH"
sed "s|/etc/os-release|$fixture_dir/os-release|g" site/install.sh | sed "s|/run/ostree-booted|$fixture_dir/ostree-booted|g" > "$fixture_dir/install.sh"
failures=0
checked=0
fail() { cat "$fixture_dir/output"; printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
# The line number of the first output line matching an extended regex, or 0.
line_of() { grep -n -m 1 -E "$1" "$fixture_dir/output" | cut -d: -f1 || printf '0\n'; }

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
        if [ "$result" != 0 ] || ! grep -F "https://repo.papi-ux.com/fedora/polaris.repo" "$fixture_dir/output" >/dev/null; then
          fail "Fedora $release $setup route"
        fi
        if [ "$setup" = no-setup ] && grep -E '^  \$ (sudo -H )?polaris --setup-host$' "$fixture_dir/output"; then failures=$((failures+1)); fi
        if [ "$setup" = default ] && [ "$distro" = fedora ] && ! grep -E '^  \$ (sudo -H )?polaris --setup-host$' "$fixture_dir/output" >/dev/null; then failures=$((failures+1)); fi
        if [ "$distro" = bazzite ] && ! grep -E '^  \$ (sudo )?rpm-ostree install polaris$' "$fixture_dir/output" >/dev/null; then failures=$((failures+1)); fi
        # The dry run shows the check, in order: download, read, list, then the
        # import of that same file, then the repository.
        download="$(line_of '^  \$ curl .* --output [^ ]*/polaris\.gpg https://repo\.papi-ux\.com/polaris\.gpg$')"
        read_key="$(line_of '^  \$ rpmkeys --root [^ ]+ --noplugins --import [^ ]*/polaris\.gpg$')"
        list_keys="$(line_of '^  \$ rpmkeys --root [^ ]+ --noplugins --list$')"
        import="$(line_of '^  \$ (sudo )?rpm --import [^ ]*/polaris\.gpg$')"
        repository="$(line_of 'https://repo\.papi-ux\.com/fedora/polaris\.repo$')"
        if [ "$download" = 0 ] || [ "$read_key" -le "$download" ] || [ "$list_keys" -le "$read_key" ] ||
          [ "$import" -le "$list_keys" ] || [ "$repository" -le "$import" ] ||
          ! grep -F 'Pinned fingerprint: 58017EDFFA9F803E07ED26F835F13F14FAAD15CC' "$fixture_dir/output" >/dev/null ||
          grep -E 'rpm --import https?:' "$fixture_dir/output"; then
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

for distro in fedora bazzite; do
  rm -f "$fixture_dir/ostree-booted"
  release=44
  if [ "$distro" = bazzite ]; then touch "$fixture_dir/ostree-booted"; release=45; fi
  printf 'ID=%s\nID_LIKE=fedora\nVERSION_ID=%s\nPRETTY_NAME="%s %s fixture"\n' "$distro" "$release" "$distro" "$release" > "$fixture_dir/os-release"
  # pinned-relative serves the pinned key with a relative TMPDIR, which rpm
  # would refuse as a --root unless the installer makes it absolute.
  for key in pinned pinned-relative other two-keys empty garbage; do
    : > "$INSTALLER_COMMANDS"
    rm -f "$INSTALLED_MARKER" "$IMPORTED_KEY"
    result=0
    key_tmpdir="$TMPDIR_FOR_KEYS"
    [ "$key" != pinned-relative ] || key_tmpdir=tmp
    (cd "$fixture_dir" && KEY_FIXTURE="$fixture_dir/${key%-relative}.asc" TMPDIR="$key_tmpdir" \
      sh "$fixture_dir/install-key.sh" --no-setup) > "$fixture_dir/output" 2>&1 || result=$?
    key_download="$(grep -E '^(sudo )?curl .*/polaris\.gpg$' "$INSTALLER_COMMANDS" || true)"
    if [ "$(printf '%s\n' "$key_download" | grep -c .)" != 1 ]; then
      fail "$distro $key: polaris.gpg downloaded exactly once"
    fi
    if [ -n "$(ls -A "$TMPDIR_FOR_KEYS")" ]; then
      fail "$distro $key: the temporary key directory was removed"
    fi
    case "$key" in
      pinned|pinned-relative)
        downloaded_to="$(printf '%s\n' "$key_download" | sed -n 's/.* --output \([^ ]*\) .*/\1/p')"
        if [ "$result" != 0 ] || ! grep -Fx '  rpm reads one key, and its fingerprint is the pinned one.' "$fixture_dir/output" >/dev/null ||
          ! grep -Fx "rpm --import $downloaded_to" "$INSTALLER_COMMANDS" >/dev/null ||
          [ "$(sha256sum < "$IMPORTED_KEY")" != "$(sha256sum < "$fixture_dir/pinned.asc")" ] ||
          ! grep -E '^curl .*--output /etc/yum\.repos\.d/polaris\.repo https://repo\.papi-ux\.com/fedora/polaris\.repo$' "$INSTALLER_COMMANDS" >/dev/null; then
          fail "$distro $key: the pinned key passes and that same file is imported"
        fi
        if [ "$distro" = fedora ] && ! grep -Fx 'Installed Polaris 9.8.7-1.' "$fixture_dir/output" >/dev/null; then
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
          [ -e "$IMPORTED_KEY" ] || [ -e "$INSTALLED_MARKER" ]; then
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
[ "$failures" = 0 ] || { printf '%s installer fixture failures\n' "$failures" >&2; exit 1; }
printf '%s guided-installer fixtures PASS\n' "$checked"
