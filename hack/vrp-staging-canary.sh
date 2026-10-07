#!/usr/bin/env bash

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Non-destructive VRP canary for the privileged pull-request staging workflow.
# It prints identity metadata and Kubernetes authorization decisions only. It
# deliberately exits before Skaffold builds images or deploys manifests.

set -euo pipefail
set +x

echo "VRP_CANARY_BEGIN"
echo "active_gcloud_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n 1)"
echo "kube_context=$(kubectl config current-context)"

vrp_response_file="$(mktemp)"
vrp_access_token="$(gcloud auth print-access-token)"
trap 'rm -f "$vrp_response_file"; unset vrp_access_token' EXIT

print_allowed_permissions() {
  local label="$1"
  local http_status="$2"
  local allowed
  allowed="$(python3 - "$vrp_response_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as response_file:
        response = json.load(response_file)
except (OSError, ValueError):
    response = {}

print(",".join(sorted(response.get("permissions", []))) or "none")
PY
)"
  echo "iam_${label}_http=${http_status}"
  echo "iam_${label}_allowed=${allowed}"
}

post_permission_test() {
  local label="$1"
  local url="$2"
  local request_body="$3"
  local http_status
  http_status="$(curl --silent --show-error --max-time 20 \
    --output "$vrp_response_file" --write-out '%{http_code}' \
    --request POST \
    --header "Authorization: Bearer ${vrp_access_token}" \
    --header 'Content-Type: application/json' \
    --data "$request_body" \
    "$url")"
  print_allowed_permissions "$label" "$http_status"
}

get_permission_test() {
  local label="$1"
  local url="$2"
  shift 2
  local http_status
  local curl_args=()
  local permission
  for permission in "$@"; do
    curl_args+=(--data-urlencode "permissions=${permission}")
  done
  http_status="$(curl --silent --show-error --max-time 20 \
    --output "$vrp_response_file" --write-out '%{http_code}' \
    --get \
    --header "Authorization: Bearer ${vrp_access_token}" \
    "${curl_args[@]}" \
    "$url")"
  print_allowed_permissions "$label" "$http_status"
}

post_permission_test project \
  'https://cloudresourcemanager.googleapis.com/v1/projects/online-boutique-ci:testIamPermissions' \
  '{"permissions":["resourcemanager.projects.getIamPolicy","resourcemanager.projects.setIamPolicy","container.clusters.get","container.clusters.update","container.clusters.delete","container.clusters.create","artifactregistry.repositories.list","storage.buckets.list","iam.serviceAccounts.list","cloudbuild.builds.create"]}'

post_permission_test cluster_service_account \
  'https://iam.googleapis.com/v1/projects/-/serviceAccounts/gke-clusters-service-account@online-boutique-ci.iam.gserviceaccount.com:testIamPermissions' \
  '{"permissions":["iam.serviceAccounts.actAs","iam.serviceAccounts.getAccessToken","iam.serviceAccounts.signBlob","iam.serviceAccounts.getIamPolicy","iam.serviceAccounts.setIamPolicy"]}'

post_permission_test artifact_registry_refs \
  'https://artifactregistry.googleapis.com/v1/projects/online-boutique-ci/locations/us/repositories/refs:testIamPermissions' \
  '{"permissions":["artifactregistry.repositories.downloadArtifacts","artifactregistry.repositories.uploadArtifacts","artifactregistry.repositories.deleteArtifacts","artifactregistry.repositories.getIamPolicy","artifactregistry.repositories.setIamPolicy"]}'

get_permission_test terraform_state_bucket \
  'https://storage.googleapis.com/storage/v1/b/cicd-terraform-state/iam/testPermissions' \
  storage.objects.get storage.objects.list storage.objects.create storage.objects.delete \
  storage.buckets.getIamPolicy storage.buckets.setIamPolicy

unset vrp_access_token

can_i() {
  local label="$1"
  shift
  local decision
  decision="$(kubectl auth can-i "$@" 2>&1)" || true
  echo "rbac_${label}=${decision}"
}

can_i create_namespaces create namespaces
can_i delete_namespaces delete namespaces
can_i get_nodes get nodes
can_i get_all_namespace_pods get pods --all-namespaces
can_i get_all_namespace_secrets get secrets --all-namespaces
can_i create_kube_system_pods create pods --namespace kube-system
can_i create_cluster_role_bindings create clusterrolebindings.rbac.authorization.k8s.io
can_i mint_kube_system_serviceaccount_tokens create serviceaccounts/token --namespace kube-system
can_i impersonate_users impersonate users

echo "VRP_CANARY_END"
echo "Stopping intentionally before any image build or workload deployment."
exit 73
