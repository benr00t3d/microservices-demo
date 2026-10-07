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

can_i() {
  local label="$1"
  shift
  local decision
  decision="$(kubectl auth can-i "$@")"
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
