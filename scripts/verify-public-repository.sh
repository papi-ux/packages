#!/usr/bin/env bash
# Read a deployed Polaris package repository back through its public URL and
# prove that it serves the exact signed release selected by the publish job.

set -euo pipefail

POLARIS_REPO_DEFAULT='papi-ux/polaris'
BASE_URL_DEFAULT='https://repo.papi-ux.com'
SITE_URL_DEFAULT='https://papi-ux.com'

only=''
tag=''
expected_release_sha=''
expected_fingerprint=''
expected_package_version=''
base_url="$BASE_URL_DEFAULT"
site_url="$SITE_URL_DEFAULT"
polaris_repo="$POLARIS_REPO_DEFAULT"
release_assets=''
poll_attempts="${READBACK_ATTEMPTS:-30}"
poll_delay="${READBACK_DELAY_SECONDS:-10}"
skip_release_api=false
allow_legacy_fedora_provenance=false

die() {
  printf 'verify-public-repository: %s\n' "$1" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

download() {
  local relative="$1"
  local destination="$2"
  curl --fail --silent --show-error --location --max-time 30 \
    "$base_url/$relative" --output "$destination"
}

normalize_fingerprint() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) only="${2:-}"; shift 2 ;;
    --tag) tag="${2:-}"; shift 2 ;;
    --release-sha) expected_release_sha="${2:-}"; shift 2 ;;
    --expected-fingerprint) expected_fingerprint="${2:-}"; shift 2 ;;
    --expected-package-version) expected_package_version="${2:-}"; shift 2 ;;
    --base-url) base_url="${2:-}"; shift 2 ;;
    --site-url) site_url="${2:-}"; shift 2 ;;
    --repo) polaris_repo="${2:-}"; shift 2 ;;
    --release-assets) release_assets="${2:-}"; shift 2 ;;
    --poll-attempts) poll_attempts="${2:-}"; shift 2 ;;
    --poll-delay) poll_delay="${2:-}"; shift 2 ;;
    --skip-release-api) skip_release_api=true; shift ;;
    --allow-legacy-fedora-provenance) allow_legacy_fedora_provenance=true; shift ;;
    -h|--help)
      sed -n '2,29p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$only" in
  fedora|arch|routes) ;;
  '') die 'missing --only (fedora, arch, or routes)' ;;
  *) die "--only must be fedora, arch, or routes, not: $only" ;;
esac
[ -n "$tag" ] || die 'missing --tag'
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag is not a stable version tag: $tag"
version="${tag#v}"
expected_package_version="${expected_package_version:-$version-1}"
[ -n "$expected_fingerprint" ] || die 'missing --expected-fingerprint'
case "$poll_attempts" in *[!0-9]*|'') die 'poll attempts must be an integer' ;; esac
case "$poll_delay" in *[!0-9]*|'') die 'poll delay must be an integer' ;; esac

require curl
require gpg
require sha256sum

verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/polaris-public-readback.XXXXXX")"
trap 'rm -rf -- "$verification_dir"' EXIT

# Pages deploys atomically, but its CDN does not update every edge at the same
# instant. Poll the public marker before reading any dependent object so a
# successful old deployment can never be mistaken for the requested release.
published=''
for attempt in $(seq 1 "$poll_attempts"); do
  published="$(curl --fail --silent --show-error --location --max-time 20 \
    "$base_url/PUBLISHED_TAG?readback=$attempt" 2>/dev/null || true)"
  if [ "$published" = "$tag" ]; then
    break
  fi
  if [ "$attempt" -lt "$poll_attempts" ]; then
    sleep "$poll_delay"
  fi
done
[ "$published" = "$tag" ] || die "PUBLISHED_TAG is ${published:-unavailable}, expected $tag"

download polaris.gpg "$verification_dir/polaris.gpg"
export GNUPGHOME="$verification_dir/gnupg"
mkdir -m 700 "$GNUPGHOME"
actual_fingerprint="$(gpg --batch --with-colons --show-keys "$verification_dir/polaris.gpg" |
  awk -F: '$1 == "pub" { want = 1; count += 1; next } want && $1 == "fpr" { print $10; want = 0 } END { if (count != 1) exit 42 }')" ||
  die 'the public repository key bundle must contain exactly one primary key'
[ -n "$actual_fingerprint" ] || die 'the public repository key has no fingerprint'
[ "$(normalize_fingerprint "$actual_fingerprint")" = "$(normalize_fingerprint "$expected_fingerprint")" ] ||
  die "public key fingerprint $actual_fingerprint does not match the configured key"

verify_signature() {
  local signature="$1"
  local payload="$2"
  local status
  local primary
  status="$(gpg --batch --status-fd 1 --verify "$signature" "$payload" 2>/dev/null)" ||
    die "signature verification failed for $(basename "$payload")"
  primary="$(printf '%s\n' "$status" |
    awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { count += 1; fingerprint = $NF } END { if (count == 1) print fingerprint; else exit 1 }')" ||
    die "signature for $(basename "$payload") did not yield exactly one VALIDSIG"
  [ "$(normalize_fingerprint "$primary")" = "$(normalize_fingerprint "$expected_fingerprint")" ] ||
    die "signature for $(basename "$payload") was not made by the configured primary key"
}

if [ "$skip_release_api" != true ]; then
  require gh
  require jq
  release_json="$verification_dir/release.json"
  env GH_PAGER=cat gh api "repos/$polaris_repo/releases/tags/$tag" > "$release_json"
  [ "$(jq -r .tag_name "$release_json")" = "$tag" ] || die 'release tag does not match'
  [ "$(jq -r .draft "$release_json")" = false ] || die "$tag is still a draft"
  [ "$(jq -r .prerelease "$release_json")" = false ] || die "$tag is a prerelease"
  release_sha="$(env GH_PAGER=cat gh api "repos/$polaris_repo/commits/$tag" --jq .sha)"
  [ -n "$release_sha" ] || die "could not resolve the source commit for $tag"
  if [ -n "$expected_release_sha" ] && [ "$release_sha" != "$expected_release_sha" ]; then
    die "release source $release_sha does not match resolved source $expected_release_sha"
  fi
fi

release_asset() {
  local name="$1"
  local destination="$2"
  if [ -n "$release_assets" ]; then
    [ -f "$release_assets/$name" ] || die "fixture release asset is missing: $name"
    cp "$release_assets/$name" "$destination"
  else
    env GH_PAGER=cat gh release download "$tag" --repo "$polaris_repo" \
      --pattern "$name" --output "$destination"
    declared_digest="$(jq -r --arg name "$name" \
      '.assets[] | select(.name == $name) | .digest // empty' "$release_json")"
    [ -n "$declared_digest" ] || die "GitHub release has no digest for $name"
    [ "sha256:$(sha256sum "$destination" | awk '{print $1}')" = "$declared_digest" ] ||
      die "downloaded $name does not match its GitHub release digest"
  fi
}

if [ "$only" = fedora ]; then
  require python3
  require rpm
  require rpmkeys
  require jq
  gpg --batch --quiet --import "$verification_dir/polaris.gpg"

  download fedora/polaris.repo "$verification_dir/polaris.repo"
  grep -Fx 'gpgcheck=1' "$verification_dir/polaris.repo" >/dev/null ||
    die 'fedora configuration does not require package signatures'
  grep -Fx 'repo_gpgcheck=1' "$verification_dir/polaris.repo" >/dev/null ||
    die 'fedora configuration does not require repository signatures'
  grep -Fx "gpgkey=$base_url/polaris.gpg" "$verification_dir/polaris.repo" >/dev/null ||
    die 'fedora configuration does not pin the public repository key URL'

  download fedora/x86_64/repodata/repomd.xml "$verification_dir/repomd.xml"
  download fedora/x86_64/repodata/repomd.xml.asc "$verification_dir/repomd.xml.asc"
  verify_signature "$verification_dir/repomd.xml.asc" "$verification_dir/repomd.xml"

  primary_fields="$(python3 - "$verification_dir/repomd.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
ns = {"repo": "http://linux.duke.edu/metadata/repo"}
for data in root.findall("repo:data", ns):
    if data.get("type") == "primary":
        location = data.find("repo:location", ns)
        checksum = data.find("repo:checksum", ns)
        if location is None or checksum is None or checksum.get("type") != "sha256":
            raise SystemExit("primary metadata lacks a sha256 location")
        print(location.get("href", ""))
        print(checksum.text or "")
        break
else:
    raise SystemExit("repomd.xml has no primary metadata")
PY
)"
  primary_href="$(printf '%s\n' "$primary_fields" | sed -n '1p')"
  primary_checksum="$(printf '%s\n' "$primary_fields" | sed -n '2p')"
  [ -n "$primary_href" ] && [ -n "$primary_checksum" ] || die 'invalid primary metadata reference'
  download "fedora/x86_64/$primary_href" "$verification_dir/primary.data"
  [ "$(sha256sum "$verification_dir/primary.data" | awk '{print $1}')" = "$primary_checksum" ] ||
    die 'primary metadata does not match the signed repomd checksum'

  case "$primary_href" in
    *.zst) require zstd; zstd --quiet --decompress --stdout "$verification_dir/primary.data" > "$verification_dir/primary.xml" ;;
    *.gz) gzip -dc "$verification_dir/primary.data" > "$verification_dir/primary.xml" ;;
    *.bz2) bzip2 -dc "$verification_dir/primary.data" > "$verification_dir/primary.xml" ;;
    *.xml) cp "$verification_dir/primary.data" "$verification_dir/primary.xml" ;;
    *) die "unsupported primary metadata compression: $primary_href" ;;
  esac

  # Both packages, because polaris-kms pins "polaris = <exact version>". A
  # repository serving one of them is not a repository with a missing extra: it
  # is a dependency no package manager can satisfy, and the upgrade command
  # Polaris prints fails on exactly the hosts that were told to install it.
  mkdir "$verification_dir/rpmdb"
  rpmkeys --dbpath "$verification_dir/rpmdb" --import "$verification_dir/polaris.gpg"

  for rpm_name in polaris polaris-kms; do
    case "$rpm_name" in
      polaris) rpm_asset=Polaris-fedora44-x86_64.rpm ;;
      polaris-kms) rpm_asset=Polaris-kms-fedora44-x86_64.rpm ;;
    esac

    metadata_nevra="$(python3 - "$verification_dir/primary.xml" "$rpm_name" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, wanted = sys.argv[1:3]
root = ET.parse(path).getroot()
ns = {"common": "http://linux.duke.edu/metadata/common"}
for package in root.findall("common:package", ns):
    name = package.findtext("common:name", namespaces=ns)
    if name == wanted:
        version = package.find("common:version", ns)
        arch = package.findtext("common:arch", namespaces=ns)
        if version is None:
            raise SystemExit(f"{wanted} metadata has no version")
        print(f"{version.get('epoch', '0')}:{name}-{version.get('ver')}-{version.get('rel')}.{arch}")
        break
else:
    raise SystemExit(f"primary metadata has no {wanted} package")
PY
)"
    [ "$metadata_nevra" = "0:$rpm_name-$expected_package_version.x86_64" ] ||
      die "fedora metadata reports $metadata_nevra, expected 0:$rpm_name-$expected_package_version.x86_64"

    public_rpm="$verification_dir/public-$rpm_name.rpm"
    download "fedora/x86_64/$rpm_asset" "$public_rpm"
    rpm_nevra="$(rpm --query --package --nodigest --nosignature \
      --queryformat '%{EPOCHNUM}:%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$public_rpm")"
    [ "$rpm_nevra" = "0:$rpm_name-$expected_package_version.x86_64" ] ||
      die "public $rpm_asset reports $rpm_nevra, expected 0:$rpm_name-$expected_package_version.x86_64"
    rpmkeys --dbpath "$verification_dir/rpmdb" --checksig "$public_rpm" |
      grep -E 'digests signatures OK$' >/dev/null ||
      die "public $rpm_asset signature verification failed"
  done

  # The base package stays under the names the provenance checks below expect.
  public_rpm="$verification_dir/public-polaris.rpm"
  release_rpm="$verification_dir/release.rpm"
  release_asset Polaris-fedora44-x86_64.rpm "$release_rpm"

  if [ "$allow_legacy_fedora_provenance" = true ]; then
    # Historical repositories predate the signed full-package manifest. This
    # explicit compatibility mode exists only to exercise their live layout;
    # publication workflows never set it, and new releases fail closed.
    require rpm2cpio
    [ "$(rpm2cpio "$public_rpm" | sha256sum | awk '{print $1}')" = \
      "$(rpm2cpio "$release_rpm" | sha256sum | awk '{print $1}')" ] ||
      die 'legacy repository RPM payload differs from the GitHub release asset'
  else
    provenance="$verification_dir/public.rpm.provenance.json"
    download fedora/x86_64/Polaris-fedora44-x86_64.rpm.provenance.json "$provenance"
    download fedora/x86_64/Polaris-fedora44-x86_64.rpm.provenance.json.asc "$provenance.asc"
    verify_signature "$provenance.asc" "$provenance"
    [ "$(jq -r .schema "$provenance")" = papi-ux-package-provenance-v1 ] || die 'invalid Fedora provenance schema'
    [ "$(jq -r .ecosystem "$provenance")" = fedora ] || die 'invalid Fedora provenance ecosystem'
    [ "$(jq -r .tag "$provenance")" = "$tag" ] || die 'Fedora provenance tag does not match'
    [ -n "$expected_release_sha" ] || die 'Fedora verification requires an independently supplied release SHA'
    [ "$(jq -r .release_sha "$provenance")" = "$(printf '%s' "$expected_release_sha" | tr '[:upper:]' '[:lower:]')" ] ||
      die 'Fedora provenance source SHA does not match the approved release SHA'
    [ "$(jq -r .release_asset "$provenance")" = Polaris-fedora44-x86_64.rpm ] ||
      die 'Fedora provenance release asset name does not match'
    [ "$(jq -r .release_asset_sha256 "$provenance")" = "$(sha256sum "$release_rpm" | awk '{print $1}')" ] ||
      die 'Fedora provenance does not match the complete GitHub release RPM'
    [ "$(jq -r .repository_asset_sha256 "$provenance")" = "$(sha256sum "$public_rpm" | awk '{print $1}')" ] ||
      die 'Fedora provenance does not match the complete signed repository RPM'
  fi
fi

if [ "$only" = arch ]; then
  require bsdtar
  gpg --batch --quiet --import "$verification_dir/polaris.gpg"

  download arch/polaris.conf "$verification_dir/polaris.conf"
  grep -Fx 'SigLevel = Required DatabaseRequired' "$verification_dir/polaris.conf" >/dev/null ||
    die 'arch configuration does not require package and database signatures'
  grep -Fx "Server = $base_url/arch/\$arch" "$verification_dir/polaris.conf" >/dev/null ||
    die 'arch configuration does not use the public repository URL'

  download arch/x86_64/polaris.db "$verification_dir/polaris.db"
  download arch/x86_64/polaris.db.sig "$verification_dir/polaris.db.sig"
  verify_signature "$verification_dir/polaris.db.sig" "$verification_dir/polaris.db"
  db_desc="$(bsdtar -xOf "$verification_dir/polaris.db" '*/desc')"
  db_names="$(printf '%s\n' "$db_desc" | awk '/^%NAME%$/ { getline; print }' | sort | tr '\n' ' ')"
  # Both, and only these two. polaris-kms pins the base version exactly, so a
  # database holding one of them is a dependency nothing can satisfy.
  [ "$db_names" = 'polaris polaris-kms ' ] ||
    die "arch database holds [$db_names], expected [polaris polaris-kms ]"
  for db_version in $(printf '%s\n' "$db_desc" | awk '/^%VERSION%$/ { getline; print }'); do
    [ "$db_version" = "$expected_package_version" ] ||
      die "arch database reports $db_version, expected $expected_package_version"
  done

  public_arch="$verification_dir/public.pkg.tar.zst"
  release_arch="$verification_dir/release.pkg.tar.zst"
  download arch/x86_64/Polaris-arch-x86_64.pkg.tar.zst "$public_arch"
  download arch/x86_64/Polaris-arch-x86_64.pkg.tar.zst.sig "$verification_dir/public.pkg.tar.zst.sig"
  verify_signature "$verification_dir/public.pkg.tar.zst.sig" "$public_arch"
  release_asset Polaris-arch-x86_64.pkg.tar.zst "$release_arch"
  [ "$(sha256sum "$public_arch" | awk '{print $1}')" = \
    "$(sha256sum "$release_arch" | awk '{print $1}')" ] ||
    die 'repository Arch package hash differs from the GitHub release asset'
fi

if [ "$only" = routes ]; then
  for route in /polaris/ /nova/ /compare/ /docs/; do
    http_code='000'
    for attempt in 1 2 3; do
      http_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --location --max-time 20 "$site_url$route?package-readback=$attempt" || printf '000')"
      [ "$http_code" = 200 ] && break
      sleep 10
    done
    [ "$http_code" = 200 ] || die "$site_url$route returned $http_code"
  done
fi

printf 'Verified %s public read-back for %s at %s\n' "$only" "$tag" "$base_url"
