#!/bin/bash -e
# Install LVMS operator and configure LVMCluster on one or two OpenShift clusters.
# Only needed for bare-metal / SNO clusters that have no default StorageClass.
# Cloud (AWS/GCP/Azure/ROSA/ARO) and vSphere clusters already have storage — skip this.
# Auto-detects the correct subscription channel from each cluster's OCP version.
#
# Usage:
#   export KUBECONFIG1=~/.kube/sno1
#   export KUBECONFIG2=~/.kube/sno2   # optional: omit for single-cluster
#   ./install_and_config_lvm_op.sh

KUBECONFIG1="${KUBECONFIG1:?Export KUBECONFIG1 (e.g. ~/.kube/sno1)}"
KUBECONFIG2="${KUBECONFIG2:-}"

KUBECONFIGS="$KUBECONFIG1"
[ -n "$KUBECONFIG2" ] && KUBECONFIGS="$KUBECONFIG1 $KUBECONFIG2"

for KC in $KUBECONFIGS; do
	cluster=$(oc --kubeconfig="$KC" whoami --show-server | cut -d. -f2)

	# Detect OCP minor version (e.g. 4.22 -> stable-4.22)
	ocp_ver=$(oc --kubeconfig="$KC" get clusterversion version -o jsonpath='{.status.desired.version}')
	channel="stable-$(echo "$ocp_ver" | cut -d. -f1,2)"
	echo "=== $cluster: OCP $ocp_ver -> channel $channel ==="

	# Install operator
	oc --kubeconfig="$KC" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-og
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  channel: $channel
  installPlanApproval: Automatic
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

	# Wait for CSV to appear (operator may take a moment to create it)
	echo "Waiting for LVMS CSV to appear on $cluster..."
	for i in $(seq 1 60); do
		if oc --kubeconfig="$KC" get csv -n openshift-storage -l operators.coreos.com/lvms-operator.openshift-storage --no-headers 2>/dev/null | grep -q .; then
			break
		fi
		sleep 5
	done

	echo "Waiting for LVMS CSV to succeed on $cluster..."
	oc --kubeconfig="$KC" wait csv -n openshift-storage \
		-l operators.coreos.com/lvms-operator.openshift-storage \
		--for=jsonpath='{.status.phase}'=Succeeded --timeout=5m

	# Create LVMCluster (uses /dev/sdb)
	echo "Creating LVMCluster on $cluster..."
	oc --kubeconfig="$KC" apply -f - <<'EOF'
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
    - name: vg1
      default: true
      deviceSelector:
        paths:
        - /dev/sdb
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        overprovisionRatio: 10
EOF

	echo "Waiting for LVMCluster to be ready on $cluster..."
	oc --kubeconfig="$KC" wait lvmcluster/my-lvmcluster -n openshift-storage \
		--for=jsonpath='{.status.state}'=Ready --timeout=5m
	echo "$cluster: done"
	echo
done

# Verify
echo "=== Storage Classes ==="
for KC in $KUBECONFIGS; do
	cluster=$(oc --kubeconfig="$KC" whoami --show-server | cut -d. -f2)
	echo "--- $cluster ---"
	oc --kubeconfig="$KC" get storageclass
	echo
done
