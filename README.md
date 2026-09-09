# gha

Shared GitHub Actions workflows and composite actions for yama6a repos. Pin every reference
to a tagged release (`@v1`), not `@main`.

## Reusable workflows

### `renovate.yaml`

Self-hosted Renovate runner with cross-run caching. The caller repo still needs its own thin
workflow file to own the triggers (`schedule`, `workflow_dispatch`, `push`).

```yaml
# .github/workflows/renovate.yaml
name: Renovate
on:
  schedule:
    - cron: "17 */3 * * *"
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

concurrency:
  group: renovate
  cancel-in-progress: false

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
jobs:
  build-push:
    uses: yama6a/gha/.github/workflows/docker-build-release.yaml@v1
    with:
      dockerfile: .build/Dockerfile   # default: Dockerfile
      # build-command: npm ci && npm run build
      # node-version: '24'
```

Needs `contents: write` and `packages: write` available to the caller's `GITHUB_TOKEN`
(repo Settings > Actions > General > Workflow permissions).

Does not cover bolan-fe's split-runner, digest-merge multi-arch build (needed there because
`next build` dies under QEMU emulation) - that one stays repo-local.

### `go-ci.yaml`

golangci-lint, go vet, go test, govulncheck.

```yaml
jobs:
  ci:
    uses: yama6a/gha/.github/workflows/go-ci.yaml@v1
    with:
      tidy-check: true
      race: true
      coverage: true
```

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
