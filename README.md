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

No inputs. Every check below runs on every call.

```yaml
jobs:
  go:
    uses: yama6a/gha/.github/workflows/go-ci.yaml@v2
```

Job id `go`, job name `go`, so the required-check context to pin branch protection to is
`go / go`.

| step | command |
|---|---|
| tidy check | `go mod tidy`, then `git diff --exit-code -- go.mod go.sum` |
| generate check | `go generate ./...`, then the whole worktree must be unchanged and free of new files |
| lint | `golangci-lint run --timeout 5m -c <merged config> ./...` |
| fmt check | `golangci-lint fmt --diff -c <merged config>` |
| vet | `go vet ./...` |
| test | `go test ./... -race -count=1 -coverprofile=cover.out`, then the coverage total |
| vuln | `go run golang.org/x/vuln/cmd/govulncheck@latest ./...` |
| cross-compile | `CGO_ENABLED=0 go build ./...` for linux/amd64 and linux/arm64 |

Tidy runs before generate: a generator invoked with `go run -mod=mod` can edit go.mod, and the
tidy check would then blame the wrong thing.

The generate check exists because generated code is not rebuilt at build time. A stale
committed copy compiles green and ships the wrong contract. A repo with no `//go:generate`
directives is a no-op.

#### Lint config

`.golangci.yaml` at the root of this repo is the only one. A calling repo **must delete its
own** `.golangci.yaml` or the workflow fails with an explicit error. The workflow checks this
repo out at the reusable workflow's own commit, so a caller pinned to `@v2` gets the v2
config, not main's.

Repo-specific additions go in `.golangci.local.yaml` at the caller's root, merged over the
canonical file with:

```sh
yq eval-all '. as $item ireduce ({}; . *+ $item)' .golangci.yaml .golangci.local.yaml
```

`*+` appends arrays, so the local file lists only what it adds. Copying a whole list into it
produces the canonical entries plus yours.

codarr, whose JSON is snake_case upstream and whose `fsx` package returns its own interfaces:

```yaml
# .golangci.local.yaml
version: "2"
linters:
  settings:
    tagliatelle:
      case:
        rules:
          json: snake
    ireturn:
      allow:
        - io.ReadSeekCloser
        # fsx defines WriteSyncCloser, so every implementation of fsx.FS,
        # including the test doubles, has to return it.
        - fsx.WriteSyncCloser
  exclusions:
    rules:
      # A constructor returning its own package's interface is the boundary pattern.
      - path: internal/pkg/(clock|fsx|events)/
        linters:
          - ireturn
      # The policy constants are deliberately package-level.
      - path: internal/decide/policy\.go
        linters:
          - gochecknoglobals
```

bolan-api, which carries a `replace` directive:

```yaml
# .golangci.local.yaml
version: "2"
linters:
  settings:
    gomoddirectives:
      replace-allow-list:
        - github.com/ledongthuc/pdf
```

#### Makefile

The same config drives `make lint` and CI, so the two cannot disagree. `lint-config` refetches
on every run; drop it as a prerequisite if you want to lint offline. Add `.build/` to
`.gitignore`.

```make
GO_LINT_CONFIG     ?= .build/golangci.yaml
CANONICAL_LINT_URL := https://raw.githubusercontent.com/yama6a/gha/v2/.golangci.yaml
IMAGE              ?= ghcr.io/yama6a/myapp

.PHONY: lint-config generate fmt fmt-check lint vet test cover vuln tidy tidy-check \
	generate-check mod image ci

lint-config:
	mkdir -p .build
	curl -fsSL $(CANONICAL_LINT_URL) -o .build/canonical-golangci.yaml
	if [ -f .golangci.local.yaml ]; then \
		yq eval-all '. as $$item ireduce ({}; . *+ $$item)' \
			.build/canonical-golangci.yaml .golangci.local.yaml > $(GO_LINT_CONFIG); \
	else \
		cp .build/canonical-golangci.yaml $(GO_LINT_CONFIG); \
	fi

generate:
	go generate ./...

fmt: lint-config
	golangci-lint fmt -c $(GO_LINT_CONFIG)

fmt-check: lint-config
	golangci-lint fmt --diff -c $(GO_LINT_CONFIG)

lint: lint-config
	golangci-lint run ./... -c $(GO_LINT_CONFIG)

vet:
	go vet ./...

test:
	go test ./... -race -count=1

cover:
	go test ./... -coverprofile=cover.out -covermode=atomic
	go tool cover -func=cover.out | tail -1

vuln:
	go run golang.org/x/vuln/cmd/govulncheck@latest ./...

tidy:
	go mod tidy

tidy-check:
	go mod tidy
	git diff --exit-code -- go.mod go.sum

generate-check: generate
	git diff --exit-code

mod:
	go get -u -t ./...
	go mod tidy

image:
	docker buildx build -f .build/Dockerfile -t $(IMAGE) --load .

ci: tidy-check generate-check fmt-check lint vet test vuln
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
