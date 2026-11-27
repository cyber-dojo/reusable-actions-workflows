#!/usr/bin/env bash
set -Eeuo pipefail

# Prints the instructions of a Dockerfile's bare image stage, the lines the
# hash-bare-image-stage action hashes into the bare image's cache key: every
# line up to and including the FROM that starts the stage after the
# FROM ... AS <stage> line, whatever that FROM says, without comments or blank
# lines.
#
# Use: bare_image_stage_instructions.sh DOCKERFILE STAGE
# eg:  bare_image_stage_instructions.sh ./Dockerfile base

readonly DOCKERFILE="${1}"
readonly STAGE="${2}"

INSTRUCTIONS="$(awk -v stage="${STAGE}" '
    { print }
    in_stage && $1 == "FROM" { ended = 1; exit }
    $1 == "FROM" && $(NF-1) == "AS" && $NF == stage { in_stage = 1 }
    END { if (!ended) exit 1 }
  ' "${DOCKERFILE}")" \
  || { >&2 echo "No 'FROM ... AS ${STAGE}' stage followed by another FROM in ${DOCKERFILE}"; exit 1; }
grep --invert-match --extended-regexp '^[[:space:]]*(#|$)' <<<"${INSTRUCTIONS}"
