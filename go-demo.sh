#!/bin/bash -e
# Zero Trust Demo - Pod-to-Pod mTLS on one or two federated clusters
#
# Prerequisites:
#   - go-infra.sh has been run successfully (ZTIDM + SPIRE operational)
#   - Cluster(s) have the SPIFFE CSI driver and agents running
#
# Usage:
#   Single cluster:  export KUBECONFIG1=~/.kube/sno1; ./go-demo.sh
#   Two clusters:    export KUBECONFIG1=~/.kube/sno1 KUBECONFIG2=~/.kube/sno2; ./go-demo.sh
#   Non-interactive: ./go-demo.sh --yes
#
# Re-runnable: safe to run again (oc apply is idempotent)
# Generated YAML saved to ./<cluster-name>/demo-* for inspection
#
# Architecture:
#   Cluster 1: insecure-server, secure-server (mTLS), local clients, fake-client, dashboard UI
#   Cluster 2 (optional): remote-client, remote-rogue (cross-cluster via passthrough Route)
#
# Demo scenarios:
#   1. Without Zero Trust:      any pod → insecure-server        → HTTP 200 (OPEN)
#   2. Same cluster mTLS:       authorized client → secure-server → ALLOW
#   3. Same cluster rogue:      rogue client → secure-server      → DENY (authZ fail)
#   4. Fake certificate:        self-signed cert → secure-server  → TLS REJECTED (authN fail)
#   5. Cross-cluster federation: remote client → secure-server     → ALLOW (federation!)
#   6. Cross-cluster rogue:     remote rogue → secure-server      → DENY

YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=true

pause() {
	$YES && return 0
	echo -n "Hit enter to continue or ctrl-c > "; read -t 60 yn || true
}

NS=demo-zero-trust

KUBECONFIG1="${KUBECONFIG1:?Export KUBECONFIG1 (e.g. ~/.kube/sno1)}"
KUBECONFIG2="${KUBECONFIG2:-}"

oc1() { oc --kubeconfig="$KUBECONFIG1" "$@"; }
if [ -n "$KUBECONFIG2" ]; then
	oc2() { oc --kubeconfig="$KUBECONFIG2" "$@"; }
	FEDERATION=true
else
	FEDERATION=false
fi

# Auto-detect cluster info
CN1=$(oc1 whoami --show-server | cut -d. -f2)
APPS1=$(oc1 get ingresses.config/cluster -o jsonpath='{.spec.domain}')

if $FEDERATION; then
	CN2=$(oc2 whoami --show-server | cut -d. -f2)
	APPS2=$(oc2 get ingresses.config/cluster -o jsonpath='{.spec.domain}')
else
	CN2="" APPS2=""
fi

# Trust domain = apps domain (federation Routes resolve via *.apps wildcard DNS)
TD1="$APPS1"
TD2="$APPS2"

# Route hostnames (OpenShift auto-generates: <route>-<namespace>.<apps-domain>)
SECURE_SERVER_ROUTE="secure-server-${NS}.${APPS1}"
DASHBOARD_ROUTE="dashboard-${NS}.${APPS1}"
if $FEDERATION; then
	REMOTE_CLIENT_ROUTE="remote-client-${NS}.${APPS2}"
	REMOTE_ROGUE_ROUTE="remote-rogue-${NS}.${APPS2}"
else
	REMOTE_CLIENT_ROUTE=""
	REMOTE_ROGUE_ROUTE=""
fi

# DEMO-HIGHLIGHT: Zero Trust Allow-List (SPIFFE IDs)
# Only these identities are accepted. All others get HTTP 403.
ALLOWED_IDS="spiffe://${TD1}/ns/${NS}/sa/client-sa"
$FEDERATION && ALLOWED_IDS="${ALLOWED_IDS},spiffe://${TD2}/ns/${NS}/sa/client-sa"

mkdir -p "$CN1"
$FEDERATION && mkdir -p "$CN2"

echo "Zero Trust Demo Deployment"
echo "=========================="
echo
echo "Cluster 1 ($CN1): insecure-server, secure-server, local clients, fake-client, dashboard"
$FEDERATION && echo "Cluster 2 ($CN2): remote-client, remote-rogue"
echo
$FEDERATION && echo "Trust domains:       $TD1, $TD2" || echo "Trust domain:        $TD1"
echo "Secure server route: $SECURE_SERVER_ROUTE (passthrough mTLS)"
echo "Dashboard URL:       https://$DASHBOARD_ROUTE"
echo
echo "Allowed SPIFFE IDs on secure-server:"
echo "  - spiffe://${TD1}/ns/${NS}/sa/client-sa  (local)"
$FEDERATION && echo "  - spiffe://${TD2}/ns/${NS}/sa/client-sa  (federated)"
echo
echo "Next: Phase 1 -- Create namespace, service accounts, and ConfigMap"
pause

###############################################
# Verify ZTIDM infrastructure is installed
INFRA_NS=zero-trust-workload-identity-manager
if ! oc1 get namespace $INFRA_NS &>/dev/null; then
	echo "ERROR: ZTIDM infrastructure not found on $CN1."
	echo "  Run ./go-infra.sh first, then re-run ./go-demo.sh"
	exit 1
fi
if $FEDERATION && ! oc2 get namespace $INFRA_NS &>/dev/null; then
	echo "ERROR: ZTIDM infrastructure not found on $CN2."
	echo "  Run ./go-infra.sh first, then re-run ./go-demo.sh"
	exit 1
fi

echo
echo "=========================================="
echo "  Phase 1: Namespace & Service Accounts"
echo "=========================================="

tee $CN1/demo-01-Namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
EOF
oc1 apply -f $CN1/demo-01-Namespace.yaml
if $FEDERATION; then
	cp $CN1/demo-01-Namespace.yaml $CN2/demo-01-Namespace.yaml
	oc2 apply -f $CN2/demo-01-Namespace.yaml
fi

# ServiceAccounts determine SPIFFE IDs: spiffe://<trust-domain>/ns/<ns>/sa/<sa-name>
tee $CN1/demo-02-ServiceAccounts.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: server-sa
  namespace: $NS
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: client-sa
  namespace: $NS
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rogue-sa
  namespace: $NS
EOF
oc1 apply -f $CN1/demo-02-ServiceAccounts.yaml
if $FEDERATION; then
	cp $CN1/demo-02-ServiceAccounts.yaml $CN2/demo-02-ServiceAccounts.yaml
	oc2 apply -f $CN2/demo-02-ServiceAccounts.yaml
fi

if $FEDERATION; then
# DEMO-HIGHLIGHT: ClusterSPIFFEID — Enables Cross-Cluster Cert Verification
# "federatesWith" gives pods the remote cluster's CA bundle,
# enabling cross-cluster mTLS. Without it, TLS handshake fails.
echo "--- ClusterSPIFFEID with federatesWith (workloads receive federated trust bundles) ---"
tee $CN1/demo-03-ClusterSPIFFEID.yaml <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: demo-federation
spec:
  className: zero-trust-workload-identity-manager-spire
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: In
      values:
      - $NS
  # Cluster 1 workloads need Cluster 2's CA to verify remote client certs
  federatesWith:
  - "$TD2"
EOF

tee $CN2/demo-03-ClusterSPIFFEID.yaml <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: demo-federation
spec:
  className: zero-trust-workload-identity-manager-spire
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: In
      values:
      - $NS
  # Cluster 2 workloads need Cluster 1's CA to verify the secure-server's cert
  federatesWith:
  - "$TD1"
EOF

oc1 apply -f $CN1/demo-03-ClusterSPIFFEID.yaml
oc2 apply -f $CN2/demo-03-ClusterSPIFFEID.yaml
fi  # FEDERATION

###############################################
echo
echo "=========================================="
echo "  Phase 2: ConfigMap (Python scripts)"
echo "=========================================="

tee $CN1/demo-04-ConfigMap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mtls-demo-scripts
  namespace: $NS
data:
  server.py: |
    # SECURE SERVER -- mTLS endpoint that enforces SPIFFE identity-based access control
    #
    # How it works:
    #   1. Gets an X.509-SVID (short-lived cert) from SPIRE via the Workload API
    #   2. Fetches ALL trust bundles (local + federated) to verify client certs
    #   3. Requires mTLS: every client must present a valid SVID
    #   4. Extracts the client's SPIFFE ID from the cert's URI SAN
    #   5. Checks it against the allow-list → ALLOW (200) or DENY (403)
    #
    # The SPIFFE ID encodes identity: spiffe://<trust-domain>/ns/<ns>/sa/<sa>
    # So the server can distinguish local vs. federated callers by trust domain.

    import os
    import ssl
    import tempfile
    import threading
    import time
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from spiffe import X509Source, WorkloadApiClient
    from cryptography.hazmat.primitives.serialization import Encoding

    ALLOWED_SPIFFE_IDS_STR = os.environ.get("ALLOWED_SPIFFE_IDS", "")
    ALLOWED_NAMESPACE = os.environ.get("ALLOWED_NAMESPACE", "demo-zero-trust")
    ALLOWED_SERVICE_ACCOUNT = os.environ.get("ALLOWED_SERVICE_ACCOUNT", "client-sa")
    SPIFFE_SOCKET_PATH = os.environ.get("SPIFFE_SOCKET_PATH",
                                        "/run/spire/agent-sockets/spire-agent.sock")
    HOST = "0.0.0.0"
    PORT = 8443

    def wait_for_socket(path, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(path):
                return
            time.sleep(1)
        raise RuntimeError(f"SPIFFE socket not found at {path} within {timeout}s")

    def save_all_bundles(path):
        # DEMO-HIGHLIGHT: Fetch ALL Trust Bundles (Including Federated)
        # FetchX509Bundles returns CA certs from EVERY trusted domain, not just local.
        # This is what makes cross-cluster mTLS work: the server loads both its own
        # CA and the federated cluster's CA, so it can verify certs from either cluster.
        # Requires ClusterSPIFFEID.spec.federatesWith to be configured — otherwise
        # SPIRE only returns the local trust domain's CA.
        with WorkloadApiClient() as client:
            bundle_set = client.fetch_x509_bundles()
        count = 0
        with open(path, 'wb') as f:
            for bundle in bundle_set._bundles.values():
                for cert in bundle.x509_authorities:
                    f.write(cert.public_bytes(Encoding.PEM))
                    count += 1
        print(f"Saved {count} CA cert(s) from {len(bundle_set._bundles)} trust domain(s)")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            # DEMO-HIGHLIGHT: Extract Caller's Identity from Certificate
            # The client's SPIFFE ID is embedded in the X.509 cert's URI SAN field.
            # Example: spiffe://apps.sno2.example.com/ns/demo-zero-trust/sa/client-sa
            # This is NOT a hostname or IP — it's a cryptographic identity that encodes
            # the trust domain, namespace, and service account. You can't forge it.
            peer = self.connection.getpeercert()
            san_list = peer.get("subjectAltName", [])
            uris = [v for k, v in san_list if k == "URI"]
            peer_id = uris[0] if uris else ""

            # DEMO-HIGHLIGHT: The Zero Trust Decision — Allow or Deny
            # This is the actual access control check. The server compares the caller's
            # SPIFFE ID against the allow-list. Allowed = HTTP 200. Not allowed = HTTP 403.
            # No IP checks, no network policies, no firewall rules — just cryptographic identity.
            # A "rogue" pod on the SAME cluster with a different ServiceAccount gets DENIED.
            # An authorized pod on a DIFFERENT cluster with the right identity gets ALLOWED.
            if peer_id not in self.server.allowed_spiffe_ids:
                self.send_response(403)
                self.end_headers()
                self.wfile.write(f"DENY: {peer_id} not in allow-list\n".encode())
                return

            self.send_response(200)
            self.end_headers()
            self.wfile.write(f"ALLOW: {peer_id} accepted\n".encode())

        def log_message(self, _fmt, *_args):
            return

    wait_for_socket(SPIFFE_SOCKET_PATH)

    # DEMO-HIGHLIGHT: SVID Acquisition — "Who Am I?"
    # This is where the workload gets its cryptographic identity from SPIRE.
    # X509Source() connects to the SPIRE Agent via the CSI-mounted Unix socket.
    # The Agent has already attested this pod (verified its ServiceAccount, namespace,
    # node) and returns a short-lived X.509 certificate (SVID) — valid for just 1 hour.
    # The SVID contains the pod's SPIFFE ID in the URI SAN field of the certificate.
    # No secrets, no manual cert creation — SPIRE handles the full lifecycle.
    source = X509Source()
    x509_ctx = source.get_x509_context()
    svid = x509_ctx.default_svid

    if ALLOWED_SPIFFE_IDS_STR:
        allowed = set(s.strip() for s in ALLOWED_SPIFFE_IDS_STR.split(",") if s.strip())
    else:
        allowed = {
            f"spiffe://{svid.spiffe_id.trust_domain}/ns/{ALLOWED_NAMESPACE}/sa/{ALLOWED_SERVICE_ACCOUNT}"
        }

    cert_path = os.path.join(tempfile.gettempdir(), "server-svid.pem")
    key_path = os.path.join(tempfile.gettempdir(), "server-key.pem")
    ca_path = os.path.join(tempfile.gettempdir(), "server-bundle.pem")

    svid.save(cert_path, key_path, Encoding.PEM)
    save_all_bundles(ca_path)

    # DEMO-HIGHLIGHT: Mutual TLS Enforcement
    # CERT_REQUIRED = every client MUST present a valid X.509 certificate.
    # No cert? Connection refused. Invalid cert? Connection refused.
    # The server presents its own SVID (load_cert_chain) and verifies client certs
    # against ALL trusted CAs (load_verify_locations) — both local and federated.
    # This is the difference between "encrypted" (one-way TLS) and "Zero Trust" (mTLS).
    server = HTTPServer((HOST, PORT), Handler)
    server.allowed_spiffe_ids = allowed
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.verify_mode = ssl.CERT_REQUIRED       # <-- enforce mutual TLS
    ctx.load_cert_chain(certfile=cert_path, keyfile=key_path)  # server's SVID
    ctx.load_verify_locations(cafile=ca_path)  # trusted CAs (both trust domains)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)

    # DEMO-HIGHLIGHT: Hot Certificate Reload — Zero Downtime Rotation
    # SVIDs are short-lived (1 hour) and the CA rotates every 24 hours.
    # This background thread refreshes both BEFORE they expire — no restarts needed.
    # Every 5 minutes: get fresh SVID from SPIRE, reload all CA bundles, update the
    # SSL context in-place. New connections use the fresh certs automatically.
    # This is why Zero Trust doesn't mean "operational burden" — cert lifecycle is automatic.
    def refresh_certs():
        while True:
            time.sleep(300)
            try:
                fresh_ctx = source.get_x509_context()
                fresh_ctx.default_svid.save(cert_path, key_path, Encoding.PEM)
                save_all_bundles(ca_path)
                ctx.load_cert_chain(certfile=cert_path, keyfile=key_path)
                ctx.load_verify_locations(cafile=ca_path)
                print("Refreshed server SVID and trust bundles")
            except Exception as e:
                print(f"Warning: cert refresh failed: {e}")

    threading.Thread(target=refresh_certs, daemon=True).start()

    print(f"secure-server listening on {HOST}:{PORT}")
    print(f"Allowed SPIFFE IDs: {allowed}")
    server.serve_forever()

  test-agent.py: |
    # TEST AGENT -- mTLS client that connects to the secure-server
    #
    # Used by: secure-client, secure-rogue (same cluster),
    #          remote-client, remote-rogue (cross-cluster via Route)
    #
    # Each instance gets a different SPIFFE ID based on its ServiceAccount:
    #   - client-sa → spiffe://<td>/ns/demo-zero-trust/sa/client-sa  (allowed)
    #   - rogue-sa  → spiffe://<td>/ns/demo-zero-trust/sa/rogue-sa   (denied)
    #
    # For cross-cluster: TARGET_URL points to the passthrough Route on Cluster 1,
    # so mTLS goes end-to-end (OpenShift ingress does NOT terminate TLS).
    #
    # Hot cert reload: a background thread refreshes the SVID and trust bundles
    # every 5 minutes so certs never expire during long-running demos.

    import json
    import os
    import ssl
    import tempfile
    import threading
    import time
    import traceback
    import urllib.request
    from http.server import HTTPServer, BaseHTTPRequestHandler
    from spiffe import X509Source, WorkloadApiClient
    from cryptography.hazmat.primitives.serialization import Encoding

    TARGET_URL = os.environ.get("TARGET_URL", "https://secure-server:8443")
    SPIFFE_SOCKET_PATH = os.environ.get("SPIFFE_SOCKET_PATH",
                                        "/run/spire/agent-sockets/spire-agent.sock")
    REFRESH_INTERVAL = int(os.environ.get("CERT_REFRESH_INTERVAL", "300"))
    PORT = 8080

    # Shared lock protects cert/bundle files during refresh
    cert_lock = threading.Lock()

    def wait_for_socket(path, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(path):
                return
            time.sleep(1)
        raise RuntimeError(f"Socket not found at {path} within {timeout}s")

    def save_all_bundles(path):
        # Uses FetchX509Bundles to get ALL CAs including federated trust domains.
        # For cross-cluster mTLS, the client needs the remote cluster's CA to
        # verify the server's SVID (and vice versa on the server side).
        with WorkloadApiClient() as client:
            bundle_set = client.fetch_x509_bundles()
        count = 0
        with open(path, 'wb') as f:
            for bundle in bundle_set._bundles.values():
                for cert in bundle.x509_authorities:
                    f.write(cert.public_bytes(Encoding.PEM))
                    count += 1
        return count

    print("Waiting for SPIFFE socket...")
    wait_for_socket(SPIFFE_SOCKET_PATH)

    print("Fetching SPIFFE identity...")
    source = X509Source()
    x509_ctx = source.get_x509_context()
    svid = x509_ctx.default_svid

    cert_path = os.path.join(tempfile.gettempdir(), "svid.pem")
    key_path = os.path.join(tempfile.gettempdir(), "key.pem")
    ca_path = os.path.join(tempfile.gettempdir(), "bundle.pem")
    svid.save(cert_path, key_path, Encoding.PEM)
    n = save_all_bundles(ca_path)
    print(f"Saved {n} CA cert(s) at startup")

    MY_SPIFFE_ID = str(svid.spiffe_id)
    print(f"Identity: {MY_SPIFFE_ID}")
    print(f"Target:   {TARGET_URL}")

    # Mutable container so the background refresh thread can reconnect X509Source
    source_ref = [source]

    def _refresh_loop():
        while True:
            time.sleep(REFRESH_INTERVAL)
            try:
                with cert_lock:
                    ctx = source_ref[0].get_x509_context()
                    ctx.default_svid.save(cert_path, key_path, Encoding.PEM)
                    n = save_all_bundles(ca_path)
                print(f"Refreshed SVID and {n} CA cert(s)")
            except Exception as e:
                print(f"Warning: cert refresh failed ({e}), reconnecting X509Source...")
                try:
                    source_ref[0] = X509Source()
                    print("Reconnected X509Source")
                except Exception as e2:
                    print(f"Warning: X509Source reconnect failed: {e2}")

    threading.Thread(target=_refresh_loop, daemon=True).start()
    print(f"Background cert refresh every {REFRESH_INTERVAL}s")

    def run_mtls_test():
        try:
            with cert_lock:
                # Use the latest SVID + bundles (kept fresh by background thread)
                ctx = source_ref[0].get_x509_context()
                fresh_svid = ctx.default_svid
                fresh_svid.save(cert_path, key_path, Encoding.PEM)
                save_all_bundles(ca_path)

            # DEMO-HIGHLIGHT: SPIFFE Identity Model — URI SANs, Not Hostnames
            # check_hostname=False because SPIFFE doesn't use DNS names for identity.
            # Instead, identity is a URI SAN: spiffe://<trust-domain>/ns/<ns>/sa/<sa>
            # The cert is still fully verified (CERT_REQUIRED + trusted CA chain) —
            # we just skip the DNS hostname match because SPIFFE IDs aren't hostnames.
            ctx = ssl.create_default_context(cafile=ca_path)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_REQUIRED
            ctx.load_cert_chain(certfile=cert_path, keyfile=key_path)
            req = urllib.request.Request(TARGET_URL, method="GET")
            with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
                body = resp.read().decode().strip()
                return {
                    "spiffe_id": str(fresh_svid.spiffe_id),
                    "target": TARGET_URL,
                    "http_status": resp.status,
                    "result": "ALLOW",
                    "detail": body,
                }
        except urllib.error.HTTPError as e:
            body = e.read().decode().strip() if e.fp else str(e)
            return {
                "spiffe_id": MY_SPIFFE_ID, "target": TARGET_URL,
                "http_status": e.code, "result": "DENY", "detail": body,
            }
        except Exception as e:
            traceback.print_exc()
            return {
                "spiffe_id": MY_SPIFFE_ID, "target": TARGET_URL,
                "http_status": 0, "result": "ERROR", "detail": str(e),
            }

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/test":
                data = run_mtls_test()
            elif self.path == "/identity":
                data = {"spiffe_id": MY_SPIFFE_ID}
            elif self.path == "/health":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")
                return
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        def log_message(self, fmt, *args):
            pass

    print(f"Test agent listening on :{PORT}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

  fake-agent.py: |
    # DEMO-HIGHLIGHT: Fake Certificate Attack — Authentication Failure
    # This agent generates a SELF-SIGNED certificate (NOT from SPIRE) and tries
    # to connect to the secure-server. The TLS handshake FAILS because the server's
    # ssl.CERT_REQUIRED rejects certs not signed by a trusted CA (SPIRE).
    #
    # This demonstrates the AUTHENTICATION layer of Zero Trust:
    #   - Rogue (valid SPIRE cert, wrong SA): TLS succeeds → HTTP 403 (authZ fail)
    #   - Fake  (self-signed, no SPIRE):      TLS fails    → no HTTP  (authN fail)

    import json
    import os
    import ssl
    import tempfile
    import datetime
    import traceback
    import urllib.request
    from http.server import HTTPServer, BaseHTTPRequestHandler

    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    TARGET_URL = os.environ.get("TARGET_URL", "https://secure-server:8443")
    PORT = 8080

    # Generate a self-signed certificate with a fake SPIFFE ID
    print("Generating self-signed (fake) certificate...")
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "fake-identity")])
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.datetime.utcnow())
        .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(hours=1))
        .add_extension(
            x509.SubjectAlternativeName([
                x509.UniformResourceIdentifier(
                    "spiffe://fake-trust-domain/ns/attacker/sa/evil"
                )
            ]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )

    cert_path = os.path.join(tempfile.gettempdir(), "fake-cert.pem")
    key_path = os.path.join(tempfile.gettempdir(), "fake-key.pem")
    ca_path = os.path.join(tempfile.gettempdir(), "fake-ca.pem")

    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    with open(key_path, "wb") as f:
        f.write(key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ))
    # Self-signed: the cert IS its own CA (but the server won't trust it)
    with open(ca_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))

    FAKE_SPIFFE_ID = "spiffe://fake-trust-domain/ns/attacker/sa/evil"
    print(f"Fake SPIFFE ID: {FAKE_SPIFFE_ID}")
    print(f"Target: {TARGET_URL}")
    print("NOTE: Server will REJECT this cert — it is not signed by SPIRE's CA")

    def run_fake_test():
        try:
            # Don't verify server's cert (we don't have SPIRE's CA)
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            # Present our self-signed cert — server will reject it
            ctx.load_cert_chain(certfile=cert_path, keyfile=key_path)
            req = urllib.request.Request(TARGET_URL, method="GET")
            with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
                body = resp.read().decode().strip()
                return {
                    "spiffe_id": FAKE_SPIFFE_ID,
                    "target": TARGET_URL,
                    "http_status": resp.status,
                    "result": "ALLOW",
                    "detail": body,
                }
        except urllib.error.HTTPError as e:
            body = e.read().decode().strip() if e.fp else str(e)
            return {
                "spiffe_id": FAKE_SPIFFE_ID, "target": TARGET_URL,
                "http_status": e.code, "result": "DENY", "detail": body,
            }
        except ssl.SSLError as e:
            return {
                "spiffe_id": FAKE_SPIFFE_ID, "target": TARGET_URL,
                "http_status": 0, "result": "TLS_REJECT",
                "detail": f"TLS handshake rejected: {e.reason or e}",
            }
        except Exception as e:
            traceback.print_exc()
            # Most connection resets from mTLS rejection appear here
            err_str = str(e)
            if "CERTIFICATE" in err_str.upper() or "SSL" in err_str.upper() \
               or "Connection reset" in err_str or "EOF" in err_str:
                return {
                    "spiffe_id": FAKE_SPIFFE_ID, "target": TARGET_URL,
                    "http_status": 0, "result": "TLS_REJECT",
                    "detail": f"TLS handshake rejected: {err_str}",
                }
            return {
                "spiffe_id": FAKE_SPIFFE_ID, "target": TARGET_URL,
                "http_status": 0, "result": "ERROR", "detail": err_str,
            }

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/test":
                data = run_fake_test()
            elif self.path == "/identity":
                data = {"spiffe_id": FAKE_SPIFFE_ID, "type": "SELF-SIGNED (fake)"}
            elif self.path == "/health":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")
                return
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        def log_message(self, fmt, *args):
            pass

    print(f"Fake agent listening on :{PORT}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

  dashboard.py: |
    # DASHBOARD -- Web UI that orchestrates and displays all test results
    #
    # The dashboard does NOT use SPIFFE/mTLS itself. It's a simple HTTP server
    # that calls the test agents via their Kubernetes Services (same cluster)
    # or OpenShift Routes (cross-cluster). The test agents do the actual mTLS
    # and report back the results as JSON.

    import json
    import os
    import ssl
    import datetime
    import urllib.request
    from http.server import HTTPServer, BaseHTTPRequestHandler

    PORT = 8080
    SECURE_CLIENT_URL = os.environ.get("SECURE_CLIENT_URL", "http://secure-client-svc:8080")
    SECURE_ROGUE_URL = os.environ.get("SECURE_ROGUE_URL", "http://secure-rogue-svc:8080")
    FAKE_CLIENT_URL = os.environ.get("FAKE_CLIENT_URL", "http://fake-client-svc:8080")
    INSECURE_SERVER_URL = os.environ.get("INSECURE_SERVER_URL", "http://insecure-server:8080")
    REMOTE_CLIENT_URL = os.environ.get("REMOTE_CLIENT_URL", "")
    REMOTE_ROGUE_URL = os.environ.get("REMOTE_ROGUE_URL", "")
    CLUSTER1_NAME = os.environ.get("CLUSTER1_NAME", "cluster-1")
    CLUSTER2_NAME = os.environ.get("CLUSTER2_NAME", "cluster-2")
    TRUST_DOMAIN_1 = os.environ.get("TD1", "")
    TRUST_DOMAIN_2 = os.environ.get("TD2", "")

    FEDERATION_ENABLED = bool(REMOTE_CLIENT_URL)

    # Skip TLS verification for HTTPS calls to remote test agents on Cluster 2.
    # Those calls go via OpenShift edge Routes which use the cluster's default
    # ingress certificate (typically self-signed). This is NOT the SPIFFE mTLS
    # path -- it's just the dashboard fetching JSON status over the Route.
    # In production, replace the ingress cert with a proper one from your PKI.
    _NOVERIFY = ssl.create_default_context()
    _NOVERIFY.check_hostname = False
    _NOVERIFY.verify_mode = ssl.CERT_NONE

    def fetch_json(url, timeout=10):
        try:
            ctx = _NOVERIFY if url.startswith("https://") else None
            with urllib.request.urlopen(url, timeout=timeout, context=ctx) as resp:
                return json.loads(resp.read().decode())
        except Exception as e:
            return {"result": "ERROR", "detail": str(e), "spiffe_id": "n/a", "http_status": 0}

    def test_insecure():
        try:
            with urllib.request.urlopen(INSECURE_SERVER_URL, timeout=5) as resp:
                return {"result": "OPEN", "http_status": resp.status,
                        "detail": "No authentication -- any pod can connect"}
        except Exception as e:
            return {"result": "ERROR", "http_status": 0, "detail": str(e)}

    CONFIG_JSON = json.dumps({
        "cluster1": CLUSTER1_NAME, "cluster2": CLUSTER2_NAME,
        "td1": TRUST_DOMAIN_1, "td2": TRUST_DOMAIN_2,
        "federation": FEDERATION_ENABLED,
    })

    HTML_TEMPLATE = r"""<!DOCTYPE html>
    <html lang="en"><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>ZTWIM Federation Demo</title>
    <style>
    *{margin:0;padding:0;box-sizing:border-box}
    body{font-family:'Red Hat Display','Red Hat Text','Segoe UI',system-ui,sans-serif;
         background:#0f1214;color:#e0e0e0;min-height:100vh}
    .ctr{max-width:1100px;margin:0 auto;padding:40px 20px}
    h1{color:#ee0000;font-size:1.8em;border-bottom:2px solid #ee0000;padding-bottom:.3em;margin-bottom:.2em}
    .sub{color:#888;margin-bottom:.6em;font-size:.95em}
    .cluster-info{color:#5e9ed6;font-size:.85em;margin-bottom:2em;
                  background:#1a1e22;padding:10px 16px;border-radius:6px;border:1px solid #333}
    .cluster-info b{color:#93c5fd}
    .btn{background:#ee0000;color:#fff;border:none;padding:12px 36px;border-radius:6px;
         font-size:1em;cursor:pointer;font-weight:600;transition:background .2s}
    .btn:hover{background:#cc0000}
    .btn:disabled{background:#444;cursor:wait}
    .sec{margin-top:2.2em}
    .sec-hdr{color:#5e9ed6;font-size:1.15em;margin-bottom:.4em;display:flex;align-items:center;gap:8px}
    .sec-hdr .ico{font-size:1.2em;width:24px;text-align:center}
    .sec-desc{color:#777;font-size:.88em;margin-bottom:1em}
    .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px}
    .card{background:#1a1e22;border:1px solid #333;border-radius:8px;padding:20px;
          border-left:4px solid #555;transition:border-color .4s,box-shadow .4s}
    .card.allow{border-left-color:#22c55e;box-shadow:0 0 12px #22c55e18}
    .card.deny{border-left-color:#ef4444;box-shadow:0 0 12px #ef444418}
    .card.open{border-left-color:#f59e0b;box-shadow:0 0 12px #f59e0b18}
    .card.error{border-left-color:#8b5cf6}
    .card-top{display:flex;justify-content:space-between;align-items:center;margin-bottom:14px}
    .card-title{font-weight:600;font-size:1.05em}
    .badge{padding:4px 14px;border-radius:12px;font-size:.78em;font-weight:700;
           text-transform:uppercase;letter-spacing:.5px}
    .badge.allow{background:#22c55e20;color:#22c55e}
    .badge.deny{background:#ef444420;color:#ef4444}
    .badge.open{background:#f59e0b20;color:#f59e0b}
    .badge.error{background:#8b5cf620;color:#8b5cf6}
    .badge.tls_reject{background:#dc262620;color:#dc2626}
    .card.tls_reject{border-left-color:#dc2626;box-shadow:0 0 12px #dc262618}
    .badge.pending{background:#55555530;color:#888}
    .row{display:flex;gap:8px;margin:5px 0;font-size:.88em}
    .row .lbl{color:#93c5fd;font-weight:600;min-width:90px;flex-shrink:0}
    .row .val{color:#ccc;word-break:break-all}
    .card-body{margin-top:14px;padding-top:12px;border-top:1px solid #2a2e32;font-size:.85em;color:#aaa}
    .meta{color:#555;font-size:.8em;margin-top:2.5em}
    .arrow{color:#555;font-size:1.4em;margin:0 6px}
    @keyframes pulse{0%,100%{opacity:.4}50%{opacity:1}}
    .loading .badge{animation:pulse 1.2s infinite}
    </style>
    </head><body>
    <div class="ctr">
      <h1>Zero Trust Workload Identity Manager</h1>
      <p class="sub">Pod-to-Pod mTLS Federation Demo &mdash; SPIFFE identity-based access control across OpenShift clusters</p>
      <div class="cluster-info" id="cluster-info"></div>
      <button class="btn" id="runBtn" onclick="runTests()">Run Tests</button>

      <div class="sec">
        <div class="sec-hdr"><span class="ico">&#x1f512;</span> With Zero Trust &mdash; Same Cluster</div>
        <p class="sec-desc">Mutual TLS with SPIFFE SVIDs. <b>Rogue</b> = valid cert, wrong identity (authZ fail). <b>Fake</b> = self-signed cert (authN fail).</p>
        <div class="cards">
          <div class="card loading" id="card-client">
            <div class="card-top">
              <span class="card-title">Authorized Client</span>
              <span class="badge pending" id="badge-client">pending</span>
            </div>
            <div class="row"><span class="lbl">Identity</span><span class="val" id="id-client">&mdash;</span></div>
            <div class="row"><span class="lbl">Account</span><span class="val">client-sa</span></div>
            <div class="row"><span class="lbl">Target</span><span class="val">https://secure-server:8443</span></div>
            <div class="card-body" id="body-client">Click <b>Run Tests</b> to start</div>
          </div>
          <div class="card loading" id="card-rogue">
            <div class="card-top">
              <span class="card-title">Unauthorized Rogue</span>
              <span class="badge pending" id="badge-rogue">pending</span>
            </div>
            <div class="row"><span class="lbl">Identity</span><span class="val" id="id-rogue">&mdash;</span></div>
            <div class="row"><span class="lbl">Account</span><span class="val">rogue-sa</span></div>
            <div class="row"><span class="lbl">Target</span><span class="val">https://secure-server:8443</span></div>
            <div class="card-body" id="body-rogue">Click <b>Run Tests</b> to start</div>
          </div>
          <div class="card loading" id="card-fake">
            <div class="card-top">
              <span class="card-title">Fake Certificate &#x1f4a3;</span>
              <span class="badge pending" id="badge-fake">pending</span>
            </div>
            <div class="row"><span class="lbl">Identity</span><span class="val" id="id-fake">self-signed (not from SPIRE)</span></div>
            <div class="row"><span class="lbl">Account</span><span class="val">none &mdash; no SPIRE CSI</span></div>
            <div class="row"><span class="lbl">Target</span><span class="val">https://secure-server:8443</span></div>
            <div class="card-body" id="body-fake">Click <b>Run Tests</b> to start</div>
          </div>
        </div>
      </div>

      <div class="sec" id="federation-section" style="display:none">
        <div class="sec-hdr"><span class="ico">&#x1f310;</span> Cross-Cluster Federation (SPIFFE mTLS)</div>
        <p class="sec-desc" id="fed-desc">Workloads on a remote cluster authenticate to the server via federated SPIFFE trust.</p>
        <div class="cards">
          <div class="card loading" id="card-fed-client">
            <div class="card-top">
              <span class="card-title">Federated Client</span>
              <span class="badge pending" id="badge-fed-client">pending</span>
            </div>
            <div class="row"><span class="lbl">Identity</span><span class="val" id="id-fed-client">&mdash;</span></div>
            <div class="row"><span class="lbl">Cluster</span><span class="val" id="fed-client-cluster">&mdash;</span></div>
            <div class="row"><span class="lbl">Account</span><span class="val">client-sa</span></div>
            <div class="row"><span class="lbl">Target</span><span class="val" id="fed-client-target">secure-server via Route</span></div>
            <div class="card-body" id="body-fed-client">Click <b>Run Tests</b> to start</div>
          </div>
          <div class="card loading" id="card-fed-rogue">
            <div class="card-top">
              <span class="card-title">Federated Rogue</span>
              <span class="badge pending" id="badge-fed-rogue">pending</span>
            </div>
            <div class="row"><span class="lbl">Identity</span><span class="val" id="id-fed-rogue">&mdash;</span></div>
            <div class="row"><span class="lbl">Cluster</span><span class="val" id="fed-rogue-cluster">&mdash;</span></div>
            <div class="row"><span class="lbl">Account</span><span class="val">rogue-sa</span></div>
            <div class="row"><span class="lbl">Target</span><span class="val" id="fed-rogue-target">secure-server via Route</span></div>
            <div class="card-body" id="body-fed-rogue">Click <b>Run Tests</b> to start</div>
          </div>
        </div>
      </div>

      <div class="sec">
        <div class="sec-hdr"><span class="ico">&#x1f513;</span> Without Zero Trust</div>
        <p class="sec-desc">Standard HTTP &mdash; no authentication, no encryption. Any pod can connect.</p>
        <div class="cards">
          <div class="card loading" id="card-insecure">
            <div class="card-top">
              <span class="card-title">Any Pod <span class="arrow">&rarr;</span> insecure-server</span>
              <span class="badge pending" id="badge-insecure">pending</span>
            </div>
            <div class="row"><span class="lbl">Target</span><span class="val">http://insecure-server:8080</span></div>
            <div class="row"><span class="lbl">Auth</span><span class="val">None</span></div>
            <div class="card-body" id="body-insecure">Click <b>Run Tests</b> to start</div>
          </div>
        </div>
      </div>

      <p class="meta" id="ts"></p>
    </div>
    <script>
    var CFG = __CONFIG__;
    var ci = document.getElementById('cluster-info');
    if(CFG.federation){
      ci.innerHTML='<b>Cluster 1:</b> '+CFG.cluster1+' ('+CFG.td1+') &nbsp;&mdash;&nbsp; <b>Cluster 2:</b> '+CFG.cluster2+' ('+CFG.td2+')';
      document.getElementById('federation-section').style.display='';
      document.getElementById('fed-desc').innerHTML='Workloads on <b>'+CFG.cluster2+'</b> ('+CFG.td2+') authenticate to the server on <b>'+CFG.cluster1+'</b> via federated SPIFFE trust.';
      document.getElementById('fed-client-cluster').textContent=CFG.cluster2;
      document.getElementById('fed-rogue-cluster').textContent=CFG.cluster2;
    } else {
      ci.innerHTML='<b>Cluster:</b> '+CFG.cluster1+' ('+CFG.td1+')';
    }
    async function runTests(){
      var btn=document.getElementById('runBtn');
      btn.disabled=true; btn.textContent='Running...';
      setCard('insecure','pending','loading','Testing...');
      setCard('client','pending','loading','Testing...');
      setCard('rogue','pending','loading','Testing...');
      setCard('fake','pending','loading','Testing...');
      if(CFG.federation){
        setCard('fed-client','pending','loading','Testing...');
        setCard('fed-rogue','pending','loading','Testing...');
      }
      try{
        var r=await fetch('/api/test');
        var d=await r.json();
        var ins=d.insecure;
        setCard('insecure',ins.result.toLowerCase(),ins.result.toLowerCase(),
          'HTTP '+ins.http_status+' &mdash; '+ins.detail);
        var cl=d.secure_client;
        document.getElementById('id-client').textContent=cl.spiffe_id||'n/a';
        setCard('client',cl.result.toLowerCase(),cl.result.toLowerCase(),
          'HTTP '+cl.http_status+' &mdash; '+cl.detail);
        var rg=d.secure_rogue;
        document.getElementById('id-rogue').textContent=rg.spiffe_id||'n/a';
        setCard('rogue',rg.result.toLowerCase(),rg.result.toLowerCase(),
          'HTTP '+rg.http_status+' &mdash; '+rg.detail);
        var fk=d.fake_client;
        document.getElementById('id-fake').textContent=fk.spiffe_id||'self-signed (fake)';
        var fkBadge=fk.result.toLowerCase();
        var fkBody=fk.http_status?'HTTP '+fk.http_status+' &mdash; '+fk.detail:'TLS Rejected &mdash; '+fk.detail;
        setCard('fake',fkBadge,fkBadge,fkBody);
        if(CFG.federation && d.fed_client){
          var fc=d.fed_client;
          document.getElementById('id-fed-client').textContent=fc.spiffe_id||'n/a';
          setCard('fed-client',fc.result.toLowerCase(),fc.result.toLowerCase(),
            'HTTP '+fc.http_status+' &mdash; '+fc.detail);
          var fr=d.fed_rogue;
          document.getElementById('id-fed-rogue').textContent=fr.spiffe_id||'n/a';
          setCard('fed-rogue',fr.result.toLowerCase(),fr.result.toLowerCase(),
            'HTTP '+fr.http_status+' &mdash; '+fr.detail);
        }
        document.getElementById('ts').textContent='Last run: '+d.timestamp;
      }catch(e){
        setCard('insecure','error','error','Fetch failed: '+e);
        setCard('client','error','error','Fetch failed: '+e);
        setCard('rogue','error','error','Fetch failed: '+e);
        setCard('fake','error','error','Fetch failed: '+e);
        if(CFG.federation){
          setCard('fed-client','error','error','Fetch failed: '+e);
          setCard('fed-rogue','error','error','Fetch failed: '+e);
        }
      }
      btn.disabled=false; btn.textContent='Run Tests';
    }
    function setCard(id,badge,cls,body){
      var c=document.getElementById('card-'+id);
      c.className='card '+cls;
      var b=document.getElementById('badge-'+id);
      b.className='badge '+badge; b.textContent=badge;
      document.getElementById('body-'+id).innerHTML=body;
    }
    runTests();
    </script>
    </body></html>"""

    HTML_PAGE = HTML_TEMPLATE.replace("__CONFIG__", CONFIG_JSON)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/api/test":
                results = {
                    "insecure": test_insecure(),
                    "secure_client": fetch_json(SECURE_CLIENT_URL + "/test"),
                    "secure_rogue": fetch_json(SECURE_ROGUE_URL + "/test"),
                    "fake_client": fetch_json(FAKE_CLIENT_URL + "/test"),
                    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                }
                if FEDERATION_ENABLED:
                    results["fed_client"] = fetch_json(REMOTE_CLIENT_URL + "/test")
                    results["fed_rogue"] = fetch_json(REMOTE_ROGUE_URL + "/test")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(results).encode())
            elif self.path == "/health":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")
            else:
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(HTML_PAGE.encode())

        def log_message(self, fmt, *args):
            ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
            print(f"[{ts}] {fmt % args}")

    print(f"Dashboard listening on :{PORT}")
    print(f"Federation: {FEDERATION_ENABLED}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
EOF

oc1 apply -f $CN1/demo-04-ConfigMap.yaml
if $FEDERATION; then
	cp $CN1/demo-04-ConfigMap.yaml $CN2/demo-04-ConfigMap.yaml
	oc2 apply -f $CN2/demo-04-ConfigMap.yaml
fi

###############################################
echo
echo "=========================================="
echo "  Phase 3: Deploy Demo on Cluster 1 ($CN1)"
echo "=========================================="

echo
echo "--- Insecure Server (HTTP baseline) ---"

tee $CN1/demo-05-InsecureServer.yaml <<EOF | oc1 apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: insecure-server
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: insecure-server
  template:
    metadata:
      labels:
        app: insecure-server
    spec:
      containers:
      - name: server
        image: registry.access.redhat.com/ubi9/ubi:latest
        command: ["python3", "-m", "http.server", "8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: insecure-server
  namespace: $NS
spec:
  selector:
    app: insecure-server
  ports:
  - name: http
    port: 8080
    targetPort: 8080
EOF

echo
echo "--- Secure Server (mTLS + passthrough Route for cross-cluster) ---"

tee $CN1/demo-06-SecureServer.yaml <<EOF | oc1 apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-server
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure-server
  template:
    metadata:
      labels:
        app: secure-server
    spec:
      # DEMO-HIGHLIGHT: ServiceAccount = Cryptographic Identity
      # The pod's SPIFFE ID is derived from its ServiceAccount:
      #   spiffe://<trust-domain>/ns/demo-zero-trust/sa/server-sa
      # This is NOT a label or annotation — SPIRE cryptographically attests the pod
      # and issues an X.509 certificate (SVID) with this identity baked in.
      # Changing the ServiceAccount changes the identity. No secrets to manage.
      serviceAccountName: server-sa
      containers:
      - name: secure-server
        image: registry.redhat.io/ubi9/python-311:latest
        command:
          - /bin/bash
          - -lc
          - pip install -q spiffe cryptography && python /app/server.py
        env:
          # SPIFFE_ENDPOINT_SOCKET: py-spiffe library reads this to find the
          # SPIRE Agent's Workload API (unix domain socket via CSI volume below)
          - name: SPIFFE_ENDPOINT_SOCKET
            value: unix:///run/spire/agent-sockets/spire-agent.sock
          - name: SPIFFE_SOCKET_PATH
            value: /run/spire/agent-sockets/spire-agent.sock
          # Allow-listed SPIFFE IDs: local client-sa + federated client-sa
          - name: ALLOWED_SPIFFE_IDS
            value: "$ALLOWED_IDS"
        ports:
          - containerPort: 8443
        readinessProbe:
          tcpSocket:
            port: 8443
          initialDelaySeconds: 30
          periodSeconds: 10
        volumeMounts:
          - name: app-scripts
            mountPath: /app
            readOnly: true
          # SPIFFE Workload API socket -- injected by the SPIFFE CSI Driver
          - name: spiffe-workload-api
            mountPath: /run/spire/agent-sockets
            readOnly: true
      volumes:
        - name: app-scripts
          configMap:
            name: mtls-demo-scripts
        # DEMO-HIGHLIGHT: SPIFFE CSI Driver — Cert Delivery Mechanism
        # This CSI volume mount is how SPIRE delivers certificates to pods.
        # When Kubernetes schedules this pod, the CSI driver tells the SPIRE Agent:
        # "attest this workload and provide its SVID". The Agent verifies the pod's
        # identity (ServiceAccount, namespace, node) and exposes a Unix socket at
        # the mount path. The app reads certs from this socket — no Secrets needed.
        - name: spiffe-workload-api
          csi:
            driver: csi.spiffe.io
            readOnly: true
---
apiVersion: v1
kind: Service
metadata:
  name: secure-server
  namespace: $NS
spec:
  selector:
    app: secure-server
  ports:
    - name: https
      port: 8443
      targetPort: 8443
---
# DEMO-HIGHLIGHT: Passthrough Route — End-to-End mTLS
# "passthrough" means OpenShift's ingress does NOT terminate TLS.
# The SPIRE-issued SVID certificate goes end-to-end: from the remote client
# pod on Cluster 2, across the network, directly to this server pod.
# The client verifies the server's SPIFFE cert (not an ingress cert), and
# the server verifies the client's SPIFFE cert. True mutual TLS, no middleman.
# If this were "edge" or "reencrypt", the ingress would break the mTLS chain.
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: secure-server
  namespace: $NS
spec:
  tls:
    termination: passthrough
  to:
    kind: Service
    name: secure-server
  port:
    targetPort: 8443
EOF

echo
echo "--- Secure Client (authorized, same cluster) ---"

tee $CN1/demo-07-SecureClient.yaml <<EOF | oc1 apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-client
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure-client
  template:
    metadata:
      labels:
        app: secure-client
    spec:
      serviceAccountName: client-sa
      containers:
      - name: secure-client
        image: registry.redhat.io/ubi9/python-311:latest
        command:
          - /bin/bash
          - -lc
          - pip install -q spiffe cryptography && python /app/test-agent.py
        env:
          - name: SPIFFE_ENDPOINT_SOCKET
            value: unix:///run/spire/agent-sockets/spire-agent.sock
          - name: SPIFFE_SOCKET_PATH
            value: /run/spire/agent-sockets/spire-agent.sock
          - name: TARGET_URL
            value: https://secure-server:8443
        ports:
          - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        volumeMounts:
          - name: app-scripts
            mountPath: /app
            readOnly: true
          - name: spiffe-workload-api
            mountPath: /run/spire/agent-sockets
            readOnly: true
      volumes:
        - name: app-scripts
          configMap:
            name: mtls-demo-scripts
        - name: spiffe-workload-api
          csi:
            driver: csi.spiffe.io
            readOnly: true
---
apiVersion: v1
kind: Service
metadata:
  name: secure-client-svc
  namespace: $NS
spec:
  selector:
    app: secure-client
  ports:
    - port: 8080
      targetPort: 8080
EOF

echo
echo "--- Secure Rogue (unauthorized, same cluster) ---"

tee $CN1/demo-08-SecureRogue.yaml <<EOF | oc1 apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-rogue
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure-rogue
  template:
    metadata:
      labels:
        app: secure-rogue
    spec:
      serviceAccountName: rogue-sa
      containers:
      - name: secure-rogue
        image: registry.redhat.io/ubi9/python-311:latest
        command:
          - /bin/bash
          - -lc
          - pip install -q spiffe cryptography && python /app/test-agent.py
        env:
          - name: SPIFFE_ENDPOINT_SOCKET
            value: unix:///run/spire/agent-sockets/spire-agent.sock
          - name: SPIFFE_SOCKET_PATH
            value: /run/spire/agent-sockets/spire-agent.sock
          - name: TARGET_URL
            value: https://secure-server:8443
        ports:
          - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        volumeMounts:
          - name: app-scripts
            mountPath: /app
            readOnly: true
          - name: spiffe-workload-api
            mountPath: /run/spire/agent-sockets
            readOnly: true
      volumes:
        - name: app-scripts
          configMap:
            name: mtls-demo-scripts
        - name: spiffe-workload-api
          csi:
            driver: csi.spiffe.io
            readOnly: true
---
apiVersion: v1
kind: Service
metadata:
  name: secure-rogue-svc
  namespace: $NS
spec:
  selector:
    app: secure-rogue
  ports:
    - port: 8080
      targetPort: 8080
EOF

echo
echo "--- Fake Client (self-signed cert, NO SPIRE) ---"

# DEMO-HIGHLIGHT: Fake Certificate Attack — No SPIRE, No Trust
# This pod does NOT mount the SPIFFE CSI driver. It generates a self-signed
# certificate and tries to connect to the secure-server. The TLS handshake
# is REJECTED because the cert is not signed by any SPIRE-trusted CA.
# This shows the AUTHENTICATION layer: you can't even start a conversation
# without a cert from a trusted identity provider (SPIRE).
tee $CN1/demo-08b-FakeClient.yaml <<EOF | oc1 apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fake-client
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fake-client
  template:
    metadata:
      labels:
        app: fake-client
    spec:
      # NO serviceAccountName needed — this pod doesn't use SPIRE at all
      containers:
      - name: fake-client
        image: registry.redhat.io/ubi9/python-311:latest
        command:
          - /bin/bash
          - -lc
          - pip install -q cryptography && python /app/fake-agent.py
        env:
          - name: TARGET_URL
            value: https://secure-server:8443
        ports:
          - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 10
        volumeMounts:
          - name: app-scripts
            mountPath: /app
            readOnly: true
      # NOTE: No SPIFFE CSI volume — this pod has NO access to SPIRE
      volumes:
        - name: app-scripts
          configMap:
            name: mtls-demo-scripts
---
apiVersion: v1
kind: Service
metadata:
  name: fake-client-svc
  namespace: $NS
spec:
  selector:
    app: fake-client
  ports:
    - port: 8080
      targetPort: 8080
EOF

echo
echo "--- Dashboard ---"

tee $CN1/demo-09-Dashboard.yaml <<EOF | oc1 apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dashboard
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dashboard
  template:
    metadata:
      labels:
        app: dashboard
    spec:
      containers:
      - name: dashboard
        image: registry.redhat.io/ubi9/python-311:latest
        command:
          - /bin/bash
          - -c
          - python /app/dashboard.py
        env:
          - name: SECURE_CLIENT_URL
            value: http://secure-client-svc:8080
          - name: SECURE_ROGUE_URL
            value: http://secure-rogue-svc:8080
          - name: FAKE_CLIENT_URL
            value: http://fake-client-svc:8080
          - name: INSECURE_SERVER_URL
            value: http://insecure-server:8080
          - name: REMOTE_CLIENT_URL
            value: "${REMOTE_CLIENT_ROUTE:+https://${REMOTE_CLIENT_ROUTE}}"
          - name: REMOTE_ROGUE_URL
            value: "${REMOTE_ROGUE_ROUTE:+https://${REMOTE_ROGUE_ROUTE}}"
          - name: CLUSTER1_NAME
            value: "$CN1"
          - name: CLUSTER2_NAME
            value: "$CN2"
          - name: TD1
            value: "$TD1"
          - name: TD2
            value: "$TD2"
        ports:
          - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: false
          runAsNonRoot: true
          seccompProfile:
            type: RuntimeDefault
        volumeMounts:
          - name: app-scripts
            mountPath: /app
            readOnly: true
      volumes:
        - name: app-scripts
          configMap:
            name: mtls-demo-scripts
---
apiVersion: v1
kind: Service
metadata:
  name: dashboard
  namespace: $NS
spec:
  selector:
    app: dashboard
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: dashboard
  namespace: $NS
spec:
  to:
    kind: Service
    name: dashboard
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

if $FEDERATION; then
###############################################
echo
echo "=========================================="
echo "  Phase 4: Deploy Remote Test Agents on Cluster 2 ($CN2)"
echo "=========================================="

# DEMO-HIGHLIGHT: Cross-Cluster mTLS
# This pod runs on Cluster 2 but connects to secure-server on Cluster 1
# via passthrough Route. Different trust domain, but accepted because
# federation + allow-list are both configured.
echo
echo "--- Remote Client (authorized, cross-cluster) ---"

tee $CN2/demo-05-RemoteClient.yaml <<EOF | oc2 apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: remote-client
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: remote-client
  template:
    metadata:
      labels:
        app: remote-client
    spec:
      # Same ServiceAccount name as Cluster 1's client → same SA in SPIFFE ID,
      # but different trust domain: spiffe://apps.sno2-ext.example.com/ns/.../sa/client-sa
      serviceAccountName: client-sa
      containers:
      - name: remote-client
        image: registry.redhat.io/ubi9/python-311:latest
        command:
          - /bin/bash
          - -lc
          - pip install -q spiffe cryptography && python /app/test-agent.py
        env:
          - name: SPIFFE_ENDPOINT_SOCKET
            value: unix:///run/spire/agent-sockets/spire-agent.sock
          - name: SPIFFE_SOCKET_PATH
            value: /run/spire/agent-sockets/spire-agent.sock
          # TARGET_URL points to the passthrough Route on Cluster 1 -- mTLS goes
          # from this pod on Cluster 2, through the internet/network, directly
          # to the secure-server pod on Cluster 1 (no TLS termination at ingress)
          - name: TARGET_URL
            value: "https://${SECURE_SERVER_ROUTE}"
        ports:
          - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        volumeMounts:
          - name: app-scripts
            mountPath: /app
            readOnly: true
          - name: spiffe-workload-api
            mountPath: /run/spire/agent-sockets
            readOnly: true
      volumes:
        - name: app-scripts
          configMap:
            name: mtls-demo-scripts
        - name: spiffe-workload-api
          csi:
            driver: csi.spiffe.io
            readOnly: true
---
apiVersion: v1
kind: Service
metadata:
  name: remote-client-svc
  namespace: $NS
spec:
  selector:
    app: remote-client
  ports:
    - port: 8080
      targetPort: 8080
---
# Edge Route (NOT passthrough): this is just for the dashboard on Cluster 1
# to reach the test agent's HTTP status API. Not part of the mTLS path.
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: remote-client
  namespace: $NS
spec:
  to:
    kind: Service
    name: remote-client-svc
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

echo
echo "--- Remote Rogue (unauthorized, cross-cluster) ---"

tee $CN2/demo-06-RemoteRogue.yaml <<EOF | oc2 apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: remote-rogue
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: remote-rogue
  template:
    metadata:
      labels:
        app: remote-rogue
    spec:
      serviceAccountName: rogue-sa
      containers:
      - name: remote-rogue
        image: registry.redhat.io/ubi9/python-311:latest
        command:
          - /bin/bash
          - -lc
          - pip install -q spiffe cryptography && python /app/test-agent.py
        env:
          - name: SPIFFE_ENDPOINT_SOCKET
            value: unix:///run/spire/agent-sockets/spire-agent.sock
          - name: SPIFFE_SOCKET_PATH
            value: /run/spire/agent-sockets/spire-agent.sock
          - name: TARGET_URL
            value: "https://${SECURE_SERVER_ROUTE}"
        ports:
          - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        volumeMounts:
          - name: app-scripts
            mountPath: /app
            readOnly: true
          - name: spiffe-workload-api
            mountPath: /run/spire/agent-sockets
            readOnly: true
      volumes:
        - name: app-scripts
          configMap:
            name: mtls-demo-scripts
        - name: spiffe-workload-api
          csi:
            driver: csi.spiffe.io
            readOnly: true
---
apiVersion: v1
kind: Service
metadata:
  name: remote-rogue-svc
  namespace: $NS
spec:
  selector:
    app: remote-rogue
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: remote-rogue
  namespace: $NS
spec:
  to:
    kind: Service
    name: remote-rogue-svc
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

fi  # FEDERATION (Phase 4)

###############################################
echo
echo "=========================================="
echo "  Phase 5: Wait for Pods"
echo "=========================================="

echo
echo "--- Cluster 1 ($CN1) ---"
oc1 get pods -n $NS
oc1 wait --for=condition=ready pod -l app=insecure-server -n $NS --timeout=120s
oc1 wait --for=condition=ready pod -l app=secure-server -n $NS --timeout=300s
oc1 wait --for=condition=ready pod -l app=secure-client -n $NS --timeout=300s
oc1 wait --for=condition=ready pod -l app=secure-rogue -n $NS --timeout=300s
oc1 wait --for=condition=ready pod -l app=fake-client -n $NS --timeout=120s
oc1 wait --for=condition=ready pod -l app=dashboard -n $NS --timeout=120s

if $FEDERATION; then
	echo
	echo "--- Cluster 2 ($CN2) ---"
	oc2 get pods -n $NS
	oc2 wait --for=condition=ready pod -l app=remote-client -n $NS --timeout=300s
	oc2 wait --for=condition=ready pod -l app=remote-rogue -n $NS --timeout=300s
fi

echo
echo "=========================================="
echo "  Phase 6: Verify Routes"
echo "=========================================="

echo
echo "Cluster 1 routes:"
oc1 get routes -n $NS

if $FEDERATION; then
	echo
	echo "Cluster 2 routes:"
	oc2 get routes -n $NS
fi

echo
echo "Generated YAML saved to:"
ls -1 $CN1/demo-*.yaml
$FEDERATION && ls -1 $CN2/demo-*.yaml

echo
echo "=========================================="
echo "  DONE"
echo "=========================================="
echo
echo "Dashboard URL: https://$DASHBOARD_ROUTE"
echo
echo "Open the dashboard and click 'Run Tests' to see:"
echo "  1. Insecure server      → HTTP 200 (OPEN)"
echo "  2. Authorized client    → ALLOW   (same cluster mTLS)"
echo "  3. Rogue client         → DENY    (authZ fail: valid cert, wrong identity)"
echo "  4. Fake certificate     → TLS REJECTED (authN fail: self-signed, not from SPIRE)"
if $FEDERATION; then
echo "  5. Federated client     → ALLOW   (cross-cluster federation!)"
echo "  6. Federated rogue      → DENY    (cross-cluster federation)"
fi
