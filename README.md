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
      CHECKOUT_REPOSITORY: cyber-dojo/saver
      CHECKOUT_REF: ${{ github.sha }}
      CHECKOUT_DEPTH: 1
      IMAGE_NAME: ${{ needs.setup.outputs.ecr_registry }}/${{ needs.setup.outputs.service_name }}
      IMAGE_TAG: ${{ needs.setup.outputs.image_tag }}
      IMAGE_BUILD_ARGS: |
        COMMIT_SHA=${{ github.sha }}
        BASE_IMAGE=${{ inputs.BASE_IMAGE }}
      ATTEST_TO_KOSLI: ${{ github.ref == 'refs/heads/main' }}        
      KOSLI_FLOW: ${{ env.KOSLI_FLOW }}
      KOSLI_TRAIL: ${{ env.KOSLI_TRAIL }}
      KOSLI_REFERENCE_NAME: saver
    secrets:
      KOSLI_API_TOKEN: ${{ secrets.KOSLI_API_TOKEN }}


  after-build-image:
    runs-on: ubuntu-latest
    needs: [setup, build-image]
    env:
      IMAGE_NAME:        ${{ needs.setup.outputs.ecr_registry }}/${{ needs.setup.outputs.service_name }}
      KOSLI_FINGERPRINT: ${{ needs.build-image.outputs.digest }}
    steps:
      - name: Download docker image
        uses: cyber-dojo/download-artifact@main
        with:
          IMAGE_NAME:   ${{ needs.setup.outputs.image_name }}
          IMAGE_DIGEST: ${{ needs.build-image.outputs.digest }}
      ...
```

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
git tag -a v0.0.6 -m "Add KOSLI_API_TOKEN_STAGING to all workflows"
git push origin v0.0.6
```
