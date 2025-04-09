# reusable-actions-workflows

Used by cyber-dojo Org repos in their Github Actions workflows.
- secure-build.yml


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
    permissions:
      id-token: write
      contents: read
    env:
      IMAGE_NAME:        ${{ needs.setup.outputs.ecr_registry }}/${{ needs.setup.outputs.service_name }}
      KOSLI_FINGERPRINT: ${{ needs.build-image.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region:            ${{ needs.setup.outputs.aws_region }}
          role-duration-seconds: 900
          role-session-name:     ${{ github.event.repository.name }}
          role-to-assume:        arn:aws:iam::${{ needs.setup.outputs.aws_account_id_beta }}:role/${{ needs.setup.outputs.gh_actions_iam_role_name }}
          mask-aws-account-id:   no

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Pull image from ECR registry
        run:
          docker image pull "${IMAGE_NAME}@sha256:${KOSLI_FINGERPRINT}"
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
