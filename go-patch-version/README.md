# Go patch version bump

A GitHub Action that keeps the Go version of a repository up to date.

It looks up the Go version shipped by a container builder image (or a version
you pin yourself), rewrites `go.mod`, Containerfiles and any `KEY=value` files
you care about, runs `go mod tidy` / `go mod vendor`, and opens one pull
request per branch. Re-running it refreshes the existing pull requests instead
of piling up new ones.

It handles several branches in one go, so a single scheduled workflow can keep
`main` and all your release branches current.

## Quick start

```yaml
name: Go patch version bump

on:
  schedule:
    - cron: "0 6 * * 1" # every Monday at 06:00 UTC
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write

jobs:
  bump:
    runs-on: ubuntu-latest
    steps:
      - uses: red-hat-storage/actions/go-patch-version@v1
        with:
          token: ${{ secrets.GH_PAT }}
          registry-username: ${{ secrets.REDHAT_REGISTRY_USER }}
          registry-password: ${{ secrets.REDHAT_REGISTRY_PASSWORD }}
          fork-repo: odf-bot/my-repo
          branches: |
            main:rhel_9_golang_1.26
            release-4.22:rhel_9_golang_1.25
```

More complete, real-world workflows live in [`examples`](./examples).

## Before you start

A few things the action expects:

- **A Linux runner.** It checks for this and stops early on anything else.
- **`git`, `jq` and `gh`** on the runner (all present on GitHub-hosted
  runners), plus **`skopeo`** if you let it read versions from a builder image.
- **A token that can push.** Usually a PAT belonging to the bot that owns the
  fork. It needs _Contents: write_, and also _Workflows: write_ if the bump can
  touch anything under `.github/workflows`.

## What it actually does, per branch

1. Works out the target Go version — either from the builder image's `version`
   label, or from the value you pinned.
2. Clones the branch (shallow, single branch).
3. Compares it against the `go` directive in `go.mod` and your version files.
   If nothing is behind, the branch is **skipped**.
4. Rewrites `go.mod` files, version files and Containerfiles, and commits that.
5. Runs `go mod tidy` / `go mod vendor` (or your own command) and commits that
   separately, so reviewers can read the real change without the vendor noise.
6. Pushes the branch and opens — or updates — the pull request.

## Configuration

Every input is optional unless marked **required**.

### Which branches to bump

| Input            | Default      | What it does                                                                            |
| ---------------- | ------------ | --------------------------------------------------------------------------------------- |
| `branches`       | **required** | The branches to process, one per line. See below for the format.                        |
| `default-go-tag` | _(empty)_    | Fallback builder image tag (or `=x.y.z`) for branch entries that don't carry their own. |
| `fail-fast`      | `false`      | Stop at the first branch that fails. By default the rest still get their turn.          |

Each line of `branches` can take one of three shapes:

```yaml
branches: |
  devel:rhel_9_golang_1.26   # probe this image tag, use the version it reports
  release-4.22:1.25          # also a tag — "1.25" is just the tag name here
  release-4.21:=1.25.3       # pinned: use exactly 1.25.3, don't touch any registry
  release-4.18               # no value, so default-go-tag is used
```

The leading `=` is the thing to remember: it means "this is a version, not a
tag", and it skips the image lookup entirely.

### Where the version comes from

| Input                    | Default                                                          | What it does                                                      |
| ------------------------ | ---------------------------------------------------------------- | ----------------------------------------------------------------- |
| `builder-image-template` | `brew.registry.redhat.io/rh-osbs/openshift-golang-builder:{tag}` | The image to inspect. `{tag}` is replaced with the branch's tag.  |
| `registry`               | `brew.registry.redhat.io`                                        | Registry to log in to before inspecting the image.                |
| `registry-username`      | _(empty)_                                                        | Service account username. Leave empty to skip the login entirely. |
| `registry-password`      | _(empty)_                                                        | Password for that service account.                                |
| `image-version-label`    | `version`                                                        | The image label that holds the Go version.                        |

A leading `v` on the label value is stripped, so both `1.26.1` and `v1.26.1`
work fine.

### Repositories

| Input            | Default                   | What it does                                                                                                                    |
| ---------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `target-repo`    | the current repo          | Where the pull requests are opened.                                                                                             |
| `fork-repo`      | _(empty)_                 | Fork that receives the bump branches. Leave it empty to push straight to `target-repo` — then `token` needs write access there. |
| `default-branch` | the repo's default branch | Which branch counts as "main". It gets `pr-title-template`; everything else gets `release-pr-title-template`.                   |

### Tokens

| Input      | Default               | What it does                                                                                                                        |
| ---------- | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `token`    | **required**          | Pushes the bump branch. Needs _Contents: write_ (plus _Workflows: write_ if `.github/workflows` may change). Usually the bot's PAT. |
| `pr-token` | `${{ github.token }}` | Creates and updates the pull requests on `target-repo`. The default is normally enough.                                             |

### What gets rewritten

| Input                          | Default   | What it does                                                                                                                                                                                 |
| ------------------------------ | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `go-mod-paths`                 | `auto`    | Module directories to update and tidy, e.g. `. e2e tools actions/retest`. `auto` finds every `go.mod` outside vendor trees. Directories that don't exist are skipped quietly.                |
| `vendor`                       | `auto`    | `auto` vendors a module only if it already has a `vendor/` directory, `true` always vendors, `false` never does. `auto` is the safe choice when some modules are vendored and others aren't. |
| `deps-update-command`          | _(empty)_ | Run this from the repo root instead of the built-in tidy/vendor, e.g. `make deps-update`.                                                                                                    |
| `containerfiles`               | `auto`    | Dockerfiles/Containerfiles whose base image tag should follow the Go version. `auto` finds `Dockerfile*` and `Containerfile*` outside vendor trees, `none` turns the rewrite off.            |
| `containerfile-image-prefixes` | `golang:` | Image name prefixes to rewrite inside those files, e.g. `registry.access.redhat.com/ubi9/go-toolset:`. Always end with the colon.                                                            |
| `version-files`                | _(empty)_ | Plain `KEY=value` files to keep in sync. One entry per line as `<path>:<KEY>`, or `<path>:<KEY>:minor` to write only `major.minor`. Example: `build.env:GOLANG_VERSION`.                     |
| `remove-toolchain`             | `true`    | Drop the `toolchain` directive from `go.mod` files.                                                                                                                                          |

Note on Containerfiles: only the `major.minor` part of the tag is written
(`golang:1.26`), because that's how the builder images are tagged. A pure patch
bump therefore leaves these files untouched.

### Commits and pull requests

| Input                       | Default                                            | What it does                                                                                                                                                         |
| --------------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `head-branch-template`      | `chore/bump-go-{branch}`                           | Name of the pushed branch. Keep it stable per target branch so re-runs refresh one pull request instead of opening duplicates.                                       |
| `git-user-name`             | `odf-bot`                                          | Commit author/committer name.                                                                                                                                        |
| `git-user-email`            | `odf-bot@users.noreply.github.com`                 | Commit author/committer email.                                                                                                                                       |
| `signoff`                   | `true`                                             | Add a `Signed-off-by` trailer.                                                                                                                                       |
| `commit-message`            | `build: bump go from {from} to {to}` (+ body)      | Message for the version bump commit. First line is the subject, then a blank line, then the body.                                                                    |
| `deps-commit-message`       | `build: add go mod tidy/vendor changes` (+ body)   | Message for the dependency refresh commit.                                                                                                                           |
| `pr-title-template`         | `Bump go from {from} to {to}`                      | Pull request title on the default branch.                                                                                                                            |
| `release-pr-title-template` | `NO-ISSUE: [{branch}] Bump go from {from} to {to}` | Pull request title on every other branch.                                                                                                                            |
| `pr-body-template`          | see `action.yml`                                   | Pull request body.                                                                                                                                                   |
| `pr-labels`                 | _(empty)_                                          | Labels for newly created pull requests, one per line or comma separated. Labels may contain spaces. Only applied when the pull request is created, not on refreshes. |
| `draft`                     | `false`                                            | Open the pull requests as drafts.                                                                                                                                    |

All of the message and title templates understand these placeholders:

| Placeholder        | Becomes                                                      |
| ------------------ | ------------------------------------------------------------ |
| `{branch}`         | The branch being bumped, e.g. `release-4.22`                 |
| `{from}`           | The current Go version, e.g. `1.25.1`                        |
| `{to}`             | The new Go version, e.g. `1.25.3`                            |
| `{to_minor}`       | The new version without the patch, e.g. `1.25`               |
| `{image}`          | The builder image that was probed, or `pinned version x.y.z` |
| `{repo}`           | The target repository, e.g. `red-hat-storage/ceph-csi`       |
| `{default_branch}` | The value of `default-branch`                                |

### Runtime

| Input         | Default   | What it does                                                                                                                                                                           |
| ------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `go-version`  | `stable`  | The bootstrap Go used to drive the module updates. The exact per-branch toolchain is still fetched automatically when `gotoolchain` is `auto`, so leaving this alone is usually right. |
| `setup-go`    | `true`    | Install Go with `actions/setup-go`. Set to `false` to use whatever Go the runner already has.                                                                                          |
| `gotoolchain` | `auto`    | Value of `GOTOOLCHAIN`. `auto` lets Go download the toolchain matching each branch's new `go` directive; use `local` if the runner must not download toolchains.                       |
| `dry-run`     | `false`   | Do all the work locally but skip the push and the pull request. The resulting diff is printed to the log — great for a first try.                                                      |
| `work-dir`    | _(empty)_ | Directory for the per-branch clones. Defaults to a temp directory under the runner.                                                                                                    |

Boolean inputs accept `true`, `yes` or `1` as "on"; anything else is off.

## Outputs

| Output    | What you get                                                                                                                                    |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `results` | A JSON array with one object per branch: `{branch, status, current_go, target_go, pr}`. `status` is `bumped`, `skipped`, `dry-run` or `failed`. |
| `bumped`  | Space separated list of branches that got a pull request.                                                                                       |
| `failed`  | Space separated list of branches that failed.                                                                                                   |

The action also writes a small table to the job summary, so you can see at a
glance what happened without digging through the log.

If any branch fails, the step fails too — but with `fail-fast: false` (the
default) the remaining branches are still processed first.

## Tips

- **Start with `dry-run: true`.** You'll see the full diff in the log without
  anything being pushed.
- **Use a `concurrency` group** in your workflow so two scheduled runs never
  race each other.
- **Running branches in parallel** is possible with a job matrix — see
  [`../examples/matrix-parallel.yaml`](../examples/matrix-parallel.yaml). The
  single-job form is simpler and usually fast enough.
- **Nothing happens and that's correct:** if `go.mod` is already at or ahead of
  the target version (and your version files are too), the branch is reported
  as `skipped`.
