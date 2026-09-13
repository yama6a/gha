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

Lint, typecheck, test, audit, build - on by default, so a new repo never quietly ships
without them. Disable the ones that don't apply.

```yaml
jobs:
  ci:
    uses: yama6a/gha/.github/workflows/node-ci.yaml@v1
    with:
      package-manager: pnpm   # default: npm
      # typecheck: false      # e.g. a plain-JS repo with no tsconfig
      # test: false           # e.g. a repo with no test script yet
      # build-env: |
      #   NEXT_PUBLIC_USE_MOCK_DATA=true
      # working-directory: web            # frontend not at the repo root
      # pre-check: make generate          # monorepo codegen a check depends on
```

Assumes the standard script names: `lint`, `typecheck`, `test`, `build`. A repo whose scripts
are named differently renames the script rather than adding an override here.

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

yamllint + actionlint. No inputs: it lints the whole repo against `.yamllint.yml` at this repo's root,
so a rule change lands in every repo at once.

```yaml
- uses: yama6a/gha/.github/actions/yaml-checks@v1
```

A repo keeps its own `.yamllint.yml` only to extend `ignore:` (a generated directory, a vendored tree).
That file replaces the canonical one rather than merging with it, so copy it and add the paths.

### `actions/helm-chart-checks`

Per chart: `helm dependency build` (skipped when `Chart.yaml` has no `dependencies:`), `helm lint`,
`helm unittest` when `<chart>/tests` exists, then `helm template` piped to kubeconform. One `::group::`
per chart, and every chart runs before the job fails.

| input | default | what it does |
|---|---|---|
| `charts` | required | chart directories, one per line |
| `helm-version` | `v4.3.0` | tag handed to `azure/setup-helm` |
| `api-versions` | `monitoring.coreos.com/v1` | comma-separated, passed to `helm template --api-versions`, for a chart gated on a CRD |
| `values` | none | lines of `<chart dir>=<values file>`, applied to that chart's lint and template |
| `schema` | `off` | `check` regenerates `values.schema.json` and fails if it differs from the committed one |
| `docs` | `off` | `check` regenerates the chart README with helm-docs and fails if it differs |

```yaml
- uses: yama6a/gha/.github/actions/helm-chart-checks@v1
  with:
    charts: charts/longhorn-replica-affinity
```

A shared chart whose templates `fail` on a missing required value renders to nothing on its own, so
`values` is the only way it gets linted at all. The fixture is a values file the repo keeps for CI, not
a real deployment.

```yaml
- uses: yama6a/gha/.github/actions/helm-chart-checks@v1
  with:
    charts: |
      lib/helm/ingress
      lib/helm/nfs-volume
      lib/helm/pg-cluster
      lib/helm/redis-instance
    values: |
      lib/helm/pg-cluster=.github/testdata/helm/pg-cluster.yaml
      lib/helm/redis-instance=.github/testdata/helm/redis-instance.yaml
    schema: check
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
