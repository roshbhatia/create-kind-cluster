#!/bin/sh
# Usage:
# kind-with-registry-up.sh [up|down] [flags]
#
# Examples:
# ./kind-with-registry-up.sh up
# ./kind-with-registry-up.sh down
#
# Requirements:
# - kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation
# - kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl/
# - jq: https://stedolan.github.io/jq/download/

set -o errexit

CLUSTER_NAME=${CLUSTER_NAME:-kind}

REGISTRY_PORT=${REGISTRY_PORT:-5000}

# Dependency checks.
if ! command -v kind &> /dev/null
then
  echo "kind could not be found. Please install kind before continuing."
  exit 1
fi

if ! command -v kubectl &> /dev/null
then
  echo "kubectl could not be found. Please install kubectl before continuing."
  exit 1
fi

if ! command -v jq &> /dev/null
then
  echo "jq could not be found. Please install jq before continuing."
  exit 1
fi

# Input validation.
if [[ $CLUSTER_NAME =~ [^a-zA-Z0-9-] ]]; then
  echo "Cluster name must consist of alphanumeric characters or '-'"
  exit 1
fi

if [[ $REGISTRY_PORT =~ [^0-9] ]]; then
  echo "Registry port must be a number"
  exit 1
fi

# Create the cluster if argument is "up".
if [ "$1" = "up" ]; then
  # Create the cluster.
  cat <<EOF | kind create cluster --wait 90s --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
    endpoint = ["http://${reg_name}:${REGISTRY_PORT}"]
EOF

  # Create the registry container unless it already exists.
  reg_name="${CLUSTER_NAME}-registry"
  running="$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)"
  if [ "${running}" != 'true' ]; then
    docker run \
      -d --restart=always -p "${REGISTRY_PORT}:5000" --name "${reg_name}" \
      registry:2
  fi

  # Connect the registry to the cluster network.
  docker network connect "kind" "${reg_name}" || true

  # Document the local registry.
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry
  namespace: kube-public
data:
  localRegistryHost: "localhost:${REGISTRY_PORT}"
EOF

  echo "Registry created and configured. To use it, add the following to the containerd config of your nodes:"
  echo ""
  echo "    [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"localhost:${REGISTRY_PORT}\"]"
  echo "      endpoint = [\"http://localhost:${REGISTRY_PORT}\"]"
  echo ""
  echo "You can then push images to localhost:${REGISTRY_PORT} and they will be available from the registry within the cluster."
  echo "This has been added to the kind config for you."

  # Create NGINX ingress resources.
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml --context "kind-${CLUSTER_NAME}"
  kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=600s --context "kind-${CLUSTER_NAME}"

# Delete the cluster if argument is "down".
elif [ "$1" = "down" ]; then
  kind delete cluster --name "$CLUSTER_NAME"

  # Delete the registry container.
  docker container rm -f kind-registry

# Print usage if argument is not "up" or "down".
else
  echo "Usage: kind-with-registry-up.sh [up|down]"
  echo ""
  echo "Examples:"
  echo "  ./kind-with-registry-up.sh up"
  echo "  ./kind-with-registry-up.sh down"
fi
