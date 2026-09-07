# Zero Trust Federation Demo — Guided Walkthrough

Walk through each `DEMO-HIGHLIGHT` marker in order.  Each link opens the
exact line on GitHub so you can show the code during a live demo.

> **Tip:** `grep -rn DEMO-HIGHLIGHT go-infra.sh go-demo.sh` to find all markers locally.

---

## 1 — Identity & Trust Model

### 1.1 Trust Domain = Apps Domain
The trust domain is the root of all SPIFFE IDs on a cluster.
Using the `*.apps` domain means federation routes resolve automatically
via OpenShift's wildcard DNS — no extra DNS configuration needed.
The trust domain is **immutable** once set.

📍 [`go-infra.sh` L41-46](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-infra.sh#L41-L46)

### 1.2 Zero Trust Allow-List (SPIFFE IDs)
The server's allow-list uses the format
`spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`.
Two entries: one for the local `client-sa`, one for the **federated**
cluster's `client-sa`.  Any pod without a matching SPIFFE ID —
even on the same cluster — gets HTTP 403.

📍 [`go-demo.sh` L60-66](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L60-L66)

### 1.3 ServiceAccount = Cryptographic Identity
A pod's SPIFFE ID is derived from its Kubernetes ServiceAccount.
SPIRE cryptographically attests the pod and issues an X.509 certificate
(SVID) with this identity baked in.  No secrets to manage.

📍 [`go-demo.sh` L873-879](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L873-L879)

---

## 2 — Cross-Cluster Federation

### 2.1 Cross-Cluster Trust Establishment
`ClusterFederatedTrustDomain` tells SPIRE: "trust this remote cluster".
Each cluster gets a resource pointing to the other cluster's federation
endpoint.  The `https_spiffe` profile means SPIRE fetches and auto-refreshes
the remote CA bundle — no manual cert exchange.

📍 [`go-infra.sh` L361-367](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-infra.sh#L361-L367)

### 2.2 ClusterSPIFFEID — federatesWith
Without `federatesWith`, workloads only receive their **local** cluster's CA.
Adding it tells SPIRE: "also deliver the federated cluster's CA bundle
to these pods", enabling them to verify and trust SVIDs from across
clusters.  Without it, the TLS handshake fails.

📍 [`go-demo.sh` L129-135](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L129-L135)

### 2.3 Cross-Cluster mTLS — The "Wow" Moment
A pod on Cluster 2 connects to the secure-server on Cluster 1.
Different trust domains, yet mTLS succeeds because:
federation established trust, `federatesWith` delivers remote CAs,
the allow-list includes the remote SPIFFE ID, and the passthrough
Route preserves end-to-end mTLS.

📍 [`go-demo.sh` L1203-1210](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L1203-L1210)

---

## 3 — Cryptographic Plumbing

### 3.1 SPIFFE CSI Driver — Cert Delivery
The CSI volume mount is how SPIRE delivers certificates to pods.
When Kubernetes schedules the pod, the CSI driver tells the SPIRE Agent:
"attest this workload".  The Agent verifies the pod's identity and exposes
a Unix socket.  The app reads certs from this socket — no Secrets needed.

📍 [`go-demo.sh` L911-917](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L911-L917)

### 3.2 Passthrough Route — End-to-End mTLS
`passthrough` means the OpenShift ingress does **not** terminate TLS.
The SPIRE-issued SVID goes end-to-end from the remote client to the
server pod.  If this were `edge` or `reencrypt`, the ingress would
break the mTLS chain.

📍 [`go-demo.sh` L935-942](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L935-L942)

### 3.3 Fetch ALL Trust Bundles (Including Federated)
`FetchX509Bundles` returns CA certs from **every** trusted domain, not just
the local one.  This is what makes cross-cluster mTLS work: the server
loads both its own CA and the federated cluster's CA.

📍 [`go-demo.sh` L229-235](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L229-L235)

### 3.4 SVID Acquisition — "Who Am I?"
`X509Source()` connects to the SPIRE Agent via the CSI-mounted Unix socket.
The Agent has already attested the pod and returns a short-lived X.509
certificate (SVID) — valid for just 1 hour — with the pod's SPIFFE ID
in the URI SAN.  No secrets, no manual cert creation — fully automatic.

📍 [`go-demo.sh` L278-286](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L278-L286)

---

## 4 — Application-Level Zero Trust Decision

### 4.1 Mutual TLS Enforcement
`ssl.CERT_REQUIRED` — every client **must** present a valid X.509 certificate.
No cert? Connection refused.  Invalid cert? Connection refused.
The server presents its own SVID and verifies client certs against all
trusted CAs (both local and federated).

📍 [`go-demo.sh` L303-310](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L303-L310)

### 4.2 Extract Caller's Identity from Certificate
The client's SPIFFE ID is embedded in the X.509 cert's URI SAN field.
Example: `spiffe://apps.sno2.example.com/ns/demo-zero-trust/sa/client-sa`.
This is a cryptographic identity — you can't forge it.

📍 [`go-demo.sh` L247-253](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L247-L253)

### 4.3 The Zero Trust Decision — Allow or Deny
The server compares the caller's SPIFFE ID against the allow-list.
Allowed → HTTP 200.  Not allowed → HTTP 403.

**Key distinction — Authentication vs. Authorization:**
The rogue pod **passes authentication** — its SVID is a real, valid X.509
certificate issued by SPIRE, signed by the cluster's trusted CA.  The TLS
handshake succeeds because the server recognizes the CA.  But the rogue's
SPIFFE ID (`rogue-sa`) is **not on the allow-list**, so it fails
**authorization** and gets HTTP 403.  This is the classic authn-vs-authz
split: "I know who you are, but you're not allowed in."

📍 [`go-demo.sh` L257-263](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L257-L263)

### 4.4 Fake Certificate Attack — Authentication Failure
A pod with a **self-signed certificate** (not issued by SPIRE) tries to
connect.  The TLS handshake itself **fails** — the server's
`ssl.CERT_REQUIRED` rejects the cert because it was not signed by any
trusted CA (local or federated).  No HTTP response is generated at all.

This is the other side of the coin: the rogue gets past authentication
(valid cert) but fails authorization (wrong identity).  The fake cert
fails **authentication** — it never even gets to the authorization check.

| Scenario | TLS Handshake | HTTP Response | Failure Layer |
|---|---|---|---|
| Authorized client | ✅ passes | 200 ALLOW | — |
| Rogue (valid SPIRE cert) | ✅ passes | 403 DENY | Authorization |
| Fake cert (self-signed) | ❌ rejected | none | Authentication |

📍 [`go-demo.sh` — fake-agent.py in ConfigMap](https://github.com/sjbylo/ztidm-federation-demo/blob/main/go-demo.sh)

### 4.5 SPIFFE Identity Model — URI SANs, Not Hostnames
`check_hostname = False` because SPIFFE doesn't use DNS names for identity.
Identity is a URI SAN: `spiffe://<trust-domain>/ns/<ns>/sa/<sa>`.
The cert is still fully verified (CERT_REQUIRED + trusted CA chain) —
we just skip the DNS hostname match.

📍 [`go-demo.sh` L452-457](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L452-L457)

---

## 5 — Operational Resilience

### 5.1 Short-Lived Certificates — No Long-Lived Secrets
SVIDs (workload certs) expire in **1 hour**.  The CA rotates every **24 hours**.
If a cert is compromised, the blast radius is at most 1 hour — not months.
SPIRE handles all rotation automatically.

📍 [`go-infra.sh` L189-190](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-infra.sh#L189-L190) *(in the SpireServer heredoc)*

### 5.2 Hot Certificate Reload — Zero Downtime Rotation
A background thread refreshes the SVID and trust bundles every 5 minutes —
before they expire.  No pod restarts needed.  Cert lifecycle is fully
automatic; Zero Trust doesn't mean operational burden.

📍 [`go-demo.sh` L317-323](https://github.com/sjbylo/ztidm-federation-demo/blob/63e923be0d33517f3ee582a6fefc629ace404ddd/go-demo.sh#L317-L323)

---

## Demo Flow Summary

```
┌─────────────────────────────────────────────────────────────┐
│ 1. IDENTITY:  ServiceAccount → SPIFFE ID → X.509 SVID      │
│ 2. TRUST:     ClusterFederatedTrustDomain links clusters    │
│ 3. DELIVERY:  CSI driver → Workload API → certs to pods     │
│ 4. TRANSPORT: Passthrough Route → end-to-end mTLS           │
│ 5. DECISION:  Extract SPIFFE ID → check allow-list → 200/403│
│    ATTACK:   Fake cert → TLS rejected (never reaches app)   │
│ 6. LIFECYCLE: 1h SVIDs, background reload, zero downtime    │
└─────────────────────────────────────────────────────────────┘
```

## Quick Commands

```bash
# Find all markers locally
grep -rn DEMO-HIGHLIGHT go-infra.sh go-demo.sh

# Run the federation setup
export KUBECONFIG1=~/.kube/sno1 KUBECONFIG2=~/.kube/sno2
./go-infra.sh           # install ZTIDM + SPIRE + federation

# Deploy the demo app
./go-demo.sh      # deploy demo workloads + dashboard

# Open the dashboard
oc get route dashboard -n demo-zero-trust -o jsonpath='https://{.spec.host}'
```
