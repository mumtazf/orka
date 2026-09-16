#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v go >/dev/null
fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT
commit="$(git -C "${root}" rev-parse HEAD)"

assert_contains() {
  if ! grep -Fq -- "$2" "$1"; then
    printf 'FAIL: expected %s in %s\n' "$2" "$1" >&2
    exit 1
  fi
}

assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    printf 'FAIL: unexpected %s in %s\n' "$2" "$1" >&2
    exit 1
  fi
}

cat > "${fixture_dir}/go.mod" <<'EOF'
module example.com/coveragefixture

go 1.20
EOF

cat > "${fixture_dir}/fixture.go" <<'EOF'
package coveragefixture

func Covered() int {
    return 1
}

func Uncovered() int {
    value := 1
    value++
    return value
}
EOF

cat > "${fixture_dir}/valid.out" <<'EOF'
mode: set
example.com/coveragefixture/fixture.go:3.20,5.2 1 1
example.com/coveragefixture/fixture.go:7.22,11.2 3 0
EOF

touch "${fixture_dir}/empty.out"
printf 'mode: set\n' > "${fixture_dir}/header-only.out"
printf 'not a Go coverage profile\n' > "${fixture_dir}/invalid.out"

for outcome in success failure skipped cancelled; do
  for profile_case in valid missing empty header-only invalid; do
    summary="${fixture_dir}/${profile_case}-${outcome}.md"
    (
      cd "${fixture_dir}"
      TEST_OUTCOME="${outcome}" GITHUB_STEP_SUMMARY="${summary}" GITHUB_SHA=not-the-checked-out-commit \
        bash "${root}/scripts/go-coverage-summary.sh" "${fixture_dir}/${profile_case}.out"
    )

    assert_contains "${summary}" "${commit}"
    assert_not_contains "${summary}" 'not-the-checked-out-commit'
    assert_contains "${summary}" 'existing `make test` non-E2E Go run'
    assert_contains "${summary}" "Go test outcome: **${outcome}**"

    case "${profile_case}" in
      valid)
        assert_contains "${summary}" 'Available: valid Go coverage profile'
        assert_contains "${summary}" 'Total statement coverage: **25.0%**'
        ;;
      missing) assert_contains "${summary}" 'Missing:' ;;
      empty|header-only) assert_contains "${summary}" 'Empty:' ;;
      invalid) assert_contains "${summary}" 'Invalid or unreadable:' ;;
    esac

    if [[ "${profile_case}" != valid ]]; then
      assert_not_contains "${summary}" '%'
      assert_not_contains "${summary}" 'Total statement coverage:'
    fi
    if [[ "${outcome}" == success ]]; then
      assert_not_contains "${summary}" 'incomplete diagnostic output'
    else
      assert_contains "${summary}" 'incomplete diagnostic output'
      assert_contains "${summary}" 'not an accepted baseline'
    fi
    printf 'ok - %s profile / %s outcome\n' "${profile_case}" "${outcome}"
  done
done