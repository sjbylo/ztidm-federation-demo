#!/bin/bash -e
# Delete the Federation Demo (NOT the ZTIDM infrastructure)
#
# Deletes the demo-zero-trust namespace on both clusters.
# The ZTIDM operator, SPIRE components, and federation config are untouched.
#
# Usage:
#   export KUBECONFIG1=~/.kube/sno1 KUBECONFIG2=~/.kube/sno2
#   ./demo-delete.sh

YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=true

pause() {
	$YES && return 0
	echo -n "Hit enter to continue or ctrl-c > "; read -t 60 yn || true
}

NS=demo-zero-trust

KUBECONFIG1="${KUBECONFIG1:?Export KUBECONFIG1 (e.g. ~/.kube/sno1)}"
KUBECONFIG2="${KUBECONFIG2:?Export KUBECONFIG2 (e.g. ~/.kube/sno2)}"

oc1() { oc --kubeconfig="$KUBECONFIG1" "$@"; }
oc2() { oc --kubeconfig="$KUBECONFIG2" "$@"; }

CN1=$(oc1 whoami --show-server | cut -d. -f2)
CN2=$(oc2 whoami --show-server | cut -d. -f2)

echo "Delete Federation Demo"
echo "======================"
echo
echo "This will delete namespace '$NS' on both clusters:"
echo "  Cluster 1: $CN1"
echo "  Cluster 2: $CN2"
echo
echo "ZTIDM infrastructure will NOT be affected."
echo
echo "Next: Delete namespace '$NS' on both clusters"
pause

echo
echo "--- Deleting ClusterSPIFFEID (cluster-scoped) ---"
oc1 delete clusterspiffeid demo-federation --ignore-not-found
oc2 delete clusterspiffeid demo-federation --ignore-not-found

echo
echo "--- Deleting on $CN2 (remote test agents) ---"
oc2 delete namespace $NS --ignore-not-found --wait=true --timeout=5m

echo
echo "--- Deleting on $CN1 (servers + dashboard) ---"
oc1 delete namespace $NS --ignore-not-found --wait=true --timeout=5m

echo
echo "--- Verify ---"
oc1 get namespace $NS 2>/dev/null && echo "WARNING: namespace still exists on $CN1" || echo "$CN1: namespace gone"
oc2 get namespace $NS 2>/dev/null && echo "WARNING: namespace still exists on $CN2" || echo "$CN2: namespace gone"

echo
echo "DONE -- demo removed from both clusters."
echo "ZTIDM infrastructure is untouched."
