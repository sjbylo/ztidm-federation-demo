# Zero Trust Workload Identity — mTLS Demo

Pod-to-pod **mTLS** using the
[Zero Trust Workload Identity Manager (ZTIDM)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager)
operator on OpenShift. Works on **one cluster** (same-cluster mTLS) or
**two clusters** (adds cross-cluster federation).

No shared secrets, no IP allow-lists, no sidecars.

![Federation Architecture](diagrams/federation-architecture.png)

## What the demo shows

| # | Scenario | Result | Why |
|---|----------|--------|-----|
| 1 | Insecure server | OPEN (200) | Plain HTTP, no auth |
| 2 | Authorized client → secure-server | ALLOW (200) | Valid SPIFFE ID on allow-list |
| 3 | Rogue client → secure-server | DENY (403) | Valid cert, wrong identity |
| 4 | Fake certificate → secure-server | TLS REJECTED | Self-signed cert, not from SPIRE |
| 5 | Federated client (Cluster 2) | ALLOW (200) | Cross-cluster, identity on allow-list |
| 6 | Federated rogue (Cluster 2) | DENY (403) | Cross-cluster, wrong identity |

Scenarios 5–6 only appear when two clusters are configured.

A **web dashboard** shows all results in real-time.

📖 **Presenting this demo?** See the [`DEMO-WALKTHROUGH.md`](DEMO-WALKTHROUGH.md) for a guided narrative with direct links to every key code section.

## Prerequisites

- **One or two OpenShift 4.16+ clusters** (any topology: SNO, compact, standard)
- **For two clusters**: each cluster must be able to reach the other's `*.apps` routes (e.g. two clusters on the same public cloud, or on-prem clusters with shared DNS)
- **A StorageClass** (cloud/vSphere clusters have one by default; bare-metal SNO may need `install_and_config_lvm_op.sh`)
- **OperatorHub access** (or a mirror containing the ZTIDM operator)
- **`oc`** and **`jq`** on the workstation

No bastion DNS needed — all network operations run from inside the clusters.

## Quick start

```bash
# Set kubeconfigs (KUBECONFIG2 is optional for single-cluster)
export KUBECONFIG1=~/.kube/cluster1
export KUBECONFIG2=~/.kube/cluster2

# (Optional) Bare-metal SNO only: install LVM Storage if no StorageClass exists
./install_and_config_lvm_op.sh

# Install ZTIDM + SPIRE (+ federation if two clusters)
./go-infra.sh --yes

# Deploy the demo
./go-demo.sh --yes

# Open the dashboard
echo "https://dashboard-demo-zero-trust.$(oc --kubeconfig=$KUBECONFIG1 \
  get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
```

Drop `--yes` for interactive mode (pauses between phases).

## Teardown

**Always delete the demo first**, then infrastructure (the CSI driver must
be running for demo pods to unmount cleanly):

```bash
# 1. Remove demo app only (keeps ZTIDM infrastructure)
./delete-demo.sh --yes

# 2. Full teardown (operator, CRDs, everything)
./delete-infra.sh --yes
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| SpireServer PVC stuck `Pending` | No StorageClass — run `install_and_config_lvm_op.sh` (bare-metal SNO) |
| SPIRE agent `CrashLoopBackOff` with `lookup <node>: no such host` | Add node DNS records (see below) |
| Federation endpoint returns `EOF` | Wait 1–2 min for both SPIRE servers to start |
| Namespace stuck `Terminating` | Force-delete stuck pods, then clear namespace finalizers |

### Node hostname DNS (rare)

If nodes use **short hostnames** (e.g. `sno1`) not in cluster DNS,
add records to your DNS server or configure an upstream forwarder:

```bash
oc patch dns.operator/default --type=merge -p '{
  "spec": {"upstreamResolvers": {"policy": "Sequential", "upstreams": [
    {"type": "Network", "address": "<your-dns-ip>", "port": 53},
    {"type": "SystemResolvConf", "port": 53}
  ]}}}'
```

## Files

| File | Purpose |
|------|---------|
| `go-infra.sh` | Install ZTIDM + SPIRE (+ federation if two clusters) |
| `go-demo.sh` | Deploy the demo application + dashboard |
| `delete-infra.sh` | Full teardown |
| `delete-demo.sh` | Remove demo only (keeps infrastructure) |
| `install_and_config_lvm_op.sh` | Optional: install LVM Storage (bare-metal SNO only) |
| [`DEMO-WALKTHROUGH.md`](DEMO-WALKTHROUGH.md) | Guided walkthrough with code links |

## References

- [ZTIDM docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager)
- [SPIFFE](https://spiffe.io/) / [SPIRE](https://github.com/spiffe/spire)

Apache License 2.0
