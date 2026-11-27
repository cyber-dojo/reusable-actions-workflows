# Runs the standalone test suites: the rego policies, and the bare image
# stage hash. Each keeps its own tests/ dir (shunit2 helpers, fixtures,
# runner) so it can be exercised in isolation. CI gates the build on all
# three in a single call:
#
#   make test-provenance test-sbom test-bare-image-hash

.PHONY: test-provenance test-sbom test-bare-image-hash

test-provenance:
	./SDLC-CTRL-0002/tests/run_tests.sh

test-sbom:
	./SDLC-CTRL-0004/tests/run_tests.sh

# The instructions the hash-bare-image-stage action hashes into the bare
# image's cache key.
test-bare-image-hash:
	./.github/actions/hash-bare-image-stage/tests/run_tests.sh
