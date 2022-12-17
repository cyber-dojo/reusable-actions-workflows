# reusable-actions-workflows

Used by all cyber-dojo services in their Github Actions workflows.
- kosli_build_test_push.sh
  - Calls ./build_test_push.sh 
- kosli_deploy.sh
  - Sources ./sh/kosli.sh 
  - Runs kosli_expect_deployment twice, once for kosli staging and once for kosli prod.
