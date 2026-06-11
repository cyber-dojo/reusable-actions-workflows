# reusable-actions-workflows

- The secure-docker-build.yml workflow is used by cyber-dojo Org repos in their Github Actions workflows.
- There is a partner composite workflow called [download-artifact](https://github.com/cyber-dojo/download-artifact) for downloading the docker-image created.


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

The @v0.0.5 refers to tags in this repo:

```shell
git tag

v0.0.1
v0.0.2
v0.0.3
v0.0.4
v0.0.5
```

To create a new tag:

```shell
git tag -a v0.0.6 -m "Some message"
git push origin v0.0.6
```
