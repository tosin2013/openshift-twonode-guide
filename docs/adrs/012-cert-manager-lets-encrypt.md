# 012. cert-manager + Let's Encrypt for TNF and TNA Clusters

**Status**: Accepted
**Date**: 2026-06-09
**Validated**: 2026-06-10 — live TNF cluster, cert-manager-operator v1.19.0, Let's Encrypt DNS-01 Route53, production wildcard cert issued in ~2 min, console HTTPS confirmed
**Domain**: security / certificate-management
**Related ADRs**: [002 Agent-Based Installer](002-agent-based-installer.md), [006 OVNKubernetes](006-ovnkubernetes-network-plugin.md)

---

## Context

All demo Routes in this repository (Demos 01–06) are served over plain HTTP. The OpenShift
API server and ingress use the default self-signed certificate generated at install time.
This is acceptable for development but inadequate for any environment where:

- Browsers or CLI clients reject self-signed certificates
- Compliance requires externally-trusted TLS for all endpoints
- Demos need to be shown to customers without browser security warnings

Three certificate management approaches exist in the OpenShift ecosystem:

| Approach | Issuer | How |
|----------|--------|-----|
| OpenShift serving-cert annotation | Self-signed cluster CA | `service.beta.openshift.io/serving-cert-secret-name` annotation on Service |
| cert-manager-operator (OperatorHub) | Any (ACME, CA, self-signed) | OLM-managed operator with CRD-based lifecycle |
| Manual cert rotation | Any | `oc patch --type merge` on `Ingress.config.openshift.io` |

The serving-cert annotation only works for in-cluster service-to-service TLS using the
cluster's internal CA — it does not issue publicly-trusted certificates for Routes.

The TNF cluster's Ingress VIP (`192.168.49.252`) is on a **private** `192.168.49.0/24`
subnet. This has a critical implication for ACME certificate issuance:

- **HTTP-01 challenge** — Let's Encrypt makes an HTTP request to
  `http://<domain>/.well-known/acme-challenge/<token>` from the public internet. This
  **cannot work** if the ingress IP is private and not internet-accessible.
- **DNS-01 challenge** — Let's Encrypt validates by checking for a TXT record at
  `_acme-challenge.<domain>`. This requires only **outbound HTTPS** from the cluster to
  the DNS provider API. Works on private networks, air-gapped-adjacent deployments, and
  any topology where the cluster has outbound internet access.

DNS-01 is the only viable ACME challenge type for TNF and TNA clusters in this repository.

---

## Decision

Install the **Red Hat cert-manager Operator** (available on OperatorHub as
`cert-manager-operator`) and configure a **Let's Encrypt DNS-01 ACME ClusterIssuer** on
both the TNF (`examples/two-node-fencing/`) and TNA (`examples/two-node-arbiter/`)
cluster templates.

**Chosen option**: Option A — cert-manager-operator via OLM + DNS-01 ACME

---

## Alternatives Considered

### Option A — cert-manager-operator (OperatorHub, Red Hat) + DNS-01 ACME ✅ CHOSEN

- Installed via OLM Subscription (`stable-v1` channel)
- Runs in `openshift-cert-manager` namespace
- ClusterIssuer uses Let's Encrypt ACME with DNS-01 solver
- DNS provider credentials stored in a Kubernetes Secret in `openshift-cert-manager` namespace
- Certificate resources create TLS Secrets that can be referenced by Routes
- **Pros**: Red Hat supported; integrates with OLM lifecycle; proper RBAC under OpenShift
  security model; supports multiple issuers (ACME, CA, self-signed, Vault, Venafi)
- **Cons**: Requires a real domain and DNS provider API credentials; OLM operator upgrade
  is manual on TNF (`featureSet: TechPreviewNoUpgrade` blocks automatic channel upgrades)

### Option B — Upstream cert-manager Helm chart

- Installed via Helm (`helm install cert-manager jetstack/cert-manager`)
- **Pros**: Version pinning; available on any Kubernetes distribution
- **Cons**: Not Red Hat supported; does not integrate with OLM; requires Helm tooling;
  no operator lifecycle management; not in OperatorHub

### Option C — OpenShift native serving-cert annotation

- `service.beta.openshift.io/serving-cert-secret-name` annotation on a Service
- **Pros**: Built-in, no operator required; zero configuration
- **Cons**: Issues certificates signed by the cluster's internal CA, which is not
  publicly trusted. Does not support external TLS for Routes visible to end-users.
  Cannot issue Let's Encrypt certificates.

---

## Implementation

The operator and supporting manifests live in `examples/cert-manager/`. The installation
sequence is:

```
1. Apply namespace, OperatorGroup, Subscription  →  cert-manager-operator installs
2. Create DNS provider Secret                    →  DNS-01 credentials stored
3. Apply letsencrypt-staging ClusterIssuer       →  test ACME flow (no rate limits)
4. Create a test Certificate, verify it issues   →  confirm DNS-01 works
5. Apply letsencrypt-production ClusterIssuer    →  switch to trusted certs
6. Annotate demo Routes                          →  TLS applied per Route
```

### DNS Provider Support

cert-manager supports the following DNS providers via built-in solvers. This repository
provides Secret templates for the three most common:

| Provider | Secret type | Template file |
|----------|-------------|---------------|
| AWS Route53 | `route53` solver with IAM access key | `dns-secret-examples/route53-secret.yaml` |
| Cloudflare | `cloudflare` solver with API token | `dns-secret-examples/cloudflare-secret.yaml` |
| Google Cloud DNS | `clouddns` solver with service account JSON | `dns-secret-examples/gcpdns-secret.yaml` |

Other providers (Azure DNS, DigitalOcean, etc.) are supported by cert-manager but not
templated here; see the cert-manager docs for solver configuration.

### Ingress Certificate Coverage

| Endpoint | Certificate | Common Name |
|----------|-------------|-------------|
| `*.apps.{cluster}.{domain}` | Wildcard Certificate | covers all Route hostnames |
| `api.{cluster}.{domain}` | Separate Certificate (optional) | API server |
| Individual Routes | Route annotation | optional — wildcard covers all |

The wildcard certificate for `*.apps.{cluster}.{domain}` requires a **wildcard DNS-01
challenge**, which is supported by cert-manager's DNS-01 solver with the `dnsNames` field.

---

## TNF-Specific Constraints

### cert-manager Operand Namespace

The Red Hat cert-manager-operator runs in `openshift-cert-manager-operator`. The
operator automatically creates and manages a separate `cert-manager` namespace where the
operands (controller, webhook, cainjector) run. DNS provider Secrets **must** be created
in the `cert-manager` namespace — not `openshift-cert-manager`. This was confirmed during
live validation (2026-06-10, cert-manager-operator v1.19.0).

### cert-manager Runs on Control-Plane Nodes

TNF has zero dedicated worker nodes. All pods including cert-manager run on the two
schedulable control-plane nodes. cert-manager's `Deployment` has `tolerations` for
`node-role.kubernetes.io/master` that allow this — no manual toleration is needed.

### Single-Replica Availability

cert-manager's controller runs as a single-replica `Deployment` by default. On TNF:

- If the node hosting cert-manager is fenced (STONITH), cert-manager reschedules on the
  surviving node after the ~2-minute Pacemaker recovery cycle
- Certificate renewals run **30 days before expiry** — a 2-minute cert-manager outage
  window is acceptable and does not risk certificate expiry
- Active ACME challenges (new certificate issuances) fail if interrupted mid-challenge;
  cert-manager retries automatically with exponential backoff

### No Pacemaker Interaction

cert-manager does not interact with Pacemaker-managed etcd. Certificate renewals write
to Kubernetes Secrets (via the API server), not to etcd directly. The Pacemaker etcd
lifecycle is orthogonal to cert-manager operations.

### `featureSet: TechPreviewNoUpgrade`

This feature set does not prevent cert-manager-operator installation or operation. It only
prevents in-place OCP version upgrades. Operators installed via OLM can still be updated
manually by updating the Subscription's `channel` or pinning `startingCSV`.

---

## TNA vs TNF

cert-manager configuration is **identical** for both topologies. The operator manifests
in `examples/cert-manager/` are shared. The only topology-aware difference is
cert-manager availability:

| Topology | Nodes | cert-manager HA |
|----------|-------|-----------------|
| TNF | 2 control-plane | Single replica; ~2 min recovery after STONITH |
| TNA | 2 full + 1 arbiter | Single replica; standard pod rescheduling |

---

## Prerequisites

The following must be satisfied **before** applying `examples/cert-manager/`:

1. `base_domain` in `cluster.yml` must be a real, internet-resolvable domain you control
   (`example.com` will not work — Let's Encrypt cannot issue for it)
2. DNS provider API credentials (Route53 IAM key, Cloudflare API token, or GCP service
   account JSON key with DNS admin permissions)
3. Outbound HTTPS (port 443) from the cluster to:
   - `acme-v02.api.letsencrypt.org`
   - The DNS provider API endpoint (e.g., `route53.amazonaws.com`, `api.cloudflare.com`)
4. The A/CNAME records for `*.apps.{cluster}.{domain}` must resolve to the cluster's
   Ingress VIP before certificate issuance (cert-manager does not create DNS A records)

---

## Consequences

### Positive

- All demo Routes served over HTTPS with publicly-trusted Let's Encrypt certificates
- API server endpoint covered by a trusted certificate (optional but recommended)
- Certificate rotation is fully automated (renewals 30 days before expiry)
- Same operator works for both TNF and TNA clusters without topology-specific changes
- Staging → production promotion pattern prevents Let's Encrypt rate limit exhaustion

### Negative / Risks

- Requires a real domain — the default `example.com` placeholder is not usable
- DNS provider API credentials must be managed as a Kubernetes Secret; accidental
  deletion of the Secret breaks certificate renewals
- Let's Encrypt production rate limits: 5 duplicate certificates per week; use staging
  issuer for initial testing to avoid rate limit exhaustion
- `featureSet: TechPreviewNoUpgrade` makes cert-manager-operator channel upgrades manual;
  must be tracked and applied by the cluster administrator

---

## References

- [cert-manager-operator on OperatorHub](https://operatorhub.io/operator/cert-manager)
- [Red Hat cert-manager Operator docs](https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/index.html)
- [cert-manager DNS-01 challenge docs](https://cert-manager.io/docs/configuration/acme/dns01/)
- [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/)
- [ADR-002: Agent-Based Installer](002-agent-based-installer.md)
- [ADR-006: OVNKubernetes Network Plugin](006-ovnkubernetes-network-plugin.md)
