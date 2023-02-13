aws cloudformation deploy \
--template-file cloudfront.yml \
--stack-name production-distro \
--parameter-overrides PipelineID="${my-bucket544462693762}" # Name of the S3 bucket you created manually.