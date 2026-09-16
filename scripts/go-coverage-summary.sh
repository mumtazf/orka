#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-cover.out}"
: "${TEST_OUTCOME:?TEST_OUTCOME must be set}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY must be set}"

commit="$(git -C "${root}" rev-parse HEAD)"
status='Invalid or unreadable: the profile could not be processed by `go tool cover`.'
total=''

if [[ ! -f "${profile}" ]]; then
  status='Missing: no coverage profile was produced.'
elif [[ ! -s "${profile}" ]]; then
  status='Empty: the coverage profile contains no data.'
elif report="$(go tool cover -func="${profile}" 2>/dev/null)"; then
  total="$(awk '$1 == "total:" && $2 == "(statements)" { print $3 }' <<< "${report}")"
  if [[ "${report}" == total:* ]]; then
    status='Empty: the coverage profile contains no function data.'
    total=''
  elif [[ "${total}" =~ ^[0-9]+([.][0-9]+)?%$ ]]; then
    status='Available: valid Go coverage profile.'
  else
    total=''
  fi
fi

{
  printf '## Go Test Coverage\n\n'
  printf -- '- Tested commit: `%s`\n' "${commit}"
  printf -- '- Scope: existing `make test` non-E2E Go run.\n'
  printf -- '- Go test outcome: **%s**\n' "${TEST_OUTCOME}"
  printf -- '- Report: %s\n' "${status}"
  if [[ -n "${total}" ]]; then
    printf -- '- Total statement coverage: **%s**\n' "${total}"
  fi
  if [[ "${TEST_OUTCOME}" != success ]]; then
    printf '\nAny available report is **incomplete diagnostic output**, not an accepted baseline, because the Go test step did not succeed.\n'
  fi
} >> "${GITHUB_STEP_SUMMARY}"