#!/usr/bin/env bash
# Build a tiny signed package/repository fixture and exercise the public
# read-back verifier without network access or production signing material.

set -euo pipefail

case "${1:-}" in
  fedora|arch) fixture_kind="$1" ;;
  *) printf 'usage: %s fedora|arch\n' "$0" >&2; exit 2 ;;
esac

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/polaris-repo-fixture.XXXXXX")"
trap 'rm -rf -- "$fixture_dir"' EXIT
fixture_sha='0123456789abcdef0123456789abcdef01234567'
export GNUPGHOME="$fixture_dir/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key \
  'Fixture repository <fixture@example.invalid>' rsa2048 sign 0
fingerprint="$(gpg --batch --with-colons --list-keys |
  awk -F: '$1 == "fpr" { print $10; exit }')"
[ -n "$fingerprint" ]

mkdir "$fixture_dir/assets" "$fixture_dir/repo"

if [ "$fixture_kind" = fedora ]; then
  rpmbuild_dir="$fixture_dir/rpmbuild"
  mkdir -p "$rpmbuild_dir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  printf 'fixture\n' > "$rpmbuild_dir/SOURCES/polaris.txt"
  cat > "$rpmbuild_dir/SPECS/polaris.spec" <<'SPEC'
Name: polaris
Version: 9.8.7
Release: 1
Summary: Polaris repository verification fixture
License: MIT
BuildArch: x86_64
Source0: polaris.txt

%description
Fixture package used only by repository contract tests.

%install
mkdir -p %{buildroot}/usr/share/polaris
install -m 0644 %{SOURCE0} %{buildroot}/usr/share/polaris/fixture.txt

%files
/usr/share/polaris/fixture.txt
SPEC
  rpmbuild --define "_topdir $rpmbuild_dir" -bb "$rpmbuild_dir/SPECS/polaris.spec"
  cp "$rpmbuild_dir/RPMS/x86_64/polaris-9.8.7-1.x86_64.rpm" \
    "$fixture_dir/assets/Polaris-fedora44-x86_64.rpm"

  # The repository carries the DRM/KMS helper beside the base package, and the helper
  # pins its base version exactly, so a fixture with only one of them would exercise a
  # repository no package manager could resolve.
  sed -e 's/^Name: polaris$/Name: polaris-kms/' \
      -e 's/^Summary: .*/Summary: Polaris DRM\/KMS helper verification fixture/' \
      -e '/^BuildArch:/a Requires: polaris = %{version}-%{release}' \
      "$rpmbuild_dir/SPECS/polaris.spec" > "$rpmbuild_dir/SPECS/polaris-kms.spec"
  rpmbuild --define "_topdir $rpmbuild_dir" -bb "$rpmbuild_dir/SPECS/polaris-kms.spec"
  cp "$rpmbuild_dir/RPMS/x86_64/polaris-kms-9.8.7-1.x86_64.rpm" \
    "$fixture_dir/assets/Polaris-kms-fedora44-x86_64.rpm"
fi

if [ "$fixture_kind" = arch ]; then
  mkdir -p "$fixture_dir/package/usr/share/polaris"
  cat > "$fixture_dir/package/.PKGINFO" <<'PKGINFO'
pkgname = polaris
pkgbase = polaris
pkgver = 9.8.7-1
pkgdesc = Polaris repository verification fixture
url = https://example.invalid
builddate = 1
packager = Fixture
size = 8
arch = x86_64
license = MIT
PKGINFO
  printf 'fixture\n' > "$fixture_dir/package/usr/share/polaris/fixture.txt"
  bsdtar --uid 0 --gid 0 -C "$fixture_dir/package" -cf - .PKGINFO usr |
    zstd --quiet -o "$fixture_dir/assets/Polaris-arch-x86_64.pkg.tar.zst"

  # The helper package, as above: it depends on its exact base version, so a database
  # holding one of the pair is a dependency nothing can satisfy.
  mkdir -p "$fixture_dir/package-kms/usr/share/polaris"
  sed -e 's/^pkgname = polaris$/pkgname = polaris-kms/' \
      -e 's/^pkgbase = polaris$/pkgbase = polaris-kms/' \
      "$fixture_dir/package/.PKGINFO" > "$fixture_dir/package-kms/.PKGINFO"
  printf 'depend = polaris=9.8.7-1\n' >> "$fixture_dir/package-kms/.PKGINFO"
  printf 'fixture\n' > "$fixture_dir/package-kms/usr/share/polaris/fixture-kms.txt"
  bsdtar --uid 0 --gid 0 -C "$fixture_dir/package-kms" -cf - .PKGINFO usr |
    zstd --quiet -o "$fixture_dir/assets/Polaris-kms-arch-x86_64.pkg.tar.zst"
fi

bash scripts/build-package-repos.sh --only "$fixture_kind" \
  --assets "$fixture_dir/assets" --version 9.8.7 --output "$fixture_dir/repo" \
  --base-url "file://$fixture_dir/repo" --gpg-key-id "$fingerprint" \
  --release-tag v9.8.7 --release-sha "$fixture_sha"
printf 'v9.8.7' > "$fixture_dir/repo/PUBLISHED_TAG"

verify_fixture() {
  bash scripts/verify-public-repository.sh --only "$fixture_kind" --tag v9.8.7 \
    --release-sha "$fixture_sha" --expected-fingerprint "$fingerprint" \
    --base-url "file://$fixture_dir/repo" --release-assets "$fixture_dir/assets" \
    --skip-release-api --poll-attempts 1
}

expect_failure() {
  local description="$1"
  shift
  if "$@" > "$fixture_dir/negative.log" 2>&1; then
    printf 'negative fixture unexpectedly passed: %s\n' "$description" >&2
    exit 1
  fi
  printf '  rejected: %s\n' "$description"
}

verify_fixture

expect_failure 'malformed stable tag' \
  bash scripts/verify-public-repository.sh --only "$fixture_kind" --tag v9x8.7 \
    --release-sha "$fixture_sha" --expected-fingerprint "$fingerprint" \
    --base-url "file://$fixture_dir/repo" --release-assets "$fixture_dir/assets" \
    --skip-release-api --poll-attempts 1

gpg --batch --passphrase '' --quick-generate-key \
  'Rogue fixture key <rogue@example.invalid>' rsa2048 sign 0
rogue_fingerprint="$(gpg --batch --with-colons --list-keys |
  awk -F: '$1 == "pub" { seen += 1; want = (seen == 2); next } want && $1 == "fpr" { print $10; exit }')"
[ -n "$rogue_fingerprint" ]
gpg --batch --yes --armor --export "$fingerprint" "$rogue_fingerprint" > "$fixture_dir/repo/polaris.gpg"
expect_failure 'public key bundle containing a second primary key' verify_fixture
gpg --batch --yes --armor --export "$fingerprint" > "$fixture_dir/repo/polaris.gpg"

if [ "$fixture_kind" = fedora ]; then
  provenance="$fixture_dir/repo/fedora/x86_64/Polaris-fedora44-x86_64.rpm.provenance.json"
  cp "$provenance" "$provenance.good"
  cp "$provenance.asc" "$provenance.asc.good"
  python3 - "$provenance" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
document["repository_asset_sha256"] = "0" * 64
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  gpg --batch --yes --detach-sign --armor --local-user "$fingerprint" \
    --output "$provenance.asc" "$provenance"
  expect_failure 'signed provenance with an altered complete-package digest' verify_fixture
  mv "$provenance.good" "$provenance"
  mv "$provenance.asc.good" "$provenance.asc"

  epoch_dir="$fixture_dir/rpmbuild-epoch"
  mkdir -p "$epoch_dir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  cp "$rpmbuild_dir/SOURCES/polaris.txt" "$epoch_dir/SOURCES/polaris.txt"
  sed '/^Version:/a Epoch: 1' "$rpmbuild_dir/SPECS/polaris.spec" > "$epoch_dir/SPECS/polaris.spec"
  rpmbuild --define "_topdir $epoch_dir" -bb "$epoch_dir/SPECS/polaris.spec"
  epoch_assets="$fixture_dir/epoch-assets"
  mkdir "$epoch_assets"
  cp "$epoch_dir/RPMS/x86_64/polaris-9.8.7-1.x86_64.rpm" \
    "$epoch_assets/Polaris-fedora44-x86_64.rpm"
  expect_failure 'nonzero RPM epoch' \
    bash scripts/build-package-repos.sh --only fedora --assets "$epoch_assets" \
      --version 9.8.7 --output "$fixture_dir/epoch-repo"
fi
