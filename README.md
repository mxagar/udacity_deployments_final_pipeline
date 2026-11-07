# Flask deployment tests on Amazon EKS

This repository builds a Flask container, pushes it to Amazon Elastic Container Registry (ECR), and deploys it to an existing Amazon Elastic Kubernetes Service (EKS) cluster. GitHub pushes trigger AWS CodePipeline through an AWS CodeConnections GitHub App connection.

## Architecture and files

```text
GitHub -> CodeConnections -> CodePipeline -> CodeBuild -> ECR -> EKS
```

- `pyproject.toml` declares the Python 3.13 application and its Flask/Gunicorn dependencies; `uv.lock` records exact versions and hashes for macOS and Linux.
- `.python-version` selects Python 3.13 locally. `Dockerfile` uses uv 0.13.5 to synchronize the lockfile into `/opt/venv`, then copies that environment into the runtime image, which runs as UID 10001.
- `.dockerignore`: includes only the application and dependency inputs, excluding local `.env` files and Git metadata.
- `buildspec.yml` and `scripts/pipeline.sh`: install a checksum-verified Linux kubectl matching the cluster minor version, test, build, smoke-test, push, deploy, and wait for rollout.
- `scripts/smoke-test.sh`: checks HTTP with a read-only container filesystem and verifies that credentials are absent from the application directory.
- `deployment.yml`: three replicas, resource limits, health probes, non-root security settings, and a ClusterIP Service in `deployment-tests`.
- `rbac.yml`: namespace, Role, and RoleBinding. Apply as a cluster administrator before creating the pipeline.
- `ci-cd-codepipeline.cfn.yml`: the pipeline, build project, separate build/deploy roles, EKS access entry, ECR repository, artifact bucket, and build logs.
- `tests/`: application and pipeline failure-path tests.
- `security.guard`: scoped CloudFormation Guard rules for artifact security, immutable/scanned images, access entries, and the modern source action.

The historical `trust.json`, `iam-role-policy.json`, and `aws-auth-patch.yml` files are retained only as course references. The updated pipeline does not use them, personal access tokens, or a custom provisioning Lambda.

## Prerequisites

Use an existing EKS cluster with Ready nodes and an API endpoint reachable from CodeBuild. This template uses an x86-64 managed CodeBuild image and produces Linux amd64 images; use amd64 nodes such as `t3.medium`. Local Docker tests also run on Apple Silicon. A private-only EKS endpoint requires a separate CodeBuild VPC configuration.

The EKS cluster, stack, and GitHub connection must be in the same AWS Region. The cluster must support EKS access entries (`API` or `API_AND_CONFIG_MAP`). Your operator identity needs cluster-admin Kubernetes access to bootstrap RBAC and AWS permissions to create the stack's IAM, EKS access-entry, CodeBuild, CodePipeline, ECR, S3, and Logs resources. CodeBuild uses its service role, not your local SSO session.

Commands below run from this repository's root.

Install the local project environment and run its tests with uv:

```bash
uv sync --locked
uv run --locked python -m unittest discover -s tests -v
```

This repository has its own `pyproject.toml`, lockfile, and `.venv`, separate from the parent course environment. Docker and CodeBuild use `uv sync --locked --no-dev`; a stale lockfile causes a build failure rather than a dependency update.

```bash
aws sso login --profile deployment-course
export AWS_PROFILE=deployment-course
export AWS_DEFAULT_REGION=eu-central-1
export EKS_CLUSTER_NAME=eksctl-demo

aws sts get-caller-identity
aws eks update-kubeconfig --region "$AWS_DEFAULT_REGION" --name "$EKS_CLUSTER_NAME"
aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
  --query 'cluster.{version:version,authenticationMode:accessConfig.authenticationMode}' --output table
```

Use a local `kubectl` within one minor version of the control plane. The build selects the correct Linux client automatically; it does not reuse your Mac binary.

If the reported authentication mode is `CONFIG_MAP`, enable access entries and wait:

```bash
aws eks update-cluster-config --name "$EKS_CLUSTER_NAME" \
  --access-config authenticationMode=API_AND_CONFIG_MAP
aws eks wait cluster-active --name "$EKS_CLUSTER_NAME"
```

Enabling the access-entry API cannot be reversed to `CONFIG_MAP` only. This hybrid mode preserves existing node/user mappings. No migration of existing access is performed by the pipeline.

## 1. Bootstrap Kubernetes RBAC

First confirm that kubeconfig selects the intended cluster, then apply:

```bash
kubectl config current-context
kubectl get nodes -o wide
kubectl apply -f rbac.yml
```

The RoleBinding connects the `final-pipeline-deployer` group to permissions in the `deployment-tests` namespace. The deploy role can manage Deployments and Services and read rollout diagnostics; it cannot manage RBAC, access Secrets, or administer other namespaces.

CloudFormation later creates an EKS access entry that maps its generated deploy role to this group. The previous `system:masters` mapping is unnecessary. If you added that mapping for the old exercise, it remains in place until you deliberately remove it; this stack does not modify existing identities.

## 2. Connect GitHub

In **AWS Developer Tools -> Settings -> Connections**, create or select a GitHub connection in the stack Region. Authorize the AWS Connector GitHub App for this repository and complete the connection until its status is **AVAILABLE**. A connection left **PENDING** cannot fetch source.

Copy its ARN and verify:

```bash
export CONNECTION_ARN="arn:aws:codeconnections:eu-central-1:<ACCOUNT_ID>:connection/<CONNECTION_ID>"
aws codeconnections get-connection --connection-arn "$CONNECTION_ARN" \
  --query Connection.ConnectionStatus --output text
```

Both modern `codeconnections` and older `codestar-connections` ARNs are accepted. No GitHub token belongs in the template, build variables, or Docker image.

## 3. Create the pipeline stack

Push these files to your GitHub fork first: CodePipeline builds the remote commit, not uncommitted local changes or the parent course repository.

Create a **new exercise stack** with `ci-cd-codepipeline.cfn.yml`. This replaces the legacy PAT/Lambda architecture; inspect a change set before using the template to update an existing stack.

| Parameter | Default / value |
| --- | --- |
| `EksClusterName` | `eksctl-demo` |
| `GitHubUser` | `mxagar`, or your repository owner |
| `GitSourceRepo` | `udacity_deployments_final_pipeline` |
| `GitBranch` | `main` |
| `ConnectionArn` | The authorized connection ARN |
| `CodeBuildDockerImage` | `aws/codebuild/standard:8.0` |

Use the CloudFormation console in the cluster Region, upload the template, enter the parameters, acknowledge IAM resource creation, and wait for `CREATE_COMPLETE`. Alternatively:

```bash
aws cloudformation deploy \
  --template-file ci-cd-codepipeline.cfn.yml \
  --stack-name final-pipeline-test \
  --parameter-overrides \
    EksClusterName="$EKS_CLUSTER_NAME" \
    GitHubUser=mxagar \
    GitSourceRepo=udacity_deployments_final_pipeline \
    GitBranch=main \
    ConnectionArn="$CONNECTION_ARN" \
  --capabilities CAPABILITY_IAM
```

The stack creates a build role, a deploy role that trusts only that build role, and an EKS access entry. A separate IAM policy connects the roles without a circular CloudFormation dependency. The build role reads cluster metadata for kubectl selection; Kubernetes requests use the assumed deploy role. ECR image tags are immutable. Artifacts are encrypted, versioned, private, and HTTPS-only.

## 4. Build and verify

The build uses Python 3.13 and AWS CLI v2 from `standard:8.0`. uv 0.13.5 is pinned in the Dockerfile and buildspec; update both pins together when upgrading the build tool. Its four phases:

1. `install`: checks AWS CLI v2, installs the pinned uv version when needed, reads the target cluster version, downloads the matching Linux kubectl with SHA-256 verification, and ensures Docker is running.
2. `pre_build`: renders the exact ECR image URI into `deployment.rendered.yml` and logs in with `get-login-password`.
3. `build`: synchronizes `uv.lock` into the project environment, runs unit tests with `uv run --locked`, builds the image using the same lockfile, and runs an HTTP container smoke test.
4. `post_build`: stops if an earlier phase failed; otherwise pushes the image, assumes the deploy role through kubeconfig, applies Deployment and Service, waits up to 180 seconds for rollout, checks the image URI, and writes `build.json`.

Image tags use the CodeBuild build number and commit ID, so repository/branch punctuation cannot produce an invalid Docker tag. The original manifest remains unchanged.

A push to the configured branch triggers the pipeline. You can also use **Release change** in CodePipeline; starting the CodeBuild project directly omits its source artifacts.

After a successful build:

```bash
kubectl -n deployment-tests rollout status deployment/simple-flask-deployment
kubectl -n deployment-tests get pods,services -o wide
kubectl -n deployment-tests port-forward service/simple-flask-deployment 8080:80
```

Keep port forwarding running; in another terminal:

```bash
curl --fail http://127.0.0.1:8080/
# Hello, World from Flask!
```

The Service is internal (`ClusterIP`); it has no external IP and creates no AWS load balancer.

## Local validation

```bash
uv lock --check
uv sync --locked
uv run --locked python -m unittest discover -s tests -v
bash -n scripts/pipeline.sh scripts/smoke-test.sh
docker build -t final-pipeline-local .
bash scripts/smoke-test.sh final-pipeline-local
uv tool run --from cfn-lint==1.60.0 cfn-lint \
  --regions eu-central-1 --template ci-cd-codepipeline.cfn.yml
```

With the official [CloudFormation Guard CLI](https://docs.aws.amazon.com/cfn-guard/latest/ug/setting-up.html) available, check the repository's security invariants:

```bash
cfn-guard validate --data ci-cd-codepipeline.cfn.yml \
  --rules security.guard --show-summary all
```

These rules check this template's security constraints; they are not a comprehensive compliance audit. Local validation does not verify live account permissions, connection authorization, cluster networking, or quotas.

Declare dependency changes in `pyproject.toml`, then resolve and verify them. Commit `pyproject.toml` and `uv.lock` together:

```bash
uv lock
uv sync --locked
uv run --locked python -m unittest discover -s tests -v
# To intentionally upgrade all dependencies within the declared bounds:
# uv lock --upgrade
```

## Troubleshooting and cleanup

- **Source fails:** verify the connection is AVAILABLE, authorized for the repository, and configured for the correct owner/branch.
- **Cluster not found:** verify the stack Region and `EksClusterName`; this template expects the cluster in the same Region.
- **Unauthorized or Forbidden:** check the stack-created access entry, role trust, and `rbac.yml` in the correct cluster. Reapply RBAC using your administrator identity. Do not grant `system:masters` to bypass the failure.
- **Rollout fails:** inspect CodeBuild's Pod/event diagnostics and `kubectl -n deployment-tests logs deployment/simple-flask-deployment`. Confirm amd64 nodes and that nodes can pull from ECR.
- **Artifact error when starting CodeBuild:** run the pipeline through CodePipeline instead.
- **Private API endpoint timeout:** a private-only endpoint needs CodeBuild VPC/subnet/security-group configuration and network access; the current template does not provision that networking.

Deleting the pipeline stack removes its IAM roles and EKS access entry but retains the ECR repository and versioned S3 bucket. Deployed Kubernetes resources, the cluster, and the GitHub connection also remain. After inspecting the exact resources, remove those you created for the exercise when no longer needed; cluster/node and storage charges continue until cleanup.
