# Terraform AWS CI/CD with GitHub Actions

A hands-on DevOps project that uses Terraform and GitHub Actions to
manage AWS S3 security settings through an automated CI workflow and a
separate apply workflow.

> **Project status:** Core CI and Apply workflows have run successfully.
> Terraform created the S3 public-access-block and default
> server-side-encryption configuration resources. This README documents
> the implementation and the troubleshooting performed during the build.
> Review the current repository and AWS configuration before treating
> every item below as a verified production control.

## Table of contents

-   [Overview](#overview)
-   [What this project builds](#what-this-project-builds)
-   [Architecture](#architecture)
-   [Technologies](#technologies)
-   [AWS resources](#aws-resources)
-   [Repository structure](#repository-structure)
-   [How the pipeline works](#how-the-pipeline-works)
-   [Terraform configuration](#terraform-configuration)
-   [Security decisions](#security-decisions)
-   [Errors encountered and
    troubleshooting](#errors-encountered-and-troubleshooting)
-   [How to operate the project](#how-to-operate-the-project)
-   [Validation checklist](#validation-checklist)
-   [Known limitations and next
    improvements](#known-limitations-and-next-improvements)
-   [Interview explanation](#interview-explanation)

## Overview

The goal is to practise Infrastructure as Code (IaC) and CI/CD for AWS:

1.  Store Terraform configuration in GitHub.
2.  Use a GitHub Actions self-hosted runner on an EC2 instance.
3.  Authenticate to AWS through the EC2 instance's IAM role instead of
    hardcoding AWS access keys.
4.  Store Terraform state remotely in an S3 bucket and enable S3
    lock-file state locking.
5.  Run formatting, initialization, validation and planning in CI.
6.  Run Terraform apply through a separate workflow using a saved plan.
7.  Configure an existing S3 learning bucket to block public access and
    use default SSE-S3 encryption.

## What this project builds

The Terraform configuration manages these resources:

-   An existing S3 learning bucket: `terraform-learning-454015599516`.
-   An S3 Block Public Access configuration for that bucket.
-   An S3 default server-side encryption configuration using AES-256
    (SSE-S3).
-   A data source that reads the current AWS account ID.

Terraform's latest successful apply output was:

``` text
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
Outputs:
aws_account_id = "454015599516"
```

This means Terraform created the two security-configuration resources.
It did not create a new bucket during that apply, and it did not destroy
or modify existing resources.

## Architecture

``` mermaid
flowchart TD
    A[Developer pushes code to GitHub] --> B[GitHub Actions CI workflow]
    B --> C[EC2 self-hosted runner]
    C --> D[Terraform fmt / init / validate / plan]
    D --> E[Remote Terraform state in S3]
    C --> F[EC2 instance profile IAM role]
    F --> G[AWS APIs]
    G --> H[Learning S3 bucket]
    H --> I[Block Public Access]
    H --> J[Default SSE-S3 encryption]
    D --> K[Separate manual Apply workflow]
    K --> L[Apply saved tfplan after reviewing plan]
    L --> G
```

The runner uses the EC2 instance role `TerraformGitHubRunnerRole`. The
role is intended to provide AWS API permissions to Terraform without
putting long-lived AWS credentials in the repository.

## Technologies

-   **Terraform** --- declares and manages infrastructure.
-   **AWS S3** --- stores remote Terraform state and hosts the learning
    bucket.
-   **AWS IAM** --- controls the runner's permissions through an EC2
    instance role.
-   **Amazon EC2** --- hosts the self-hosted GitHub Actions runner.
-   **GitHub Actions** --- runs CI and a separate apply workflow.
-   **AWS provider for Terraform** --- communicates with AWS.

Known environment details from this build:

  Setting                              Value
  ------------------------------------ ----------------------------------------
  AWS Region                           `ap-south-1` (Mumbai)
  Terraform state bucket               `terraform-state-da5f85cbcc8e`
  State key                            `terraform-aws-cicd/terraform.tfstate`
  State locking                        S3 lock file (`use_lockfile = true`)
  Learning bucket                      `terraform-learning-454015599516`
  Runner role                          `TerraformGitHubRunnerRole`
  Runner OS                            Ubuntu 24.04 on EC2
  Terraform CLI observed on runner     `1.16.5`
  AWS provider observed during build   `6.68.0`

Avoid publishing account IDs or internal infrastructure details if you
do not want them public. Replace them with placeholders before sharing
this repository publicly.

## Repository structure

The known workflow paths are:

``` text
terraform-aws-cicd/
├── main.tf
├── .terraform.lock.hcl
└── .github/
    └── workflows/
        ├── terraform.yml
        └── terraform-apply.yml
```

Add other files or folders to this tree if they exist in your actual
repository. Do not commit the local `.terraform/` directory or state
files.

## How the pipeline works

### CI workflow

The CI workflow is `.github/workflows/terraform.yml`. It is configured
to run on manual dispatch and on pushes to `main` when Terraform files,
the lock file, or this workflow file change.

The workflow steps are:

1.  Check out the repository.
2.  Print the Terraform version.
3.  Run `terraform fmt -check -recursive`.
4.  Run `terraform init -input=false`.
5.  Inspect state with `terraform state list`.
6.  Clear the learning bucket's tainted marker with
    `terraform untaint aws_s3_bucket.learning`.
7.  Run `terraform validate`.
8.  Run `terraform plan -input=false`.

**Important maintenance note:** The `terraform untaint` step was added
as a recovery action after the S3 bucket was marked tainted. It changes
the shared remote state. It should not normally be run on every CI
execution. After confirming the resource is healthy and the state is
stable, consider removing this one-time recovery step from the normal CI
workflow. If a resource becomes tainted again, investigate why before
clearing the marker.

### Apply workflow

The separate `.github/workflows/terraform-apply.yml` workflow uses a
plan/apply pattern. The apply job ran:

``` bash
terraform apply -input=false tfplan
```

A saved plan (`tfplan`) helps apply the reviewed set of actions from the
plan job. Always inspect the plan before applying it. Never apply a plan
that unexpectedly destroys or replaces a resource.

Check the actual `terraform-apply.yml` file to confirm its current
inputs, environment protection, artifact handling and approval behavior.
A GitHub environment name alone does not require human approval; that
depends on configured environment protection rules and plan
availability.

## Terraform configuration

The key parts of `main.tf` include:

### Provider and backend

``` hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "terraform-state-da5f85cbcc8e"
    key          = "terraform-aws-cicd/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-south-1"
}
```

-   The S3 backend keeps state outside the runner's working directory.
-   `encrypt = true` enables server-side encryption for the remote state
    object.
-   `use_lockfile = true` enables S3 lock-file-based state locking.
-   `.terraform.lock.hcl` records provider selections and should be
    committed.

### Learning bucket and safety guard

``` hcl
resource "aws_s3_bucket" "learning" {
  bucket = "terraform-learning-454015599516"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "terraform-learning"
    Environment = "learning"
    ManagedBy   = "Terraform"
  }
}
```

`prevent_destroy = true` makes Terraform reject plans that destroy this
resource while the lifecycle rule remains in the configuration. It is a
safety guard, not a substitute for reviewing plans or maintaining
backups.

### Block public access

``` hcl
resource "aws_s3_bucket_public_access_block" "learning" {
  bucket = aws_s3_bucket.learning.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

These settings help prevent public access through the bucket's supported
ACL and policy mechanisms. Confirm the bucket's effective access
controls in AWS and avoid adding public policies unless there is a
deliberate requirement.

### Default SSE-S3 encryption

``` hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "learning" {
  bucket = aws_s3_bucket.learning.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

This configures default server-side encryption with Amazon S3-managed
keys (SSE-S3) for objects written to the bucket.

## Security decisions

-   **IAM role instead of static AWS keys:** The EC2 runner obtains
    temporary credentials through its attached instance profile. Do not
    store AWS access keys in source code.
-   **Least privilege:** Limit the role to the actions and resources the
    workflows need. Review broad actions such as `s3:*` and wildcard
    resources carefully; some list or discovery operations may require
    broader resource scopes.
-   **Remote state:** Protect the state bucket and state object because
    state can contain sensitive infrastructure metadata and, depending
    on configuration, sensitive values.
-   **State locking:** Keep locking enabled to reduce the risk of
    concurrent Terraform operations modifying the same state.
-   **S3 security:** The learning bucket has Block Public Access enabled
    and default SSE-S3 encryption configured.
-   **Plan review:** Do not apply unexpected resource replacement or
    deletion actions.
-   **Runner security:** A self-hosted runner executes repository
    workflow code on your EC2 instance. Only run trusted workflows and
    review changes to workflow files.

The IAM policy for `TerraformGitHubRunnerRole` still needs a documented
least-privilege review. Do not claim that the role is fully hardened
until its trust relationship and attached/inline permissions have been
checked.

## Errors encountered and troubleshooting

### 1. `terraform plan` failed because the S3 bucket was tainted

**Symptom:**

``` text
aws_s3_bucket.learning is tainted, so must be replaced
Instance cannot be destroyed
lifecycle.prevent_destroy is set
```

**Cause:** Terraform state marked `aws_s3_bucket.learning` as tainted,
so Terraform proposed replacing the bucket. The lifecycle guard
correctly blocked the destroy operation.

**Resolution performed:**

1.  Ran `terraform state list` and confirmed that
    `aws_s3_bucket.learning` was tracked.

2.  Verified the bucket in AWS before modifying the state.

3.  Ran:

    ``` bash
    terraform untaint aws_s3_bucket.learning
    ```

4.  Re-ran validation and planning.

5.  Confirmed the plan showed `2 to add, 0 to change, 0 to destroy`.

**Lesson:** Do not grant `s3:DeleteBucket` simply to make a replacement
plan succeed. Investigate why the resource is tainted and preserve the
bucket when that is the intended outcome. `terraform untaint` changes
state and should be used deliberately.

### 2. Apply failed with `AccessDenied` for `s3:DeleteBucket`

**Symptom:** An earlier apply attempt tried to delete the learning
bucket and AWS denied `s3:DeleteBucket`.

**Cause:** The saved plan included a bucket replacement/destruction. The
IAM role did not have permission to delete the bucket.

**Resolution:** The issue was addressed by fixing the tainted-state
condition, not by granting delete permission.

**Lesson:** An access-denied error can reveal an unsafe plan. Inspect
the plan first; do not expand IAM permissions until you understand why
the operation is required.

### 3. Terraform state inspection

**Command:**

``` bash
terraform state list
```

**Observed resources:**

``` text
data.aws_caller_identity.current
aws_s3_bucket.learning
```

**Meaning:** The data source and learning bucket were tracked in the
current Terraform state. The two S3 security configuration resources
were then created by the successful apply.

### 4. Terraform initialization and provider lock-file changes

**Observed message:** `terraform init` reported changes to provider
selections recorded in `.terraform.lock.hcl`.

**What to do:** Review the lock-file diff, confirm the provider version
is intended, and commit the lock file. Avoid ignoring unexpected
dependency changes.

### 5. Plan and apply use different saved-plan behavior

**Important:** A plain `terraform plan` without `-out` does not create
the saved plan file used by `terraform apply tfplan`.

**Correct plan/apply pattern:**

``` bash
terraform plan -input=false -out=tfplan
terraform apply -input=false tfplan
```

In a two-job GitHub Actions workflow, create the plan in the plan job,
securely transfer the plan artifact to the apply job, and ensure both
jobs use the same commit and compatible Terraform/provider
configuration. Review artifact access and retention because plans can
contain sensitive values.

### 6. `terraform validate` versus `terraform plan`

-   `terraform validate` checks the configuration's syntax and internal
    consistency.
-   `terraform plan` additionally refreshes real infrastructure state
    and proposes actions.
-   A successful validation does not guarantee the plan is safe.
-   A successful apply should be followed by verification in AWS.

## How to operate the project

Run Terraform commands only in the configured project directory on a
machine with the required Terraform installation and AWS permissions.

Common commands:

``` bash
terraform fmt -check -recursive
terraform init -input=false
terraform state list
terraform validate
terraform plan -input=false
```

For a saved plan:

``` bash
terraform plan -input=false -out=tfplan
terraform show tfplan
terraform apply -input=false tfplan
```

Do not create or apply a plan locally if you are not using the intended
backend, workspace, credentials and configuration. In this project,
Terraform was run by the EC2 self-hosted GitHub Actions runner.

### GitHub Actions troubleshooting checklist

If a workflow fails:

1.  Open **GitHub → Actions → the failed run**.
2.  Expand the first failing step; later failures may only be
    consequences.
3.  Identify whether the error comes from GitHub Actions, Terraform
    configuration, state/backend access, AWS IAM or the actual resource
    API.
4.  Read the plan carefully, especially replacement (`-/+`) or destroy
    (`-`) actions.
5.  Fix the underlying cause, commit the change, and rerun CI.
6.  Never paste credentials, tokens, state contents or sensitive plan
    output into public issues or logs.

## Validation checklist

-   [x] CI workflow succeeded.
-   [x] Terraform initialization succeeded with the S3 backend.
-   [x] Terraform validation succeeded.
-   [x] Tainted marker was cleared after checking state and the bucket.
-   [x] Plan showed `2 to add, 0 to change, 0 to destroy`.
-   [x] Apply completed with `2 added, 0 changed, 0 destroyed`.
-   [x] AWS Console showed Block all public access enabled.
-   [x] AWS Console showed SSE-S3 default encryption.
-   [ ] Review the current IAM trust policy and attached/inline
    permissions for least privilege.
-   [ ] Confirm the apply workflow's saved-plan artifact and failure
    behavior.
-   [ ] Remove the one-time `terraform untaint` recovery step from
    routine CI after confirming state is stable.
-   [ ] Add a concise screenshot or sanitized run link to the repository
    README, if appropriate.

## Known limitations and next improvements

1.  **IAM hardening:** Inspect the trust relationship and permissions
    for `TerraformGitHubRunnerRole`, then reduce permissions carefully
    and test the pipeline.
2.  **One-time recovery step:** Remove `terraform untaint` from the
    normal CI workflow after recovery. Do not clear taint automatically
    on every run.
3.  **Destructive-plan safeguards:** Ensure unexpected
    replacement/deletion is reviewed before apply.
4.  **Manual approval:** Optional for a personal learning project;
    useful for team or production deployments.
5.  **Security scanning:** Consider a tool such as Checkov or TFLint and
    add it to CI after establishing a baseline.
6.  **State recovery:** Document backup/recovery procedures for the
    remote state and protect access to the state bucket.
7.  **Runner maintenance:** Patch the EC2 host and runner, restrict
    repository/workflow access, and stop the instance when it is not
    needed if appropriate.
8.  **Cost awareness:** An EC2 runner can incur charges while running.
    Review instance and storage costs and clean up only resources you
    deliberately intend to remove.

## Interview explanation

**Short answer:**

> I built a Terraform-based AWS CI/CD pipeline using GitHub Actions and
> an EC2 self-hosted runner. Terraform uses an S3 remote backend with
> state locking, and the runner authenticates to AWS through an EC2 IAM
> role rather than static access keys. The CI workflow runs formatting,
> initialization, validation and planning. A separate workflow applies a
> saved plan. I configured an S3 learning bucket with Block Public
> Access and default SSE-S3 encryption. During troubleshooting,
> Terraform marked the bucket as tainted and proposed replacement. I
> verified the state and bucket, cleared the tainted marker
> deliberately, confirmed the plan had zero destroys, and then
> successfully applied the two security configurations.

**Concepts demonstrated:**

-   Infrastructure as Code
-   Terraform state and S3 backend
-   State locking
-   Terraform plan versus apply
-   GitHub Actions CI/CD
-   Self-hosted runners
-   EC2 instance profiles and IAM roles
-   S3 encryption and Block Public Access
-   Safe troubleshooting and lifecycle protection

## Final note

This is a learning project, not automatically a production-ready
platform. Before using the pattern for production, review IAM least
privilege, runner isolation, state recovery, artifact protection,
deployment approvals and destructive-change controls.
