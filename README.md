# gha

Shared GitHub Actions workflows and composite actions for yama6a repos. Pin every reference
to a tagged release (`@v1`), not `@main`.

This repo also hosts the shared Renovate presets, which are referenced by content rather than
by tag. See [Renovate presets](#renovate-presets).

## Reusable workflows

### `renovate.yaml`

Self-hosted Renovate runner with cross-run caching. The caller repo still needs its own thin
workflow file to own the triggers (`schedule`, `workflow_dispatch`, `push`).

```yaml
# .github/workflows/renovate.yaml
name: Renovate
on:
  schedule:
    - cron: "13 5 * * *"  # opens PRs
    - cron: "43 5 * * *"  # merges the ones whose CI went green
  workflow_dispatch:
    inputs:
      logLevel:
        default: info
        type: choice
        options: [info, debug]
      dryRun:
        default: false
        type: boolean
  push:
    branches: [main]
    paths: [renovate.json5, .github/workflows/renovate.yaml]

jobs:
  renovate:
    uses: yama6a/gha/.github/workflows/renovate.yaml@v1
    with:
      log-level: ${{ inputs.logLevel || 'info' }}
      dry-run: ${{ inputs.dryRun || false }}
      # allowed-commands: '["^find \. -name Chart\.lock -exec sed -i "]'
    secrets:
      RENOVATE_TOKEN: ${{ secrets.RENOVATE_TOKEN }}
```

Requires a `RENOVATE_TOKEN` secret (a PAT, not `GITHUB_TOKEN`, since it needs to open PRs that
re-trigger workflows).

### `deploy-gitops.yaml`

Bumps an image tag in a GitOps repo's `values.yaml`, opens a PR, arms automerge. Call it as a
job that needs the build job's output tag.

```yaml
jobs:
  build-push:
    uses: yama6a/gha/.github/workflows/docker-build-release.yaml@v1
    # ...

  deploy:
    needs: build-push
    uses: yama6a/gha/.github/workflows/deploy-gitops.yaml@v1
    with:
      tag: ${{ needs.build-push.outputs.version }}
      values-path: argo_apps/workloads/charts/myapp/values.yaml
      # values-path: |                        # one image pinned by several charts: one PR bumps them all
      #   argo_apps/workloads/charts/myapp-a/values.yaml
      #   argo_apps/workloads/charts/myapp-b/values.yaml
      # target-repo: yama6a/offgrid-private   # default
    secrets:
      DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

Requires a `DEPLOY_TOKEN` secret with write access to the target repo.

### `docker-build-release.yaml`

Determines the next integer release version, optionally runs a build command (for a static
site or SPA the Dockerfile only `COPY`s), builds and pushes a multi-arch image to GHCR, tags a
GitHub release. Outputs `version` for a following `deploy-gitops.yaml` call.

```yaml
# A reusable workflow's jobs can request only what the caller grants here.
permissions:
  contents: write
  packages: write

jobs:
  build-push:
    uses: yama6a/gha/.github/workflows/docker-build-release.yaml@v1
    with:
      dockerfile: .build/Dockerfile   # default: Dockerfile
      # build-command: npm ci && npm run build
      # node-version: '24'
      # package-manager: pnpm   # default: npm; only affects which setup-node cache/lockfile it looks for
```

Does not cover a build that cannot run under QEMU (e.g. `next build`, which SIGILLs under
emulation) - use `docker-build-release-multiarch.yaml` for that.

### `docker-build-release-multiarch.yaml`

Same job as above, but each platform builds on its own native runner and the resulting images
are joined into one manifest list. Use when the build cannot run under QEMU emulation.

```yaml
# A reusable workflow's jobs can request only what the caller grants here.
permissions:
  contents: write
  packages: write

jobs:
  build-push:
    uses: yama6a/gha/.github/workflows/docker-build-release-multiarch.yaml@v1
    with:
      build-args: |
        NEXT_PUBLIC_API_URL_CLIENT=https://api.example.com
      # platforms: >-
      #   [{"platform":"linux/amd64","runner":"ubuntu-latest"},
      #    {"platform":"linux/arm64","runner":"ubuntu-24.04-arm"}]   # default
```

### `go-ci.yaml`

golangci-lint, go vet, go test, govulncheck. The job is named `go`, so that is the
required-check context a caller pins branch protection to.

```yaml
jobs:
  go:
    uses: yama6a/gha/.github/workflows/go-ci.yaml@v1
    with:
      tidy-check: true
      race: true
      coverage: true
      # fmt-check: true          # golangci-lint fmt --diff; `run` does not enforce formatters
      # test-args: -count=1      # go test otherwise serves cached results from the restored GOCACHE
      # cross-compile: |         # for a repo whose release is a manifest list
      #   linux/amd64
      #   linux/arm64
```

### `node-ci.yaml`

Generate drift, lint, format, typecheck, test, audit, build. Job id `check`, job name `node` -
`node` is the required-check context to pin branch protection to.

```yaml
jobs:
  node:
    uses: yama6a/gha/.github/workflows/node-ci.yaml@v2
    # with:
    #   working-directory: web           # frontend not at the repo root
    #   runner: ubuntu-24.04             # default: ubuntu-24.04-arm
    #   build-env: |
    #     NEXT_PUBLIC_USE_MOCK_DATA=true
```

| input | default | meaning |
|---|---|---|
| `working-directory` | `.` | where `package.json`, `package-lock.json` and `.nvmrc` live |
| `build-env` | `''` | newline `KEY=VALUE` pairs, exported before the build step only |
| `runner` | `ubuntu-24.04-arm` | |

No toggles. Every project defines all six scripts; one that has nothing to do for a step defines
it as `"exit 0"`, so the gap sits in `package.json` where a reader sees it.

| script | what CI does with it |
|---|---|
| `generate` | runs it, then `git diff --exit-code` from the repo root; a dirty tree fails the job |
| `lint` | eslint, with any repo-specific checks chained in (see below) |
| `format:check` | `prettier --check .` |
| `typecheck` | `tsc --noEmit` |
| `test` | unit tests |
| `build` | production build, after `build-env` is exported |

`.nvmrc` is required (`24`), in `working-directory`. It is the only place the Node version is
written: `setup-node` reads it, the Dockerfile reads it, and the `engines` field is left to
Renovate's ignore rule in `node.json5`.

Repo-specific checks chain into `lint` rather than becoming their own job:

```json
"lint": "eslint && npm run lint:raw-colors && npm run lint:translations",
"lint:raw-colors": "! grep -rn --include='*.tsx' -E '#[0-9a-fA-F]{3,8}' src/components/ui/",
```

Every project copies this `.prettierrc.json`:

```json
{
  "printWidth": 100,
  "singleQuote": true,
  "overrides": [
    { "files": ["*.html", "*.css", "*.json", "*.json5", "*.yaml", "*.yml"], "options": { "singleQuote": false } }
  ]
}
```

`.prettierignore` must list `package-lock.json` and every generated output dir. Prettier
reformats generated files otherwise, and the `generate` drift check then fails on every run.

### `playwright-e2e.yaml`

Builds once, uploads the build, runs the suite sharded across parallel runners. Job id `gate`,
job name `e2e` - that is the required check; the per-shard jobs are not, so `shard-total` can
change without stranding a context.

```yaml
jobs:
  e2e:
    uses: yama6a/gha/.github/workflows/playwright-e2e.yaml@v2
    with:
      build-env: |
        NEXT_PUBLIC_USE_MOCK_DATA=true
      # shard-total: 4
      # browser: chromium
      # working-directory: web
      # build-artifact-paths: |          # default is the three .next lines
      #   dist
```

| input | default | meaning |
|---|---|---|
| `shard-total` | `4` | parallel shards |
| `runner` | `ubuntu-24.04-arm` | must match the warm-cache caller, the cache key includes `runner.arch` |
| `working-directory` | `.` | where `package.json` lives |
| `build-env` | `''` | newline `KEY=VALUE` pairs, exported before the build step only |
| `build-artifact-paths` | `.next`, `!.next/cache`, `!.next/standalone` | `upload-artifact` paths, relative to the repo root; the first non-`!` line is where the shards download it back to |
| `browser` | `chromium` | |
| `warm-cache` | `false` | run only the cache-warming job |

`playwright.config.ts` starts the built app itself (`webServer`), so the shards serve the
downloaded artifact instead of rebuilding. Set `workers: 2` in CI: a worker drives a whole
Chromium and they all share one server.

A cache written on a PR is restorable only by that same PR, so PRs never share one. A cache
written on the default branch is restorable by all of them, which is what the second caller is
for:

```yaml
# .github/workflows/warm-cache.yaml
name: warm-cache

on:
  push:
    branches: [master]   # the default branch, wherever the restorable caches have to be written
    paths: ['package-lock.json']

concurrency:
  group: warm-cache
  cancel-in-progress: true

jobs:
  warm:
    uses: yama6a/gha/.github/workflows/playwright-e2e.yaml@v2
    with:
      warm-cache: true
      runner: ubuntu-24.04-arm   # same runner as the e2e caller
```

Only on a lockfile change: both caches are keyed off it (the Playwright version lives there
too), so a merge that leaves it alone leaves the existing caches valid.

## Renovate presets

Three preset files at the repo root, so a consuming repo's `renovate.json5` holds only the rules
that are actually about that repo.

| preset | extends value | contents |
|---|---|---|
| `default.json5` | `github>yama6a/gha:default.json5` | `config:recommended`, dependency dashboard, digest pinning for actions and base images, the combined non-major auto-merged PR, and auto-merged GHA majors |
| `go.json5` | `github>yama6a/gha:go.json5` | `gomodTidy` + `gomodUpdateImportPaths` |
| `node.json5` | `github>yama6a/gha:node.json5` | the vite and eslint major groupings, and the typescript 5.x hold |

```json5
{
  $schema: "https://docs.renovatebot.com/renovate-schema.json",
  extends: [
    "github>yama6a/gha:default.json5",
    "github>yama6a/gha:node.json5", // or :go.json5, or both
  ],
  packageRules: [
    // only what is specific to this repo; these append after the preset's and win on any key they set
  ],
}
```

The filename is spelled out in every reference. The bare `github>yama6a/gha` form only ever looks
for `default.json`, and a `.json` file carrying comments is deprecated by Renovate.

References are **not** pinned to a tag, unlike the workflows above: an edit here reaches every repo
on its next Renovate run. Dry-run a consuming repo (`workflow_dispatch` with `dryRun: true`) before
merging a change to these files.

## Composite actions

### `actions/validate-renovate-config`

```yaml
- uses: yama6a/gha/.github/actions/validate-renovate-config@v1
  # with:
  #   config-file: renovate.json5
```

### `actions/yaml-checks`

yamllint + actionlint.

```yaml
- uses: yama6a/gha/.github/actions/yaml-checks@v1
  # with:
  #   yamllint-config: .yamllint.yml
```

### `actions/kubeconform`

Installs a pinned kubeconform and, with `paths`, validates them. Without `paths` it only
installs, and exports the resolved flags as `KUBECONFORM_ARGS` for a caller that pipes
rendered YAML in on stdin.

```yaml
- uses: yama6a/gha/.github/actions/kubeconform@v1
  with:
    paths: lib/k8s/*.yaml
    # crd-catalog: false   # core types only, skip the datreeio schema location
    # parallelism: 8

# or, install only:
- uses: yama6a/gha/.github/actions/kubeconform@v1
- run: |
    # shellcheck disable=SC2086
    helm template ./chart | kubeconform $KUBECONFORM_ARGS
```

### `actions/shellcheck`

```yaml
- uses: yama6a/gha/.github/actions/shellcheck@v1
  with:
    glob: lib/shell/*.sh
    exclude: SC2034
```

Repo-specific extras (helm/kubeconform validation, hadolint, per-app npm test suites) stay
local to each repo - only the pieces that were byte-for-byte duplicated across 3+ repos live
here.
