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

hadolint, next integer release version, an optional build command (for a static site or SPA the
Dockerfile only `COPY`s), a multi-arch image pushed to GHCR, a trivy scan, a signed provenance
attestation, a GitHub release. Outputs `version` for a following `deploy-gitops.yaml` call.

```yaml
permissions:
  contents: write      # create the GitHub release
  packages: write      # push the image
  id-token: write      # mint the OIDC token the attestation is signed with
  attestations: write  # store the attestation

jobs:
  build-push:
    uses: yama6a/gha/.github/workflows/docker-build-release.yaml@v1
    with:
      dockerfile: .build/Dockerfile   # default: Dockerfile
      # build-command: npm ci && npm run build
      # version: ${{ needs.tag.outputs.semver }}   # use this string instead of the integer counter

  deploy:
    needs: build-push
    permissions: {}   # the block above is workflow-wide; scope it back off for jobs that do not build
    uses: yama6a/gha/.github/workflows/deploy-gitops.yaml@v1
```

All four `permissions` lines are required. A reusable workflow's jobs can only request what the
caller grants, and a missing `attestations: write` surfaces three quarters of the way through
the run, after the image is already pushed.

`build-command` runs on the runner rather than in the Dockerfile, so it happens once instead of
once per target arch under emulation. Node comes from the repo's `.nvmrc` and the package
manager is npm; neither is an input.

Trivy scans a throwaway `ci-<run_id>` tag, which the release tag is then copied from with
`docker buildx imagetools create` - a two-platform QEMU build cannot `--load` a manifest list,
so there is nothing local to scan. The copy is byte-identical, so the digest that was scanned is
the digest that gets attested and released. The scan is report-only today: CRITICAL and HIGH,
fixed vulnerabilities only, printed as a table, `exit-code: '0'`. Once a repo has had a week of
output and a `.trivyignore` covering what it decides to carry, flip that one line to `'1'`.

Does not cover a build that cannot run under QEMU (e.g. `next build`, which SIGILLs under
emulation) - use `docker-build-release-multiarch.yaml` for that.

### `docker-build-release-multiarch.yaml`

Same job as above, but each platform builds on its own native runner and the resulting images
are joined into one manifest list. Use when the build cannot run under QEMU emulation.

```yaml
permissions:
  contents: write      # create the GitHub release
  packages: write      # push the image
  id-token: write      # mint the OIDC token the attestation is signed with
  attestations: write  # store the attestation

jobs:
  build-push:
    uses: yama6a/gha/.github/workflows/docker-build-release-multiarch.yaml@v1
    with:
      build-args: |
        NEXT_PUBLIC_API_URL_CLIENT=https://api.example.com
      # version: ${{ needs.tag.outputs.semver }}
      # platforms: >-
      #   [{"platform":"linux/amd64","runner":"ubuntu-latest"},
      #    {"platform":"linux/arm64","runner":"ubuntu-24.04-arm"}]   # default
```

hadolint runs once, in the `version` job. Each arch is scanned on its own native runner right
after its digest is pushed, so nothing is emulated; the provenance is attested once, on the
finished manifest list. The scan is report-only on the same terms as above, and `merge` needs
`build`, so enforcing it would block the manifest rather than only the report.

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

### `actions/shell-checks`

shellcheck 0.10.0 and shfmt 3.10.0, both pinned. The runner image ships shellcheck 0.9.0, and a
runner-image bump would otherwise red-light six repos at once.

```yaml
- uses: yama6a/gha/.github/actions/shell-checks@v1
  # with:
  #   paths: lib/shell/*.sh   # empty discovers *.sh plus extensionless bash-shebang files
```

No `-S` and no `-e`. Severity and suppressed codes belong in the repo's own `.shellcheckrc`,
which shellcheck reads by itself, so a suppression stays reviewable in the repo it applies to.

shfmt always runs as `shfmt -d -i 2 -ci -bn -sr`, and the flags are not an input: shfmt takes
its options from `.editorconfig` when no printer flag is given, and passing one turns that
lookup off, so a stray `.editorconfig` cannot move CI.

### `actions/hadolint`

hadolint 2.12.0, pinned. Uses the repo's own `.hadolint.yaml` when it has one and the canonical
one at the root of this repo otherwise.

```yaml
- uses: yama6a/gha/.github/actions/hadolint@v1
  # with:
  #   dockerfiles: .build/Dockerfile   # empty discovers Dockerfile* recursively
```

`failure-threshold: info`, so style findings are advisory and everything else fails the job.
Three rules are off everywhere:

| rule | why |
|---|---|
| `DL3008` | apt version pins go stale. Debian drops old versions from the archive on every point release, so a `pkg=ver` that passes today fails in a few weeks. The digest-pinned base image is what makes the build reproducible. |
| `DL3018` | the same for apk: Alpine only carries the current version of a package per branch. |
| `DL3006` | `FROM ${IMAGE}` with no default is deliberate in the image-builder repos, so a bare `docker build` fails instead of quietly producing an unpinned image. |

Both `docker-build-release` workflows already run this, so a repo that only builds images
through them has no reason to call it directly.

Repo-specific extras (helm/kubeconform validation, per-app npm test suites) stay
local to each repo - only the pieces that were byte-for-byte duplicated across 3+ repos live
here.
