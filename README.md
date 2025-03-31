# reusable-actions-workflows

Used by cyber-dojo Org repos in their Github Actions workflows.
- secure-build.yml


Typical use is like this:

```yml
name: Main

on:
  push:
    branches:
      - main

jobs:
  build-test-push:
    uses: cyber-dojo/reusable-actions-workflows/.github/workflows/secure-build.yml@v0.0.5
    secrets:
      ...
    with:
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
