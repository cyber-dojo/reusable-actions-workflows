# Resolves an opa to run, for scripts that source it. Defines _opa and W, the
# path prefix arguments must carry (the repository root under Docker).
#
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR

ROOT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

# shellcheck source=../test.env
source "${ROOT_DIR}/test.env"

# The `-static` tag is a multi-arch manifest, so it runs natively on Apple
# Silicon; the bare tag is amd64-only and emulates.
OPA_IMAGE="openpolicyagent/opa:${OPA_VERSION}-static"

if command -v opa >/dev/null 2>&1; then
    native="$(command opa version | awk '/^Version:/ { print $2 }')"
    if [[ "${native}" != "${OPA_VERSION}" ]]; then
        echo "warning: opa ${native} on PATH, test.env pins ${OPA_VERSION}" >&2
    fi
    _opa() { command opa "$@"; }
    # shellcheck disable=SC2034  # read by the sourcing script
    W="${ROOT_DIR}"
else
    # -i forwards stdin, which `opa eval --stdin-input` reads.
    _opa() { docker run --rm -i -v "${ROOT_DIR}:/w" "${OPA_IMAGE}" "$@"; }
    # shellcheck disable=SC2034  # read by the sourcing script
    W="/w"
fi
