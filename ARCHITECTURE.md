# Federation Demo Architecture

## Overview

The demo deploys workloads across **two federated OpenShift clusters** to
demonstrate SPIFFE/SPIRE-based mTLS with identity-based access control.

![Federation Architecture](diagrams/federation-architecture.png)

## Cluster layout

### Cluster 1 (primary)

All server-side workloads and same-cluster clients live here:

| Pod | ServiceAccount | SPIFFE ID | Role |
|-----|---------------|-----------|------|
| `secure-server` | `server-sa` | `spiffe://<TD1>/ns/demo-zero-trust/sa/server-sa` | mTLS server with allow-list |
| `secure-client` | `client-sa` | `spiffe://<TD1>/ns/demo-zero-trust/sa/client-sa` | Authorized local client |
| `secure-rogue` | `rogue-sa` | `spiffe://<TD1>/ns/demo-zero-trust/sa/rogue-sa` | Unauthorized local client |
| `insecure-server` | (default) | — | Plain HTTP baseline |
| `dashboard` | (default) | — | Web UI, no SPIFFE identity |

### Cluster 2 (remote)

Remote clients that connect cross-cluster via a passthrough Route:

| Pod | ServiceAccount | SPIFFE ID | Role |
|-----|---------------|-----------|------|
| `remote-client` | `client-sa` | `spiffe://<TD2>/ns/demo-zero-trust/sa/client-sa` | Authorized federated client |
| `remote-rogue` | `rogue-sa` | `spiffe://<TD2>/ns/demo-zero-trust/sa/rogue-sa` | Unauthorized federated client |

## Trust domains

Each cluster has its own SPIFFE trust domain, set to the cluster's `apps`
domain (e.g. `apps.cluster1.example.com`).  This is the Red Hat recommended
approach because:

1. The `*.apps.<domain>` wildcard DNS already resolves
2. The federation Route (`federation.<apps-domain>`) is reachable without
   extra DNS configuration
3. The OIDC discovery Route (`oidc-discovery.<apps-domain>`) also resolves

## SPIRE infrastructure per cluster

```
┌─────────────────────────────────────────────────┐
│  zero-trust-workload-identity-manager namespace  │
│                                                   │
│  ┌──────────────┐  ┌────────────┐  ┌──────────┐ │
│  │ SpireServer   │  │ SpireAgent │  │ CSIDriver│ │
│  │ (StatefulSet) │  │ (DaemonSet)│  │(DaemonSet│ │
│  │              │  │            │  │          │ │
│  │ SQLite DB    │  │ Workload   │  │ SPIFFE   │ │
│  │ Federation   │  │ Attestor   │  │ socket   │ │
│  │ endpoint     │  │ via kubelet│  │ mount    │ │
│  └──────────────┘  └────────────┘  └──────────┘ │
│                                                   │
│  ┌──────────────────┐  ┌─────────────────────┐   │
│  │ OIDC Discovery   │  │ Controller Manager  │   │
│  │ Provider         │  │ (processes CSIDs)    │   │
│  └──────────────────┘  └─────────────────────┘   │
└─────────────────────────────────────────────────┘
```

## Federation flow

```
 Cluster 1                                    Cluster 2
 ─────────                                    ─────────

 SpireServer ◄──── trust bundle ────► SpireServer
      │          (https_spiffe)             │
      │                                     │
      ▼                                     ▼
 ClusterFederatedTrustDomain          ClusterFederatedTrustDomain
   (points to Cluster 2)               (points to Cluster 1)
      │                                     │
      ▼                                     ▼
 ClusterSPIFFEID                      ClusterSPIFFEID
   federatesWith: [TD2]                 federatesWith: [TD1]
      │                                     │
      ▼                                     ▼
 Workloads receive                    Workloads receive
 BOTH trust bundles                   BOTH trust bundles
```

1. **Trust bundle exchange**: Each SPIRE server exposes a federation
   endpoint (`https://federation.<apps-domain>`) via a passthrough Route.
   The `ClusterFederatedTrustDomain` resource tells SPIRE to fetch and
   cache the remote cluster's trust bundle.

2. **`federatesWith` on ClusterSPIFFEID**: Without this field, workloads
   only receive their local trust domain's CA certificate.  Adding
   `federatesWith: ["<remote-trust-domain>"]` tells SPIRE to include the
   federated CA in the workload's trust bundle, enabling cross-cluster
   certificate verification.

3. **Passthrough Route**: The `secure-server` is exposed via a passthrough
   (not edge/re-encrypt) Route so that mTLS goes end-to-end.  OpenShift
   ingress passes the TLS connection through without terminating it.

## Request flow: cross-cluster mTLS

```
remote-client (Cluster 2)
    │
    │  1. Gets X.509-SVID from local SPIRE agent
    │     (spiffe://TD2/ns/demo-zero-trust/sa/client-sa)
    │
    │  2. Connects to passthrough Route:
    │     secure-server-demo-zero-trust.apps.<cluster1>
    │
    ▼
OpenShift Router (Cluster 1)
    │
    │  3. SNI-based routing, TLS NOT terminated
    │
    ▼
secure-server (Cluster 1)
    │
    │  4. mTLS handshake:
    │     - Server presents its SVID
    │     - Client presents its SVID
    │     - Both verify using federated trust bundles
    │
    │  5. Server extracts client SPIFFE ID from cert URI SAN
    │
    │  6. Checks against allow-list:
    │     ✓ spiffe://TD1/ns/demo-zero-trust/sa/client-sa → ALLOW
    │     ✓ spiffe://TD2/ns/demo-zero-trust/sa/client-sa → ALLOW
    │     ✗ spiffe://TD2/ns/demo-zero-trust/sa/rogue-sa  → DENY
    │
    ▼
HTTP 200 (ALLOW) or HTTP 403 (DENY)
```

## Hot certificate reload

SPIFFE SVIDs are short-lived (default 1 hour).  All demo pods implement
automatic certificate refresh:

- **Background thread** refreshes SVID + trust bundles every 5 minutes
- **Thread-safe** file writes prevent races between refresh and request handling
- **Auto-reconnect**: if the SPIRE Workload API connection drops, the
  `X509Source` is recreated automatically
- The demo can run **indefinitely** without manual restarts

## Key Kubernetes resources

### ClusterSPIFFEID

The most important resource for the demo.  It tells the ZTIDM controller-
manager which pods should receive SPIFFE identities and federated trust
bundles:

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: demo-federation
spec:
  # REQUIRED: must match the controller-manager's class name
  className: zero-trust-workload-identity-manager-spire
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: In
      values: ["demo-zero-trust"]
  # Include the remote cluster's CA in the trust bundle
  federatesWith:
  - "apps.cluster2.example.com"
```

**Common gotcha**: If `className` is missing, the controller-manager
ignores the resource and no SPIRE registration entries are created.

### SpireServer federation config

```yaml
spec:
  federation:
    bundleEndpoint:
      profile: https_spiffe    # IMMUTABLE after first apply
      refreshHint: 300
    managedRoute: "true"       # auto-creates the passthrough Route
    federatesWith:
    - trustDomain: "apps.cluster2.example.com"
      bundleEndpointUrl: "https://federation.apps.cluster2.example.com"
      bundleEndpointProfile: "https_spiffe"
      endpointSpiffeId: "spiffe://apps.cluster2.example.com/spire/server"
```

**Warning**: `trustDomain` and `federation.bundleEndpoint.profile` are
**immutable** once applied.  Changing them requires full teardown and
reinstall.
