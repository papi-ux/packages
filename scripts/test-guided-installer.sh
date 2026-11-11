#!/usr/bin/env bash
# Execute the complete installer against os-release and read-only command fixtures.
# Only OS identity/ostree marker paths are substituted; the installer body is real.
set -euo pipefail
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/polaris-installer-fixture.XXXXXX")"
trap 'rm -rf -- "$fixture_dir"' EXIT
mkdir "$fixture_dir/bin"
cat > "$fixture_dir/bin/rpm" <<'STUB'
#!/bin/sh
printf '%s\n' "rpm $*" >> "$INSTALLER_COMMANDS"
[ "$1" = -q ] && exit 1
exit 99
STUB
cat > "$fixture_dir/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "unexpected curl $*" >> "$INSTALLER_COMMANDS"
exit 99
STUB
chmod +x "$fixture_dir/bin/"*
export INSTALLER_COMMANDS="$fixture_dir/commands"
export PATH="$fixture_dir/bin:$PATH"
sed "s|/etc/os-release|$fixture_dir/os-release|g" site/install.sh | sed "s|/run/ostree-booted|$fixture_dir/ostree-booted|g" > "$fixture_dir/install.sh"
failures=0
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
          cat "$fixture_dir/output"; printf 'FAIL: Fedora %s %s route\n' "$release" "$setup"; failures=$((failures+1))
        fi
        if [ "$setup" = no-setup ] && grep -E '^  \$ (sudo -H )?polaris --setup-host$' "$fixture_dir/output"; then failures=$((failures+1)); fi
        if [ "$setup" = default ] && [ "$distro" = fedora ] && ! grep -E '^  \$ (sudo -H )?polaris --setup-host$' "$fixture_dir/output" >/dev/null; then failures=$((failures+1)); fi
        if [ "$distro" = bazzite ] && ! grep -E '^  \$ (sudo )?rpm-ostree install polaris$' "$fixture_dir/output" >/dev/null; then failures=$((failures+1)); fi
        ;;
      *)
        if [ "$result" = 0 ] || ! grep -F 'Fedora 44 and 45' "$fixture_dir/output" >/dev/null || grep -E 'Importing|Adding the repository|  \$ ' "$fixture_dir/output"; then
          cat "$fixture_dir/output"; printf 'FAIL: Fedora %s refused before trust changes\n' "$release"; failures=$((failures+1))
        fi ;;
    esac
    if grep -Ev '^rpm -q ' "$INSTALLER_COMMANDS"; then failures=$((failures+1)); fi
    printf 'checked %s %s %s (exit %s)\n' "$distro" "$release" "$setup" "$result"
  done
done
done
[ "$failures" = 0 ] || { printf '%s installer fixture failures\n' "$failures" >&2; exit 1; }
printf '20 guided-installer fixtures PASS\n'
