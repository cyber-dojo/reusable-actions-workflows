# reusable-actions-workflows

Used by cyber-dojo Org repos in their Github Actions workflows.
- kosli_build_test.yml
  - Does not push image to dockerhub registry
  - Intended for base images
- kosli_build_test_push.yml
  - Calls ./build_test_push.sh 


Typical use is like this:

```yml
name: Main

on:
  push:
    branches:
      - main

jobs:
  build-test-push:
    uses: cyber-dojo/reusable-actions-workflows/.github/workflows/kosli_build_test_push.yml@v0.0.5
    secrets:
      ...
    with:
      BUILD_COMMAND: build_test_publish.sh
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
