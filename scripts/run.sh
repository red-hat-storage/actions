#!/usr/bin/env bash
#
# Entry point of the go-patch-version action: expands the `branches` input
# into the action's internal matrix and runs bump-branch.sh once per entry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${TARGET_REPO:?target-repo is required}"

if [[ -z "$(split_list "${BRANCHES}")" ]]; then
  err "the 'branches' input is empty"
  exit 1
fi

work_dir="${WORK_DIR:-${RUNNER_TEMP:-/tmp}/go-patch-version}"
mkdir -p "${work_dir}"

# We use gh cli, export GH_HOST if needed so it respects the origin.
if [[ -z "${GH_HOST:-}" && "${GITHUB_SERVER_URL:-}" == https://* ]]; then
  gh_host="${GITHUB_SERVER_URL#https://}"
  gh_host="${gh_host%/}"
  if [[ "${gh_host}" != "github.com" ]]; then
    export GH_HOST="${gh_host}"
  fi
fi

results_file="${work_dir}/results.jsonl" # hack to avoid [ {...} ]
: >"${results_file}"

bumped=()
failed=()
overall_rc=0

# This does what a matrix would do in GH action.
# Runs the same loop for a single branch `entry` (devel:builder_tag).
while read -r entry; do
  # This means extract the branch (devel) from: devel:anything_else
  branch="${entry%%:*}"
  spec=""

  # If entry contains a colon anywhere, remove everything before colon
  # to get just the version/builder tag and store it in spec.
  [[ "${entry}" == *:* ]] && spec="${entry#*:}"
  [[ -z "${spec}" ]] && spec="${DEFAULT_GO_TAG}" # When a branch has no version, use default.

  slug="${branch//\//-}" # A BASH-y sed, replace all / with -.
  result_file="${work_dir}/result-${slug}.json"
  rc=0

  echo "::group::bump (${branch})"
  (
    export BRANCH="${branch}"
    export GO_SPEC="${spec}"
    export CHECKOUT_DIR="${work_dir}/src-${slug}"
    export RESULT_FILE="${result_file}"
    bash "${SCRIPT_DIR}/bump-branch.sh"
  ) || rc=$?
  echo "::endgroup::"

  if [[ ${rc} -ne 0 ]]; then
    err "branch ${branch} failed (exit ${rc})"
    failed+=("${branch}")
    overall_rc=1
    jq -nc --arg branch "${branch}" \
      '{branch: $branch, status: "failed", current_go: "",
        target_go: "", pr: ""}' >>"${results_file}"
    if is_true "${FAIL_FAST}"; then
      break
    fi
    continue
  fi

  if [[ -f "${result_file}" ]]; then
    cat "${result_file}" >>"${results_file}"
    status="$(jq -r '.status' "${result_file}")"
    if [[ "${status}" == "bumped" || "${status}" == "dry-run" ]]; then
      bumped+=("${branch}")
    fi
  fi
done < <(split_list "${BRANCHES}")

# And now let jq add [] to our list of {...} in jsonl.
results="$(jq -sc . "${results_file}")"

{
  echo "results=${results}"
  echo "bumped=${bumped[*]-}"
  echo "failed=${failed[*]-}"
} >>"${GITHUB_OUTPUT:-/dev/null}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Go patch version bump"
    echo
    echo "| Branch | Status | From | To | PR |"
    echo "| --- | --- | --- | --- | --- |"
    jq -r '.[] | "| \(.branch) | \(.status) | \(.current_go // "-") |"
                 + " \(.target_go // "-") | \(.pr // "") |"' \
      <<<"${results}"
  } >>"${GITHUB_STEP_SUMMARY}"
fi

# Even if a single step failed, this will be 1.
# The workflows do still run, unless FAIL_FAST.
exit "${overall_rc}"
