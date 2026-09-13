# Conventions for yama6a repos

gha holds the shared workflows, composite actions and Renovate presets; `v2` is current, and every
`uses:` pins the `@v2` tag.

## Every repo

| thing | rule |
|---|---|
| default branch | left as is, `main` or `master`; nothing in gha reads it |
| `renovate.json5` | extends `github>yama6a/gha:default.json5`, plus `go.json5` or `node.json5` |
| CI | a `renovate-config` job, everywhere |
| `.yamllint.yml` | absent, unless the repo extends `ignore:` |
| `.dockerignore` | next to every Dockerfile |
| `.editorconfig` | none |
| LICENSE | MIT, `Copyright (c) 2026 yama6a`, in every public repo; praxis carries a proprietary notice |
| merges | squash only, offgrid-private also merge commits; squash title `PR_TITLE`, body `BLANK`; head branch deleted on merge |
| auto-merge | on, with branch protection requiring the checks below, `strict: false`, no reviews |
| Dependabot alerts | off; Renovate is the update path |
| secret scanning | on with push protection in every public repo; a private repo needs Team, the plan here is Pro |
| commits | signed, one-line subject |

Applied by `scripts/repo-settings.sh`, not by hand.

## Required-check names

- caller job id = the reusable workflow's short name.
- the reusable workflow's job carries `name:` with that same word.
- GitHub names the context `<caller job id> / <reusable job name>`, so both halves match.

| stack | required contexts |
|---|---|
| Go | `go / go` |
| Node | `node / node` |
| Playwright | `e2e / e2e` |
| shell and config repos | `shell`, `yaml` |
| every repo | `renovate-config` |

Never require a conditional job, a single matrix shard, or a job from a push-only workflow: none of
them report on a PR, so the PR sits pending forever.

## Go

- Go 1.27 in `go.mod` and in the Dockerfile; Renovate bumps the `go` directive.
- `uses: yama6a/gha/.github/workflows/go-ci.yaml@v2`, no inputs.
- go-ci runs: `go mod tidy` drift, `go generate` drift, fmt, golangci-lint with the canonical
  config, vet, `go test -race -count=1` with coverage, govulncheck, cross-compile amd64 and arm64.
- no local `.golangci.yaml`. A repo-specific delta goes in `.golangci.local.yaml`, merged on top.
- tool dependencies: Go 1.24 `tool` directives in `go.mod`. No `tools.go`.
- logging: zap, typed fields. The logger is an unexported struct field or the last constructor
  param, never a package global. `zap.NewNop()` in tests.
- tests: testify, and testcontainers for anything that talks to a database.
- image: `.build/Dockerfile`, `gcr.io/distroless/static:nonroot`. A binary that needs an OS
  (shelling out, glibc, CA tooling) uses debian-slim or alpine, digest-pinned.

- Makefile: a copy of `templates/Makefile.go` from gha, repo extras added below it; `ci` runs
  the same checks as go-ci.

## Frontend

- npm only, `package-lock.json` committed.
- `.nvmrc` holds `24` and is the only place the Node version is written: no `engines.node`, no
  `node-version` workflow input.
- these scripts all exist, set to `"exit 0"` where the repo has nothing to do:
  `generate`, `lint`, `format:check`, `typecheck`, `test`, `build`.
- prettier, with this `.prettierrc.json` in every repo, and `eslint-config-prettier` last in the
  eslint config so it can turn off the rules that fight it:

```json
{
  "printWidth": 100,
  "singleQuote": true,
  "overrides": [
    { "files": ["*.html", "*.css", "*.json", "*.json5", "*.yaml", "*.yml"], "options": { "singleQuote": false } }
  ]
}
```

- `.prettierignore` lists `package-lock.json` and every generated output dir; prettier reformats
  generated files otherwise and the `generate` drift check then fails on every run.
- API types are generated from the committed spec, and CI fails if the committed output drifts.
- an eslint or TypeScript version hold lives in the repo that has the blocker, with the blocker
  named next to it. Never in the shared Renovate preset.
- `uses: yama6a/gha/.github/workflows/node-ci.yaml@v2`.
- Playwright through `playwright-e2e.yaml@v2`, with a caller-side `.github/workflows/warm-cache.yaml`
  that fills the shared npm and browser cache.
- serving image and framework are per project.

## Shell

- `#!/usr/bin/env bash` and `set -euo pipefail`.
- `.shellcheckrc` per repo owns the disable policy, one disabled code per line with its reason.
- shfmt `-i 2 -ci -bn -sr`.
- CI: `yama6a/gha/.github/actions/shell-checks@v2`.

## Images

- hadolint with the canonical `.hadolint.yaml`: DL3008 and DL3018 (pinned apt and apk package
  versions) ignored because distros drop old versions from the archive and the digest-pinned base
  image is where reproducibility comes from; DL3006 (untagged `FROM`) ignored because the
  image-builder repos take the base as a build arg on purpose.
- every image goes through `docker-build-release.yaml@v2`, or the multiarch variant when the build
  cannot run under QEMU: hadolint, build with provenance and SBOM, trivy scan (report-only until
  flipped), signed attestation (public repos only; private needs Enterprise Cloud), GitHub release.
- the caller grants `contents: write`, `packages: write`, `id-token: write`,
  `attestations: write`; a `deploy` job in the same file gets `permissions: {}`.
- release versions are integers. A repo that derives its own version passes `version`.

## Helm and Kubernetes

- kubeconform with the CRD catalog, so custom resources validate too.
- charts are deployed by ArgoCD out of offgrid; CI only validates them.
- `yama6a/gha/.github/actions/helm-chart-checks@v2` runs lint, unittest, template, kubeconform.
- `values.schema.json` only on a published chart (longhorn-replica-affinity).
- no chart-testing: it diffs against the released chart version, which does not fit charts whose
  version is bumped on every change.
- helm-docs: deferred, not wired up.
- a lib or helper chart validates its inputs in `templates/validate.yaml` with `fail`, and needs a
  values fixture to lint against at all.

## Renovate

- nightly through `renovate.yaml@v2`: 05:13 UTC opens PRs, 05:43 UTC merges the ones that went
  green.
- non-major updates are grouped into one PR and auto-merged; GitHub Actions majors auto-merged;
  everything digest-pinned.
- per-repo `packageRules` cover only what is specific to that repo.
