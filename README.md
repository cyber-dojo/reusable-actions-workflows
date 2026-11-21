# reusable-actions-workflows

Reusable GitHub Actions workflows used by cyber-dojo Org repos to build a
service's docker image securely and attest it for compliance. There are four:

- `secure-docker-build.yml` builds the image from a `Dockerfile` (via
  `docker/build-push-action`).
- `build-bare-image.yml` and `secure-docker-build-from-bare-image.yml` are a
  pair. The first builds the `Dockerfile`'s bare image (its OS packages,
  language and libraries, with no source code) for the caller to run its unit
  tests in. The second builds the deployed image FROM that same bare image.
  See [Bare image builds](#bare-image-builds).
- `secure-start-point-build.yml` builds a cyber-dojo start-point image via the
  caller's `make image` (`cyber-dojo start-point create`) rather than a
  `Dockerfile`.

A partner composite action,
[download-artifact](https://github.com/cyber-dojo/download-artifact), downloads
the docker image the build produces.

## What the workflows do

The three `secure-` workflows build and push the image to Amazon ECR, then run
the same compliance attestations (shared via the `attest-and-evaluate`
composite action). `build-bare-image.yml` does neither: a bare image is never
published, and is never deployed.

- Attest the image's build provenance and its SBOM to GitHub (sigstore) and to
  Kosli.
- Distill provenance-facts and sbom-facts and attest them to Kosli.
- Evaluate the provenance against the `SDLC-CTRL-0002` (SLSA provenance) rego
  policy and the SBOM against the `SDLC-CTRL-0004` rego policy, then attest each
  compliance decision to Kosli. The SBOM policy honours a per-service overrides
  allow-list (`SDLC-CTRL-0004/sbom-overrides.<service>.json`) that waives named
  per-package checks.

Before building, each workflow runs this repo's own rego policy tests as a build
gate, so a broken policy fails the build early. The Kosli attestations are made
only when `attest_to_kosli` is true (typically on `main`).

Typical use is like this:

```yml
name: Main

...

jobs:
  setup:
    ...
  
  build-image:
    needs: [setup]    
    uses: cyber-dojo/reusable-actions-workflows/.github/workflows/secure-docker-build.yml@main
    with:
      checkout_repository: cyber-dojo/saver
      checkout_ref: ${{ github.sha }}
      checkout_fetch_depth: 1
      image_name: ${{ needs.setup.outputs.ecr_registry }}/${{ needs.setup.outputs.service_name }}
      image_tag: ${{ needs.setup.outputs.image_tag }}
      image_build_args: |
        COMMIT_SHA=${{ github.sha }}
        BASE_IMAGE=${{ inputs.BASE_IMAGE }}
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
      - name: Download docker image
        uses: cyber-dojo/download-artifact@main
        with:
          image_digest: ${{ needs.build-image.outputs.digest }}
      ...
```

## Monorepo builds

By default the image is built from the repo root (`build_context: .`) using
the root `./Dockerfile`. For a monorepo, point the build at a specific service
directory with the optional `build_context` and `dockerfile` inputs:

```yml
  build-image:
    needs: [setup]
    uses: cyber-dojo/reusable-actions-workflows/.github/workflows/secure-docker-build.yml@main
    with:
      checkout_repository: cyber-dojo/services
      checkout_ref: ${{ github.sha }}
      checkout_fetch_depth: 1
      build_context: services/web
      dockerfile: services/web/Dockerfile
      image_name: ${{ needs.setup.outputs.ecr_registry }}/${{ needs.setup.outputs.service_name }}
      image_tag: ${{ needs.setup.outputs.image_tag }}
      image_build_args: |
        COMMIT_SHA=${{ github.sha }}
        BASE_IMAGE=${{ inputs.BASE_IMAGE }}
      kosli_flow: ${{ env.KOSLI_FLOW }}
      kosli_trail: ${{ env.KOSLI_TRAIL }}
      kosli_reference_name: web
      attest_to_kosli: ${{ github.ref == 'refs/heads/main' }}
    secrets:
      kosli_api_token: ${{ secrets.KOSLI_API_TOKEN }}
      docker_user: ${{ secrets.DOCKER_USER }}
      docker_pass: ${{ secrets.DOCKER_PASS }}
```

The whole repo is checked out, so the service directory is available as the
build context. Give each service its own distinct `image_name`, `kosli_flow`
and `kosli_reference_name` so their attestations stay separate.

When several services share one multi-stage `Dockerfile`, select each one's
stage with the optional `target` input, eg `target: web`. Left unset, the
build produces the Dockerfile's last stage.

## Bare image builds

### Why

With `secure-docker-build.yml`, a repo's unit tests run in the deployed image,
so they cannot start until the whole secure build has finished: building every
platform with no cache, pushing to ECR and Docker Hub, the multi-platform
index, provenance and SBOMs, the rego policy evaluations, and the Kosli
attestations. For saver that was about 4.5 minutes before its unit tests
started.

The unit tests need none of that. They need only the image's runtime: its OS
packages, language and libraries, with the source code mounted in. That is
the bare image. So the work is split between two workflows:

- `build-bare-image.yml` is the slimline one, for the unit tests. It builds
  the bare image, and does nothing else: no push to any registry, no
  provenance, no SBOM, no rego policy evaluations, no Kosli attestations. A
  bare image is never published and never deployed, so it needs none of
  them. It is cached, so it is usually restored, not built. For saver its job
  takes about 20 seconds, and the unit tests start well under a minute into
  the run.
- `secure-docker-build-from-bare-image.yml` is the secure one, for the
  deployed image. It does everything `secure-docker-build.yml` does
  (provenance, SBOM, push, policy evaluations, Kosli attestations), but
  builds the image FROM the bare image, adding only the source code. It runs
  alongside the unit tests, not before them.

### Why the unit tests are still evidence for the deployed image

The deployed image is built FROM the very bare image the unit tests ran in,
not from a rebuild of the same `Dockerfile` stage, which could pick up newer
packages. Each bare image's digest links the two: `build-bare-image.yml`
outputs it, the caller's unit tests check it before loading the bare image,
and `secure-docker-build-from-bare-image.yml` checks it before building
FROM it, failing if any differs. So the deployed image's layers start with
those of the bare image the unit tests ran in, exactly. The caller can also
compare the two images' packages and attest that they match (saver attests
`saver.bare-image-match`, which its Kosli flow template requires).

The unit tests finish before the deployed image exists, so they attest to
Kosli with no `--fingerprint`, by `--name=<artifact>.<attestation>` (eg
`saver.unit-test`). Kosli binds such an attestation to the artifact by the
git commit, once the secure workflow has attested the artifact itself.

### How

The `Dockerfile` is split in two: its first stage, named `base`, is the bare
image (no source code), and the last stage, `FROM base`, adds the source
code. A default `docker build` of it still builds the whole image, as before.
Then:

- `build-bare-image.yml` builds the `base` stage once per platform, and
  uploads each as the artifact `<artifact_prefix>-<arch>`. It outputs each
  one's digest as `digest_amd64` and `digest_arm64`. Each is cached by a hash
  of the `base` stage's instructions (comments and blank lines aside), so it
  is rebuilt, with no layer cache, only when one of them changes. To refresh
  unpinned packages, eg `apk add git`, change an instruction (eg bump an
  `ARG`).
- The caller's unit tests run in the linux/amd64 bare image.
- `secure-docker-build-from-bare-image.yml` takes the same inputs as
  `secure-docker-build.yml`, plus `bare_image_artifact_prefix` and the two
  digests. Each platform's build fails unless its downloaded bare image has
  its digest, and replaces the `base` stage with it (`--build-context`), so
  the deployed image's layers start with those of the bare image the unit
  tests ran in.

```yml
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
```

The unit tests and the deployed image's build run side by side. See
[cyber-dojo/saver](https://github.com/cyber-dojo/saver/blob/main/.github/workflows/main.yml)
for a whole workflow.

## Start-point builds

`secure-start-point-build.yml` is for cyber-dojo start-point images, which are
built by the caller's `make image` (running `cyber-dojo start-point create`)
rather than from a `Dockerfile`. It takes the same `checkout_*`, `image_*`,
`kosli_*` and `attest_to_kosli` inputs, but not `build_context`, `dockerfile`,
`target` or `image_build_args`. Its one extra input is the optional `local_image_name`,
the tag `make image` produces locally before it is retagged to `image_name`
(defaults to `cyberdojo/<kosli_reference_name>`).

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

## Versioning

The examples above pin `@main`. To pin a release tag instead, list the
available tags with `git tag`. To create a new one:

```shell
git tag -a v0.0.16 -m "Some message"
git push origin v0.0.16
```
