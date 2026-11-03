# Releasing

**Nothing here has been run.** No package exists yet on any registry, no tag
exists, and the public names below wait for the owner's confirmation (see
`AGENTS.md`); `VERSION` is a provisional `0.1.0`. This file describes the flow
for when they are confirmed.

One version for every SDK (`VERSION`). Pushing the tag `vX.Y.Z` runs
`.github/workflows/release.yml`, which publishes that version to every registry
below. Each job first asks its registry whether the version is already there
and does nothing if it is, so a version published by hand beforehand, or a
re-run of the tag, never fails on a duplicate. The jobs are independent: one
registry failing does not stop the others, and a failed job can be re-run alone.

## What gates a release

- The first job, `guard`, fails unless the tagged commit is an ancestor of
  `origin/main`, and every publish job needs it. A tag on a commit that is not
  on `main` publishes nothing. Push `main` first, then tag.
- Every publish job runs in a GitHub environment, so required reviewers can
  hold the publish for a human: `release` for npm, RubyGems, crates.io, pub.dev,
  NuGet and Maven Central, `pypi` for PyPI and `hex` for Hex (those two are
  already the environments their trusted publishers name, and a job has only
  one). Those registries' publishers leave the environment blank, which accepts
  any, so naming `release` does not change what they match.

## Each release

1. Bump `VERSION`, run `go run ./cmd/sdkgen` and `./check.sh`, commit on
   `main`, and wait for CI.
2. On that commit, tag and push both tags:

   ```sh
   git tag vX.Y.Z && git tag go/vX.Y.Z
   git push origin vX.Y.Z go/vX.Y.Z
   ```

   - `vX.Y.Z` runs the workflow (npm, PyPI, RubyGems, crates.io, Hex, pub.dev,
     NuGet, Maven Central) and is what Packagist and Swift read.
   - `go/vX.Y.Z` is the Go module's version.

## What the release installs

The jobs that hold an OIDC token install only pinned tools, so a compromised
upstream release cannot reach a publish credential:

- npm: `typescript/package-lock.json` is committed and installed with
  `npm ci --ignore-scripts`; npm itself is installed at an exact version
  (12.2.1; trusted publishing needs 11.5.1 or later, and npm 12 needs Node 22.22.2, 24.15 or later, which `node-version: '24'` gives). Raise it on purpose.
  After a change to `typescript/package.json` run
  `npm install --package-lock-only --ignore-scripts` there and commit the lock.
- PyPI: the build tools are in `.github/release/python-build.txt`, hash-locked
  (`pip-compile --generate-hashes --allow-unsafe --strip-extras
  python-build.in`, from `.github/release/`).
- Hex: `mix local.hex 2.6.0`.
- Every action is pinned to a commit SHA, kept current by Dependabot.

## One-time setup, per registry

The package belongs to the `alpr-sh` organization everywhere the registry has
one. In every trusted publisher form the values are the same: owner
`alpr-sh`, repository `sdk`, workflow `release.yml`; the environment is blank
unless this file says otherwise (blank accepts any environment, so the jobs
that run in `release` match). Binding a publisher to `release` is a follow-up
once the environment's reviewers are set; PyPI and Hex stay on `pypi` and
`hex` until their publishers are moved to `release`. Names are fixed in
`AGENTS.md`.

| Registry | Package | Auth in the workflow |
| --- | --- | --- |
| npm | `@alpr-sh/sdk` | OIDC |
| PyPI | `alpr-sdk` | OIDC |
| RubyGems | `alpr-sdk` | OIDC |
| crates.io | `alpr-sdk` | OIDC |
| Hex | `alpr_sdk` | OIDC (secret as fallback) |
| pub.dev | `alpr_sdk` | OIDC |
| NuGet | `AlprSh.Sdk` | OIDC + one secret |
| Maven Central | `sh.alpr:sdk` | secrets |
| Packagist, Go, Swift | | the tag itself, no workflow |

A trusted publisher can only be added to a package that already exists on
npm, crates.io, Hex and pub.dev, so the first release of a package there is
published by hand; every later one is the tag. RubyGems and PyPI accept a
publisher for a package that does not exist yet.

### GitHub (repository alpr-sh/sdk)

- Environments `release`, `pypi` and `hex` (created by the first run that names
  them). Add required reviewers to all three, and restrict deployment to the
  `v*` tags (deployment protection rules, selected tags); until then nothing
  holds a publish for approval. `pypi` and `hex` must keep the names the
  trusted publishers below use.
- Branch protection on `main` and a tag ruleset for `v*` and `go/v*` (only
  maintainers may create them) back up the `guard` job.
- Repository secrets: only those listed under NuGet, Maven Central and, if used,
  Hex.

### npm

1. Organization `alpr-sh` owns `@alpr-sh/sdk`.
2. Package settings, Trusted Publisher, GitHub Actions: organization
   `alpr-sh`, repository `sdk`, workflow `release.yml`, environment blank.

### PyPI

Organization `alpr-sh` owns `alpr-sdk`. Trusted publisher (GitHub): owner
`alpr-sh`, repository `sdk`, workflow `release.yml`, environment `pypi`.

### RubyGems

Gem `alpr-sdk` (owned by the `alpr-sh` organization). Gem page, Trusted
publishers, GitHub Actions: owner `alpr-sh`, repository `sdk`, workflow
`release.yml`, environment blank.

### crates.io

Crate `alpr-sdk` (owner: a GitHub team of `alpr-sh`). Crate settings,
Trusted Publishing, add GitHub: owner `alpr-sh`, repository `sdk`, workflow
`release.yml`, environment blank.

### Hex

Package `alpr_sdk`, owned by the `alpr-sh` Hex organization. As a full
owner with two-factor on, open the package's "Workload identities" tab and add:
owner `alpr-sh`, repository `sdk`, workflow `release.yml` (case-sensitive),
environment `hex` (required while the repository is public).

If that is not done yet, add the repository secret `HEX_API_KEY` (a key with
publish permission for the package); the job uses it when present.

### pub.dev

1. First release by hand from `dart/`: `dart pub publish`, under the verified
   publisher chosen for `alpr-sh` (confirm the publisher name before creating
   it, see `AGENTS.md`).
2. Package Admin, Automated publishing, enable publishing from GitHub Actions:
   repository `alpr-sh/sdk`, tag pattern `v{{version}}`. Do not require a
   specific environment: the job runs in `release`. Requiring `release` there
   is a follow-up that tightens it once the environment's reviewers are set.

### NuGet

1. Account or organization `alpr-sh` on nuget.org owns `AlprSh.Sdk`
   (reserve the `AlprSh.` prefix).
2. Trusted Publishing, new policy: policy owner the `alpr-sh` account or
   organization, repository owner `alpr-sh`, repository `sdk`, workflow file
   `release.yml` (file name only), environment blank, scope to allow new
   packages and new versions (glob `AlprSh.*`).
3. Repository secret `NUGET_USER`: the nuget.org profile name (not the e-mail).

### Maven Central

1. Sonatype Central Portal account; register the namespace `sh.alpr` and
   verify it with the DNS TXT record on `alpr.sh`.
2. Portal, Account, Generate User Token. Repository secrets
   `MAVEN_CENTRAL_USERNAME` and `MAVEN_CENTRAL_TOKEN` (the token's two halves).
3. Create a GPG key, publish its public half to `keyserver.ubuntu.com` or
   `keys.openpgp.org`. Repository secrets `MAVEN_GPG_PRIVATE_KEY`
   (`gpg --armor --export-secret-keys <id>`) and `MAVEN_GPG_PASSPHRASE`.

The job runs `mvn -Prelease deploy` in `java/` (sources, Javadoc and signatures
come from the `release` profile in the generator's template) and waits until
the portal has published the version, which can take several minutes.

### Packagist, Go, Swift

Nothing in the workflow. Packagist reads the `v` tag through the root
`composer.json`, Swift through the root `Package.swift`, and Go proxies the
`go/vX.Y.Z` tag.

## Checking a release without publishing

Locally, from the matching folder: `gem build alpr-sdk.gemspec`,
`cargo package --allow-dirty`, `mix hex.build`, `dart pub publish --dry-run`,
`dotnet pack src/Alpr/Alpr.csproj -c Release`, and
`mvn -Prelease -Dgpg.skip=true package`.
