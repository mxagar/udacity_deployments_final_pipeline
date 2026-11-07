#!/usr/bin/env bash
# Invoked by buildspec.yml. AWS credentials come from the CodeBuild service role.
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }

configure() {
  : "${REPOSITORY_URI:?Missing REPOSITORY_URI}"
  : "${EKS_CLUSTER_NAME:?Missing EKS_CLUSTER_NAME}"
  : "${EKS_KUBECTL_ROLE_ARN:?Missing EKS_KUBECTL_ROLE_ARN}"
  : "${AWS_DEFAULT_REGION:?Missing AWS_DEFAULT_REGION}"
  : "${CODEBUILD_BUILD_NUMBER:?Missing CODEBUILD_BUILD_NUMBER}"
  : "${CODEBUILD_RESOLVED_SOURCE_VERSION:?Missing CODEBUILD_RESOLVED_SOURCE_VERSION}"
  export KUBECONFIG="${CODEBUILD_SRC_DIR:-$PWD}/.kube/config"
  export KUBERNETES_NAMESPACE=deployment-tests
  export IMAGE_URI="${REPOSITORY_URI}:build-${CODEBUILD_BUILD_NUMBER}-${CODEBUILD_RESOLVED_SOURCE_VERSION:0:12}"
  [[ "$IMAGE_URI" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "Invalid image URI"
}

install_tools() {
  configure
  local aws_version cluster_version kubectl_version download_dir architecture uv_version
  aws_version="$(aws --version 2>&1)"
  [[ "$aws_version" == aws-cli/2.* ]] || die "AWS CLI v2 is required: $aws_version"
  python --version
  uv_version="${UV_VERSION:-0.13.5}"
  [[ "$uv_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid uv version"
  download_dir="$(mktemp -d)"
  if ! command -v uv >/dev/null 2>&1 || [[ "$(uv --version)" != "uv ${uv_version}"* ]]; then
    curl -fsSL --retry 3 "https://astral.sh/uv/${uv_version}/install.sh" -o "$download_dir/install-uv.sh"
    UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh "$download_dir/install-uv.sh"
  fi
  uv --version
  cluster_version="$(aws eks describe-cluster --region "$AWS_DEFAULT_REGION" \
    --name "$EKS_CLUSTER_NAME" --query cluster.version --output text)"
  [[ "$cluster_version" =~ ^1\.[0-9]+$ ]] || die "Invalid cluster version"
  kubectl_version="$(curl -fsSL --retry 3 "https://dl.k8s.io/release/stable-${cluster_version}.txt")"
  [[ "$kubectl_version" =~ ^v1\.[0-9]+\.[0-9]+$ ]] || die "Invalid kubectl release"
  [[ "$kubectl_version" == "v${cluster_version}."* ]] || die "kubectl version does not match the cluster"
  case "$(uname -m)" in
    x86_64) architecture=amd64 ;;
    aarch64|arm64) architecture=arm64 ;;
    *) die "Unsupported build architecture" ;;
  esac
  curl -fsSL --retry 3 "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${architecture}/kubectl" \
    -o "$download_dir/kubectl"
  curl -fsSL --retry 3 "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${architecture}/kubectl.sha256" \
    -o "$download_dir/kubectl.sha256"
  (cd "$download_dir" && printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check)
  install -m 0755 "$download_dir/kubectl" /usr/local/bin/kubectl
  kubectl version --client
  if ! docker info >/dev/null 2>&1; then
    nohup /usr/local/bin/dockerd --host=unix:///var/run/docker.sock \
      --storage-driver=overlay2 >/tmp/final-pipeline-dockerd.log 2>&1 &
    timeout 30 sh -c 'until docker info >/dev/null 2>&1; do sleep 1; done'
  fi
}

render_manifest() {
  : "${IMAGE_URI:?Missing IMAGE_URI}"
  python - <<'PY'
import os
from pathlib import Path

source = Path("deployment.yml").read_text()
if source.count("CONTAINER_IMAGE") != 1:
    raise SystemExit("deployment.yml must contain exactly one CONTAINER_IMAGE placeholder")
Path("deployment.rendered.yml").write_text(source.replace("CONTAINER_IMAGE", os.environ["IMAGE_URI"]))
PY
}

prepare() {
  configure
  render_manifest
  aws ecr get-login-password --region "$AWS_DEFAULT_REGION" |
    docker login --username AWS --password-stdin "${REPOSITORY_URI%%/*}"
}

build_image() {
  configure
  UV_PYTHON_DOWNLOADS=never uv sync --locked --no-dev --python "$(command -v python)"
  UV_PYTHON_DOWNLOADS=never uv run --locked --no-dev python -m unittest discover -s tests -v
  docker build --pull --tag "$IMAGE_URI" .
  bash scripts/smoke-test.sh "$IMAGE_URI"
}

deploy() {
  # CodeBuild can execute post_build even when an earlier phase failed.
  [[ "${CODEBUILD_BUILD_SUCCEEDING:-0}" == 1 ]] || die "Earlier phase failed; skipping deployment"
  configure
  render_manifest
  docker push "$IMAGE_URI"
  aws eks update-kubeconfig --region "$AWS_DEFAULT_REGION" --name "$EKS_CLUSTER_NAME" \
    --role-arn "$EKS_KUBECTL_ROLE_ARN"
  kubectl --namespace "$KUBERNETES_NAMESPACE" apply -f deployment.rendered.yml
  if ! kubectl --namespace "$KUBERNETES_NAMESPACE" rollout status \
    deployment/simple-flask-deployment --timeout=180s; then
    kubectl --namespace "$KUBERNETES_NAMESPACE" get pods -o wide || true
    kubectl --namespace "$KUBERNETES_NAMESPACE" get events --sort-by=.metadata.creationTimestamp || true
    exit 1
  fi
  local deployed_image
  deployed_image="$(kubectl --namespace "$KUBERNETES_NAMESPACE" get deployment simple-flask-deployment \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [[ "$deployed_image" == "$IMAGE_URI" ]] || die "Deployment image does not match this build"
  python - <<'PY'
import json
import os
from pathlib import Path

Path("build.json").write_text(json.dumps([{"name": "simple-flask", "imageUri": os.environ["IMAGE_URI"]}]))
PY
}

case "${1:-}" in
  install) install_tools ;;
  pre-build) prepare ;;
  build) build_image ;;
  deploy) deploy ;;
  render) render_manifest ;;
  *) die "Usage: bash scripts/pipeline.sh {install|pre-build|build|deploy|render}" ;;
esac
