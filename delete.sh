#!/bin/bash -e
# Full ZTIDM + SPIRE Federation teardown on two clusters
# Exact reverse of go.sh -- deletes everything in safe dependency order
#
# Usage:
#   export KUBECONFIG1=~/.kube/sno1 KUBECONFIG2=~/.kube/sno2
#   ./delete.sh
#
# Re-runnable: --ignore-not-found on all deletes, safe if partially deleted already

YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=true

pause() {
	$YES && return 0
	echo -n "Hit enter to continue or ctrl-c > "; read -t 60 yn || true
}

NS=zero-trust-workload-identity-manager

KUBECONFIG1="${KUBECONFIG1:?Export KUBECONFIG1 (e.g. ~/.kube/sno1)}"
KUBECONFIG2="${KUBECONFIG2:?Export KUBECONFIG2 (e.g. ~/.kube/sno2)}"

oc1() { oc --kubeconfig="$KUBECONFIG1" "$@"; }
oc2() { oc --kubeconfig="$KUBECONFIG2" "$@"; }

CN1=$(oc1 whoami --show-server | cut -d. -f2)
CN2=$(oc2 whoami --show-server | cut -d. -f2)

echo "Will DELETE all ZTIDM + Federation resources from:"
echo "  Cluster 1: $CN1 ($(oc1 whoami --show-server))"
echo "  Cluster 2: $CN2 ($(oc2 whoami --show-server))"
echo
echo "This removes: federation, all operands, operator, PVCs, CRDs, namespace."
echo "THIS CANNOT BE UNDONE."
echo
echo "Type 'yes' to continue (auto-proceeds in 60s):"
if $YES; then yn=yes; else echo -n "Hit enter to continue or ctrl-c > "; read -t 60 yn || true; fi
if [ "$yn" != "yes" ]; then
	echo "Aborted."
	exit 0
fi

###############################################
echo
echo "=========================================="
echo "  Phase 1: Remove Federation Resources"
echo "=========================================="

for i in 1 2; do
	if [ "$i" = "1" ]; then
		OC=oc1; CN=$CN1; REMOTE=$CN2
	else
		OC=oc2; CN=$CN2; REMOTE=$CN1
	fi

	echo
	echo "--- Removing federation on $CN ---"

	echo "  ClusterFederatedTrustDomains:"
	$OC get clusterfederatedtrustdomains --ignore-not-found
	$OC delete clusterfederatedtrustdomain federation-to-${REMOTE} --ignore-not-found --wait=true
	echo "  Deleted."

done

echo
echo "Verify federation resources gone:"
oc1 get clusterfederatedtrustdomains --ignore-not-found
oc2 get clusterfederatedtrustdomains --ignore-not-found

###############################################
echo
echo "=========================================="
echo "  Phase 2: Delete Operands (reverse order)"
echo "=========================================="

for i in 1 2; do
	if [ "$i" = "1" ]; then
		OC=oc1; CN=$CN1
	else
		OC=oc2; CN=$CN2
	fi

	echo
	echo "--- Deleting operands on $CN ---"

	###############################################
	echo "  SpireOIDCDiscoveryProvider..."
	$OC get deployment -l app.kubernetes.io/name=spiffe-oidc-discovery-provider -n $NS --ignore-not-found
	$OC delete SpireOIDCDiscoveryProvider cluster --ignore-not-found --wait=true
	$OC wait --for=delete pod -l app.kubernetes.io/name=spiffe-oidc-discovery-provider -n $NS --timeout=120s || true
	echo "  Gone."

	###############################################
	echo "  SpiffeCSIDriver..."
	$OC get daemonset -l app.kubernetes.io/component=csi -n $NS --ignore-not-found
	$OC delete SpiffeCSIDriver cluster --ignore-not-found --wait=true
	$OC wait --for=delete pod -l app.kubernetes.io/component=csi -n $NS --timeout=120s || true
	echo "  Gone."

	###############################################
	echo "  SpireAgent..."
	$OC get daemonset -l app.kubernetes.io/component=node-agent -n $NS --ignore-not-found
	$OC delete SpireAgent cluster --ignore-not-found --wait=true
	$OC wait --for=delete pod -l app.kubernetes.io/component=node-agent -n $NS --timeout=120s || true
	echo "  Gone."

	###############################################
	echo "  SpireServer..."
	$OC get statefulset -l app.kubernetes.io/component=control-plane -n $NS --ignore-not-found
	$OC get po -l app.kubernetes.io/component=control-plane -n $NS --ignore-not-found
	$OC get pvc -l app.kubernetes.io/component=control-plane -n $NS --ignore-not-found
	$OC delete SpireServer cluster --ignore-not-found --wait=true
	$OC wait --for=delete pod -l app.kubernetes.io/component=control-plane -n $NS --timeout=120s || true
	echo "  Gone."

	###############################################
	echo "  ZeroTrustWorkloadIdentityManager..."
	$OC delete ZeroTrustWorkloadIdentityManager cluster --ignore-not-found --wait=true
	echo "  Gone."

	###############################################
	echo "  PVCs..."
	$OC delete pvc -l app.kubernetes.io/name=spire-server -n $NS --ignore-not-found --wait=true
	echo "  Gone."

	echo
	echo "  Verify no operand pods remain on $CN..."
	remaining=$($OC get po -n $NS --no-headers --ignore-not-found 2>&1 | grep -cv "No resources" || true)
	if [ "$remaining" -gt 0 ]; then
		echo "WARNING: $remaining pod(s) still present on $CN:"
		$OC get po -n $NS
	else
		echo "  No operand pods remain on $CN."
	fi

done

echo
echo "Next: Phase 3 -- Uninstall Operator"
pause

###############################################
echo
echo "=========================================="
echo "  Phase 3: Uninstall Operator"
echo "=========================================="

for i in 1 2; do
	if [ "$i" = "1" ]; then
		OC=oc1; CN=$CN1
	else
		OC=oc2; CN=$CN2
	fi

	echo
	echo "--- Uninstalling operator on $CN ---"

	echo "  Deleting Subscription..."
	$OC delete subscription openshift-zero-trust-workload-identity-manager -n $NS --ignore-not-found --wait=true

	echo "  Deleting CSVs..."
	$OC delete csv --all -n $NS --ignore-not-found --wait=true

	echo "  Deleting OperatorGroup..."
	$OC delete operatorgroup openshift-zero-trust-workload-identity-manager -n $NS --ignore-not-found --wait=true

	echo "  Verify operator deployment gone..."
	$OC get deployment -n $NS --no-headers --ignore-not-found 2>&1 | grep -q "zero-trust" && {
		echo "WARNING: Operator deployment still present on $CN:"
		$OC get deployment -n $NS
	} || echo "  Operator deployment gone on $CN."

done

echo
echo "Next: Phase 4 -- Clean Up Cluster-Scoped Resources"
pause

###############################################
echo
echo "=========================================="
echo "  Phase 4: Clean Up Cluster-Scoped Resources"
echo "=========================================="

for i in 1 2; do
	if [ "$i" = "1" ]; then
		OC=oc1; CN=$CN1
	else
		OC=oc2; CN=$CN2
	fi

	echo
	echo "--- Cleaning up cluster resources on $CN ---"

	echo "  Services..."
	$OC delete service -l app.kubernetes.io/name=zero-trust-workload-identity-manager -n $NS --ignore-not-found

	echo "  Cluster roles..."
	$OC delete clusterrole -l app.kubernetes.io/name=zero-trust-workload-identity-manager --ignore-not-found

	echo "  Cluster role bindings..."
	$OC delete clusterrolebinding -l app.kubernetes.io/name=zero-trust-workload-identity-manager --ignore-not-found

	echo "  Validating webhooks..."
	$OC delete validatingwebhookconfigurations -l app.kubernetes.io/name=zero-trust-workload-identity-manager --ignore-not-found

	echo "  Namespace..."
	$OC delete namespace $NS --ignore-not-found --wait=true

	echo "  Verify namespace gone..."
	$OC get namespace $NS --ignore-not-found 2>&1 | grep -q "Active" && {
		echo "WARNING: Namespace $NS still exists on $CN (may be terminating)"
	} || echo "  Namespace gone on $CN."

done

echo
echo "Next: Phase 5 -- Delete CRDs (cluster-wide, removing them is final)"
pause

###############################################
echo
echo "=========================================="
echo "  Phase 5: Delete CRDs"
echo "=========================================="

for i in 1 2; do
	if [ "$i" = "1" ]; then
		OC=oc1; CN=$CN1
	else
		OC=oc2; CN=$CN2
	fi

	echo
	echo "--- Deleting CRDs on $CN ---"

	$OC delete crd spireoidcdiscoveryproviders.operator.openshift.io --ignore-not-found
	$OC delete crd spiffecsidrivers.operator.openshift.io --ignore-not-found
	$OC delete crd spireagents.operator.openshift.io --ignore-not-found
	$OC delete crd spireservers.operator.openshift.io --ignore-not-found
	$OC delete crd zerotrustworkloadidentitymanagers.operator.openshift.io --ignore-not-found
	$OC delete crd clusterfederatedtrustdomains.spire.spiffe.io --ignore-not-found
	$OC delete crd clusterspiffeids.spire.spiffe.io --ignore-not-found
	$OC delete crd clusterstaticentries.spire.spiffe.io --ignore-not-found

	echo "  Verify CRDs gone:"
	$OC get crd | grep -E "spire|spiffe|zero-trust" || echo "  All ZTIDM CRDs removed."

done

###############################################
echo
echo "=========================================="
echo "  Verification"
echo "=========================================="

for i in 1 2; do
	if [ "$i" = "1" ]; then
		OC=oc1; CN=$CN1
	else
		OC=oc2; CN=$CN2
	fi

	echo
	echo "--- $CN ---"
	echo "  Namespace:"
	$OC get namespace $NS --ignore-not-found
	echo "  CRDs:"
	$OC get crd | grep -E "spire|spiffe|zero-trust" || echo "  None."
	echo "  Cluster roles:"
	$OC get clusterrole -l app.kubernetes.io/name=zero-trust-workload-identity-manager --ignore-not-found
	echo "  Webhooks:"
	$OC get validatingwebhookconfigurations -l app.kubernetes.io/name=zero-trust-workload-identity-manager --ignore-not-found

done

echo
echo "DONE -- all ZTIDM resources removed from both clusters."
