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

`.github/workflows/publish.yml` runs every six hours and on manual dispatch. The
scheduled run compares the latest Polaris release against `PUBLISHED_TAG` and
does nothing when they match, so it only rebuilds when there is something new.

Polaris cannot trigger it — that would need a token able to write here, which is
a worse thing to own than a few hours of delay.

```bash
gh workflow run publish.yml --repo papi-ux/packages                # latest release
gh workflow run publish.yml --repo papi-ux/packages -f tag=v1.3.6  # a specific one
```

## Secrets

| Secret | Value |
|---|---|
| `POLARIS_REPO_GPG_KEY_ID` | signing key fingerprint |
| `POLARIS_REPO_GPG_PRIVATE_KEY` | armored secret key |

The key must be RSA. `rpmsign` exits 0 on an Ed25519 key and signs nothing at
all, which is why `scripts/build-package-repos.sh` verifies the signature after
signing rather than trusting the exit code.
