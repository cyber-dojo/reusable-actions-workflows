#!/usr/bin/env bash

# Tests for bare_image_stage_instructions.sh, in the parent action dir, which
# prints the instructions of a Dockerfile's bare image stage that the
# hash-bare-image-stage action hashes into the bare image's cache key.
#
# The fixtures are genuine Dockerfiles: differ.Dockerfile is differ's at
# 837321f, whose base stage is followed by a FROM base stage,
# web.Dockerfile is web's at fa7cd539c, whose base stage is followed by an
# asset stage, and nginx.Dockerfile is nginx's at a173ddb, which has no base
# stage.

readonly my_dir="$(cd "$(dirname "${0}")" && pwd)"
readonly action_dir="$(cd "${my_dir}/.." && pwd)"
readonly SCRIPT="${action_dir}/bare_image_stage_instructions.sh"
readonly DIFFER="${my_dir}/fixtures/differ.Dockerfile"
readonly NGINX="${my_dir}/fixtures/nginx.Dockerfile"
readonly WEB="${my_dir}/fixtures/web.Dockerfile"

test_prints_the_base_stage_instructions_through_the_FROM_base_line()
{
  # Comments and blank lines are not instructions, so they are not printed.
  local -r expected=(
    'FROM ghcr.io/cyber-dojo/sinatra-base:4d448af@sha256:d2d3fd0451afc5954ea4433e41f6f17ad6ad856bf607c9cd23dd4cf9c32b6ce8 AS base'
    'LABEL maintainer=jon@jaggersoft.com'
    'ARG APK_REFRESH=1'
    'RUN apk --update --upgrade --no-cache add git'
    'RUN gem install --no-document path_coverage --version 0.7.2'
    'ARG APP_DIR=/differ'
    'ENV APP_DIR=${APP_DIR}'
    'WORKDIR ${APP_DIR}/source'
    'USER nobody'
    'FROM base'
  )
  stage_instructions "${DIFFER}" base
  assert_status_0
  assert_stderr_empty
  assert_stdout_equals "$(printf '%s\n' "${expected[@]}")"
}

test_the_instructions_hash_to_the_cache_key_differ_has_today()
{
  # The hash differ's bare image is cached by now, so its cache still hits.
  stage_instructions "${DIFFER}" base
  assert_status_0
  assertEquals 'c696b15fa46bff12f83bf44b0a3beff9227a2473b77d07c7bc027f7a3008b587' \
    "$(shasum -a 256 < "${stdoutF}" | cut -d' ' -f1)"
}

test_prints_the_base_stage_instructions_through_the_next_FROM_whatever_it_says()
{
  # web's three apps each build FROM base, but the stage after base is an
  # asset stage built FROM another image, so no line is exactly FROM base.
  local -r expected=(
    'FROM ghcr.io/cyber-dojo/sinatra-base:4d448af@sha256:d2d3fd0451afc5954ea4433e41f6f17ad6ad856bf607c9cd23dd4cf9c32b6ce8 AS base'
    'FROM --platform=$BUILDPLATFORM cyberdojo/asset_builder:4f30636 AS creator-assets'
  )
  stage_instructions "${WEB}" base
  assert_status_0
  assert_stderr_empty
  assert_stdout_equals "$(printf '%s\n' "${expected[@]}")"
}

test_fails_when_there_is_no_base_stage()
{
  stage_instructions "${NGINX}" base
  assert_status_equals 1
  assert_stdout_empty
  assert_stderr_equals "No 'FROM ... AS base' stage followed by another FROM in ${NGINX}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# Runs the script on the given Dockerfile and stage, capturing its stdout,
# stderr and exit status for the assert_ functions.
stage_instructions()
{
  "${SCRIPT}" "${1}" "${2}" >"${stdoutF}" 2>"${stderrF}"
  echo $? >"${statusF}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

echo "::${0##*/}"
. ${my_dir}/shunit2_helpers.sh
. ${my_dir}/shunit2
