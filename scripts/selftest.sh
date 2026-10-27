#!/usr/bin/env bash
#
# Offline smoke test for the go-patch-version action.
#
# Builds a throwaway repository, serves it over a file:// "GitHub server" and
# runs the action in dry-run mode, so nothing is pushed and no network or
# registry access is needed. Run it from anywhere:
#
#   bash go-patch-version/scripts/selftest.sh
#
# On macOS it transparently shims GNU sed (brew install gnu-sed); the action
# itself only supports Linux runners.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TMPDIR:-/tmp}/gpv-selftest"
FAILURES=0

rm -rf "${ROOT}"
mkdir -p "${ROOT}/bin" "${ROOT}/remotes/acme"

if command -v gsed >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec gsed "$@"\n' >"${ROOT}/bin/sed"
  chmod +x "${ROOT}/bin/sed"
  export PATH="${ROOT}/bin:${PATH}"
fi

check() { # check <description> <expected> <actual>
  if [[ "${2}" == "${3}" ]]; then
    echo "ok   - ${1}"
  else
    echo "FAIL - ${1}: expected '${2}', got '${3}'"
    FAILURES=$((FAILURES + 1))
  fi
}

# --------------------------------------------------------------------------
# Fixture: acme/widget with two modules, a build.env and two Containerfiles.
# --------------------------------------------------------------------------
make_fixture() {
  local src="${ROOT}/fixture"
  rm -rf "${src}" "${ROOT}/remotes/acme/widget.git"
  mkdir -p "${src}/api" "${src}/build"

  printf 'module example.com/acme\n\ngo 1.24.0\n\ntoolchain go1.24.6\n' \
    >"${src}/go.mod"
  printf 'module example.com/acme/api\n\ngo 1.24.0\n' >"${src}/api/go.mod"
  printf 'GOLANG_VERSION=1.24.0\nOTHER=keepme\n' >"${src}/build.env"
  printf 'FROM golang:1.24 AS builder\n' >"${src}/build/Containerfile"
  printf 'FROM golang:1.24.0 AS builder\n' >"${src}/Dockerfile"
  printf 'all:\n\t@echo deps-update ran >deps.log\n' >"${src}/Makefile"

  git init -q -b devel "${src}"
  git -C "${src}" add -A
  git -C "${src}" -c user.email=t@t -c user.name=t commit -qm init
  git -C "${src}" branch -q release-1.0
  git clone -q --bare "${src}" "${ROOT}/remotes/acme/widget.git"
}

# run_action <branches> [VAR=value ...] - run the action with sane defaults.
run_action() {
  local branches="${1}"
  shift
  (
    export GITHUB_SERVER_URL="file://${ROOT}/remotes"
    export GITHUB_OUTPUT="${ROOT}/outputs.txt"
    export GITHUB_STEP_SUMMARY="${ROOT}/summary.md"
    export WORK_DIR="${ROOT}/work"
    export BRANCHES="${branches}"
    export DEFAULT_GO_TAG="" FAIL_FAST=false
    export BUILDER_IMAGE_TEMPLATE="example.invalid/builder:{tag}"
    export IMAGE_VERSION_LABEL=version
    export TARGET_REPO="acme/widget" FORK_REPO="" DEFAULT_BRANCH=devel
    export PUSH_TOKEN="" GH_TOKEN=""
    export GO_MOD_PATHS=auto VENDOR=auto DEPS_UPDATE_COMMAND=""
    export CONTAINERFILES=auto CONTAINERFILE_IMAGE_PREFIXES="golang:"
    export VERSION_FILES="build.env:GOLANG_VERSION"
    export REMOVE_TOOLCHAIN=true
    export HEAD_BRANCH_TEMPLATE="chore/bump-go-{branch}"
    export GIT_USER_NAME=bot GIT_USER_EMAIL=bot@users.noreply.github.com
    export SIGNOFF=true
    export COMMIT_MESSAGE="build: bump go from {from} to {to}"
    export DEPS_COMMIT_MESSAGE="build: add go mod tidy/vendor changes"
    export PR_TITLE_TEMPLATE="Bump go from {from} to {to}"
    export RELEASE_PR_TITLE_TEMPLATE="NO-ISSUE: [{branch}] Bump go from {from} to {to}"
    export PR_BODY_TEMPLATE="Upgraded the Golang version of the repo."
    export PR_LABELS="" DRAFT=false
    export GOTOOLCHAIN=auto GOFLAGS=-mod=mod GOPROXY=off
    export DRY_RUN=true
    local assignment
    for assignment in "$@"; do
      export "${assignment?}"
    done
    bash "${SCRIPT_DIR}/run.sh"
  )
}

status_of() { # status_of <branch>
  grep '^results=' "${ROOT}/outputs.txt" | tail -n1 | cut -d= -f2- \
    | jq -r --arg b "${1}" '.[] | select(.branch == $b) | .status'
}

# --------------------------------------------------------------------------
echo "== case 1: full bump of one branch =="
make_fixture
run_action "devel:=1.26.1" >"${ROOT}/case1.log" 2>&1 \
  || { echo "FAIL - case 1 exited non-zero"; cat "${ROOT}/case1.log"; exit 1; }
out="${ROOT}/work/src-devel"

check "root go directive" "go 1.26.1" "$(grep '^go ' "${out}/go.mod")"
check "nested go directive" "go 1.26.1" "$(grep '^go ' "${out}/api/go.mod")"
check "toolchain removed" "" "$(grep '^toolchain' "${out}/go.mod" || true)"
check "build.env bumped" "GOLANG_VERSION=1.26.1" \
  "$(grep '^GOLANG_VERSION=' "${out}/build.env")"
check "unrelated key kept" "OTHER=keepme" "$(grep '^OTHER=' "${out}/build.env")"
check "Containerfile minor tag" "FROM golang:1.26 AS builder" \
  "$(cat "${out}/build/Containerfile")"
check "Dockerfile patch tag collapsed" "FROM golang:1.26 AS builder" \
  "$(cat "${out}/Dockerfile")"
check "commit subject" "build: bump go from 1.24.0 to 1.26.1" \
  "$(git -C "${out}" log -1 --format=%s)"
check "sign-off trailer" "1" \
  "$(git -C "${out}" log -1 --format=%b | grep -c '^Signed-off-by:')"
check "head branch name" "chore/bump-go-devel" \
  "$(git -C "${out}" rev-parse --abbrev-ref HEAD)"
check "default-branch PR title" "1" \
  "$(grep -c 'title: Bump go from 1.24.0 to 1.26.1' "${ROOT}/case1.log")"
check "status" "dry-run" "$(status_of devel)"
check "bumped output" "bumped=devel" "$(grep '^bumped=' "${ROOT}/outputs.txt")"
check "nothing pushed" "" \
  "$(git -C "${ROOT}/remotes/acme/widget.git" branch --list 'chore/*')"

echo
echo "== case 2: up-to-date branch, release title, missing branch =="
make_fixture
rc=0
run_action "$(printf 'devel:=1.24.0\nrelease-1.0:=1.25.0\nnope:=1.25.0\n')" \
  >"${ROOT}/case2.log" 2>&1 || rc=$?
check "exit code reports the failure" "1" "${rc}"
check "up-to-date branch skipped" "skipped" "$(status_of devel)"
check "release branch bumped" "dry-run" "$(status_of release-1.0)"
check "missing branch failed" "failed" "$(status_of nope)"
check "failure did not stop the run" "failed=nope" \
  "$(grep '^failed=' "${ROOT}/outputs.txt" | tail -n1)"
check "release PR title" "1" \
  "$(grep -c 'title: NO-ISSUE: \[release-1.0\] Bump go from 1.24.0 to 1.25.0' \
    "${ROOT}/case2.log")"

echo
echo "== case 3: explicit paths, custom deps command, rewrites disabled =="
make_fixture
run_action "devel:=1.26.1" \
  "GO_MOD_PATHS=." \
  "CONTAINERFILES=none" \
  "VERSION_FILES=" \
  "DEPS_UPDATE_COMMAND=make all" \
  "REMOVE_TOOLCHAIN=false" \
  "HEAD_BRANCH_TEMPLATE=bot/go-{to_minor}-{branch}" \
  >"${ROOT}/case3.log" 2>&1 \
  || { echo "FAIL - case 3 exited non-zero"; cat "${ROOT}/case3.log"; exit 1; }
out="${ROOT}/work/src-devel"

check "listed module bumped" "go 1.26.1" "$(grep '^go ' "${out}/go.mod")"
check "unlisted module untouched" "go 1.24.0" "$(grep '^go ' "${out}/api/go.mod")"
check "toolchain kept" "toolchain go1.24.6" \
  "$(grep '^toolchain' "${out}/go.mod")"
check "containerfiles untouched" "FROM golang:1.24 AS builder" \
  "$(cat "${out}/build/Containerfile")"
check "version file untouched" "GOLANG_VERSION=1.24.0" \
  "$(grep '^GOLANG_VERSION=' "${out}/build.env")"
check "deps command ran" "deps-update ran" "$(cat "${out}/deps.log")"
check "deps changes committed" "build: add go mod tidy/vendor changes" \
  "$(git -C "${out}" log -1 --format=%s)"
check "templated head branch" "bot/go-1.26-devel" \
  "$(git -C "${out}" rev-parse --abbrev-ref HEAD)"

echo
echo "== case 4: a version-shaped tag is a tag, not a pinned version =="
make_fixture
rc=0
run_action "devel:1.24" >"${ROOT}/case4.log" 2>&1 || rc=$?
check "probing a bad image fails the branch" "1" "${rc}"
check "the tag was fed to the image template" "1" \
  "$(grep -c 'example.invalid/builder:1.24' "${ROOT}/case4.log")"
check "nothing was pinned" "0" \
  "$(grep -c 'is pinned to' "${ROOT}/case4.log")"

echo
if [[ ${FAILURES} -eq 0 ]]; then
  echo "all checks passed"
else
  echo "${FAILURES} check(s) failed"
fi
exit $((FAILURES > 0))
