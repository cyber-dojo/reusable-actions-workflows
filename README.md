# reusable-actions-workflows

Reusable GitHub Actions workflows used by cyber-dojo Org repos to build a
service's docker image securely and attest it to Kosli for compliance.

| Workflow | What it does |
| --- | --- |
| [`build-bare-image.yml`](#build-bare-imageyml) | Builds the `Dockerfile`'s bare image (OS packages, language, libraries, no source code), for the caller to run its unit tests in. Never published. |
| [`secure-docker-build-from-bare-image.yml`](#secure-docker-build-from-bare-imageyml) | Builds the deployed image FROM that bare image, pushes it to ECR and Docker Hub, and attests and evaluates it in Kosli. |
| [`secure-start-point-build.yml`](#secure-start-point-buildyml) | Builds a cyber-dojo start-point image via the caller's `make image`, pushes it, and attests and evaluates it in Kosli. |

A partner composite action,
[download-artifact](https://github.com/cyber-dojo/download-artifact), downloads
the image a secure build produces.

## Why two workflows build one service's image

A service's unit tests need only its runtime, not the secure, published
image, which takes minutes to build, push, attest and evaluate. So
`build-bare-image.yml` builds just the runtime, the bare image, cached and
usually restored in seconds, and the unit tests start in it at once.
Meanwhile `secure-docker-build-from-bare-image.yml` builds the deployed image
FROM that same bare image, digest-checked, so the tests are evidence for
what is deployed. See [Bare images](#bare-images) for the details.

## Typical use

The two bare image workflows are a pair. The unit tests and the deployed
image's build run side by side:

```yml
jobs:
  setup:
    ...

  bare-image:
    uses: cyber-dojo/reusable-actions-workflows/.github/workflows/build-bare-image.yml@main
    with:
      checkout_repository: cyber-dojo/saver
      checkout_ref: ${{ github.sha }}
      artifact_prefix: saver-bare-image

  unit-tests:
    runs-on: ubuntu-latest
    needs: [setup, bare-image]
    steps:
      ...download saver-bare-image-amd64, check its digest, docker load it, run the tests

  build-image:
    needs: [setup, bare-image]
    uses: cyber-dojo/reusable-actions-workflows/.github/workflows/secure-docker-build-from-bare-image.yml@main
    with:
      checkout_repository: cyber-dojo/saver
      checkout_ref: ${{ github.sha }}
      checkout_fetch_depth: 1
      image_name: ${{ needs.setup.outputs.ecr_registry }}/${{ needs.setup.outputs.service_name }}
      image_tag: ${{ needs.setup.outputs.image_tag }}
      image_build_args: |
        COMMIT_SHA=${{ github.sha }}
      bare_image_artifact_prefix: saver-bare-image
      bare_image_digest_amd64: ${{ needs.bare-image.outputs.digest_amd64 }}
      bare_image_digest_arm64: ${{ needs.bare-image.outputs.digest_arm64 }}
      kosli_flow: ${{ env.KOSLI_FLOW }}
      kosli_trail: ${{ env.KOSLI_TRAIL }}
      kosli_reference_name: saver
      attest_to_kosli: ${{ github.ref == 'refs/heads/main' }}
    secrets:
      kosli_api_token: ${{ secrets.KOSLI_API_TOKEN }}
      docker_user: ${{ secrets.DOCKER_USER }}
      docker_pass: ${{ secrets.DOCKER_PASS }}

  after-build-image:
    runs-on: ubuntu-latest
    needs: [build-image]
    steps:
      - uses: cyber-dojo/download-artifact@main
        with:
          image_digest: ${{ needs.build-image.outputs.digest }}
      ...
```

See [cyber-dojo/saver](https://github.com/cyber-dojo/saver/blob/main/.github/workflows/main.yml)
for a whole workflow.

## `build-bare-image.yml`

Builds the `Dockerfile`'s bare image stage once per platform and uploads each
as the artifact `<artifact_prefix>-<arch>`: `bare-image.tar`, an OCI layout
whose image is named `<artifact_prefix>:local`, so `docker load` names it.
Nothing is pushed to a registry, and there is no provenance, SBOM or Kosli
attestation: a bare image is never published or deployed.

Each platform's bare image is cached by a hash of the bare image stage's
instructions (comments and blank lines aside): every line up to and
including the next `FROM`, whatever it says. A cache hit skips the build. A
miss builds with no layer cache, so unpinned packages (eg `apk add git`) are
as new as the last change to those instructions. To refresh them, change an
instruction (eg bump an `ARG`). The
[`hash-bare-image-stage`](.github/actions/hash-bare-image-stage) action
computes the hash, and its tests pin which lines it covers.

### Inputs

| Name | Required | Type | Default | Description |
| --- | --- | --- | --- | --- |
| `checkout_repository` | yes | string | | The repo to build, eg `cyber-dojo/saver` |
| `checkout_ref` | yes | string | | The commit to build, eg `${{ github.sha }}` |
| `artifact_prefix` | yes | string | | Names the artifacts, eg `saver-bare-image` gives `saver-bare-image-amd64` and `saver-bare-image-arm64` |
| `build_context` | no | string | `.` | The build context, eg `services/foo` |
| `dockerfile` | no | string | `./Dockerfile` | The Dockerfile, eg `services/foo/Dockerfile` |
| `bare_image_stage` | no | string | `base` | The Dockerfile stage that is the bare image |
| `platforms` | no | string | `linux/amd64,linux/arm64` | The platforms to build |

### Outputs

| Name | Description |
| --- | --- |
| `digest_amd64` | The linux/amd64 bare image's OCI manifest digest, eg `sha256:...` |
| `digest_arm64` | The linux/arm64 bare image's OCI manifest digest; empty when not built |

## `secure-docker-build-from-bare-image.yml`

Builds the deployed image, once per platform, with its bare image stage
replaced (`--build-context`) by the bare image the caller uploaded. Each
platform's build fails unless that bare image has the given digest, so the
deployed image's layers start with those of the bare image the unit tests
ran in, exactly. Each platform is built with no cache, with SLSA provenance
and an SBOM, then `create-index` joins them in one index, pushed to ECR and
to Docker Hub (`cyberdojo/<last part of image_name>:<image_tag>`, same
digest).

Before building, it runs this repo's own tests as a gate, so a broken policy
fails the build early. After it, when `attest_to_kosli` is true:

- the image's build provenance and SBOM are attested to GitHub (sigstore) and
  to Kosli,
- provenance-facts and sbom-facts are distilled and attested to Kosli,
- the provenance is evaluated against the `SDLC-CTRL-0002` (SLSA provenance)
  rego policy and the SBOM against the `SDLC-CTRL-0004` rego policy, and each
  decision is attested to Kosli. The SBOM policy honours a per-service
  overrides allow-list (`SDLC-CTRL-0004/sbom-overrides.<service>.json`) that
  waives named per-package checks.

### Inputs

| Name | Required | Type | Default | Description |
| --- | --- | --- | --- | --- |
| `checkout_repository` | yes | string | | The repo to build, eg `cyber-dojo/differ` |
| `checkout_ref` | yes | string | | The commit to build, eg `${{ github.sha }}` |
| `checkout_fetch_depth` | yes | string | | The checkout depth, eg `1` |
| `image_name` | yes | string | | The ECR image name, eg `244531986313.dkr.ecr.eu-central-1.amazonaws.com/differ` |
| `image_tag` | yes | string | | The image tag, eg `52ec808` |
| `image_build_args` | no | string | | Build args, one `NAME=value` per line |
| `build_context` | no | string | `.` | The build context, eg `services/foo` |
| `dockerfile` | no | string | `./Dockerfile` | The Dockerfile, eg `services/foo/Dockerfile` |
| `target` | no | string | `''` | The stage to build, eg `web`; empty builds the last stage |
| `platforms` | no | string | `linux/amd64,linux/arm64` | The platforms to build |
| `bare_image_artifact_prefix` | yes | string | | The `artifact_prefix` given to `build-bare-image.yml` |
| `bare_image_stage` | no | string | `base` | The Dockerfile stage the bare image replaces |
| `bare_image_digest_amd64` | yes | string | | `build-bare-image.yml`'s `digest_amd64` |
| `bare_image_digest_arm64` | yes | string | | `build-bare-image.yml`'s `digest_arm64`; `''` when linux/arm64 is not in `platforms` |
| `kosli_flow` | yes | string | | The Kosli flow, eg `${{ vars.KOSLI_FLOW }}` |
| `kosli_trail` | yes | string | | The Kosli trail, eg `${{ github.sha }}` |
| `kosli_reference_name` | yes | string | | The artifact's name in the flow template, eg `saver` |
| `attest_to_kosli` | no | boolean | `true` | Whether to attest to Kosli, eg `${{ github.ref == 'refs/heads/main' }}` |
| `kosli_cli_version` | no | string | `${{ vars.KOSLI_CLI_VERSION }}` | The Kosli CLI version |
| `kosli_debug` | no | string | `${{ vars.KOSLI_DEBUG }}` | `true` or `false` |
| `kosli_dry_run` | no | string | `${{ vars.KOSLI_DRY_RUN }}` | `true` or `false` |
| `kosli_host` | no | string | `${{ vars.KOSLI_HOST }}` | eg `https://app.kosli.com` |
| `kosli_org` | no | string | `${{ vars.KOSLI_ORG }}` | eg `cyber-dojo` |

### Secrets

| Name | Required | Description |
| --- | --- | --- |
| `kosli_api_token` | yes | Kosli API token for the attestations |
| `docker_user` | yes | Docker Hub user the image is pushed as |
| `docker_pass` | yes | Docker Hub password or token for `docker_user` |

### Outputs

| Name | Description |
| --- | --- |
| `digest` | The image index's SHA256 digest |
| `tagged_image_name` | eg `244531986313.dkr.ecr.eu-central-1.amazonaws.com/differ:52ec808` |

## `secure-start-point-build.yml`

For cyber-dojo start-point images, which the caller's `make image` builds
(running `cyber-dojo start-point create`) rather than a `Dockerfile`. With no
buildkit build, its SBOM is generated with syft (SPDX 2.3), and there is no
SLSA provenance predicate. It pushes, gates on this repo's tests, and attests
and evaluates exactly as `secure-docker-build-from-bare-image.yml` does.

```yml
  build-image:
    needs: [setup]
    uses: cyber-dojo/reusable-actions-workflows/.github/workflows/secure-start-point-build.yml@main
    with:
      checkout_repository: cyber-dojo/custom-start-points
      checkout_ref: ${{ github.sha }}
      checkout_fetch_depth: 1
      image_name: ${{ needs.setup.outputs.ecr_registry }}/${{ needs.setup.outputs.service_name }}
      image_tag: ${{ needs.setup.outputs.image_tag }}
      kosli_flow: ${{ env.KOSLI_FLOW }}
      kosli_trail: ${{ env.KOSLI_TRAIL }}
      kosli_reference_name: custom-start-points
      attest_to_kosli: ${{ github.ref == 'refs/heads/main' }}
    secrets:
      kosli_api_token: ${{ secrets.KOSLI_API_TOKEN }}
      docker_user: ${{ secrets.DOCKER_USER }}
      docker_pass: ${{ secrets.DOCKER_PASS }}
```

### Inputs

| Name | Required | Type | Default | Description |
| --- | --- | --- | --- | --- |
| `checkout_repository` | yes | string | | The repo to build, eg `cyber-dojo/custom-start-points` |
| `checkout_ref` | yes | string | | The commit to build, eg `${{ github.sha }}` |
| `checkout_fetch_depth` | yes | string | | The checkout depth, eg `1` |
| `image_name` | yes | string | | The ECR image name, eg `244531986313.dkr.ecr.eu-central-1.amazonaws.com/custom-start-points` |
| `image_tag` | yes | string | | The image tag, eg `52ec808` |
| `local_image_name` | no | string | `""` | The tag `make image` produces locally, before it is retagged to `image_name`; empty means `cyberdojo/<kosli_reference_name>` |
| `platforms` | no | string | `linux/amd64,linux/arm64` | The platforms to build |
| `kosli_flow` | yes | string | | The Kosli flow, eg `${{ vars.KOSLI_FLOW }}` |
| `kosli_trail` | yes | string | | The Kosli trail, eg `${{ github.sha }}` |
| `kosli_reference_name` | yes | string | | The artifact's name in the flow template, eg `custom-start-points` |
| `attest_to_kosli` | no | boolean | `true` | Whether to attest to Kosli, eg `${{ github.ref == 'refs/heads/main' }}` |
| `kosli_cli_version` | no | string | `${{ vars.KOSLI_CLI_VERSION }}` | The Kosli CLI version |
| `kosli_debug` | no | string | `${{ vars.KOSLI_DEBUG }}` | `true` or `false` |
| `kosli_dry_run` | no | string | `${{ vars.KOSLI_DRY_RUN }}` | `true` or `false` |
| `kosli_host` | no | string | `${{ vars.KOSLI_HOST }}` | eg `https://app.kosli.com` |
| `kosli_org` | no | string | `${{ vars.KOSLI_ORG }}` | eg `cyber-dojo` |

### Secrets

| Name | Required | Description |
| --- | --- | --- |
| `kosli_api_token` | yes | Kosli API token for the attestations |
| `docker_user` | yes | Docker Hub user the index is tagged as |
| `docker_pass` | yes | Docker Hub password or token for `docker_user` |

### Outputs

| Name | Description |
| --- | --- |
| `digest` | The image index's SHA256 digest |
| `tagged_image_name` | eg `244531986313.dkr.ecr.eu-central-1.amazonaws.com/custom-start-points:52ec808` |

## Bare images

### Why

The unit tests need only the image's runtime: its OS packages, language and
libraries, with the source code mounted in. That is the bare image. The
deployed image needs much more: every platform built with no cache, pushed
to ECR and Docker Hub, a multi-platform index, provenance and SBOMs, rego
policy evaluations, and Kosli attestations. Tests run in the deployed image
wait for all of that; for saver it was about 4.5 minutes. Run in the bare
image, which is cached and usually restored in about 20 seconds, they start
well under a minute into the run, alongside the secure build.

### Why the unit tests are still evidence for the deployed image

The deployed image is built FROM the very bare image the unit tests ran in,
not from a rebuild of the same stage, which could pick up newer packages.
Each bare image's digest links the two: `build-bare-image.yml` outputs it,
the caller's unit tests check it before loading the bare image, and
`secure-docker-build-from-bare-image.yml` checks it before building FROM it,
failing if any differs. The caller can also compare the two images' packages
and attest that they match (eg `saver.bare-image-match`, which saver's Kosli
flow template requires).

The unit tests finish before the deployed image exists, so they attest to
Kosli with no `--fingerprint`, by `--name=<artifact>.<attestation>` (eg
`saver.unit-test`). Kosli binds such an attestation to the artifact by the
git commit, once the secure workflow has attested the artifact itself.

### The Dockerfile

The bare image is the stage named `base` (or `bare_image_stage`), with no
source code. It ends at the next `FROM`, so it must be followed by another
stage. Usually that is `FROM base`, adding the source code:

```dockerfile
FROM ghcr.io/cyber-dojo/sinatra-base:...@sha256:... AS base
RUN apk add git
...
FROM base
COPY source/server .
```

A repo building several services from one multi-stage `Dockerfile` selects
each one's stage with `target`. Its bare image stage may be followed by any
stage, eg an asset stage built FROM another image, as in
[cyber-dojo/web](https://github.com/cyber-dojo/web/blob/main/Dockerfile).

For a monorepo, point both workflows at a service directory with
`build_context` and `dockerfile`, and give each service its own distinct
`image_name`, `kosli_flow` and `kosli_reference_name`.

## This repo

`make test-provenance test-sbom test-bare-image-hash` runs this repo's own
shunit2 suites: the `SDLC-CTRL-0002` and `SDLC-CTRL-0004` rego policies, and
the `hash-bare-image-stage` action. Each secure build runs the same command
as its `test-policies` gate.

`publish-policies.yml` is not reusable. On a push to `main` that changes a
rego policy, it publishes the policies to Kosli, where the
`attest-and-evaluate` action evaluates them.

## Versioning

The examples above pin `@main`. To pin a release tag instead, list the
available tags with `git tag`. To create a new one:

```shell
git tag -a v0.0.16 -m "Some message"
git push origin v0.0.16
```
