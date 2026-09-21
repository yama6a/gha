# gha

Shared GitHub Actions workflows, composite actions and Renovate presets for yama6a repos.
Pin every `uses:` to `@v2`. How the repos themselves are set up is in
[ORG_CONVENTIONS.md](ORG_CONVENTIONS.md).

## Reusable workflows

Required-check names follow one rule: the caller's job id is the workflow's short name, the
workflow's job carries the same `name:`, so the context is `go / go`, `node / node`, `e2e / e2e`.

### `go-ci.yaml`

No inputs. Tidy drift, generate drift, golangci-lint with the canonical `.golangci.yaml` from this
repo, fmt, vet, `go test -race -count=1` with coverage, govulncheck, cross-compile amd64 and arm64.
The module and build caches are restored on every run and saved only from runs that are not a
`pull_request`, so keep the caller's `push: branches: [main]` trigger.

```yaml
jobs:
  go:
    uses: yama6a/gha/.github/workflows/go-ci.yaml@v2
```

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
`format:check`, `typecheck`, `test`, `npm audit --audit-level=high`, `build`. Node version from
`.nvmrc`. Every script must exist; `"exit 0"` where a project has nothing to do.

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
| `runner` | `ubuntu-24.04-arm` |

### `playwright-e2e.yaml`

Builds once, uploads the build, runs the suite sharded. Required check is the gate job, `e2e / e2e`;
shards are not required, so `shard-total` can change freely.

```yaml
jobs:
  e2e:
    uses: yama6a/gha/.github/workflows/playwright-e2e.yaml@v2
    with:
      build-env: |
        NEXT_PUBLIC_USE_MOCK_DATA=true
```

| input | default |
|---|---|
| `shard-total` | `4` |
| `runner` | `ubuntu-24.04-arm`; must match the warm-cache caller, the cache key includes the arch |
| `working-directory` | `.` |
| `build-env` | none |
| `build-artifact-paths` | `.next`, `!.next/cache`, `!.next/standalone`; first non-`!` line is the download target |
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
and SBOM, trivy scan (report-only), signed attestation (public repos only), GitHub release.
Outputs `version`.

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
| `build-command` | none; runs on the runner before the build, Node from `.nvmrc`, npm |
| `build-args` | none; newline `KEY=VALUE` |
| `version` | none; use this string instead of the integer counter |
| `create-release` | `true`; `false` when the caller publishes more artifacts and tags itself |

### `docker-build-release-multiarch.yaml`

Same result, one native runner per architecture, for a build that cannot run under QEMU. Same
caller permissions. Inputs: `dockerfile`, `context`, `build-args`, `version`, and `platforms` as a
JSON array of `{platform, runner}` (default amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`).

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
wraps. Either way Copilot lists every difference before judging any, then for each one traces the
upstream PR or issue behind it and checks whether the triggering condition (registry, platform,
input value) exists in the repo; a change whose trigger is absent does not count. The review lands
as a PR comment with one of the labels `bc-safe`, `bc-breaking`, `bc-unknown`. `bc-safe` arms
auto-merge; the other two leave the PR for a human. A verdict is tied to the PR head, so a rebase
gets a fresh check and an unchanged PR is never re-billed.

Prompt shape follows two published findings. Changelog-only review misses behavior changes that a
source diff plus call-site check catches ([arXiv 2510.03480](https://arxiv.org/abs/2510.03480)),
so the diff is primary. An agent that judges as it reads drops findings between reading and
writing, so it must inventory first and keep the go/no-go rule in deterministic code
([EdgeBit](https://edgebit.io/blog/automated-dependency-updates-with-ai/)); here that rule is the
label, the nonce and required checks.

## Renovate presets

| preset | extends | contents |
|---|---|---|
| `default.json5` | `github>yama6a/gha:default.json5` | `config:recommended`, dashboard, digest pinning, grouped non-majors on native auto-merge, majors labelled `dep-major` and replacements `dep-swap`, neither auto-merged |
| `go.json5` | `github>yama6a/gha:go.json5` | `gomodTidy`, import-path rewrites, `go` directive bumps, strict constraints |
| `node.json5` | `github>yama6a/gha:node.json5` | vite, eslint and node major groups, typescript below 7, `engines` ignored |

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

yamllint with this repo's `.yamllint.yml` (a local one wins, and replaces it wholesale) plus
actionlint. No inputs.

```yaml
- uses: yama6a/gha/.github/actions/yaml-checks@v2
```

### `actions/hadolint`

Pinned hadolint 2.12.0 with this repo's `.hadolint.yaml` unless the repo has its own. Both docker
workflows already run it.

```yaml
- uses: yama6a/gha/.github/actions/hadolint@v2
  # with:
  #   dockerfiles: .build/Dockerfile   # default discovers Dockerfile* recursively
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
| `paths` | none |
| `strict` | `true` |
| `ignore-missing-schemas` | `true` |
| `crd-catalog` | `true`; adds the datreeio CRDs catalog |
| `parallelism` | kubeconform's default |

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

### `actions/validate-renovate-config`

Pinned `renovate-config-validator --strict`. On `pull_request` and `push` it first diffs the
changed files and skips the validator (the step, not the job, so a required `renovate-config`
check still reports green) unless a config file changed. Every other event validates.

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
