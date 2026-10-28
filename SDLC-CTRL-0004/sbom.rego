package policy

import data.ergo
import rego.v1

# Dependency Management / SBOM (SDLC-CTRL-0004)
# https://sdlc.kosli.com/controls/build/dependency_management/
# Rego policy reference: https://docs.kosli.com/policy-reference/rego_policy#rego-policy
#
# Control intent (SDLC-CTRL-0004): "Every dependency is defined securely,
# managed, and auditable as part of the software development lifecycle."
# This policy checks the artifact's SBOM against that intent:
#   defined    -> the SBOM exists, is non-empty, and is a real dependency graph
#   managed    -> every package has a concrete version
#   auditable  -> every package has a resolvable purl identity
#
# Package licenses are recorded in the SBOM facts for visibility but are NOT
# checked: a container image always ships GPL-licensed base-OS packages, and
# syft cannot resolve licenses for many ecosystems (Go modules in particular),
# so gating on license would fail every build without adding real assurance.
#
# The checks are ergo requirements, written as sentences in sbom.ergo.yaml, over
# the facts this file builds. This file also decides which overrides are
# active. So it is evaluated as a bundle of this file, sbom.ergo.yaml and
# lib/ergo.rego, never as this file alone.
#
# WHAT THIS POLICY READS
# ----------------------
# kosli evaluate policy runs this policy on the Kosli server, with the trail's
# moment as input.trail. It does NOT expose raw attestation attachments (the raw sbom.spdx.json blob is invisible
# to rego). It DOES expose structured data attested via
#   kosli attest custom --type <schema> --attestation-data <file> --name <name> --fingerprint <digest>
# under input.trail...attestations_statuses[<name>].attestation_data.
#
# So the workflow must distill sbom.spdx.json (SPDX 2.3 JSON) into the small,
# rego-friendly attestation_data contract below, and attest it BEFORE this
# policy is evaluated. sbom.ergo.yaml holds the checks; the jq step only reshapes.
#
# REQUIRED attestation_data CONTRACT (produced by the sbom-facts.jq distill step)
# -------------------------------------------------------------------------------
# {
#   "spec_version": "SPDX-2.3",              # SPDX .spdxVersion
#   "created":      "2026-07-08T12:00:00Z",  # SPDX .creationInfo.created
#   "creators":     ["Tool: syft-..."],      # SPDX .creationInfo.creators
#   "relationship_count": 143,               # (.relationships | length)
#   "packages": [                            # one entry per SPDX .packages[]
#     {
#       "name":    "openssl",                # .name
#       "version": "3.0.13",                 # .versionInfo
#       "license": "Apache-2.0",             # recorded for visibility, not checked
#       "purl":    "pkg:deb/debian/openssl@3.0.13"  # externalRefs[] purl, else ""
#     }
#   ]
# }
#
# The server does not return the input it evaluated. The input path is pinned
# by tests/test_sbom_rego_rules.sh, which builds that input shape.
# If the SBOM facts attestation lands elsewhere, adjust the single `sbom` rule below.
#
# PARAMS (kosli evaluate policy --params @file.json)
#   artifact_name          template reference name of the artifact (eg "saver")
#   sbom_attestation_name  --name of the custom SBOM-facts attestation (eg "sbom-facts")
#   min_packages           minimum package count for a non-empty inventory (eg 1)
#   allowed_spec_versions  allowed SPDX spec versions (eg ["SPDX-2.3"])
#   now                    evaluation date "YYYY-MM-DD"; overrides expire against it
#   overrides             per-service allow-list (see sbom-overrides.schema.json).
#                          Each entry waives one check for one package:
#                            {package, check: version|purl, reason, expires}
#                          A missing / expired / malformed entry waives nothing.
#
# A missing param fails every check that reads it, so allow stays false -- fail
# toward non-compliance. The overrides list is additive (it only makes packages
# pass), so a missing or invalid overrides list makes fewer packages pass --
# also fail toward non-compliance.

control := {"control": "SDLC-CTRL-0004", "title": "Dependency Management", "url": "https://sdlc.kosli.com/controls/build/dependency_management/"}

# METADATA
# entrypoint: true
default allow := false

# Artifact template reference name; falls back to "artifact" to match SDLC-CTRL-0002.
artifact_name := name if {
	name := data.params.artifact_name
	is_string(name)
} else := "artifact"

# Name of the custom attestation carrying the distilled SBOM facts. No fallback:
# "" names no attestation, so the sbom subject is missing and document fails.
sbom_attestation_name := name if {
	name := data.params.sbom_attestation_name
	is_string(name)
} else := ""

# Evaluation date ("YYYY-MM-DD") used to expire overrides. If absent, no
# override is active -- exemptions fail toward non-compliance.
now_date := data.params.now

# ---------------------------------------------------------------------------
# Single source of truth for where the SBOM facts live in the trail input.
# Adjust ONLY this rule if the shape of the trail moment changes.
# ---------------------------------------------------------------------------
sbom := object.get(input, ["trail", "compliance_status", "artifacts_statuses", artifact_name, "attestations_statuses", sbom_attestation_name, "attestation_data"], null)

packages := ps if {
	is_object(sbom)
	ps := sbom.packages
	is_array(ps)
} else := []

override_list := data.params.overrides if is_array(data.params.overrides)

else := []

# ---------------------------------------------------------------------------
# Overrides
# ---------------------------------------------------------------------------

# A field is unset if it is absent, empty, or an SPDX no-value sentinel.
is_unset(v) if not is_string(v)

is_unset(v) if v == ""

is_unset(v) if upper(v) == "NOASSERTION"

is_unset(v) if upper(v) == "NONE"

# The per-package field a named check inspects.
field_of(pkg, "version") := pkg.version

field_of(pkg, "purl") := pkg.purl

# An overrides entry waives one check for one package only when it has a
# non-empty reason and is not expired. A missing / malformed / expired entry
# waives nothing.
exempt(pkg, check) if {
	some e in override_list
	e.package == pkg.name
	e.check == check
	is_string(e.reason)
	e.reason != ""
	override_active(e)
}

# Active while the evaluation date is on or before the entry's expiry date.
# Both are "YYYY-MM-DD", so a lexicographic compare is a chronological compare.
override_active(e) if {
	is_string(e.expires)
	is_string(now_date)
	e.expires >= now_date
}

waived(pkg, check) if exempt(pkg, check)

default waived(_, _) := false

# An override applies where a package it names lacks the field it waives, so
# only those overrides are checked for expiry.
applies(e) if {
	some pkg in packages
	pkg.name == e.package
	is_unset(field_of(pkg, e.check))
}

default applies(_) := false

# ---------------------------------------------------------------------------
# Facts: what ergo checks
# ---------------------------------------------------------------------------

# The input ergo reads. Every value is defined whatever the trail holds, because
# an undefined field would drop the whole document and leave ergo nothing to
# report on. Each subject in sbom.ergo.yaml reads one of these fields.
facts := {
	"sbom": sbom_subject,
	"packages": [package_subject(pkg) | some pkg in packages],
	"overrides": [override_subject(e) | some e in override_list],
}

sbom_subject := s if {
	is_object(sbom)
	s := object.union(sbom, {
		"name": sbom_attestation_name,
		"package_count": inventory_count(object.get(sbom, "packages", null)),
	})
} else := null

inventory_count(ps) := count(ps) if is_array(ps)

else := null

# A package's id is name@version, because an SBOM can list one name at several
# versions (a gem and an apk zlib, say), and ergo needs every id unique.
package_subject(pkg) := {
	"id": sprintf("%v@%v", [object.get(pkg, "name", ""), object.get(pkg, "version", "")]),
	"version": object.get(pkg, "version", null),
	"purl": object.get(pkg, "purl", null),
	"version_waived": waived(pkg, "version"),
	"purl_waived": waived(pkg, "purl"),
}

# An override's id is package/check, because one package can have an override
# for each check.
override_subject(e) := {
	"id": sprintf("%v/%v", [e.package, e.check]),
	"expires": object.get(e, "expires", null),
	"applies": applies(e),
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

params_object := data.params if is_object(data.params)

else := {}

written := {"ergo_spec": data.ergo_spec, "description": data.description, "subjects": data.subjects, "requirements": data.requirements}

policy := object.union(written, {
	"meta": control,
	"requirements": {name: object.union(r, {"meta": control}) | some name, r in written.requirements},
})

# METADATA
# entrypoint: true
report := ergo.report(facts, policy, params_object)

allow if report.compliant

# METADATA
# entrypoint: true
violations := ergo.violations(report)
