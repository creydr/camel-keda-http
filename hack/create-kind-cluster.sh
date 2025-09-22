#!/usr/bin/env bash

set -e
set -o errexit
set -o nounset
set -o pipefail

header=$'\e[1;33m'
reset=$'\e[0m'

function header_text {
	echo "$header$*$reset"
}

kind delete cluster || true

NODE_VERSION=${NODE_VERSION:-"v1.34.0"}
NODE_SHA=${NODE_SHA:-"sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a"}
REGISTRY_NAME=${REGISTRY_NAME:-"kind-registry"}
REGISTRY_PORT=${REGISTRY_PORT:-"5001"}

# create registry container unless it already exists
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "${REGISTRY_NAME}" \
    docker.io/registry:2
fi

cat <<EOF | kind create cluster --config=-
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster

containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
    endpoint = ["http://${REGISTRY_NAME}:5000"]
nodes:
- role: control-plane
  image: kindest/node:${NODE_VERSION}@${NODE_SHA}
- role: worker
  image: kindest/node:${NODE_VERSION}@${NODE_SHA}
EOF

# connect the registry to the cluster network if not already connected
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}")" = 'null' ]; then
  docker network connect "kind" "${REGISTRY_NAME}"
fi

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

header_text "Installing Strimzi Operator"
kubectl create namespace kafka
kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
header_text "Waiting for Strimzi Operator to become ready"
kubectl wait deployment --all --timeout=-1s --for=condition=Available -n kafka
header_text "Create an Apache Kafka Cluster"
kubectl apply -f https://strimzi.io/examples/latest/kafka/kafka-single-node.yaml -n kafka
header_text "Waiting for Kafka cluster to become ready"
kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka

header_text "Installing Cert Manager"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml
header_text "Waiting for Cert Manager to become ready"
kubectl wait deployment --all --timeout=-1s --for=condition=Available -n cert-manager

header_text "Installing OTel Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
header_text "Waiting for OTel Operator to become ready"
kubectl wait deployment --all --timeout=-1s --for=condition=Available -n opentelemetry-operator-system

header_text "Installing Grafana Operator"
helm upgrade -i grafana-operator oci://ghcr.io/grafana/helm-charts/grafana-operator --version v5.19.0 --namespace grafana  --create-namespace
header_text "Waiting for Grafana operator to become ready"
kubectl wait deployment --all --timeout=-1s --for=condition=Available -n grafana

header_text "Installing Prometheus Operator"
helm install kube-prometheus-stack oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --namespace kube-prometheus --create-namespace --set grafana.enabled=false
header_text "Waiting for Prometheus Operator to become ready"
kubectl wait deployment --all --timeout=-1s --for=condition=Available --namespace kube-prometheus

header_text "Creating Otel Collector"
kubectl create namespace observability
kubectl apply -f - <<EOF
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: collector
  namespace: observability
spec:
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: "0.0.0.0:4317"
          http:
            endpoint: "0.0.0.0:4318"
    processors:
      batch:
        timeout: 5s
    exporters:
      debug:
        verbosity: detailed
      prometheus:
        endpoint: "0.0.0.0:8889"
        namespace: default
    service:
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug, prometheus]
EOF

header_text "Creating Prometheus ServiceMonitor"
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: otel-collector-metrics
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: collector
  endpoints:
  - port: prometheus
    path: /metrics
EOF

header_text "Creating Grafana instance"
kubectl apply -f - <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: observability
  labels:
    dashboards: grafana
spec:
  config:
    security:
      admin_user: root
      admin_password: secret
EOF

kubectl apply -f - <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: metrics
  namespace: observability
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  datasource:
    name: prometheus
    type: prometheus
    access: proxy
    url: http://kube-prometheus-stack-prometheus.kube-prometheus.svc.cluster.local:9090
    isDefault: true
    jsonData:
      'tlsSkipVerify': true
      'timeInterval': "5s"
EOF

header_text "Installing keda"
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.17.0/keda-2.17.0.yaml
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.17.0/keda-2.17.0-core.yaml
header_text "Waiting for Keda to become ready"
kubectl wait deployment --all --timeout=-1s --for=condition=Available --namespace keda