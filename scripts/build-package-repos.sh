#!/usr/bin/env bash
# Assemble dnf and pacman repositories from release assets that already exist.
#
# Polaris publishes four packages per tag, and until now the only way to take an
# upgrade was to download one by hand and install it by exact filename. This
# turns those same packages into repositories, so `dnf upgrade` and `pacman -Syu`
# carry Polaris along with everything else on the host.
#
# Nothing is rebuilt. The package a repository serves is the package the release
# published and CI tested; the only difference is a signature on the repository
# copy. Rebuilding would mean shipping a second binary nobody tested, and the
# Fedora spec pulls a CUDA toolkit over the network during %build, which no
# sandboxed rebuild service will do anyway.
#
# Each ecosystem needs its own toolchain, so --only runs one at a time and the
# results are combined into a single output tree:
#
#   --only fedora   needs createrepo_c, rpm, rpmsign   (Fedora container)
#   --only arch     needs repo-add                     (Arch container)
#
# Usage:
#   scripts/build-package-repos.sh --only fedora --assets DIR --version 1.3.7 \
#       --output DIR [--base-url URL] [--gpg-key-id KEYID]
#
# Without --gpg-key-id the repositories are assembled unsigned, which is useful
# for checking the layout locally. Publishing unsigned is not supported.

set -euo pipefail

BASE_URL_DEFAULT='https://repo.papi-ux.com'

only=''
assets_dir=''
version=''
output_dir=''
base_url="$BASE_URL_DEFAULT"
gpg_key_id=''
release_tag=''
release_sha=''

die() {
  printf 'build-package-repos: %s\n' "$1" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) only="${2:-}"; shift 2 ;;
    --assets) assets_dir="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    --base-url) base_url="${2:-}"; shift 2 ;;
    --gpg-key-id) gpg_key_id="${2:-}"; shift 2 ;;
    --release-tag) release_tag="${2:-}"; shift 2 ;;
    --release-sha) release_sha="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$only" in
  fedora|arch) ;;
  '') die 'missing --only (fedora or arch)' ;;
  *) die "--only must be fedora or arch, not: $only" ;;
esac
[ -n "$assets_dir" ] || die 'missing --assets'
[ -n "$version" ] || die 'missing --version'
[ -n "$output_dir" ] || die 'missing --output'
[ -d "$assets_dir" ] || die "assets directory does not exist: $assets_dir"

require gpg

if [ -n "$gpg_key_id" ]; then
  [ -n "$release_tag" ] || die 'signed repositories require --release-tag'
  [ -n "$release_sha" ] || die 'signed repositories require --release-sha'
  [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "release tag is not a stable semantic version: $release_tag"
  [[ "$release_sha" =~ ^[0-9a-fA-F]{40}$ ]] || die 'release SHA must be a full 40-character commit SHA'
  [ "${release_tag#v}" = "$version" ] ||
    die "release tag $release_tag does not match version $version"
fi

mkdir -p "$output_dir"

# The exact release assets. Naming them rather than globbing means a renamed or
# missing asset fails here, instead of publishing a repository that quietly
# offers nothing.
#
# polaris-kms is not optional. 1.4.13 moved the DRM/KMS capture capability into
# that package so an update would stop taking it away, and told people to run
# "dnf install polaris-kms" to get it. A repository that carries only the base
# package makes that instruction fail, and makes the upgrade command Polaris
# prints leave a broken dependency: polaris-kms pins "polaris = <exact version>",
# so moving one without the other is not a transaction the package manager can
# satisfy.
case "$only" in
  fedora) assets="Polaris-fedora44-x86_64.rpm" ;;
  arch) assets="Polaris-arch-x86_64.pkg.tar.zst" ;;
esac

# polaris-kms arrived in 1.4.13. An older release legitimately has no KMS package,
# so requiring one would make republishing an old tag impossible. The publish
# workflow applies the same rule when it decides a release is ready and when it
# checks the published tree; all three have to agree or a tag resolves ready and
# then dies on a package that never existed.
if [ "$(printf '%s\n%s\n' 1.4.13 "$version" | sort -V | head -1)" = 1.4.13 ]; then
  case "$only" in
    fedora) assets="$assets Polaris-kms-fedora44-x86_64.rpm" ;;
    arch) assets="$assets Polaris-kms-arch-x86_64.pkg.tar.zst" ;;
  esac
fi

for name in $assets; do
  [ -f "$assets_dir/$name" ] || die "missing release asset: $assets_dir/$name"
done

printf 'Assembling %s repository for Polaris %s\n' "$only" "$version"

if [ "$only" = fedora ]; then
  require createrepo_c
  require rpm

  # Both package managers decide "is there an upgrade" from metadata inside the
  # package, never from its filename. A package whose internal version disagrees
  # with the release is one nobody ever upgrades to, and the failure is silent:
  # the repository works, it just never offers anything.
  # Repository clients compare the package metadata, not the release tag or
  # filename. Require the stable package identity exactly: accepting a commit
  # suffix here would publish 1.3.14.a1b2c3d-1 under a v1.3.14 marker.
  fedora_dir="$output_dir/fedora/x86_64"
  rm -rf "$output_dir/fedora"
  mkdir -p "$fedora_dir"

  for name in $assets; do
  asset="$assets_dir/$name"
  rpm_evr="$(rpm --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' -qp "$asset" 2>/dev/null)"
  [ "$rpm_evr" = "0:$version-1" ] ||
    die "$name reports epoch:version-release $rpm_evr but the release requires 0:$version-1"

  cp "$asset" "$fedora_dir/"
  rpm_in_repo="$fedora_dir/$(basename "$asset")"

  if [ -n "$gpg_key_id" ]; then
    require rpmsign
    # Signs the repository copy only. The published release asset is untouched,
    # so a package installed by hand and one installed from the repository are
    # the same build.
    rpmsign --define "_gpg_name $gpg_key_id" --addsign "$rpm_in_repo"

    # The signature lands in the RSAHEADER header, not SIGPGP -- SIGPGP reads
    # back empty on a correctly signed package, so checking it would reject
    # every good build. The key has to be RSA: rpmsign exits 0 on an Ed25519
    # key and signs nothing at all, which is why this is verified rather than
    # trusted.
    signature="$(rpm --queryformat '%{RSAHEADER:pgpsig}' -qp "$rpm_in_repo" 2>/dev/null)"
    case "$signature" in
      *'Key ID'*) ;;
      *) die 'rpmsign exited 0 but the RPM carries no signature (is the key RSA?)' ;;
    esac
    printf '  signed %s (%s)\n' "$(basename "$rpm_in_repo")" "$signature"

    require python3
    release_digest="$(sha256sum "$asset" | awk '{print $1}')"
    repository_digest="$(sha256sum "$rpm_in_repo" | awk '{print $1}')"
    provenance="$rpm_in_repo.provenance.json"
    python3 - "$provenance" "$release_tag" "$release_sha" \
      "$(basename "$asset")" "$release_digest" "$repository_digest" <<'PY'
import json
import sys

path, tag, release_sha, asset_name, release_digest, repository_digest = sys.argv[1:]
document = {
    "schema": "papi-ux-package-provenance-v1",
    "ecosystem": "fedora",
    "tag": tag,
    "release_sha": release_sha.lower(),
    "release_asset": asset_name,
    "release_asset_sha256": release_digest,
    "repository_asset_sha256": repository_digest,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
    gpg --batch --yes --detach-sign --armor --local-user "$gpg_key_id" "$provenance"
  fi
  done

  createrepo_c --quiet "$fedora_dir"
  [ -f "$fedora_dir/repodata/repomd.xml" ] || die 'createrepo_c produced no repomd.xml'

  if [ -n "$gpg_key_id" ]; then
    gpg --batch --yes --detach-sign --armor --local-user "$gpg_key_id" \
      "$fedora_dir/repodata/repomd.xml"
  fi

  cat > "$output_dir/fedora/polaris.repo" <<EOF
[polaris]
name=Polaris
baseurl=$base_url/fedora/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$base_url/polaris.gpg
metadata_expire=6h
EOF
fi

if [ "$only" = arch ]; then
  require repo-add

  arch_dir="$output_dir/arch/x86_64"
  rm -rf "$output_dir/arch"
  mkdir -p "$arch_dir"

  arch_basenames=''
  for name in $assets; do
    cp "$assets_dir/$name" "$arch_dir/"
    arch_in_repo="$arch_dir/$name"
    if [ -n "$gpg_key_id" ]; then
      gpg --batch --yes --detach-sign --no-armor --local-user "$gpg_key_id" "$arch_in_repo"
      [ -f "$arch_in_repo.sig" ] ||
        die "gpg reported success but no detached signature exists for $name"
    fi
    arch_basenames="$arch_basenames $name"
  done

  # repo-add records the filename it is handed and pacman fetches exactly that,
  # so a release asset does not have to be named like a pacman package. Both
  # packages go into one database in one call: repo-add rewrites the database it
  # is given, so calling it once per package would leave only the last one.
  if [ -n "$gpg_key_id" ]; then
    ( cd "$arch_dir" && repo-add --quiet --sign --key "$gpg_key_id" \
        polaris.db.tar.gz $arch_basenames )
    [ -f "$arch_dir/polaris.db.tar.gz.sig" ] || die 'repo-add did not sign the database'
  else
    ( cd "$arch_dir" && repo-add --quiet polaris.db.tar.gz $arch_basenames )
  fi
  [ -f "$arch_dir/polaris.db" ] || die 'repo-add produced no polaris.db'

  # repo-add leaves polaris.db and polaris.files as symlinks to the .tar.gz.
  # pacman fetches polaris.db by name over HTTP, and a static host serves a
  # symlink as its target's name in a text file rather than following it, so
  # these are materialized as real files.
  for link in polaris.db polaris.files polaris.db.sig polaris.files.sig; do
    if [ -L "$arch_dir/$link" ]; then
      target="$(readlink "$arch_dir/$link")"
      rm "$arch_dir/$link"
      cp "$arch_dir/$target" "$arch_dir/$link"
    fi
  done

  # The versions pacman will compare against, read back out of the database it
  # just wrote rather than trusted from the filenames. Every entry is checked,
  # not just the first: polaris-kms pins "polaris=<exact version>", so one of the
  # two carrying a different version is a dependency nothing can satisfy.
  db_versions="$(tar -xzOf "$arch_dir/polaris.db.tar.gz" --wildcards '*/desc' |
    awk '/^%VERSION%$/ { getline; print }')"
  db_entries=0
  for db_version in $db_versions; do
    db_entries=$((db_entries + 1))
    [ "$db_version" = "$version-1" ] ||
      die "pacman database reports version $db_version but the release requires $version-1"
  done
  expected_entries="$(printf '%s\n' $assets | wc -l | tr -d ' ')"
  [ "$db_entries" = "$expected_entries" ] ||
    die "pacman database holds $db_entries packages but $expected_entries were assembled"
  printf '  database records %s\n' "$db_version"

  # Without an explicit SigLevel pacman falls back to the checksum in the
  # database and reports "Validated By: SHA-256 Sum" -- it never looks at the
  # signature, so an attacker who can rewrite the database rewrites the
  # checksum with it. Requiring both closes that.
  cat > "$output_dir/arch/polaris.conf" <<EOF
[polaris]
SigLevel = Required DatabaseRequired
Server = $base_url/arch/\$arch
EOF
fi

if [ -n "$gpg_key_id" ]; then
  gpg --batch --yes --armor --export "$gpg_key_id" > "$output_dir/polaris.gpg"
  [ -s "$output_dir/polaris.gpg" ] || die 'exported public key is empty'
fi

printf 'Done. %s repository contents:\n' "$only"
find "$output_dir/$only" -type f | sort | sed 's/^/  /'
