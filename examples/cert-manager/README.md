# cert-manager + Let's Encrypt for TNF and TNA Clusters

This example installs the Red Hat cert-manager Operator (via OLM) and configures a
Let's Encrypt DNS-01 ACME ClusterIssuer for both the TNF (`examples/two-node-fencing/`)
and TNA (`examples/two-node-arbiter/`) cluster topologies.

See [ADR-012](../../docs/adrs/012-cert-manager-lets-encrypt.md) for the full decision
record, including why DNS-01 is required (private Ingress VIP) and the trade-offs
between the cert-manager operator and alternatives.

---

## Architecture

```
cert-manager-operator (OLM)
  └── ClusterIssuer (letsencrypt-production)
        ├── Certificate *.apps.{cluster}.{domain}  →  Secret wildcard-apps-tls
        └── Certificate api.{cluster}.{domain}     →  Secret api-cert-tls (optional)

ACME DNS-01 flow:
  cert-manager → DNS provider API (outbound HTTPS) → TXT record created
  Let's Encrypt → validates TXT record → issues certificate
```

---

## Prerequisites

Before applying any manifests:

1. **Real domain**: `base_domain` in your `cluster.yml` must be a real,
   internet-resolvable domain you control. `example.com` will not work — Let's
   Encrypt cannot issue certificates for it.

2. **DNS A record**: The wildcard `*.apps.{cluster}.{domain}` must resolve to your
   cluster's Ingress VIP (the IP in `machineNetwork` with the VIP configuration).
   cert-manager does **not** create DNS A records — only DNS TXT records for ACME challenges.

3. **DNS provider API credentials**: You need one of:
   - AWS Route53: IAM access key + secret key with Route53 DNS permissions
   - Cloudflare: API Token with Zone DNS Edit permission
   - Google Cloud DNS: Service account JSON key with `roles/dns.admin`
   
   See `dns-secret-examples/` for credential templates.

4. **Outbound HTTPS** (port 443) from the cluster nodes to:
   - `acme-v02.api.letsencrypt.org` (Let's Encrypt ACME API)
   - `acme-staging-v02.api.letsencrypt.org` (staging — for initial testing)
   - Your DNS provider API endpoint

---

## Files

```
examples/cert-manager/
├── README.md                          # This file
├── namespace.yaml                     # openshift-cert-manager-operator + openshift-cert-manager
├── operator-group.yaml                # OLM OperatorGroup
├── subscription.yaml                  # OLM Subscription (stable-v1 channel, Manual approval)
├── cluster-issuer-staging.yaml        # letsencrypt-staging ClusterIssuer (test first)
├── cluster-issuer-production.yaml     # letsencrypt-production ClusterIssuer
├── wildcard-certificate.yaml          # Certificate for *.apps.{cluster}.{domain}
└── dns-secret-examples/
    ├── route53-secret.yaml            # AWS Route53 credentials template
    ├── cloudflare-secret.yaml         # Cloudflare API token template
    └── gcpdns-secret.yaml             # Google Cloud DNS service account template
```

---

## Installation

### Step 1 — Create DNS provider Secret

Choose the template matching your DNS provider and fill in credentials.
The secret must be created in the `cert-manager` namespace (created automatically
by the operator — not the `openshift-cert-manager` namespace):

```bash
# AWS Route53
cp dns-secret-examples/route53-secret.yaml /tmp/dns-secret.yaml
# Edit /tmp/dns-secret.yaml: replace REPLACE_ME_* values
oc apply -f /tmp/dns-secret.yaml   # deploys to cert-manager namespace

# Cloudflare
cp dns-secret-examples/cloudflare-secret.yaml /tmp/dns-secret.yaml
# Edit /tmp/dns-secret.yaml: replace REPLACE_ME_CLOUDFLARE_API_TOKEN
oc apply -f /tmp/dns-secret.yaml

# Google Cloud DNS
cp dns-secret-examples/gcpdns-secret.yaml /tmp/dns-secret.yaml
# Edit /tmp/dns-secret.yaml: replace all REPLACE_ME_* values
oc apply -f /tmp/dns-secret.yaml
```

### Step 2 — Install the cert-manager Operator

```bash
# Create namespaces and OLM resources
oc apply -f namespace.yaml
oc apply -f operator-group.yaml
oc apply -f subscription.yaml

# Approve the InstallPlan (Manual approval mode)
oc get installplan -n openshift-cert-manager-operator
# Note the NAME of the pending InstallPlan, then:
oc patch installplan <INSTALLPLAN_NAME> \
  -n openshift-cert-manager-operator \
  --type merge \
  -p '{"spec":{"approved":true}}'

# Wait for the operator to become ready (~2-3 minutes)
oc get csv -n openshift-cert-manager-operator --watch
# Wait for PHASE: Succeeded

# Verify cert-manager pods are running
oc get pods -n openshift-cert-manager
# Expected: cert-manager-*, cert-manager-cainjector-*, cert-manager-webhook-*
```

### Step 3 — Edit ClusterIssuer manifests

Before applying, edit `cluster-issuer-staging.yaml` and `cluster-issuer-production.yaml`:

1. Replace `admin@REPLACE_ME_BASE_DOMAIN` with your email address
2. Uncomment the solver block matching your DNS provider
3. Remove or comment out the other solver blocks
4. Remove the placeholder fallback solver block

### Step 4 — Test with Staging Issuer

```bash
# Apply staging issuer
oc apply -f cluster-issuer-staging.yaml

# Wait for the issuer to become Ready
oc get clusterissuer letsencrypt-staging
# READY: True

# Apply wildcard certificate (edit first to replace REPLACE_ME_* values)
# Use staging issuer for initial test: change issuerRef.name to letsencrypt-staging
cp wildcard-certificate.yaml /tmp/wildcard-certificate.yaml
# Edit: set REPLACE_ME_CLUSTER_NAME and REPLACE_ME_BASE_DOMAIN
# Edit: set issuerRef.name to letsencrypt-staging
oc apply -f /tmp/wildcard-certificate.yaml

# Monitor certificate issuance (~1-5 minutes for DNS propagation)
oc get certificate wildcard-apps-cert -n openshift-ingress --watch
# Wait for READY: True

# Check the CertificateRequest and Order for details if it's slow
oc describe certificate wildcard-apps-cert -n openshift-ingress
oc get certificaterequest -n openshift-ingress
oc get order -n openshift-ingress
oc get challenge -n openshift-ingress
```

### Step 5 — Promote to Production

Once staging succeeds (READY: True, even with the "Fake LE" CA):

```bash
# Apply production issuer
oc apply -f cluster-issuer-production.yaml

# Update the certificate to use production issuer
# Edit /tmp/wildcard-certificate.yaml: change issuerRef.name to letsencrypt-production
oc apply -f /tmp/wildcard-certificate.yaml

# Delete the old staging CertificateRequest to force re-issuance
oc delete certificaterequest -n openshift-ingress \
  $(oc get certificaterequest -n openshift-ingress -o name)

# Wait for production cert to issue
oc get certificate wildcard-apps-cert -n openshift-ingress --watch
```

### Step 6 — Configure Cluster Ingress to Use the Wildcard Certificate

```bash
# Patch the Ingress controller to use the cert-manager-issued TLS secret
oc patch ingresscontroller default \
  -n openshift-ingress-operator \
  --type merge \
  -p '{
    "spec": {
      "defaultCertificate": {
        "name": "wildcard-apps-tls"
      }
    }
  }'

# Verify the ingress controller picked up the new cert
oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate}'

# Test with the OpenShift console route
curl -I https://console-openshift-console.apps.$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')
# Expected: HTTP/2 200, TLS cert issued by Let's Encrypt
```

---

## Annotating Individual Routes (Optional)

If you prefer per-Route certificates instead of a shared wildcard, annotate each Route:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-production"
```

> **Note**: For TNF clusters, the wildcard certificate approach is preferred because it
> requires only one ACME challenge (DNS-01 wildcard) vs. one challenge per Route.

---

## Verification

```bash
# Check all certificate objects in the cluster
oc get certificate -A

# Check ClusterIssuers
oc get clusterissuer

# Check cert-manager pods (operator deploys to cert-manager namespace)
oc get pods -n cert-manager

# Check cert-manager logs for errors
oc logs -n cert-manager \
  $(oc get pods -n cert-manager -l app=cert-manager -o name) \
  --tail=50
```

> **Namespace note**: The Red Hat cert-manager-operator runs in
> `openshift-cert-manager-operator`. The cert-manager operands (controller, webhook,
> cainjector) run in `cert-manager` (created automatically by the operator).
> DNS provider Secrets must be in the `cert-manager` namespace.

---

## TNA vs TNF

cert-manager configuration is **identical** for both TNF and TNA topologies. The
manifests in this directory apply unchanged to either cluster type. For TNA clusters,
cert-manager benefits from 3-node scheduling (no dependency on Pacemaker recovery cycle).

---

## Troubleshooting

See [Section 9 of the Troubleshooting Guide](../../docs/troubleshooting.md#9-cert-manager-issues)
for common cert-manager failure modes, including:

- `CertificateRequest Failed` — DNS provider secret misconfigured
- ACME rate limit exceeded — use staging → production promotion pattern
- cert-manager pods not scheduling on TNF control-plane nodes

---

## References

- [ADR-012: cert-manager + Let's Encrypt](../../docs/adrs/012-cert-manager-lets-encrypt.md)
- [Red Hat cert-manager Operator docs](https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/index.html)
- [cert-manager DNS-01 configuration](https://cert-manager.io/docs/configuration/acme/dns01/)
- [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/)
