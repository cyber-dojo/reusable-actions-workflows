# reusable-actions-workflows

Reusable GitHub Actions workflows used by cyber-dojo Org repos to build a
service's docker image securely and attest it for compliance. There are two:

- `secure-docker-build.yml` builds the image from a `Dockerfile` (via
  `docker/build-push-action`).
- `secure-start-point-build.yml` builds a cyber-dojo start-point image via the
  caller's `make image` (`cyber-dojo start-point create`) rather than a
  `Dockerfile`.

A partner composite action,
[download-artifact](https://github.com/cyber-dojo/download-artifact), downloads
the docker image the build produces.

## What the workflows do

Both build and push the image to Amazon ECR, then run the same compliance
attestations (shared via the `attest-and-evaluate` composite action):

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
```

The whole repo is checked out, so the service directory is available as the
build context. Give each service its own distinct `image_name`, `kosli_flow`
and `kosli_reference_name` so their attestations stay separate.

## Start-point builds

`secure-start-point-build.yml` is for cyber-dojo start-point images, which are
built by the caller's `make image` (running `cyber-dojo start-point create`)
rather than from a `Dockerfile`. It takes the same `checkout_*`, `image_*`,
`kosli_*` and `attest_to_kosli` inputs, but not `build_context`, `dockerfile`
or `image_build_args`. Its one extra input is the optional `local_image_name`,
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
```

## Versioning

The examples above pin `@main`. To pin a release tag instead, list the
available tags with `git tag`. To create a new one:

```shell
git tag -a v0.0.16 -m "Some message"
git push origin v0.0.16
```
