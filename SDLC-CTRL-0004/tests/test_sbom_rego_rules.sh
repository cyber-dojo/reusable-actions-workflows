#!/usr/bin/env bash

# Tests for sbom.rego and its distill filter sbom-facts.jq, both living in the
# parent SDLC-CTRL-0004 dir.
#
# The baseline is a genuine SBOM: fixtures/creator-sbom.spdx.json is a real syft
# SPDX slice taken from a cyber-dojo creator-ci build. Tests mutate that real
# SPDX, distill it through the SAME sbom-facts.jq the workflow uses, and
# evaluate the result with `opa eval` (no API calls).
#
# The genuine creator SBOM contains packages that fail the strict per-package
# checks (no license: .ruby-rundeps, minitest-ci, ruby, selenium-manager; no
# purl: selenium-manager). sbom-overrides.creator.json waives exactly those,
# so the policy is only compliant on the real SBOM when those overrides apply.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly control_dir="$(cd "${my_dir}/.." && pwd)"

# Defines _opa, and W, the prefix a path given to _opa must carry.
. "${control_dir}/../bin/lib-opa.sh"

readonly REGO="${W}/SDLC-CTRL-0004/sbom.rego"
readonly ERGO_POLICY="${W}/SDLC-CTRL-0004/sbom.ergo.yaml"
readonly ERGO_LIB="${W}/lib/ergo.rego"
readonly DISTILL="${control_dir}/sbom-facts.jq"
readonly FIXTURE="${my_dir}/fixtures/creator-sbom.spdx.json"
readonly CREATOR_OVERRIDES="${control_dir}/sbom-overrides.creator.json"

# An evaluation date on which the example overrides (expires 2027-01-08) are active.
readonly NOW="2026-07-08"

# Base params with no overrides; individual tests override via make_params.
readonly BASE_PARAMS='{"artifact_name":"creator","sbom_attestation_name":"sbom-facts","min_packages":1,"allowed_spec_versions":["SPDX-2.3"],"now":"2026-07-08","overrides":[]}'

# Distill an SPDX document (passed as a JSON string) through the shared filter.
distill()
{
  echo "${1}" | jq -f "${DISTILL}"
}

# The overrides array from a per-service allow-list file.
overrides_of()
{
  jq -c '.overrides' "${1}"
}

# Build a --params object: base config plus an evaluation date and overrides.
# now="" omits the now param entirely (to test the missing-now fail-safe).
make_params()
{
  local -r now="${1}"
  local -r overrides="${2:-[]}"
  jq -n --arg now "${now}" --argjson ovr "${overrides}" \
    '{artifact_name:"creator", sbom_attestation_name:"sbom-facts", min_packages:1, allowed_spec_versions:["SPDX-2.3"], overrides:$ovr}
     + (if $now == "" then {} else {now:$now} end)'
}

# A minimal well-formed facts document carrying the given packages array, so
# only the per-package checks are exercised (document/inventory/graph all pass).
facts_with()
{
  jq -n --argjson pkgs "${1}" \
    '{spec_version: "SPDX-2.3", created: "2026-07-03T00:00:00Z", creators: ["Tool: syft-v1.42.3"], relationship_count: 5, packages: $pkgs}'
}

# Wrap distilled SBOM facts in the trail input shape the policy expects.
wrap_facts()
{
  jq -n \
    --argjson facts "${1}" \
    '{
      trail: {
        name: "test-trail",
        compliance_status: {
          artifacts_statuses: {
            creator: {attestations_statuses: {"sbom-facts": {attestation_data: $facts}}}
          }
        }
      }
    }'
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Distill correctness, verified against the genuine fixture

test_distill_excludes_the_spdx_document_root_package()
{
  # The real fixture contains the document-root package (name "sbom"); the
  # distill must drop it because it is the image itself, not a dependency.
  local -r raw="$(jq '[.packages[] | select(.name == "sbom")] | length' "${FIXTURE}")"
  assertEquals "fixture must contain the document-root package" "1" "${raw}"
  local -r facts="$(distill "$(cat "${FIXTURE}")")"
  local -r kept="$(echo "${facts}" | jq '[.packages[] | select(.name == "sbom")] | length')"
  assertEquals "document-root package must be excluded" "0" "${kept}"
  local -r count="$(echo "${facts}" | jq '.packages | length')"
  assertEquals "distilled package count" "21" "${count}"
}

test_distill_uses_declared_license_when_concluded_is_noassertion()
{
  # syft leaves licenseConcluded=NOASSERTION and puts the license in
  # licenseDeclared; the distill must fall back to the declared value.
  local -r facts="$(distill "$(cat "${FIXTURE}")")"
  local -r license="$(echo "${facts}" | jq -r '[.packages[] | select(.name == "abbrev")][0].license')"
  assertEquals "abbrev license from licenseDeclared" "BSD-2-Clause AND Ruby" "${license}"
}

test_distill_extracts_purl_and_not_a_cpe_reference()
{
  # A package carries both cpe23Type and purl externalRefs; the distill must
  # pick the purl, not the first (cpe) reference.
  local -r facts="$(distill "$(cat "${FIXTURE}")")"
  local -r purl="$(echo "${facts}" | jq -r '[.packages[] | select(.name == "addressable")][0].purl')"
  assertEquals "addressable purl" "pkg:gem/addressable@2.9.0" "${purl}"
}

test_distill_reports_the_real_document_metadata()
{
  local -r facts="$(distill "$(cat "${FIXTURE}")")"
  assertEquals "spec_version"       "SPDX-2.3" "$(echo "${facts}" | jq -r '.spec_version')"
  assertEquals "created recorded"   "false"    "$(echo "${facts}" | jq -r '.created == ""')"
  assertEquals "syft creator kept"  "1"        "$(echo "${facts}" | jq '[.creators[] | select(test("syft"))] | length')"
  assertEquals "relationship_count" "26"       "$(echo "${facts}" | jq '.relationship_count')"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Overrides allow-list, driven off the genuine SBOM

test_allow_genuine_sbom_when_service_overrides_cover_the_gaps()
{
  # The real creator SBOM only becomes compliant when its overrides apply.
  local -r facts="$(distill "$(cat "${FIXTURE}")")"
  evaluate_facts "${facts}" "$(make_params "${NOW}" "$(overrides_of "${CREATOR_OVERRIDES}")")"
  assert_allow
}

test_deny_genuine_sbom_when_no_overrides_apply()
{
  # Only the purl gap fails; licenseless packages (.ruby-rundeps, minitest-ci,
  # ruby) are no longer checked, so they must not appear as violations.
  local -r facts="$(distill "$(cat "${FIXTURE}")")"
  evaluate_facts "${facts}" "$(make_params "${NOW}" '[]')"
  assert_deny
  assert_violation purls purl_set selenium-manager@UNKNOWN
  assert_violation_count 1
}

test_deny_when_the_override_has_expired()
{
  # Same overrides, but evaluated after their expiry date: the waivers lapse.
  local -r facts="$(distill "$(cat "${FIXTURE}")")"
  evaluate_facts "${facts}" "$(make_params "2027-06-01" "$(overrides_of "${CREATOR_OVERRIDES}")")"
  assert_deny
  assert_violation purls purl_set selenium-manager@UNKNOWN
  assert_violation overrides not_expired selenium-manager/purl
}

test_no_waiver_when_the_now_param_is_absent()
{
  # Without an evaluation date, no override can be active -- fail toward non-compliance.
  local -r facts="$(distill "$(cat "${FIXTURE}")")"
  evaluate_facts "${facts}" "$(make_params "" "$(overrides_of "${CREATOR_OVERRIDES}")")"
  assert_deny
  assert_violation purls purl_set selenium-manager@UNKNOWN
}

test_override_waives_only_its_named_check()
{
  # A package missing both version and purl, waived only for purl: the purl
  # check passes while the version check still fails. Per-check granularity.
  local -r facts="$(facts_with '[{"name":"selenium-manager","version":"","license":"NOASSERTION","purl":""}]')"
  local -r ovr='[{"package":"selenium-manager","check":"purl","reason":"vendored binary, no purl","expires":"2027-01-08"}]'
  evaluate_facts "${facts}" "$(make_params "${NOW}" "${ovr}")"
  assert_deny
  assert_violation versions version_set selenium-manager@
  refute_violation purls purl_set selenium-manager@
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Package identity, driven off the entries syft gives saver's selenium-manager

test_allow_when_one_version_is_listed_under_two_purls()
{
  local -r facts="$(facts_with '[
    {"name":"selenium-manager","version":"0.4.51","license":"Apache-2.0","purl":"pkg:cargo/selenium-manager@0.4.51?download_url=file://."},
    {"name":"selenium-manager","version":"0.4.51","license":"NOASSERTION","purl":"pkg:cargo/selenium-manager@0.4.51?download_url=file://.#src/main.rs"}
  ]')"
  evaluate_facts "${facts}"
  assert_allow
}

test_allow_when_a_package_is_listed_twice_identically()
{
  local -r facts="$(facts_with '[
    {"name":"selenium-manager","version":"0.4.51","license":"Apache-2.0","purl":"pkg:cargo/selenium-manager@0.4.51?download_url=file://."},
    {"name":"selenium-manager","version":"0.4.51","license":"Apache-2.0","purl":"pkg:cargo/selenium-manager@0.4.51?download_url=file://."}
  ]')"
  evaluate_facts "${facts}"
  assert_allow
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Document metadata checks (rego), driven off mutations of the real SPDX

test_deny_when_spec_version_not_allowed()
{
  evaluate_spdx "$(jq '.spdxVersion = "SPDX-2.2"' "${FIXTURE}")"
  assert_deny
  assert_violation document spec_version
}

test_deny_when_created_timestamp_blank()
{
  evaluate_spdx "$(jq '.creationInfo.created = ""' "${FIXTURE}")"
  assert_deny
  assert_violation document created
}

test_deny_when_no_creators_recorded()
{
  evaluate_spdx "$(jq '.creationInfo.creators = []' "${FIXTURE}")"
  assert_deny
  assert_violation document creators
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Dependency graph and inventory presence

test_deny_when_no_relationships()
{
  evaluate_spdx "$(jq '.relationships = []' "${FIXTURE}")"
  assert_deny
  assert_violation document dependency_graph
}

test_deny_when_inventory_is_empty()
{
  evaluate_spdx "$(jq '.packages = []' "${FIXTURE}")"
  assert_deny
  assert_violation document inventory_size
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Rego fail-safes (malformed attestation the distill would never emit)

test_deny_when_sbom_facts_attestation_missing()
{
  # Artifact present in the trail, but carrying no sbom-facts attestation.
  evaluate_input "$(jq -n '{trail: {name: "t", compliance_status: {artifacts_statuses: {creator: {attestations_statuses: {}}}}}}')"
  assert_deny
  assert_violation document '$min_subjects'
}

test_deny_when_packages_is_not_an_array_fails_safe()
{
  # Genuine facts with only .packages corrupted -- allow must be false and the
  # diagnostic must name the malformed attestation.
  local -r facts="$(distill "$(cat "${FIXTURE}")" | jq '.packages = "not-an-array"')"
  evaluate_facts "${facts}"
  assert_deny
  assert_violation document inventory
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# Evaluate a complete policy input (trail JSON) against the rego. The params go
# in the query rather than a file, so a Docker opa needs no mount but the repo.
evaluate_input()
{
  local -r input="${1}"
  local -r params="${2:-${BASE_PARAMS}}"
  _opa eval --stdin-input --format raw \
    --data "${REGO}" --data "${ERGO_POLICY}" --data "${ERGO_LIB}" \
    "{\"allow\": data.policy.allow, \"violations\": data.policy.violations} with data.params as ${params}" \
    <<<"${input}" >"${stdoutF}" 2>"${stderrF}"
  echo $? >"${statusF}"
}

# Evaluate distilled SBOM facts (wrapped into a trail input) against the rego.
evaluate_facts()
{
  evaluate_input "$(wrap_facts "${1}")" "${2:-${BASE_PARAMS}}"
}

# Distill an SPDX document and evaluate the resulting facts against the rego.
evaluate_spdx()
{
  evaluate_facts "$(distill "${1}")" "${2:-${BASE_PARAMS}}"
}

# Assert the policy allowed (allow == true) with no violations.
assert_allow()
{
  assertEquals "allow:$(dump_sss)" "true" "$(jq '.allow' "${stdoutF}")"
  assertEquals "violations:$(dump_sss)" "0" "$(jq '.violations | length' "${stdoutF}")"
}

# Assert the policy denied (allow == false), read from stdout regardless of exit.
assert_deny()
{
  assertEquals "allow:$(dump_sss)" "false" "$(jq '.allow' "${stdoutF}")"
}

# How many violations fail the given requirement's check, for any subject when
# subject_id is "". A jq error is printed in place of the count, so neither
# assertion below can mistake it for one.
violations_of()
{
  local -r requirement="${1}" check="${2}" subject_id="${3:-}"
  jq --arg r "${requirement}" --arg c "${check}" --arg id "${subject_id}" \
    '[.violations[]? | select(.requirement == $r and .check == $c and ($id == "" or .subject.id == $id))] | length' \
    "${stdoutF}" 2>&1
}

# Assert the requirement's check failed, for the subject when one is given.
assert_violation()
{
  local -r count="$(violations_of "$@")"
  case "${count}" in
    '' | *[!0-9]* | 0)
      dump_sss
      fail "expected a violation of ${1}.${2}${3:+ for '${3}'}, got: ${count}"
      ;;
  esac
}

# Assert the requirement's check did not fail, for the subject when one is given.
refute_violation()
{
  local -r count="$(violations_of "$@")"
  if [ "${count}" != "0" ]; then
    dump_sss
    fail "expected no violation of ${1}.${2}${3:+ for '${3}'}, got: ${count}"
  fi
}

# Assert exactly this many violations were reported.
assert_violation_count()
{
  assertEquals "violation count:$(dump_sss)" "${1}" "$(jq '.violations | length' "${stdoutF}")"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "::${0##*/}"
. ${my_dir}/shunit2_helpers.sh
. ${my_dir}/shunit2
