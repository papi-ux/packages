# papi-ux packages

Signed dnf and pacman repositories for [Polaris](https://github.com/papi-ux/polaris),
served at **https://repo.papi-ux.com**.

Setup instructions live with the project:
[docs/repositories.md](https://github.com/papi-ux/polaris/blob/master/docs/repositories.md).

```bash
sudo dnf upgrade          # Fedora, Bazzite
sudo pacman -Syu          # Arch, CachyOS
```

## Why this is a separate repository

GitHub reserves `<user-domain>/<repo-name>` for any repository with a Pages
site. Publishing from `papi-ux/polaris` therefore took over
`papi-ux.com/polaris/`, which is a real page on the docs site — replacing it
with a 404, and then with a 301 once a custom domain was added. A custom domain
does not avoid the collision; it only changes what the collision returns.

Publishing from a repository whose name collides with nothing does avoid it.
`papi-ux.com/packages/` is unused, and the deploy asserts the docs site's routes
still return 200 afterwards.

It also means no cross-repository credential exists. Polaris releases are
public, so the assets need no auth, and Pages deploys with this repository's own
`GITHUB_TOKEN`.

## What is published

Nothing is rebuilt. Each repository serves the package the Polaris release
published and its CI tested; the repository copy only gains a signature. The
published asset in the release is left untouched, so a package installed by
hand and one installed from a repository are the same build.

```
repo.papi-ux.com/
  CNAME
  PUBLISHED_TAG                     the release currently served
  polaris.gpg                       public signing key
  fedora/polaris.repo               drop into /etc/yum.repos.d/
  fedora/x86_64/                    packages + repodata, repomd.xml signed
  arch/polaris.conf                 append to /etc/pacman.conf
  arch/x86_64/                      packages + database, both signed
```

The repository carries the latest release only. Rolling back means installing an
older release package by hand from the
[releases page](https://github.com/papi-ux/polaris/releases).

## How it runs

`.github/workflows/publish.yml` runs hourly and on manual dispatch.
The scheduled run compares the latest Polaris release against `PUBLISHED_TAG`
and does nothing when they match, so it only rebuilds when there is something
new.

Hourly is a trade. Polaris' Update Center offers `dnf upgrade polaris` as soon
as a release appears on GitHub, and until this repository catches up that
command correctly does nothing — which to anyone running it looks like the
feature is broken. Checking every fifteen minutes would shrink that window, but
96 runs a day turns the Actions tab into a wall of green checkmarks where a real
failure goes unnoticed. Releases land a few times a week; a release worth having
immediately is one dispatch away.

Only stable releases are published. The resolve job rejects malformed tags,
drafts, and prereleases before assembling or deploying any repository content.
An explicit tag also requires the independently approved, full Polaris merge
SHA and fails before publication if that SHA is not the tag target.

Polaris cannot trigger this directly — that would need a token able to write
here, which is a worse thing to own than fifteen minutes. Publishing a release
and wanting it immediately is a one-liner:

```bash
gh workflow run publish.yml --repo papi-ux/packages \
  -f tag=v1.3.14 -f approved_sha=0123456789abcdef0123456789abcdef01234567
```

After Pages reports a successful deployment, the workflow reads the public
repository back before it can finish green. It waits for the exact
`PUBLISHED_TAG`, checks the public key fingerprint, both repository and package
signatures, exact package metadata, and provenance against the GitHub release
assets. It also rechecks the product and documentation routes on papi-ux.com.

## Secrets

| Secret | Value |
|---|---|
| `POLARIS_REPO_GPG_KEY_ID` | signing key fingerprint |
| `POLARIS_REPO_GPG_PRIVATE_KEY` | armored secret key |

The key must be RSA. `rpmsign` exits 0 on an Ed25519 key and signs nothing at
all, which is why `scripts/build-package-repos.sh` verifies the signature after
signing rather than trusting the exit code.
