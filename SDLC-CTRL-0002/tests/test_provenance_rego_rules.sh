#!/usr/bin/env bash

# Tests for slsa-provenance.rego and its distill filter provenance-facts.jq,
# both living in the parent SDLC-CTRL-0002 dir.
#
# The baseline is a genuine GitHub sigstore attestation bundle:
# fixtures/custom-start-points-provenance.json is the real bundle from a
# cyber-dojo custom-start-points build. Tests distill it through the SAME
# provenance-facts.jq the workflow uses, then wrap the facts in a trail and
# evaluate with `kosli evaluate input` (no API calls). Negative cases mutate
# either the distilled facts or the trail values they are cross-checked against.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly control_dir="$(cd "${my_dir}/.." && pwd)"

readonly REGO="${control_dir}/slsa-provenance.rego"
readonly DISTILL="${control_dir}/provenance-facts.jq"
readonly FIXTURE="${my_dir}/fixtures/custom-start-points-provenance.json"

# The genuine values in the fixture (used to pin the distill output).
readonly REAL_SUBJECT_DIGEST="dd604131d80f7e188c94472211eb4859c2d50568b46dca3c088ea3af08e48a40"
readonly REAL_SOURCE_COMMIT="fa54f696648b78ac710d6f7e2357139eb9c3c89b"
readonly REAL_SOURCE_REPO="https://github.com/cyber-dojo/custom-start-points"

# A different genuine custom-start-points commit, for an artifact recorded
# against a commit other than the one the builder attested.
readonly OTHER_SOURCE_COMMIT="7dea378dc49b23ed66cd5a57e74060d90bc0a349"

# A genuine cyber-dojo saver image digest, for an artifact whose fingerprint is
# not the image the provenance is about.
readonly OTHER_SUBJECT_DIGEST="9cfef3281fc531a3c5a5a00ed8a67256e1b954b5271b03936808623960afebfc"

readonly PARAMS='{
  "artifact_name": "custom-start-points",
  "provenance_attestation_name": "provenance-facts",
  "allowed_predicate_types": ["https://slsa.dev/provenance/v1"],
  "allowed_build_types": ["https://actions.github.io/buildtypes/workflow/v1"],
  "expected_builder_id_prefix": "https://github.com/cyber-dojo/reusable-actions-workflows/.github/workflows/",
  "expected_source_repo_prefix": "https://github.com/cyber-dojo/"
}'

# Distill the genuine bundle into the provenance-facts contract.
distill()
{
  jq -f "${DISTILL}" "${FIXTURE}"
}

# Wrap provenance facts in the trail input shape the policy expects, with the
# given artifact fingerprint and artifact commit (the values the rego
# cross-checks). The commit sits on the artifact entry, where the server-side
# trail moment carries it.
wrap()
{
  jq -n \
    --argjson facts "${1}" \
    --arg fingerprint "${2}" \
    --arg commit "${3}" \
    '{
      trail: {
        name: "test-trail",
        compliance_status: {
          artifacts_statuses: {
            "custom-start-points": {
              artifact_fingerprint: $fingerprint,
              git_commit_info: {sha1: $commit},
              attestations_statuses: {"provenance-facts": {attestation_data: $facts}}
            }
          }
        }
      }
    }'
}

# Wrap facts with a trail whose fingerprint and commit match the facts, so that
# only a field deliberately mutated in the facts can cause a failure.
wrap_matching()
{
  local -r facts="${1}"
  wrap "${facts}" "$(echo "${facts}" | jq -r '.subject_digest')" "$(echo "${facts}" | jq -r '.source_git_commit')"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Distill correctness, verified against the genuine bundle

test_distill_decodes_the_slsa_v1_statement_from_the_bundle()
{
  local -r f="$(distill)"
  assertEquals "predicate_type" "https://slsa.dev/provenance/v1" "$(echo "${f}" | jq -r '.predicate_type')"
  assertEquals "build_type"     "https://actions.github.io/buildtypes/workflow/v1" "$(echo "${f}" | jq -r '.build_type')"
  assertEquals "builder is the reusable workflow" "true" \
    "$(echo "${f}" | jq -r '.builder_id | startswith("https://github.com/cyber-dojo/reusable-actions-workflows/.github/workflows/")')"
}

test_distill_extracts_the_git_source_commit_and_repo()
{
  local -r f="$(distill)"
  assertEquals "source_git_commit" "${REAL_SOURCE_COMMIT}" "$(echo "${f}" | jq -r '.source_git_commit')"
  assertEquals "source_repo"       "${REAL_SOURCE_REPO}"   "$(echo "${f}" | jq -r '.source_repo')"
  assertEquals "source_uri is a git material" "true" "$(echo "${f}" | jq -r '.source_uri | startswith("git+")')"
}

test_distill_extracts_the_subject_digest()
{
  local -r f="$(distill)"
  assertEquals "subject_digest" "${REAL_SUBJECT_DIGEST}" "$(echo "${f}" | jq -r '.subject_digest')"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Compliant case

test_allow_when_subject_and_source_match_the_trail()
{
  # The real provenance is compliant when the trail's fingerprint and commit are
  # the ones the builder attested.
  evaluate_input "$(wrap_matching "$(distill)")"
  assert_allow
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Cross-checks against the trail

test_deny_when_provenance_facts_attestation_missing()
{
  evaluate_input "$(jq -n \
    --arg fingerprint "${REAL_SUBJECT_DIGEST}" \
    --arg commit "${REAL_SOURCE_COMMIT}" \
    '{trail: {name: "t", compliance_status: {artifacts_statuses: {"custom-start-points": {artifact_fingerprint: $fingerprint, git_commit_info: {sha1: $commit}, attestations_statuses: {}}}}}}')"
  assert_deny
  assert_violation_message "no 'provenance-facts' provenance-facts attestation found under artifact 'custom-start-points' -- SLSA provenance was not attested as structured data"
}

test_deny_when_subject_digest_does_not_match_the_fingerprint()
{
  local -r f="$(distill)"
  evaluate_input "$(wrap "${f}" "${OTHER_SUBJECT_DIGEST}" "${REAL_SOURCE_COMMIT}")"
  assert_deny
  assert_violation_message "provenance subject digest '${REAL_SUBJECT_DIGEST}' does not match the artifact fingerprint '${OTHER_SUBJECT_DIGEST}'"
}

test_deny_when_source_commit_does_not_match_the_artifact_commit()
{
  local -r f="$(distill)"
  evaluate_input "$(wrap "${f}" "${REAL_SUBJECT_DIGEST}" "${OTHER_SOURCE_COMMIT}")"
  assert_deny
  assert_violation_message "provenance source commit '${REAL_SOURCE_COMMIT}' does not match the artifact commit '${OTHER_SOURCE_COMMIT}'"
}

test_deny_when_facts_and_trail_are_both_blank_do_not_falsely_match()
{
  # The distill emits "" for missing fields; "" must NOT match "". This is the
  # critical guard - blank provenance must fail, not silently pass.
  local -r f="$(distill | jq '.subject_digest = "" | .source_git_commit = ""')"
  evaluate_input "$(wrap "${f}" "" "")"
  assert_deny
  assert_violation_message "provenance subject digest '' does not match the artifact fingerprint ''"
  assert_violation_message "provenance source commit '' does not match the artifact commit ''"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Builder / source / type checks (mutating the distilled facts)

test_deny_when_builder_is_not_trusted()
{
  local -r f="$(distill | jq '.builder_id = "https://github.com/evil/attacker/.github/workflows/x.yml@main"')"
  evaluate_input "$(wrap_matching "${f}")"
  assert_deny
  assert_violation_message "provenance builder 'https://github.com/evil/attacker/.github/workflows/x.yml@main' is not a trusted builder (expected prefix 'https://github.com/cyber-dojo/reusable-actions-workflows/.github/workflows/')"
}

test_deny_when_source_repo_is_not_expected()
{
  local -r f="$(distill | jq '.source_repo = "https://github.com/evil/attacker"')"
  evaluate_input "$(wrap_matching "${f}")"
  assert_deny
  assert_violation_message "provenance source_repo 'https://github.com/evil/attacker' is not an expected repository (expected prefix 'https://github.com/cyber-dojo/')"
}

test_deny_when_build_type_is_not_allowed()
{
  local -r f="$(distill | jq '.build_type = "https://evil.example/buildtype"')"
  evaluate_input "$(wrap_matching "${f}")"
  assert_deny
  assert_violation_message "provenance build_type 'https://evil.example/buildtype' is not in the allowed set"
}

test_deny_when_predicate_type_is_not_allowed()
{
  local -r f="$(distill | jq '.predicate_type = "https://slsa.dev/provenance/v0.2"')"
  evaluate_input "$(wrap_matching "${f}")"
  assert_deny
  assert_violation_message "provenance predicate_type 'https://slsa.dev/provenance/v0.2' is not in the allowed set"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

evaluate_input()
{
  echo "${1}" | kosli evaluate input \
    --policy "${REGO}" \
    --params "${PARAMS}" \
    --output json \
    >"${stdoutF}" 2>"${stderrF}"
  echo $? >"${statusF}"
}

assert_allow()
{
  assertEquals "allow:$(dump_sss)" "true" "$(jq '.allow' "${stdoutF}")"
  assertEquals "violations:$(dump_sss)" "null" "$(jq '.violations' "${stdoutF}")"
}

assert_deny()
{
  assertEquals "allow:$(dump_sss)" "false" "$(jq '.allow' "${stdoutF}")"
}

assert_violation_message()
{
  local -r expected="${1}"
  local found
  found="$(jq --arg s "${expected}" '.violations[] | select(. == $s)' "${stdoutF}")"
  if [ -z "${found}" ]; then
    dump_sss
    fail "expected violations to include '${expected}'"
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "::${0##*/}"
. ${my_dir}/shunit2_helpers.sh
. ${my_dir}/shunit2
