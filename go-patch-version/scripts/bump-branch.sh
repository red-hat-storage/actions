#!/usr/bin/env bash
#
# Bump the Go version on a single branch and open/refresh its pull request.
#
# Driven entirely by environment variables (see action.yml). Called once per
# branch by run.sh with BRANCH and GO_SPEC set; writes a one line JSON result
# to RESULT_FILE.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${BRANCH:?BRANCH is required}"
: "${TARGET_REPO:?target-repo is required}"

CURRENT_GO=""
TARGET_GO=""
IMAGE_DESC=""
PR_URL=""

write_result() {
  jq -nc \
    --arg branch "${BRANCH}" \
    --arg status "${1}" \
    --arg current_go "${CURRENT_GO}" \
    --arg target_go "${TARGET_GO}" \
    --arg pr "${PR_URL}" \
    '{branch: $branch, status: $status, current_go: $current_go,
      target_go: $target_go, pr: $pr}' >"${RESULT_FILE}"
}

# 1. Find out the target go version that BRANCH should be bumped to.
resolve_target_go() {
  local spec="${GO_SPEC}"

  # A leading '=' pins the version instead of probing an image.
  if [[ "${spec}" == =* ]]; then
    TARGET_GO="${spec#=}"
    if ! is_version "${TARGET_GO}"; then
      err "'${spec}' on branch '${BRANCH}' is not a version;" \
        "pinned values look like '=1.26.1'"
      return 1
    fi
    IMAGE_DESC="pinned version ${TARGET_GO}"
    log "Target Go for ${BRANCH} is pinned to ${TARGET_GO}"
    return
  fi

  if [[ -z "${spec}" ]]; then
    err "no builder image tag or version for branch '${BRANCH}'" \
      "(set it as '${BRANCH}:<tag>', '${BRANCH}:=<x.y.z>' or via" \
      "default-go-tag)"
    return 1
  fi

  # Replace all `{tag}` with GO_SPEC.
  local image="${BUILDER_IMAGE_TEMPLATE//\{tag\}/${spec}}"
  IMAGE_DESC="${image}"

  if ! command -v skopeo >/dev/null 2>&1; then
    err "skopeo is required to probe ${image}"
    return 1
  fi

  local version
  version="$(skopeo inspect "docker://${image}" \
    -f "{{.Labels.${IMAGE_VERSION_LABEL}}}" | sed 's/^v//')"
  if ! is_version "${version}"; then
    err "unexpected '${IMAGE_VERSION_LABEL}' label on ${image}: '${version}'"
    return 1
  fi
  log "Builder image ${image} ships Go ${version}"
  TARGET_GO="${version}"
}

# 2. Now we clone the repo's branch.
clone_branch() {
  rm -rf "${CHECKOUT_DIR}"
  git clone --quiet --depth 1 --branch "${BRANCH}" --no-tags \
    --single-branch "$(repo_url "${TARGET_REPO}" "${GH_TOKEN}")" \
    "${CHECKOUT_DIR}"
  cd "${CHECKOUT_DIR}"
  # Do not leave the token behind in .git/config.
  git remote set-url origin "$(repo_url "${TARGET_REPO}")"
  git config user.name "${GIT_USER_NAME}"
  git config user.email "${GIT_USER_EMAIL}"
}

# 3. Decide whether the branch is behind and should be bumped.
# read_version_file <path> <key> - reads the value of KEY from PATH.
# Say we have build.env with key=GO_VERSION, it will return value of it.
read_version_file() {
  # File must exist.
  [[ -f "${1}" ]] || return 0

  # Using = as separator, and $2 inside variable k, if $1 == k as in,
  # if the first matched item is the key, remove everything before, including
  # = and print its value, so: GO_VERSION=1.2.3 returns 1.2.3.
  awk -F= -v k="${2}" \
    '$1 == k {sub(/^[^=]*=/, ""); gsub(/[" \t\r]/, ""); print; exit}' "${1}"
}

needs_bump() {
  if [[ ! -f go.mod ]]; then
    err "go.mod not found on ${BRANCH}"
    return 2
  fi
  CURRENT_GO="$(awk '/^go /{print $2; exit}' go.mod)"
  if [[ -z "${CURRENT_GO}" ]]; then
    err "could not parse the go directive from go.mod on ${BRANCH}"
    return 2
  fi
  log "go.mod on ${BRANCH} declares Go ${CURRENT_GO}"

  local behind=false
  if version_lt "${CURRENT_GO}" "${TARGET_GO}"; then
    behind=true
  fi

  # This loop walks over the VERSION_FILES and checks every KEY
  # for the drift.
  local entry path key mode want have
  while read -r entry; do
    IFS=':' read -r path key mode <<<"${entry}"
    [[ -z "${path}" || -z "${key}" ]] && continue
    have="$(read_version_file "${path}" "${key}")"
    [[ -z "${have}" ]] && continue
    want="${TARGET_GO}"
    [[ "${mode}" == "minor" ]] && want="$(minor_of "${TARGET_GO}")"
    log "${path} ${key} is ${have} (want ${want})"
    if version_lt "${have}" "${want}"; then
      behind=true
    fi
  done < <(split_list "${VERSION_FILES}")

  [[ "${behind}" == "true" ]]
}

# 4. Rewrite the version now, in mod, containerfiles and version files.
apply_version_changes() {
  local dir file

  # Process all go.mod(s).
  while read -r dir; do
    file="${dir}/go.mod"
    file="${file#./}"
    [[ "${dir}" == "." ]] && file="go.mod"
    if [[ ! -f "${file}" ]]; then
      log "  skipping missing ${file}"
      continue
    fi
    log "  updating ${file}"
    if is_true "${REMOVE_TOOLCHAIN}"; then
      # Drop `toolchain goX.Y.Z` and the blank line in front of it.
      sed -i -e '/^$/{N;/\ntoolchain /d;}' -e '/^toolchain /d' "${file}"
    fi
    sed -i -E "s/^go [0-9]+\.[0-9]+(\.[0-9]+)?$/go ${TARGET_GO}/" "${file}"
  done < <(go_mod_dirs)

  # Same loop as above, but this time it updates too.
  local entry path key mode value
  while read -r entry; do
    IFS=':' read -r path key mode <<<"${entry}"
    [[ -z "${path}" || -z "${key}" ]] && continue
    if [[ ! -f "${path}" ]]; then
      log "  skipping missing ${path}"
      continue
    fi
    value="${TARGET_GO}"
    [[ "${mode}" == "minor" ]] && value="$(minor_of "${TARGET_GO}")"
    log "  updating ${path} (${key}=${value})"
    sed -i -E "s|^${key}=.*$|${key}=${value}|" "${path}"
  done < <(split_list "${VERSION_FILES}")

  # Process the containerfiles, only minor is bumped here, patch is ignored
  # As the builder images usually have go tags in format of X.Y.
  local prefix escaped minor
  minor="$(minor_of "${TARGET_GO}")"
  while read -r file; do
    [[ -f "${file}" ]] || continue
    while read -r prefix; do
      escaped="${prefix//./\\.}"
      sed -i -E "s|(${escaped})[0-9]+\.[0-9]+(\.[0-9]+)?|\1${minor}|g" "${file}"
    done < <(split_list "${CONTAINERFILE_IMAGE_PREFIXES}")
  done < <(containerfile_paths)
}

# calls commit -sm when changes else returns 1.
commit_all() {
  git add --all
  if git diff --staged --quiet; then
    return 1
  fi
  local signoff_arg=()
  is_true "${SIGNOFF}" && signoff_arg=(-s)
  git commit --quiet "${signoff_arg[@]}" -m "${1}"
}

# This generates the contents on the second commit, mostly vendoring.
update_modules() {
  if [[ -n "${DEPS_UPDATE_COMMAND}" ]]; then
    log "Running deps-update-command: ${DEPS_UPDATE_COMMAND}"
    bash -c "${DEPS_UPDATE_COMMAND}"
    return
  fi

  local dir
  while read -r dir; do
    if [[ ! -f "${dir}/go.mod" ]]; then
      log "skipping missing module: ${dir}"
      continue
    fi
    log "go mod tidy in ${dir}"
    (
      cd "${dir}"
      go mod tidy
      if [[ "${VENDOR}" == "true" ]] ||
        { [[ "${VENDOR}" != "false" ]] && [[ -d vendor ]]; }; then
        log "go mod vendor in ${dir}"
        go mod vendor
      fi
    )
  done < <(go_mod_dirs)
  log "Module update finished; working tree status:"
  git status --short | head -100
}

# Push to fork and open the pr on target.
push_and_open_pr() {
  local head_branch head_ref push_repo push_url title body existing
  head_branch="$(render "${HEAD_BRANCH_TEMPLATE}")"

  if [[ -n "${FORK_REPO}" ]]; then
    push_repo="${FORK_REPO}"
    head_ref="${FORK_REPO%%/*}:${head_branch}"
  else
    push_repo="${TARGET_REPO}"
    head_ref="${head_branch}"
  fi

  git checkout -q -B "${head_branch}"

  if [[ "${BRANCH}" == "${DEFAULT_BRANCH}" ]]; then
    title="$(render "${PR_TITLE_TEMPLATE}")"
  else
    title="$(render "${RELEASE_PR_TITLE_TEMPLATE}")"
  fi
  body="$(render "${PR_BODY_TEMPLATE}")"

  if is_true "${DRY_RUN}"; then
    log "dry-run: would push ${head_branch} to ${push_repo} and open:"
    log "  title: ${title}"
    git --no-pager log --oneline "origin/${BRANCH}..HEAD"
    git --no-pager diff --stat "origin/${BRANCH}..HEAD"
    return
  fi

  if [[ -z "${PUSH_TOKEN}" ]]; then
    err "the 'token' input is required to push to ${push_repo}"
    return 1
  fi
  push_url="$(repo_url "${push_repo}" "${PUSH_TOKEN}")"
  git push --quiet "${push_url}" "HEAD:refs/heads/${head_branch}" --force
  log "Pushed ${head_branch} to ${push_repo}"

  existing="$(gh api \
    "repos/${TARGET_REPO}/pulls?state=open&base=${BRANCH}&head=${head_ref}" \
    --jq '.[0].number // empty')"

  if [[ -n "${existing}" ]]; then
    log "PR #${existing} is already open from ${head_ref}; refreshing it"
    jq -n --arg title "${title}" --arg body "${body}" \
      '{title: $title, body: $body}' |
      gh api --method PATCH "repos/${TARGET_REPO}/pulls/${existing}" \
        --input - >/dev/null
    PR_URL="https://github.com/${TARGET_REPO}/pull/${existing}"
    log "Updated ${PR_URL}"
    return
  fi

  # A GITHUB_TOKEN cannot be granted maintainer access on a bot owned fork.
  local draft_flag=false
  is_true "${DRAFT}" && draft_flag=true
  local number
  number="$(jq -n \
    --arg title "${title}" \
    --arg body "${body}" \
    --arg head "${head_ref}" \
    --arg base "${BRANCH}" \
    --argjson draft "${draft_flag}" \
    '{title: $title, body: $body, head: $head, base: $base,
      draft: $draft, maintainer_can_modify: false}' |
    gh api --method POST "repos/${TARGET_REPO}/pulls" --input - \
      --jq '.number')"
  PR_URL="https://github.com/${TARGET_REPO}/pull/${number}"
  log "Opened ${PR_URL}"

  local labels
  labels="$(split_labels "${PR_LABELS}" | jq -R . | jq -sc .)"
  if [[ "${labels}" != "[]" ]]; then
    jq -n --argjson labels "${labels}" '{labels: $labels}' |
      gh api --method POST \
        "repos/${TARGET_REPO}/issues/${number}/labels" --input - >/dev/null ||
      warn "could not apply labels to ${PR_URL}"
  fi
}

main() {
  resolve_target_go
  clone_branch

  local rc=0
  needs_bump || rc=$?
  if [[ ${rc} -eq 2 ]]; then
    return 1
  fi
  if [[ ${rc} -ne 0 ]]; then
    log "No bump needed on ${BRANCH} (already at ${CURRENT_GO})"
    write_result skipped
    return 0
  fi

  log "Bumping ${BRANCH} from ${CURRENT_GO} to ${TARGET_GO}"
  apply_version_changes
  commit_all "$(render "${COMMIT_MESSAGE}")" ||
    {
      err "version rewrite produced no changes on ${BRANCH}"
      return 1
    }

  update_modules
  if commit_all "$(render "${DEPS_COMMIT_MESSAGE}")"; then
    git --no-pager log -1 --stat
  else
    log "No dependency changes to commit"
  fi

  push_and_open_pr
  if is_true "${DRY_RUN}"; then
    write_result dry-run
  else
    write_result bumped
  fi
}

main "$@"
