#!/bin/bash -e
# Full ZTIDM + SPIRE install on one or two clusters (with optional federation)
#
# Single cluster:  export KUBECONFIG1=~/.kube/sno1; ./go.sh
# Two clusters:    export KUBECONFIG1=~/.kube/sno1 KUBECONFIG2=~/.kube/sno2; ./go.sh
#
# Expects: clusters with default storage class and OperatorHub access
#
# Usage:
#   ./go.sh          # interactive (pauses between phases)
#   ./go.sh --yes    # non-interactive (no pauses)
#
# Re-runnable: safe to run again (oc apply/patch are idempotent)
# Generated YAML saved to ./<cluster-name>/ for inspection/re-apply
#
# WARNING: trustDomain, federation profile, and persistence are IMMUTABLE once applied.
#          Changing them requires full reinstall.

YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=true

pause() {
	$YES && return 0
	echo -n "Hit enter to continue or ctrl-c > "; read -t 60 yn || true
}

NS=zero-trust-workload-identity-manager

KUBECONFIG1="${KUBECONFIG1:?Export KUBECONFIG1 (e.g. ~/.kube/sno1)}"
KUBECONFIG2="${KUBECONFIG2:-}"

oc1() { oc --kubeconfig="$KUBECONFIG1" "$@"; }
if [ -n "$KUBECONFIG2" ]; then
	oc2() { oc --kubeconfig="$KUBECONFIG2" "$@"; }
	FEDERATION=true
	CLUSTERS="1 2"
else
	FEDERATION=false
	CLUSTERS="1"
fi

# Auto-detect cluster info
CN1=$(oc1 whoami --show-server | cut -d. -f2)
APPS1=$(oc1 get ingresses.config/cluster -o jsonpath='{.spec.domain}')
SC1=$(oc1 get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

if $FEDERATION; then
	CN2=$(oc2 whoami --show-server | cut -d. -f2)
	APPS2=$(oc2 get ingresses.config/cluster -o jsonpath='{.spec.domain}')
	SC2=$(oc2 get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
else
	CN2="" APPS2="" SC2=""
fi

# DEMO-HIGHLIGHT: Trust Domain = Apps Domain
# The trust domain is the root of all SPIFFE IDs on this cluster.
# Using the *.apps domain means federation Routes (federation.<apps-domain>)
# resolve automatically via OpenShift's wildcard DNS — no extra DNS config needed.
# WARNING: trust domain is IMMUTABLE once set. Changing it requires full reinstall.
TD1="$APPS1"
TD2="$APPS2"

# Output directories for generated YAML (one per cluster)
mkdir -p "$CN1"
$FEDERATION && mkdir -p "$CN2"

echo "Cluster 1: $CN1"
echo "  API:           $(oc1 whoami --show-server)"
echo "  Apps domain:   $APPS1"
echo "  Trust domain:  $TD1"
echo "  Storage class: $SC1"
if $FEDERATION; then
	echo
	echo "Cluster 2: $CN2"
	echo "  API:           $(oc2 whoami --show-server)"
	echo "  Apps domain:   $APPS2"
	echo "  Trust domain:  $TD2"
	echo "  Storage class: $SC2"
fi
echo
echo "Mode: $($FEDERATION && echo "Two-cluster federation (https_spiffe)" || echo "Single cluster")"
echo "YAML output: ./$CN1/$($FEDERATION && echo "  ./$CN2/")"
echo
echo "Next: Phase 1 -- Install Operator on both clusters"
pause

###############################################
echo
echo "=========================================="
echo "  Phase 1: Install Operator (both clusters)"
echo "=========================================="

for i in $CLUSTERS; do
	if [ "$i" = "1" ]; then
		OC=oc1; CN=$CN1; OUTDIR=$CN1
	else
		OC=oc2; CN=$CN2; OUTDIR=$CN2
	fi

	echo
	echo "--- Installing operator on $CN ---"

tee $OUTDIR/01-Namespace.yaml <<EOF | $OC apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
EOF

tee $OUTDIR/02-OperatorGroup.yaml <<EOF | $OC apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-zero-trust-workload-identity-manager
  namespace: $NS
spec:
  upgradeStrategy: Default
EOF

tee $OUTDIR/03-Subscription.yaml <<EOF | $OC apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-zero-trust-workload-identity-manager
  namespace: $NS
spec:
  channel: stable-v1
  name: openshift-zero-trust-workload-identity-manager
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

done

echo
echo "Waiting for operator deployments (this may take a few minutes)..."
pause

for i in $CLUSTERS; do
	if [ "$i" = "1" ]; then
		OC=oc1; CN=$CN1
	else
		OC=oc2; CN=$CN2
	fi

	echo
	echo "--- Waiting for operator on $CN ---"
	$OC get subscription -n $NS
	$OC get csv -n $NS
	$OC get deployment -l name=zero-trust-workload-identity-manager -n $NS
	$OC rollout status deployment -l name=zero-trust-workload-identity-manager -n $NS --timeout=10m

done

echo
echo "Next: Phase 2 -- Deploy Operands on both clusters"
pause

###############################################
echo
echo "=========================================="
echo "  Phase 2: Deploy Operands (both clusters)"
echo "=========================================="

for i in $CLUSTERS; do
	if [ "$i" = "1" ]; then
		OC=oc1; CN=$CN1; TD=$TD1; SC=$SC1; APPS=$APPS1; OUTDIR=$CN1
	else
		OC=oc2; CN=$CN2; TD=$TD2; SC=$SC2; APPS=$APPS2; OUTDIR=$CN2
	fi

	echo
	echo "--- Deploying operands on $CN ---"

	###############################################
	echo "  ZeroTrustWorkloadIdentityManager..."

tee $OUTDIR/04-ZeroTrustWorkloadIdentityManager.yaml <<EOF | $OC apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
  labels:
    app.kubernetes.io/name: zero-trust-workload-identity-manager
    app.kubernetes.io/managed-by: zero-trust-workload-identity-manager
spec:
  trustDomain: "$TD"
  clusterName: "$CN"
  bundleConfigMap: "spire-bundle"
EOF

	###############################################
	echo "  SpireServer (with federation https_spiffe)..."

tee $OUTDIR/05-SpireServer.yaml <<EOF | $OC apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  trustDomain: "$TD"
  logLevel: "info"
  logFormat: "text"
  jwtIssuer: "https://oidc-discovery.${APPS}"
  caValidity: "24h"
  defaultX509Validity: "1h"
  defaultJWTValidity: "5m"
  jwtKeyType: "rsa-2048"
  caSubject:
    country: "US"
    organization: "SPIRE"
    commonName: "SPIRE Server CA"
  persistence:
    size: "5Gi"
    accessMode: "ReadWriteOnce"
    storageClass: "$SC"
  datastore:
    databaseType: "sqlite3"
    connectionString: "/run/spire/data/datastore.sqlite3"
    tlsSecretName: ""
    maxOpenConns: 100
    maxIdleConns: 10
    connMaxLifetime: 0
    disableMigration: "false"
  federation:
    bundleEndpoint:
      profile: https_spiffe
      refreshHint: 300
    managedRoute: "true"
EOF

	echo "  Waiting for SpireServer rollout..."
	$OC get statefulset -l app.kubernetes.io/component=control-plane -n $NS
	$OC get po -l app.kubernetes.io/component=control-plane -n $NS
	$OC get pvc -l app.kubernetes.io/component=control-plane -n $NS
	$OC rollout status statefulset -l app.kubernetes.io/component=control-plane -n $NS --timeout=5m
	$OC wait --for=condition=ready pod -l app.kubernetes.io/component=control-plane -n $NS --timeout=300s

	echo "  SpireServer CR health check..."
	$OC get spireserver cluster || { echo "ERROR: SpireServer CR not found on $CN"; exit 1; }

	###############################################
	echo "  SpireAgent..."

tee $OUTDIR/06-SpireAgent.yaml <<EOF | $OC apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  socketPath: "/run/spire/agent-sockets"
  logLevel: "info"
  logFormat: "text"
  nodeAttestor:
    k8sPSATEnabled: "true"
  workloadAttestors:
    k8sEnabled: "true"
    workloadAttestorsVerification:
      type: "auto"
      hostCertBasePath: "/etc/kubernetes"
      hostCertFileName: "kubelet-ca.crt"
    disableContainerSelectors: "false"
    useNewContainerLocator: "true"
EOF

	$OC get daemonset -l app.kubernetes.io/component=node-agent -n $NS
	$OC get po -l app.kubernetes.io/component=node-agent -n $NS
	$OC wait --for=condition=ready pod -l app.kubernetes.io/component=node-agent -n $NS --timeout=300s
	$OC rollout status daemonset -l app.kubernetes.io/component=node-agent -n $NS --timeout=5m

	###############################################
	echo "  SpiffeCSIDriver..."

tee $OUTDIR/07-SpiffeCSIDriver.yaml <<EOF | $OC apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec:
  agentSocketPath: "/run/spire/agent-sockets"
  pluginName: "csi.spiffe.io"
EOF

	$OC get daemonset -l app.kubernetes.io/component=csi -n $NS
	$OC get po -l app.kubernetes.io/component=csi -n $NS
	$OC rollout status daemonset -l app.kubernetes.io/component=csi -n $NS --timeout=5m
	$OC wait --for=condition=ready pod -l app.kubernetes.io/component=csi -n $NS --timeout=300s

	###############################################
	echo "  SpireOIDCDiscoveryProvider..."

tee $OUTDIR/08-SpireOIDCDiscoveryProvider.yaml <<EOF | $OC apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  logLevel: "info"
  logFormat: "text"
  csiDriverName: "csi.spiffe.io"
  jwtIssuer: "https://oidc-discovery.${APPS}"
  replicaCount: 1
  managedRoute: "true"
EOF

	$OC get deployment -l app.kubernetes.io/name=spiffe-oidc-discovery-provider -n $NS
	$OC get po -l app.kubernetes.io/name=spiffe-oidc-discovery-provider -n $NS
	$OC rollout status deployment -l app.kubernetes.io/name=spiffe-oidc-discovery-provider -n $NS --timeout=5m
	$OC wait --for=condition=ready pod -l app.kubernetes.io/name=spiffe-oidc-discovery-provider -n $NS --timeout=300s

	###############################################
	echo "  Health check: all operands on $CN..."
	$OC get zerotrustworkloadidentitymanager cluster -o json | jq -e '.status.operands | all(.ready == "true")' || {
		echo "ERROR: Not all operands are ready on $CN"
		echo "  Run: oc get zerotrustworkloadidentitymanager cluster -o yaml"
		exit 1
	}
	echo "  All operands Ready on $CN."

done

if $FEDERATION; then

echo
echo "Next: Phase 3 -- Federation Setup (cross-cluster trust)"
pause

###############################################
echo
echo "=========================================="
echo "  Phase 3: Federation Setup"
echo "=========================================="

FED1="https://federation.${TD1}"
FED2="https://federation.${TD2}"

echo
echo "--- Verify federation routes ---"

echo "Cluster 1 ($CN1):"
oc1 get route -n $NS | grep -q federation || { echo "ERROR: No federation route on $CN1. Check SpireServer federation config."; exit 1; }
oc1 get route -n $NS | grep federation

echo "Cluster 2 ($CN2):"
oc2 get route -n $NS | grep -q federation || { echo "ERROR: No federation route on $CN2. Check SpireServer federation config."; exit 1; }
oc2 get route -n $NS | grep federation

echo
echo "Federation endpoints:"
echo "  $CN1: $FED1"
echo "  $CN2: $FED2"

###############################################
echo
echo "--- Fetch trust bundles ---"

echo "Fetching from $CN2 ($FED2)..."
BUNDLE2=$(curl -sk "$FED2")
echo "  Keys: $(echo "$BUNDLE2" | jq -r '.keys | length')"

echo "Fetching from $CN1 ($FED1)..."
BUNDLE1=$(curl -sk "$FED1")
echo "  Keys: $(echo "$BUNDLE1" | jq -r '.keys | length')"

if ! echo "$BUNDLE1" | jq -e '.keys' >/dev/null 2>&1; then
	echo "ERROR: Bundle from $CN1 is not valid. Check: curl -sk $FED1"
	exit 1
fi

if ! echo "$BUNDLE2" | jq -e '.keys' >/dev/null 2>&1; then
	echo "ERROR: Bundle from $CN2 is not valid. Check: curl -sk $FED2"
	exit 1
fi

###############################################
echo
echo "--- Create ClusterFederatedTrustDomain resources ---"

# DEMO-HIGHLIGHT: Cross-Cluster Trust Establishment
# ClusterFederatedTrustDomain tells SPIRE: "trust this remote cluster".
# Each cluster gets a resource pointing to the OTHER cluster's federation endpoint.
# The bundleEndpointProfile "https_spiffe" means SPIRE fetches the remote cluster's
# CA bundle automatically and keeps it up-to-date — no manual cert exchange needed.
echo "On $CN1: federation-to-${CN2}..."
tee $CN1/09-ClusterFederatedTrustDomain.yaml <<EOF | oc1 apply -f -
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: federation-to-${CN2}
spec:
  trustDomain: "${TD2}"
  bundleEndpointURL: "${FED2}"
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: "spiffe://${TD2}/spire/server"
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |
    $(echo "$BUNDLE2" | jq -c '.')
EOF

echo "On $CN2: federation-to-${CN1}..."
tee $CN2/09-ClusterFederatedTrustDomain.yaml <<EOF | oc2 apply -f -
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: federation-to-${CN1}
spec:
  trustDomain: "${TD1}"
  bundleEndpointURL: "${FED1}"
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: "spiffe://${TD1}/spire/server"
  className: zero-trust-workload-identity-manager-spire
  trustDomainBundle: |
    $(echo "$BUNDLE1" | jq -c '.')
EOF

echo
echo "Verify ClusterFederatedTrustDomains..."
echo "On $CN1:"
oc1 get clusterfederatedtrustdomains
oc1 describe clusterfederatedtrustdomain federation-to-${CN2} | tail -20

echo "On $CN2:"
oc2 get clusterfederatedtrustdomains
oc2 describe clusterfederatedtrustdomain federation-to-${CN1} | tail -20

###############################################
echo
echo "--- Update SpireServers with federatesWith ---"

PATCH1="{\"spec\":{\"federation\":{\"federatesWith\":[{\"trustDomain\":\"${TD2}\",\"bundleEndpointUrl\":\"${FED2}\",\"bundleEndpointProfile\":\"https_spiffe\",\"endpointSpiffeId\":\"spiffe://${TD2}/spire/server\"}]}}}"

PATCH2="{\"spec\":{\"federation\":{\"federatesWith\":[{\"trustDomain\":\"${TD1}\",\"bundleEndpointUrl\":\"${FED1}\",\"bundleEndpointProfile\":\"https_spiffe\",\"endpointSpiffeId\":\"spiffe://${TD1}/spire/server\"}]}}}"

echo "$PATCH1" | jq '.' > $CN1/10-SpireServer-federatesWith.json
echo "$PATCH2" | jq '.' > $CN2/10-SpireServer-federatesWith.json

echo "Updating $CN1..."
oc1 patch spireserver cluster --type=merge -p "$PATCH1"

echo "Updating $CN2..."
oc2 patch spireserver cluster --type=merge -p "$PATCH2"

echo "Wait for rollout..."
oc1 rollout status statefulset -l app.kubernetes.io/component=control-plane -n $NS --timeout=5m
oc2 rollout status statefulset -l app.kubernetes.io/component=control-plane -n $NS --timeout=5m

fi  # FEDERATION

###############################################
echo
echo "=========================================="
echo "  Phase 4: Verification"
echo "=========================================="

if $FEDERATION; then
	echo
	echo "ClusterFederatedTrustDomains on $CN1:"
	oc1 get clusterfederatedtrustdomains

	echo
	echo "ClusterFederatedTrustDomains on $CN2:"
	oc2 get clusterfederatedtrustdomains

	echo
	echo "Federation endpoint health check..."
	KEYS1=$(curl -sk "$FED1" | jq -r '.keys | length')
	test "$KEYS1" -gt 0 || { echo "ERROR: $CN1 federation endpoint returned no keys ($FED1)"; exit 1; }
	echo "  $CN1: $KEYS1 keys"

	KEYS2=$(curl -sk "$FED2" | jq -r '.keys | length')
	test "$KEYS2" -gt 0 || { echo "ERROR: $CN2 federation endpoint returned no keys ($FED2)"; exit 1; }
	echo "  $CN2: $KEYS2 keys"
fi

echo
echo "SPIRE Server logs ($CN1, last 10 lines):"
oc1 logs -n $NS statefulset/spire-server -c spire-server --tail=10

if $FEDERATION; then
	echo
	echo "SPIRE Server logs ($CN2, last 10 lines):"
	oc2 logs -n $NS statefulset/spire-server -c spire-server --tail=10
fi

echo
echo "Generated YAML saved to:"
ls -1 $CN1/*.yaml $CN1/*.json 2>/dev/null || true
$FEDERATION && { ls -1 $CN2/*.yaml $CN2/*.json 2>/dev/null || true; }

echo
if $FEDERATION; then
	echo "DONE -- federation healthy on both clusters."
else
	echo "DONE -- ZTIDM + SPIRE healthy on $CN1."
fi
