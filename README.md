# gha

Shared GitHub Actions workflows, composite actions and Renovate presets for yama6a repos.
Pin every `uses:` to `@v2`. How the repos themselves are set up is in
[ORG_CONVENTIONS.md](ORG_CONVENTIONS.md).

## Reusable workflows

Required-check names follow one rule: the caller's job id is the workflow's short name, the
workflow's job carries the same `name:`, so the context is `go / go`, `node / node`, `php / php`,
`e2e / e2e`.

### `go-ci.yaml`

The `check` mode runs tidy drift, generate drift, `actions/workflow-security`, golangci-lint with
the canonical `.golangci.yaml` from this repo, `actions/validate-renovate-config`, fmt, vet,
`go test -count=1` with coverage, govulncheck, and a cross-compile for amd64 and arm64 with
`-trimpath`. golangci-lint is pinned in `GOLANGCI_LINT_VERSION`, and Renovate bumps it.

```yaml
jobs:
  go:
    uses: yama6a/gha/.github/workflows/go-ci.yaml@v2
```

The `check` mode never uses `-race`. Every Go repo runs the race tests weekly through `race.yaml` below. A
failed weekly run alerts through gha-status-exporter.

| input | default |
|---|---|
| `mode` | `check`; `race` and `warm-cache` are for the scheduled workflows below |

The job is named `go` in every mode, so the required context stays `go / go`.

| mode | runs | saves |
|---|---|---|
| `check` | every check above | the Go caches on a miss of the exact key, and the lint cache. Never from a `pull_request` |
| `race` | `go test ./... -race -count=1` only | nothing |
| `warm-cache` | golangci-lint. On a miss of the exact Go cache key also `go mod download`, `go build ./...`, the test packages through `go test -c -cover` without running them, and the cross-compile | the Go caches on a miss, and the lint cache |

A PR run can read only the caches saved on the default branch. GitHub drops an entry after 7 days
without use, and the golangci-lint key changes every 7 days. So the caller runs `check` on
`pull_request` only, and a weekly `warm-cache` run fills both caches:

- The `warm-cache` mode builds test binaries without `-race`, which are the ones PR runs reuse.
- docker-build-release.yaml reads the same cache entries, because its release build uses the
  cross-compile flags.

```yaml
# .github/workflows/warm-cache.yaml
name: warm-cache
on:
  schedule:
    - cron: '23 3 * * 1'  # a different minute in each repo
  workflow_dispatch:
concurrency:
  group: warm-cache
  cancel-in-progress: true
permissions:
  contents: read
jobs:
  go:
    uses: yama6a/gha/.github/workflows/go-ci.yaml@v2
    with:
      mode: warm-cache
```

Every Go repo runs the race tests weekly on the default branch:

```yaml
# .github/workflows/race.yaml
name: race
on:
  schedule:
    - cron: '41 3 * * 4'  # a different minute in each repo
  workflow_dispatch:
permissions:
  contents: read
jobs:
  go:
    uses: yama6a/gha/.github/workflows/go-ci.yaml@v2
    with:
      mode: race
```

- Pick a minute other than `0`. GitHub delays scheduled runs at the start of an hour, when its load
  peaks.
- Start `warm-cache.yaml` once by hand after adding it, so PRs find a cache before the first
  scheduled run: `gh workflow run warm-cache.yaml`.
- GitHub disables scheduled workflows in a public repo after 60 days without activity.

govulncheck runs through `scripts/govulncheck.sh`, which fails on the same findings plain
govulncheck exits 3 on: a vulnerability your code actually calls. A caller can allowlist an id in
`.govulncheck-ignore`, one OSV id per line with the reason after a `#`:

```
GO-2026-6452  # excelize: the OSV record has no fixed version, but v2.11.0 carries the fix
```

Use it only when no released version clears the finding, which happens when an advisory's OSV
record has no `fixed` event. An id listed there that govulncheck no longer reports produces a
warning, so the entries get cleaned up.

The caller must not carry a `.golangci.yaml`; the workflow fails if it finds one. Repo-specific
additions go in `.golangci.local.yaml`, merged on top with
`yq eval-all '. as $item ireduce ({}; . *+ $item)'` (`*+` appends to lists, so the local file
holds only its additions). `templates/Makefile.go` runs the same merge locally so `make lint` and
CI agree.

### `node-ci.yaml`

`npm ci`, then the scripts `generate` (followed by `git diff --exit-code`), `lint`,
`format:check`, `typecheck`, `test`, then `actions/workflow-security`,
`npm audit --audit-level=high`, `build`, then `actions/validate-renovate-config`. It runs last
because it pins Node 24 on PATH. Node version from `.nvmrc`. Every script must exist;
`"exit 0"` where a project has nothing to do.

The audit runs through `scripts/npm-audit.sh`. It fails on the same findings as
`npm audit --audit-level=high`: a high or critical advisory. A caller can allowlist an id in
`.npm-audit-ignore` next to `package.json`. One GHSA id per line, the reason after a `#`:

```
GHSA-vfj7-8cjw-p6xm  # braces: no patched release, reached only through dev tooling
```

Use it only when no released version clears the advisory. An id listed there that npm audit no
longer reports as high or critical produces a warning, so the entries get cleaned up.

```yaml
jobs:
  node:
    uses: yama6a/gha/.github/workflows/node-ci.yaml@v2
    # with:
    #   working-directory: web
    #   build-env: |
    #     NEXT_PUBLIC_USE_MOCK_DATA=true
```

| input | default |
|---|---|
| `working-directory` | `.` |
| `build-env` | none; newline `KEY=VALUE`, exported for the build step only |
| `upload-build` | none; upload-artifact paths, relative to the repo root. When set, the build output goes up as artifact `node-build` for `playwright-e2e.yaml` |
| `runner` | `ubuntu-24.04-arm` |
| `warm-cache` | `false`; `true` runs only `npm ci` and saves the npm store |

PR caches are private to their PR. So the caller runs `node-ci` on `pull_request` only, and warms the
default-branch npm store whenever the lockfile changes there. A repo with Playwright warms through
`playwright-e2e.yaml` instead, which fills the same npm store.

```yaml
# .github/workflows/warm-cache.yaml
name: warm-cache
on:
  push:
    branches: [main]
    paths: ['package-lock.json']
concurrency:
  group: warm-cache
  cancel-in-progress: true
permissions:
  contents: read
jobs:
  warm:
    uses: yama6a/gha/.github/workflows/node-ci.yaml@v2
    with:
      warm-cache: true
```

### `php-ci.yaml`

One job per PHP version: `composer validate --strict`, `composer install`, `composer audit`, then
each composer script in `composer-scripts`. The first version in `php-versions` also runs
`actions/validate-renovate-config`. The job `php` passes only when every version passed.
It is the required check, `php / php`. The per-version jobs are not required, so the version list
can change freely.

```yaml
jobs:
  php:
    uses: yama6a/gha/.github/workflows/php-ci.yaml@v2
    # with:
    #   php-versions: '["8.4", "8.5"]'
    #   extensions: gd, imagick
    #   composer-scripts: |
    #     lint
    #     test
```

| input | default |
|---|---|
| `php-versions` | `["8.2", "8.3", "8.4", "8.5", "8.6"]`; a JSON array |
| `extensions` | none; comma-separated, passed to `shivammathur/setup-php` |
| `composer-scripts` | `test`; one script per line, run in order |
| `runner` | `ubuntu-26.04-arm` |

### `playwright-e2e.yaml`

Runs the suite sharded, against the build that `node-ci.yaml` uploads as artifact `node-build` in
the same run. So the caller passes `upload-build` to node-ci, and the e2e job needs the node job.
Required check is the gate job, `e2e / e2e`. Shards are not required, so `shards` can change freely.

```yaml
jobs:
  node:
    uses: yama6a/gha/.github/workflows/node-ci.yaml@v2
    with:
      build-env: |
        NEXT_PUBLIC_USE_MOCK_DATA=true
      upload-build: |
        .next
        !.next/cache
        !.next/standalone
  e2e:
    needs: node
    uses: yama6a/gha/.github/workflows/playwright-e2e.yaml@v2
    with:
      shards: '[1, 2]'
```

| input | default |
|---|---|
| `shards` | `[1, 2]`; a JSON array, one job per shard |
| `runner` | `ubuntu-24.04-arm`; must match the warm-cache caller, the cache key includes the arch |
| `working-directory` | `.` |
| `build-artifact-paths` | `.next`, `!.next/cache`, `!.next/standalone`; the `upload-build` paths given to node-ci. The first non-`!` line is the download target |
| `browser` | `chromium` |
| `warm-cache` | `false`; run only the cache-priming job |

PR caches are private to their PR, so the caller also warms the default-branch cache:

```yaml
# .github/workflows/warm-cache.yaml
on:
  push:
    branches: [main]
    paths: ['package-lock.json']
concurrency:
  group: warm-cache
  cancel-in-progress: true
jobs:
  warm:
    uses: yama6a/gha/.github/workflows/playwright-e2e.yaml@v2
    with:
      warm-cache: true
```

### `docker-build-release.yaml`

hadolint, next integer version, optional `build-command`, multi-arch image to GHCR with provenance
and SBOM, signed attestation (public repos only), GitHub release.
Outputs `version`. It does not scan the image. `image-scan.yaml` does that after the build.

```yaml
permissions:
  contents: write
  packages: write
  id-token: write
  attestations: write

jobs:
  build-push:
    uses: yama6a/gha/.github/workflows/docker-build-release.yaml@v2
    with:
      dockerfile: .build/Dockerfile

  deploy:
    needs: build-push
    permissions: {}
    uses: yama6a/gha/.github/workflows/deploy-gitops.yaml@v2
    with:
      tag: ${{ needs.build-push.outputs.version }}
      values-path: argo_apps/workloads/charts/myapp/values.yaml
    secrets:
      DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

All four permissions are required; a reusable job gets only what the caller grants.

| input | default |
|---|---|
| `dockerfile` | `Dockerfile` |
| `context` | `.` |
| `platforms` | `linux/amd64,linux/arm64` |
| `build-command` | none; runs on the runner before the build, with the tools `toolchain` picks |
| `toolchain` | `node`; Node from `.nvmrc` and the npm store. `go` gives Go from `go.mod` and go-ci's caches, read-only |
| `runner` | `ubuntu-latest`; a `go` caller passes `ubuntu-26.04-arm` |
| `build-args` | none; newline `KEY=VALUE` |
| `version` | none; use this string instead of the integer counter |
| `create-release` | `true`; `false` when the caller publishes more artifacts and tags itself |
| `moving-tags` | `false`; `true` also tags `1.2` and `1` for version `1.2.3` |
| `tag-suffix` | none; `-tesseract` tags `1.2.3-tesseract` and `tesseract`, and with `moving-tags` also `1.2-tesseract` and `1-tesseract` |

Every release moves `latest`, or the bare suffix with `tag-suffix`. Call the workflow from one branch only.
Two calls with different `tag-suffix` values publish two images of one release, for example a full and a slim one.

#### Go binaries built on the runner

With `toolchain: go`, the `build-command` compiles on the runner from go-ci's warm caches. The
Dockerfile only COPYs the binaries. A compile inside the Dockerfile starts from empty cache mounts
on every release.

```yaml
jobs:
  build-push:
    uses: yama6a/gha/.github/workflows/docker-build-release.yaml@v2
    with:
      dockerfile: .build/Dockerfile
      runner: ubuntu-26.04-arm
      toolchain: go
      build-command: make dist
```

```dockerfile
FROM gcr.io/distroless/static:nonroot@sha256:<digest>
ARG TARGETARCH
COPY dist/linux-${TARGETARCH}/myapp /myapp
```

- Pass `runner: ubuntu-26.04-arm`. The cache key holds the runner arch, and go-ci runs on that
  runner.
- Compile each arch with exactly `CGO_ENABLED=0 GOOS=linux GOARCH=<arch> go build -trimpath`.
  go-ci fills the cache with these flags, and any other compile flag misses it. `-ldflags` only
  changes the link step, so `-ldflags='-s -w'` still hits.
- Write `dist/linux-<arch>/<binary>` for every arch in `platforms`.
- The cache is read-only here. The caller fills it with go-ci's weekly `warm-cache` mode, as the
  `go-ci.yaml` section shows.
- A Dockerfile whose target stage only COPYs needs no QEMU on the arm runner. A `RUN` in the
  amd64 stage runs under emulation.

### `docker-build-check.yaml`

The PR check for an image: hadolint, a build for every platform without a push, and an optional
smoke test against the image built for the runner. It needs only `contents: read`, so a PR caller
grants nothing more. The context is `docker / docker`.

```yaml
jobs:
  docker:
    uses: yama6a/gha/.github/workflows/docker-build-check.yaml@v2
    with:
      dockerfile: .build/Dockerfile
      smoke-test: docker run --rm "$IMAGE" --version
```

| input | default |
|---|---|
| `dockerfile` | `Dockerfile` |
| `context` | `.` |
| `platforms` | `linux/amd64,linux/arm64` |
| `build-args` | none; newline `KEY=VALUE` |
| `smoke-test` | none; a shell command, `$IMAGE` names the loaded image |

### `docker-build-release-multiarch.yaml`

Same result, one native runner per architecture, for a build that cannot run under QEMU. Same
caller permissions. Inputs: `dockerfile`, `context`, `build-args`, `version`, and `platforms` as a
JSON array of `{platform, runner}` (default amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`).
Every release also moves `latest`. `registry-cache: true` keeps a layer cache per architecture in
the image's GHCR package, under the tag `buildcache-<os>-<arch>`.

### `image-scan.yaml`

Trivy over released images, apart from the build. A new CVE fails this run, and the
GitHub Actions workflow failed alert fires for `image-scan.yaml`. The deploy has already run.
The caller starts it in a workflow of its own, after its build workflow passed on the default branch:

```yaml
name: image-scan

on:
  workflow_run:  # zizmor: ignore[dangerous-triggers] the build runs on push to main only, and the scan checks out main
    workflows: [build-and-push]
    types: [completed]
    branches: [main]

permissions: {}

jobs:
  scan:
    if: github.event.workflow_run.conclusion == 'success'
    uses: yama6a/gha/.github/workflows/image-scan.yaml@v2
    permissions:
      contents: read  # reads .trivyignore of a private repo
      packages: read  # pulls a private image
```

The workflow scans every platform in each tag's manifest list in one job named `scan`.
The job fails after it has scanned every target, and it lists the failing targets in its log and job summary.
It reads `.trivyignore` from the default branch. A failed run reruns with `gh run rerun <id> --failed`.

| input | default |
|---|---|
| `tags` | `latest`; space- or newline-separated tags of `ghcr.io/<repo>`, for example `latest whisper` for a release with `tag-suffix: -whisper` |
| `skip-dirs` | none; comma-separated image paths Trivy skips |

### `go-release.yaml`

Semver tag and GitHub release for a Go library on every merge to main. The bump comes from the
merged PR's labels: `release:major`, `release:minor`, else patch. A HEAD that already carries a
`v*` tag is skipped, so a rerun is safe. Outputs `version`.

```yaml
on:
  push:
    branches: [main]

concurrency:
  group: release
  cancel-in-progress: false

permissions:
  contents: write

jobs:
  go-release:
    uses: yama6a/gha/.github/workflows/go-release.yaml@v2
```

| input | default |
|---|---|
| `initial-version` | `v0.1.0`; the tag created when the repo has none |

### `php-release.yaml`

Semver tag and GitHub release on every merge to the default branch, with notes from
`gh release create --generate-notes`. The bump comes from the labels of every PR merged since the
last release tag: `major`, `minor`, `patch`, and the strongest one wins. `skip-release` or no label
releases nothing, unless another PR in the same range asks for a release. The first release counts
up from `0.0.0`. A rerun finds no new PR since the tag and does nothing. Outputs `version` and `tag`,
both empty when no release is due.

```yaml
on:
  push:
    branches: [main]

concurrency:
  group: release
  cancel-in-progress: false

permissions:
  contents: write

jobs:
  release:
    uses: yama6a/gha/.github/workflows/php-release.yaml@v2
```

| input | default |
|---|---|
| `tag-prefix` | none; tags are bare `1.2.3`, which Packagist reads. `v` gives `v1.2.3` |
| `create-release` | `true`; `false` only computes `version` and `tag` |

With `create-release: false` the caller builds its artifacts first and tags last, so a failed
build leaves no release behind:

```yaml
jobs:
  version:
    uses: yama6a/gha/.github/workflows/php-release.yaml@v2
    with:
      create-release: false

  publish:
    needs: version
    if: needs.version.outputs.tag != ''
    runs-on: ubuntu-26.04-arm
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
      - run: make phar VERSION="${{ needs.version.outputs.version }}"
      - env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ needs.version.outputs.tag }}
        run: gh release create "$TAG" --target "$GITHUB_SHA" --title "$TAG" --generate-notes build/app.phar
```

The labels come from the PR, so every PR carries exactly one of them. The `actions/release-label`
check enforces that, and a repo that uses it sets `labels: ["patch"]` in its `renovate.json5`.

### `deploy-gitops.yaml`

Bumps an image tag in a GitOps repo's `values.yaml`, opens a PR, arms auto-merge. Caller example
above. Needs a `DEPLOY_TOKEN` secret with write access to the target repo.

| input | default |
|---|---|
| `tag` | required |
| `values-path` | required; one path per line bumps several charts in one PR |
| `target-repo` | `yama6a/offgrid-private` |
| `target-branch` | `main` |

### `renovate.yaml`

Self-hosted Renovate with a cross-run cache, then a Copilot BC check on every open PR labelled
`dep-major` or `dep-swap` whose head has no verdict yet. The caller is `templates/renovate.yaml`, applied by
`scripts/rollout-renovate-caller.sh`.

```yaml
on:
  schedule:
    - cron: "13 5 * * *"
  workflow_dispatch:
    inputs:
      logLevel: { default: info, type: choice, options: [info, debug] }
      dryRun: { default: false, type: boolean }

jobs:
  renovate:
    uses: yama6a/gha/.github/workflows/renovate.yaml@v2
    permissions:
      contents: read
      copilot-requests: write
    with:
      log-level: ${{ inputs.logLevel || 'info' }}
      dry-run: ${{ inputs.dryRun || false }}
      # allowed-commands: '["^find \. -name Chart\.lock -exec sed -i "]'
    secrets:
      RENOVATE_TOKEN: ${{ secrets.RENOVATE_TOKEN }}
```

`RENOVATE_TOKEN` is a PAT: `GITHUB_TOKEN` cannot open PRs that trigger workflows, and a merge it
performs triggers no push workflows either. Copilot CLI is the one thing on `GITHUB_TOKEN`, which
is what `copilot-requests: write` is for; the credits bill to the repo owner's Copilot seat.

The BC check (`actions/renovate-bc-check`) asks Copilot CLI for silent behavior changes, ignoring
what the compiler catches. For a `dep-major` it reads the tag diff first and the changelog second.
For a `dep-swap` it resolves both packages to code and classifies the swap (rename, wrapper, fork,
unrelated), which decides what gets diffed; a wrapper's own layer counts, not only the package it
wraps, and inner-version drift the old package already carries on its default branch does not.
Either way Copilot lists every difference before judging any, then for each one traces the
upstream PR or issue behind it, names what the repo would have to rely on for the change to bite,
and checks whether that condition (registry, platform, input value) exists in the repo; a change
whose trigger is absent does not count. The review lands as a PR comment with one of the labels
`bc-safe`, `bc-breaking`, `bc-unknown`. `bc-safe` arms auto-merge; the other two leave the PR for
a human. A verdict is tied to the PR head, so a rebase gets a fresh check and an unchanged PR is
never re-billed, also on a job re-run.

Prompt shape follows two published findings. Changelog-only review misses behavior changes that a
source diff plus call-site check catches ([arXiv 2510.03480](https://arxiv.org/abs/2510.03480)),
so the diff is primary. An agent that judges as it reads drops findings between reading and
writing, so it must inventory first and keep the go/no-go rule in deterministic code
([EdgeBit](https://edgebit.io/blog/automated-dependency-updates-with-ai/)); here that rule is the
label, the nonce and required checks.

## Renovate presets

| preset | extends | contents |
|---|---|---|
| `default.json5` | `github>yama6a/gha:default.json5` | `config:recommended`, dashboard, digest pinning, grouped non-majors on native auto-merge, lock file maintenance on every run, majors labelled `dep-major` and replacements `dep-swap`, neither auto-merged |
| `go.json5` | `github>yama6a/gha:go.json5` | `gomodTidy`, import-path rewrites, `go` directive bumps, strict constraints |
| `node.json5` | `github>yama6a/gha:node.json5` | vite, eslint and node major groups, typescript below 7, `engines` ignored, `allow-remote=all` for npm 12 |
| `php.json5` | `github>yama6a/gha:php.json5` | the `php` constraint in `composer.json` left alone |

```json5
{
  $schema: "https://docs.renovatebot.com/renovate-schema.json",
  extends: ["github>yama6a/gha:default.json5", "github>yama6a/gha:go.json5"],
  packageRules: [],  // only what is specific to this repo
}
```

Spell the filename out; the bare `github>yama6a/gha` form looks for `default.json`. Presets are
not tag-pinned: an edit reaches every repo on its next run, so dry-run a consumer first.

## Composite actions

Each is a step after `actions/checkout`.

### `actions/shell-checks`

Pinned shellcheck 0.10.0 and `shfmt -d -i 2 -ci -bn -sr`. Policy lives in the repo's `.shellcheckrc`.

```yaml
- uses: yama6a/gha/.github/actions/shell-checks@v2
  # with:
  #   paths: lib/shell/*.sh   # default discovers *.sh and bash-shebang files
```

### `actions/yaml-checks`

yamllint with this repo's `.yamllint.yml` (a local one wins, and replaces it wholesale),
actionlint, then `actions/workflow-security`. No inputs.

```yaml
- uses: yama6a/gha/.github/actions/yaml-checks@v2
```

### `actions/hadolint`

Pinned hadolint 2.15.1 with this repo's `.hadolint.yaml` unless the repo has its own. Every docker
workflow already runs it. When the download from GitHub fails three times in about a minute, the
action skips the lint with a warning, so a GitHub outage does not stop a release. A hadolint
finding still fails the step.

```yaml
- uses: yama6a/gha/.github/actions/hadolint@v2
  # with:
  #   dockerfiles: .build/Dockerfile   # default discovers Dockerfile* recursively
```

### `actions/trivy-scan`

Pinned Trivy over one image, or over a list of image and platform pairs. It fails on HIGH and CRITICAL findings that have a fixed version.
The binary is cached in the Actions cache. The download of the binary from GitHub and of the
vulnerability database each get three tries in about a minute. When either still fails, the action
skips the scan with a warning. The database downloads once, however many targets there are.
The action scans every target even after one fails, then fails and lists the failing targets in the log
and in the job summary. `image-scan.yaml` runs it.
Renovate bumps `TRIVY_VERSION` in the action.

A caller can accept a finding in `.trivyignore` at the repo root, one CVE id per line with the
reason after a `#`. Use it only when no released package or base image clears the finding.

For a private image, log in with `docker/login-action` earlier in the same job. Trivy reads that
login from the Docker config and sends it only to the registry it belongs to. Do not set
`TRIVY_USERNAME` and `TRIVY_PASSWORD`: Trivy sends those to every registry it contacts, and that
includes the `mirror.gcr.io` copy of its vulnerability database.

```yaml
- uses: docker/login-action@8aa5831fb8d48d8f76594c7ddde61ae58019f550  # v4.8.0, only for a private image
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
- uses: yama6a/gha/.github/actions/trivy-scan@v2
  with:
    image-ref: ghcr.io/owner/repo:1
```

| input | default |
|---|---|
| `image-ref` | none; one image by tag or digest. Set this or `targets` |
| `targets` | none; newline-separated lines of `<image-ref> <platform>`, for example `ghcr.io/owner/repo:1 linux/arm64` |
| `skip-dirs` | none; comma-separated image paths Trivy skips |

### `actions/workflow-security`

Checks the workflows and composite actions under `.github` for token and credential scope. It only
warns today, so it never fails a check. A later change makes it fail on a finding.
`actions/yaml-checks`, `go-ci.yaml` and `node-ci.yaml` run it, so a repo that uses one of them
needs nothing more. No inputs.

- zizmor, pinned in `ZIZMOR_VERSION` and bumped by Renovate, runs offline with the shared
  `zizmor.yml`. Every finding of its regular persona becomes a warning. Examples are a checkout
  that keeps its credential (`artipacked`) and permissions wider than the job needs
  (`excessive-permissions`).
- `token-scope.sh` warns where `GITHUB_TOKEN` sits in workflow-level or job-level `env:`, or goes
  to the `with:`, `env:` or `secrets:` of a third-party action or reusable workflow. A third-party
  action is one outside `actions/` and `yama6a/`. `docker/login-action` may get it as `password`.

To silence one zizmor finding, put `# zizmor: ignore[<audit>]` on the flagged line, with the reason
after it. In a `run: |` block a `#` line is shell, not YAML, so the comment goes after `run: |`. The
config is shared and a repo cannot override it.

```yaml
- uses: yama6a/gha/.github/actions/workflow-security@v2
```

### `actions/kubeconform`

Pinned kubeconform. With `paths` it validates them; without, it only installs and exports the
resolved flags as `KUBECONFORM_ARGS` for a caller that pipes rendered YAML in.

```yaml
- uses: yama6a/gha/.github/actions/kubeconform@v2
  with:
    paths: lib/k8s/*.yaml
```

| input | default |
|---|---|
| `version` | `v0.6.7` |
| `paths` | none; paths and globs, separated by whitespace |
| `strict` | `true` |
| `ignore-missing-schemas` | `true` |
| `crd-catalog` | `true`; adds the datreeio CRDs catalog |
| `parallelism` | kubeconform's default; a whole number |

### `actions/helm-chart-checks`

Per chart: dependency build, `helm lint`, `helm unittest` when `tests/` exists, `helm template`
piped to kubeconform, optional schema and README drift checks.

```yaml
- uses: yama6a/gha/.github/actions/helm-chart-checks@v2
  with:
    charts: |
      lib/helm/pg-cluster
      lib/helm/redis-instance
    values: |
      lib/helm/pg-cluster=lib/helm/pg-cluster/ci/values.yaml
```

| input | default |
|---|---|
| `charts` | required; one per line |
| `helm-version` | `v4.3.0` |
| `api-versions` | `monitoring.coreos.com/v1` |
| `values` | none; `<chart>=<values file>` lines, for charts that `fail` without values |
| `schema` | `off`; `check` regenerates `values.schema.json` and fails on drift |
| `docs` | `off`; `check` regenerates the README with helm-docs and fails on drift |

### `actions/docker-build`

`docker buildx build` with the flags `docker/build-push-action` passes for the same inputs. A
registry rate limit or 5xx gets one more try after 5 s, which pulls of public base images need.
Any other error fails at once. Needs `docker/setup-buildx-action` first. The shared docker
workflows build through it.

```yaml
- uses: yama6a/gha/.github/actions/docker-build@v2
  with:
    platforms: linux/amd64,linux/arm64
    push: true
    tags: ghcr.io/owner/repo:1
```

| input | default |
|---|---|
| `context` | `.` |
| `file` | none; `Dockerfile` in the context |
| `platforms` | none; the builder's platform |
| `build-args`, `tags`, `outputs` | none; one value per line |
| `push`, `load` | `false` |
| `provenance` | none; like `docker/build-push-action`, `mode=max` in a public repo, `mode=min,inline-only=true` in a private one, none on `load` |
| `sbom` | none; `true` adds an SBOM attestation |
| `hide-path` | none; a workspace path moved out of the build context during the build |

Output `digest`, empty when nothing was pushed. The build summary and the build record artifact
of `docker/build-push-action` do not exist here.

### `actions/gh-release`

`gh release create` with up to three tries on an HTTP 5xx, 5 s and 15 s apart. A failed create
can leave a draft or even the finished release behind. Before each retry the action deletes the
drafts with the same title and target that did not exist before the first try. When the release
exists after all, it uploads only the missing files. The shared release workflows create their releases through it.

```yaml
- uses: yama6a/gha/.github/actions/gh-release@v2
  with:
    tag: ${{ needs.version.outputs.tag }}
    target: ${{ github.sha }}
    generate-notes: 'true'
    files: |
      app.phar
```

| input | default |
|---|---|
| `tag` | required |
| `target` | required; a commit SHA or branch |
| `title` | the tag |
| `notes` | none; with `generate-notes` they come first |
| `generate-notes` | `false` |
| `files` | none; one path per line |
| `repo` | the repo the workflow runs in |
| `token` | `github.token` |

### `actions/release-label`

Fails a PR that does not carry exactly one of the labels `major`, `minor`, `patch`,
`skip-release`, which `php-release.yaml` reads. No checkout needed. Keep the job name
`release label`, which is the required context. Run it only on `pull_request`: a push carries
no labels. Add `labeled` and `unlabeled` to the PR trigger types, so a label change re-runs it.

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]

jobs:
  release-label:
    name: release label
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-26.04-arm
    steps:
      - uses: yama6a/gha/.github/actions/release-label@v2
```

### `actions/validate-renovate-config`

Pinned `renovate-config-validator --strict`. go-ci, node-ci and php-ci run it as a step with no
inputs, so a caller needs no `renovate-config` job. On `pull_request` and `push` it first diffs the
changed files and skips the validator (the step, not the job, so a required `renovate-config`
check still reports green) unless a config file changed. Every other event validates.
The diff base is the pull request's base commit, or the push's `before` commit. A push that
creates a branch or tag has no `before`, so it validates.

The action fetches the diff base itself with the job token, so a shallow checkout with
`persist-credentials: false` works, also in a private repo. The job needs `contents: read`.

A job that checks this action out and runs it by local path, as go-ci and php-ci do, must keep
that folder until the job ends. The runner reads the action's `action.yaml` again for the post
step of `actions/setup-node`, and fails the job when the file is gone.

```yaml
- uses: yama6a/gha/.github/actions/validate-renovate-config@v2
  # with:
  #   config-file: renovate.json5   # default auto-discovers, see below
  #   extra-paths: |                # globs that also trigger the validation
  #     .github/renovate/**
```

| input | default |
|---|---|
| `config-file` | none; validator auto-discovery. The change filter then watches `renovate.json{,5}`, `.github/renovate.json{,5}`, `.gitlab/renovate.json{,5}` and `.renovaterc{,.json,.json5}`, not `package.json` |
| `extra-paths` | none; one glob per line |

## Scripts

### `scripts/retry.sh`

Sourced by the shared workflows and actions. `retry_run PATTERN WAITS COMMAND...` tries again
only when the failed command's output matches `PATTERN`, so a real error fails on the first try.

Every tool download from GitHub goes through `retry_release_download REPO TAG DIR ASSET...`. It
runs `gh release download` with the job token in `GH_TOKEN`, and gives any failure three tries in
about a minute. `gh` sends the token to the GitHub API only, not to the host a download redirects
to. `GITHUB_TOKEN` can read public releases of any owner, also with only `contents: read`.

| pattern | matches | used by |
|---|---|---|
| `RETRY_RATE_LIMIT` | `toomanyrequests`, `429 Too Many Requests`, `Rate exceeded` | `actions/docker-build` |
| `RETRY_REGISTRY_5XX` | `500 Internal Server Error` to `504 Gateway Timeout` | `actions/docker-build` |
| `RETRY_GH_5XX` | `HTTP 5xx` from gh | `gh` calls in the release workflows, `actions/gh-release` |
| `RETRY_NETWORK` | `curl error`, `HTTP/2 5xx`, a bare 500 to 504, `timed out` | `composer install` and `composer audit` in `php-ci.yaml` |

`scripts/retry_test.sh` checks the patterns against the logs in `.github/testdata/retry` and
runs `actions/gh-release` and `actions/docker-build` against a fake gh and docker.

### `scripts/repo-settings.sh`

Applies merge, security and branch-protection settings to every repo from the table at the top of
the script. Needs `jq` and `gh` as a repo admin.

```bash
scripts/repo-settings.sh --dry-run   # print every call
scripts/repo-settings.sh             # apply, idempotent
scripts/repo-settings.sh --verify    # intended vs actual, exit 1 on mismatch
```

### `scripts/rollout-renovate-caller.sh`

Renders `templates/renovate.yaml` per repo from the table at the top of the script and, where the
repo's `.github/workflows/renovate.yaml` differs, opens an auto-merged PR with the rendered file.
Same flags as `repo-settings.sh`.

## Templates

`templates/Makefile.go`: the Go Makefile every Go repo copies. `make lint` fetches the canonical
lint config and merges `.golangci.local.yaml` the same way CI does.

`templates/renovate.yaml`: the Renovate caller every repo runs. `__ALLOWED_COMMANDS__` is the line
the rollout script fills in or drops.
