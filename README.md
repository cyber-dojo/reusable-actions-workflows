# reusable-actions-workflows

Used by cyber-dojo Org repos in their Github Actions workflows.
- kosli_build_test_push.yml
  - Calls ./build_test_push.sh 
- kosli_deploy.yml
  - Calls ./sh/kosli.sh 
  - Runs kosli_expect_deployment twice, once for kosli staging and once for kosli prod.
