#!/usr/bin/env bash
# Shared helpers for the go-patch-version action.
# shellcheck shell=bash

# Print message on the stdout.
log() {
  printf '%s\n' "$*"
}

# Print error on the stderr with a prefix.
err() {
  printf '::error::%s\n' "$*" >&2
}

# Print warning on the stderr with a prefix.
warn() {
  printf '::warning::%s\n' "$*" >&2
}

# split_list <value> - print one item per line, splitting on whitespace,
# newlines and commas, drops empties and comments.
split_list() {
  printf '%s' "${1-}" |
    tr ',' '\n' |
    tr -s '[:space:]' '\n' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    grep -v -e '^$' -e '^#' || true
}

# split_labels <value> - like split_list but only splits on newlines and
# commas, so items may contain spaces.
split_labels() {
  printf '%s' "${1-}" |
    tr ',' '\n' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    grep -v -e '^$' -e '^#' || true
}

# is_version <value> - return true when value looks like x.y or x.y.z else false.
is_version() {
  [[ "${1-}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

# minor_of <version> - strip the .z from version (1.26.3 -> 1.26).
minor_of() {
  local v="${1}"
  if [[ "${v}" == *.*.* ]]; then
    printf '%s' "${v%.*}"
  else
    printf '%s' "${v}"
  fi
}

# version_lt <a> <b> - true when a is less than b.
version_lt() {
  [[ "${1}" != "${2}" ]] &&
    [[ "$(printf '%s\n%s\n' "${1}" "${2}" | sort -V | tail -n1)" == "${2}" ]]
}

# repo_url <owner/name> [token] - constructs git urls like:
# https://x-access-token:EXAMPLE_TOKEN@GITHUB_SERVER_URL/owner/name.git when token.
# https://GITHUB_SERVER_URL/owner/name.git when no token.
repo_url() {
  local server="${GITHUB_SERVER_URL:-https://github.com}"
  server="${server%/}"
  if [[ -n "${2-}" && "${server}" == https://* ]]; then
    printf 'https://x-access-token:%s@%s/%s.git' \
      "${2}" "${server#https://}" "${1}"
  else
    printf '%s/%s.git' "${server}" "${1}"
  fi
}

# render <template> - substitute the {placeholder} tokens from the current
# branch context. Expects BRANCH, CURRENT_GO, TARGET_GO, IMAGE_DESC,
# TARGET_REPO and DEFAULT_BRANCH to be set.
render() {
  local out="${1}"
  out="${out//\{branch\}/${BRANCH}}"
  out="${out//\{from\}/${CURRENT_GO}}"
  out="${out//\{to\}/${TARGET_GO}}"
  out="${out//\{to_minor\}/$(minor_of "${TARGET_GO}")}"
  out="${out//\{image\}/${IMAGE_DESC}}"
  out="${out//\{repo\}/${TARGET_REPO}}"
  out="${out//\{default_branch\}/${DEFAULT_BRANCH}}"
  printf '%s' "${out}"
}

# is_true <value> - returns true for `true`, `yes` and `1`.
is_true() {
  [[ "${1-}" == "true" || "${1-}" == "yes" || "${1-}" == "1" ]]
}

# go_mod_dirs - module directories to act on, one per line, relative to the
# current directory. Honours GO_MOD_PATHS ("auto" discovers them).
go_mod_dirs() {
  local raw="${GO_MOD_PATHS:-auto}" dir
  if [[ -z "${raw}" || "${raw}" == "auto" ]]; then
    find . -name go.mod -not -path '*/vendor/*' -not -path './.git/*' -print |
      sed -e 's|/go.mod$||' -e 's|^\./||' -e 's|^go.mod$|.|' |
      sort
    return
  fi
  while read -r dir; do
    dir="${dir%/}"               # Remove trailing slash
    dir="${dir#./}"              # Remove leading ./
    [[ -z "${dir}" ]] && dir="." # ./ to .
    printf '%s\n' "${dir}"
  done < <(split_list "${raw}")
}

# containerfile_paths - Containerfiles to rewrite, one per line.
containerfile_paths() {
  local raw="${CONTAINERFILES:-auto}"
  case "${raw}" in
  none | "")
    return
    ;;
  auto)
    find . \( -name 'Dockerfile*' -o -name 'Containerfile*' \) \
      -not -path '*/vendor/*' -not -path './.git/*' -print |
      sed -e 's|^\./||' |
      sort
    ;;
  *)
    split_list "${raw}"
    ;;
  esac
}
