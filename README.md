# Exercise: Promote to Production
Write a set of jobs that promotes a new environment to production and decommissions the old environment in an automated process.

Prerequisites
You should have finished the previous:

- Exercise: Remote Control Using Ansible,
- Exercise: Infrastructure Creation,
- Exercise: Config and Deployment, and
- Exercise: Rollback
# Instructions
There are a few manual steps we need to take to "prime the pump". These manual steps enable steps that will be automated later.

## Step 1. Create an S3 bucket (Manually)
- Create a public S3 Bucket (e.g., mybucket644752792305) manually. If you need help with this, follow the instructions found in the documentation.
- Create a simple HTML page (version 1) and name it index.html.
- Upload the index.html page to your bucket. 
- Enable the Static website hosting in that bucket and set index.html as default page of the website.

## Step 2. Create a Cloudformation Stack (Manually)
- Use a Cloudformation template to create a Cloudfront Distribution, and later in this exercise, use the same template to modify the Cloudfront distribution.

Confused between Cloudformation (IaC) vs Cloudfront (CDN)? Read the basic definition from the official docs.

Cloudformation is a service that allows creating any AWS resource using the YAML template files. In other words, it supports Infrastructure as a Code (IaC). Cloudfront is a network of servers that caches the content, such as website media, geographically close to consumers. Cloudfront is a Content Delivery Network (CDN) service.

Create a Cloudformation template file named cloudfront.yml with the following contents:
```bash
Parameters:
    # Existing Bucket name
    PipelineID:
      Description: Existing Bucket name
      Type: String
Resources:
    CloudFrontOriginAccessIdentity:
      Type: "AWS::CloudFront::CloudFrontOriginAccessIdentity"
      Properties:
        CloudFrontOriginAccessIdentityConfig:
          Comment: Origin Access Identity for Serverless Static Website
    WebpageCDN:
      Type: AWS::CloudFront::Distribution
      Properties:
        DistributionConfig:
          Origins:
            - DomainName: !Sub "${PipelineID}.s3.amazonaws.com"
              Id: webpage
              S3OriginConfig:
                OriginAccessIdentity: !Sub "origin-access-identity/cloudfront/${CloudFrontOriginAccessIdentity}"
          Enabled: True
          DefaultRootObject: index.html
          DefaultCacheBehavior:
            ForwardedValues:
              QueryString: False
            TargetOriginId: webpage
            ViewerProtocolPolicy: allow-all
Outputs:
    PipelineID:
      Value: !Sub ${PipelineID}
      Export:
        Name: PipelineID
```
- Execute the cloudfront.yml template above with the following command:
```bash
aws cloudformation deploy \
--template-file cloudfront.yml \
--stack-name production-distro \
--parameter-overrides PipelineID="${S3_BUCKET_NAME}"  # Name of the S3 bucket you created manually.
```
- In the command above, replace ${S3_BUCKET_NAME} with the actual name of your bucket (e.g., mybucket644752792305). Also, note down the stack name - production-distro for the future. You will need the cloudfront.yml file in the automation steps later again.
- Execute the *cloudfront.yml* template file that will create a CloudFront distribution (CDN) based on the bucket name mentioned against `PipelineID` parameter
- Execute the cloudfront.yml template file that will create a CloudFront distribution (CDN) based on the bucket name mentioned against PipelineID parameter

## Step 3. Cloudformation template to create a new S3 bucket

- Create another Cloudformation template named bucket.yml that will create a new bucket and bucket policy. You can use the following template:
```bash
Parameters:
  # New Bucket name
  MyBucketName:
    Description: Existing Bucket name
    Type: String
Resources:
  WebsiteBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "${MyBucketName}"
      AccessControl: PublicRead
      WebsiteConfiguration:
        IndexDocument: index.html
        ErrorDocument: error.html
  WebsiteBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref 'WebsiteBucket'
      PolicyDocument:
        Statement:
        - Sid: PublicReadForGetBucketObjects
          Effect: Allow
          Principal: '*'
          Action: s3:GetObject
          Resource: !Join ['', ['arn:aws:s3:::', !Ref 'WebsiteBucket', /*]]
```
## Step 4. Update the CircleCI Config file
- ***Job*** - Write a job named create_and_deploy_front_end that executes the bucket.yml template to:

- - Create a new S3 bucket and
- - Copy the contents of the current repo (production files) to the new bucket.

Your job should look like this:

```bash
# Executes the bucket.yml - Deploy an S3 bucket, and interface with that bucket to synchronize the files between local and the bucket.
# Note that the `--parameter-overrides` let you specify a value that override parameter value in the bucket.yml template file.
create_and_deploy_front_end:
    docker:
      - image: amazon/aws-cli
    steps:
      - checkout
      - run:
          name: Execute bucket.yml - Create Cloudformation Stack
          command: |
            aws cloudformation deploy \
            --template-file bucket.yml \
            --stack-name stack-create-bucket-${CIRCLE_WORKFLOW_ID:0:7} \
            --parameter-overrides MyBucketName="mybucket-${CIRCLE_WORKFLOW_ID:0:7}"
      # Uncomment the step below if yoou wish to upload all contents of the current directory to the S3 bucket
      #- run: aws s3 sync . s3://mybucket-${CIRCLE_WORKFLOW_ID:0:7} --delete
``` 

> Notice we are passing in the CIRCLE_WORKFLOW_ID in mybucket-${CIRCLE_WORKFLOW_ID:0:7} to help form the name of our new bucket. This helps us to reference the bucket later, in another job/command.

> Once this job runs successfully, it will change the cache in the CDN to the new index.html

- Towards the end of this exercise, we need another job for deleting the S3 bucket created manually (cleaning up after promotion). For this purpose, you need to know which pipeline ID was responsible for creating the S3 bucket created manually (the last successful production release). We can query Cloudformation for the old pipeline ID information.


- ***Job*** - Write a CircleCI job named get_last_deployment_id that performs the query and saves the id to a file that we can persist to the workspace. For convenience, here's the job that you can use:
```bash
# Fetch and save the pipeline ID (bucket ID) responsible for the last release.
get_last_deployment_id:
  docker:
    - image: amazon/aws-cli
  steps:
    - checkout
    - run: yum install -y tar gzip
    - run:
        name: Fetch and save the old pipeline ID (bucket name) responsible for the last release.
        command: |
          aws cloudformation \
          list-exports --query "Exports[?Name==\`PipelineID\`].Value" \
          --no-paginate --output text > ~/textfile.txt
    - persist_to_workspace:
        root: ~/
        paths: 
          - textfile.txt 
```
In the job above, we are saving the bucket ID to a file and persist the file to the workspace for other jobs to access.
- ***Job*** - Write a job named promote_to_production that executes our cloudfront.yml CloudFormation template used in the manual steps. Here's the job you can use:
```bash
# Executes the cloudfront.yml template that will modify the existing CloudFront Distribution, change its target from the old bucket to the new bucket - `mybucket-${CIRCLE_WORKFLOW_ID:0:7}`. 
# Notice here we use the stack name `production-distro` which is the same name we used while deploying to the S3 bucket manually.
promote_to_production:
  docker:
    - image: amazon/aws-cli
  steps:
    - checkout
    - run:
        name: Execute cloudfront.yml
        command: |
          aws cloudformation deploy \
          --template-file cloudfront.yml \
          --stack-name production-distro \
          --parameter-overrides PipelineID="mybucket-${CIRCLE_WORKFLOW_ID:0:7}"
```
Notice here we use the stack name production-distro which is the same name we used in the throw-away Cloudformation template above.
- ***Job*** - Write a Job Named clean_up_old_front_end that uses the pipeline ID to destroy the previous production version's S3 bucket and CloudFormation stack. To achieve this, you need to retrieve from the workspace the file where the previous Pipeline ID was stored. Once you have the Pipeline ID, use the following commands to clean up:
```bash
# Destroy the previous production version's S3 bucket and CloudFormation stack. 
clean_up_old_front_end:
  docker:
    - image: amazon/aws-cli
  steps:
    - checkout
    - run: yum install -y tar gzip
    - attach_workspace:
        at: ~/
    - run:
        name: Destroy the previous S3 bucket and CloudFormation stack. 
        # Use $OldBucketID environment variable or mybucket644752792305 below.
        # Similarly, you can create and use $OldStackID environment variable in place of production-distro 
        command: |
          export OldBucketID=$(cat ~/textfile.txt)
          aws s3 rm "s3://${OldBucketID}" --recursive
```
- Workflow - Define a Workflow that puts these jobs in order. Comment out the jobs that are not part of this exercise. Try to keep the workflow minimal. Your workflow will look as:

```bash
workflows:
    my_workflow:
      jobs:
        - create_and_deploy_front_end
        - promote_to_production:
            requires: 
              - create_and_deploy_front_end
        - get_last_deployment_id
        - clean_up_old_front_end:
            requires:
              - get_last_deployment_id
              - promote_to_production
```
Push your code to the Github repo, and it will trigger the CircleCI build pipeline. If successful, your pipeline workflow will look like as shown in the snapshot below.

## Step 5. Verify after upto 30 mins
- Verify version 2 is browsable using Cloudfront domain name. Note that the AWS Cloudfront takes upto 30 mins to create caches and show the updated web page.
In some cases, depending upon your geographical location, it may take upto 24 hours to update the Cloudfront CDN. See an excerpt from [here](https://aws.amazon.com/premiumsupport/knowledge-center/cloudfront-serving-outdated-content-s3/).
**Note**
> *By default, CloudFront caches a response from Amazon S3 for 24 hours (Default TTL of 86,400 seconds). If your request lands at an edge location that served the Amazon S3 response within 24 hours, then CloudFront uses the cached response even if you updated the content in Amazon S3.*

Clean up after the verification. Delete the cloudformation stack and the S3 bucket(s).

