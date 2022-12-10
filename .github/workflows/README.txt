
deploy.txt is the original deployment yaml file.
It is slowly being replaced by
deploy_to_environment.yml which relies on their
being a ./sh/kosli.sh file which can be sourced
to obtain access to the kosli_expect_deployment()
function