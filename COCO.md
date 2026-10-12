# CoCo (Confidential Containers) + Kata + OpenShell agents on SNO spokes

This repo deploys confidential containers (CoCo) running in Kata
containers (`kata-remote`, peer pods) with OpenShell agents onto Single
Node OpenShift (SNO) spokes on AWS. The KBS (Key Broker Service /
trustee) runs on the hub; confidential pods on the spokes attest against
it via initdata.

All secrets and URLs are ExternalSecrets backed by vault — nothing is
hardcoded in git (see `secrets/vault-coco` and the
`applications/policy-collection` pattern).

## Architecture

```text
HUB SNO (AWS, existing)                     SPOKE SNO (AWS, coco-* clusters)
├── trustee/KBS (applications/trustee)      ├── sandboxed-containers (OSC + KataConfig enablePeerPods)
│   └── kbs route + TLS cert (imperative)   ├── kyverno + coco-kyverno-policies (initdata injection)
├── Keycloak (per-spoke AGENT realms)       ├── openshell gateway + envoy Gateway routing
├── vault + ESO (pre-installed)             │   + CoCo agents (kata-remote pods)
└── coco-discovery (ACM lookup of hub       └── saw-users per-user agent fan-out
    routes -> PushSecret to vault)
     └── kv/ocp/sno/openshift-gitops/coco/* (kbsres1, config URLs, AWS creds, ...)
```

**URLs are never hardcoded or manually entered**: `applications/coco-discovery`
runs an ACM ConfigurationPolicy on the HUB that looks up the KBS and
Keycloak routes with `{{ (lookup "route.openshift.io/v1" "Route" ...) }}`
and pushes the URLs to vault (PushSecret). Spokes read them via ESO.
Lookup is cluster-local — a policy enforced on a spoke cannot look up hub
routes, which is why discovery runs on the hub and URLs flow to spokes
through vault.

## Applications

| App | Placement | Purpose |
|---|---|---|
| `applications/trustee` | hub | Trustee operator + `KbsConfig` (KBS), attestation policy, TLS certs, KBS secrets from vault |
| `applications/coco-discovery` | hub | ACM policy `{{ (lookup ...) }}` on hub routes → KBS_URL/KEYCLOAK_URL pushed to vault |
| `applications/sandboxed-containers` | `placement-spoke-coco` | OSC operator subscription, `KataConfig` (`enablePeerPods: true`), `peer-pods-cm`/`peer-pods-secret` |
| `applications/kyverno` | `placement-spoke-coco` | Kyverno (OpenShift SCC overrides) |
| `applications/coco-kyverno-policies` | `placement-spoke-coco` | initdata injection/propagation/validation policies + initdata generation Job |
| `applications/openshell` (gateway) | `placement-spoke-coco` | OpenShell gateway (vendored chart 0.1.2) + routing overlay: envoy Gateway listeners, HTTPRoute/GRPCRoute, LE wildcard cert, Route53 creds via ESO — see `applications/openshell/overlay/gateway/` |
| `applications/openshell-dashboard` | hub app → spoke | BFF + oauth2-proxy dashboard (manages AgentSandboxes via the gateway) |
| `applications/openshell` (agents) | `placement-spoke-coco` | CoCo agent pods (AIPCC OpenClaw, `runtimeClassName: kata-remote`) + governance interceptor |
| `applications/saw-users` | `placement-spoke-coco` | Per-user CoCo agent fan-out (adapted from secure-agent-workspace, no CNV) |
| `applications/spoke-realms` | hub | Creates a Keycloak realm per coco-* spoke **for agents only** (client `openshell-agents`) |

## Deployment sequence

1. **`trustee`** (hub) — KBS + secrets. Needs vault seeded (below).
2. **`coco-discovery`** (hub) — looks up the KBS/Keycloak routes and pushes KBS_URL/KEYCLOAK_URL to vault.
3. **`sandboxed-containers`** (spoke) — OSC operator + `KataConfig`. The KataConfig takes ~15–30 minutes to deploy the peer-pod machine image; check with `oc get kataconfig default-kata-config -o jsonpath='{.status}'`.
4. **`kyverno` + `coco-kyverno-policies`** (spoke) — initdata pipeline.
5. **`openshell` + `openshell-agents` + `saw-users`** (spoke) — gateway, routing (envoy Gateway + wildcard cert), agents.

Test with sandboxed agents after the infrastructure deploys.

### Agent deployment (openshell / openshell-agents / saw-users)

All ArgoCD-driven from this repo — no manual commands; commit → app-of-apps
→ ApplicationSet → ACM PolicyGenerator → spoke:

| App | Source | What it deploys |
|---|---|---|
| `app-of-apps/hub/openshell.yaml` | vendored chart 0.1.2 (`applications/openshell/gateway-chart` — ghcr 403s anonymous ArgoCD token requests, so the OCI source can't resolve) | OpenShell **gateway** (hub, Synced/Healthy); the SPOKE gateway + routing deploy via `openshell-agents.yaml` → PolicyGenerator → ACM policy `openshell-gateway` |
| `app-of-apps/hub/openshell-agents.yaml` | `applications/openshell/overlay` (PolicyGenerator `placement-spoke-coco`) | CoCo **agent pods** (`openclaw-agent` in `coco-agents` ns, kata-remote) |
| `app-of-apps/hub/saw-users.yaml` | `applications/saw-users` (helm chart `coco-agents`) | per-user agents (`agent-<user>`, env `SAW_USER`/`SAW_PROFILE`) |

Agent container contract (both `applications/openshell/base/agent-deployment.yaml`
and `applications/saw-users/charts/coco-agents/templates/agent.yaml`):

- `command: sh -c 'openclaw onboard --non-interactive --accept-risk --skip-health || true; exec openclaw gateway run'` — the image default Cmd is bare `openclaw`, which is NOT the gateway; without onboarding it exits with "Onboarding needs an interactive TTY".
- Pod annotations: `peerpods: "true"`, `coco.io/initdata-configmap: initdata`, `io.katacontainers.config.runtime.create_container_timeout: "900"`.
- Volumes: `sandbox` emptyDir at `/sandbox` (agent home — persists for the pod's lifetime), governance policy/profiles CMs at `/sandbox/governance/` (generated into BOTH `openshell` and `coco-agents` namespaces by `applications/openshell/base/kustomization.yaml`), namespace-local `initdata` CM at `/opt/confidential-containers/initdata`.
- Do NOT set `fsGroup` outside the namespace SCC range — restricted-v2 rejects it; the emptyDir is world-writable anyway.
- Per-user agents read `agent-<user>-secrets` via `envFrom` (vault-backed).

## Vault secrets

All values are seeded from **`secrets/vault-coco`** (same pattern as
`secrets/vault-prelude`): fill in the placeholders, run the script to
push values into vault, then encrypt it with ansible-vault —
**no secret values are committed to git**.

```bash
export BASE_DOMAIN=<hub-base-domain>        # e.g. sandbox3000.opentlc.com
sh ./secrets/vault-coco <root-token>
ansible-vault encrypt secrets/vault-coco
```

Seeded vault paths (read by the ESOs as
`kv/data/ocp/sno/openshift-gitops/coco/<name>`):

> UI: `.../ui/vault/secrets/kv/kv/list/ocp/sno/openshift-gitops/coco`

| Path | Contents |
|---|---|
| `config` | SECURITY_POLICY_FLAVOUR, REALM_PREFIX, AGENT_CLIENT_ID — KBS_URL/KEYCLOAK_URL are **auto-populated** by `applications/coco-discovery` (ACM `{{ (lookup ...) }}` on hub routes + PushSecret) |
| `kbsres1` | key1/key2/key3 (KBS test resources) |
| `passphrase` | passphrase |
| `attestationStatus` | status=attested, random |
| `securityPolicyConfig` | insecure/reject/signed image policies |
| `networking` | AWS_SUBNET_ID/AWS_VPC_ID/AWS_SG_IDS for peer pods (per spoke; OSC 1.13 requires them in peer-pods-cm) |
| `keycloak-admin` | username/password for the spoke-realms Job |
| `kbs-auth-public-key` | dummy publicKey (trustee 1.2 operator requirement) |

The KBS TLS certificate is pushed to vault by the trustee app's
PushSecret (`kv/ocp/sno/openshift-gitops/coco/kbs-tls-self-signed`) and
pulled by the spoke initdata Job via ESO.

### AWS IAM for peer pods

The peer-pod AWS credentials (Hive-managed) needs an IAM policy with:

- `ec2:RunInstances`, `ec2:CreateTags`, `ec2:TerminateInstances`
- `ec2:DescribeInstances`, `ec2:DescribeImages`, `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`
- `ec2:CreateNetworkInterface`, `ec2:DeleteNetworkInterface`, `ec2:DescribeNetworkInterfaces`
- EC2 quota adds per spoke (see `AWS_QUOTAS.md`): on-demand C/VT instances, Elastic IPs, VPCs

The spoke's IPI-created NAT gateway handles peer-pod egress (no extra
config needed — unlike the Azure CoCo pattern).

### AWS security group for peer pods (required ports)

The SG in `peer-pods-cm` `AWS_SG_IDS` (attached to pod VMs) **must allow
inbound TCP 15150 (kata agent proxy) and TCP 8000 (health probe) from the
VPC CIDR** — the IPI-created cluster SG does NOT include these ports, and
without them the CAA logs `failed to establish agent proxy connection to
<podvm-ip>:15150: context deadline exceeded` and pods sit in
ContainerCreating forever. One-time fix per cluster:

```bash
aws ec2 authorize-security-group-ingress --group-id sg-0780a5e32d8170563 \
  --protocol tcp --port 15150 --cidr 10.0.0.0/16
aws ec2 authorize-security-group-ingress --group-id sg-0780a5e32d8170563 \
  --protocol tcp --port 8000 --cidr 10.0.0.0/16
```

(The CAA retries the agent proxy connection automatically — no restart
needed after the SG rule lands.)

### AWS IAM for the pod VM image creation (OSC 1.13)

The OSC 1.13 `osc-podvm-image-creation` job builds the pod VM AMI on AWS
(pull podvm image -> upload to S3 -> `ec2 import-snapshot` -> register
AMI). Per the OSC 1.13 docs, the credentials additionally need the
`OSC-ImageCreation-Policy` attached. The policy JSON is kept at
`applications/sandboxed-containers/osc-image-creation-policy.json`
(the docs' extended policy **plus `iam:PassRole`**, which the docs omit
but `ec2 import-snapshot` requires).

```bash
export AWS_DEFAULT_REGION=us-east-2
export AWS_ACCESS_KEY_ID=<peer-pods key>     # open-environment-m6wl4-admin
export AWS_SECRET_ACCESS_KEY=<peer-pods secret>

# create the policy (file in this repo) and attach it to the peer-pods user
aws iam create-policy \
  --policy-name OSC-ImageCreation-Policy \
  --policy-document file://applications/sandboxed-containers/osc-image-creation-policy.json

aws iam attach-user-policy \
  --user-name open-environment-m6wl4-admin \
  --policy-arn arn:aws:iam::130164124975:policy/OSC-ImageCreation-Policy

# then force a retry:
oc -n openshift-sandboxed-containers-operator delete job osc-podvm-image-creation
```

Notes:
- The `vmimport` role is created/managed **by the job itself** (the
  VMImportRoleManagement permissions) — no manual role setup needed.
- The OSC 1.13 docs' variant uses an IAM **role** with IRSA trust
  (`AmazonEC2FullAccess` + the same extended policy attached to the role);
  our setup uses the `open-environment-m6wl4-admin` **user** with static
  credentials, so the policies attach to the user.
- Without this policy the image job fails, the OSC `deploymentMode` feature
  gate falls back to `DaemonSet` (local kata — no /dev/kvm on virtual EC2
  instances) and CoCo pods fail with *"failed to add any hypervisor device
  to devices cgroup"*.

## Topology

```text
HUB SNO (sno.sandbox1254.opentlc.com)
├── Keycloak (SSO/realms)              ◄── ③ OIDC: per-spoke agent realms
├── trustee/KBS (ClusterIP :8080)      ◄── ① ATTESTATION (pod VM dials IN)
│   └── route: kbs.apps.sno...             + openshell-dashboard client
├── vault + ESO (hub-trusted)          ──► ② SEEDS (Pattern B: vault → spoke)
└── OpenShell gateway (vendored chart 0.1.2, Synced/Healthy)

SPOKE (coco-m6wl4-gfqch.sandbox1832.opentlc.com)
├── openshift-ingress ns
│   ├── envoy Gateway `openshell-gateway` (gateway ELB, class openshift-default)
│   │   ├── listener https            openshell-gw.apps.<domain>
│   │   │     cert tls-apps (*.apps — platform LE)
│   │   │     → GRPCRoute `openshell` (gRPC upstream, h2)
│   │   └── listener https-services   *.openshell.apps.<domain>
│   │         cert openshell-services-apps-tls (LE wildcard, DNS-01 Route53)
│   │         → HTTPRoute `openshell-services`
│   └── HAProxy router (*.apps.<domain>)
│         fallback: Route `openshell-services-apps` (reencrypt, 1 specific host)
├── openshell ns
│   ├── svc openshell-http :8080   NO appProtocol: grpc → HTTP/1.1 upstream
│   │                              (REQUIRED for WebSocket proxying — an h2
│   │                               upstream swallows the WS Upgrade)
│   ├── svc openshell :8080/:9090  appProtocol: grpc → h2 upstream (gRPC)
│   ├── openshell server — host-based service routing (service_routing.rs):
│   │     {ws}--{sbx}--{svc}.openshell.apps.<domain> → 127.0.0.1:<port> in the VM
│   └── svc dashboard :4180 (oauth2-proxy; Route openshell-dashboard.apps.<domain>)
├── openshift-gitops (ACM PolicyGenerator — git is the source of truth)
├── coco-agents ns (openclaw-agent / agent-<user> pods, kata-remote;
│   Route agent-alice-coco-agents.apps...)
└── CoCo pod VM (kata-remote peer pod, SNP CVM m6a.large)
      sandbox + openclaw gateway :18789
      exposed services (openshell service expose — runtime registration)
      initdata → aa.toml/cdh.toml ──► ① attests to the hub KBS

USER paths
  a) browser ──► https://{ws}--{sbx}--{svc}.openshell.apps.<domain>
        wildcard DNSRecord → gateway ELB → envoy https-services (LE wildcard)
        → HTTPRoute → openshell-http → server host routing → sandbox VM
  b) openshell CLI ──► https://openshell-gw.apps.<domain>
        envoy https (*.apps cert) → GRPCRoute → openshell server :8080 (gRPC)
  c) oc port-forward / d) in-cluster ClusterIP services (unchanged)
```

**Glossary:**

- **CAA — Cloud API Adaptor**: the CoCo project component behind the
  `osc-caa-ds` DaemonSet on the spoke node. The kata shim asks the CAA to
  create a pod sandbox; instead of running a pod VM on the node (virtual EC2
  instances have no `/dev/kvm`), the CAA calls the AWS EC2 API to launch a
  **remote** micro-VM running the same pod spec, then tunnels the pod
  network back to the node so the pod gets a normal pod IP and Services /
  Routes work unchanged.
- **CVM — Confidential Virtual Machine**: a VM whose memory is encrypted and
  measured by hardware. Here: AMD **SEV-SNP** on `m6a.large` — the guest
  memory is encrypted, the hypervisor (AWS) cannot read it, and the guest
  can prove its identity/measurement to the KBS via attestation. The OSC's
  CoCo flavour forces `DISABLECVM=false`, so every pod VM boots as an SNP
  CVM.

**Connection paths:**

| Path | How | Status |
|---|---|---|
| a) Browser → dashboard | `https://{ws}--{sbx}--{svc}.openshell.apps.<domain>` → wildcard DNSRecord → gateway ELB → envoy `https-services` (LE wildcard) → HTTPRoute `openshell-services` → `openshell-http` (HTTP/1.1) → host routing → sandbox VM | works |
| b) openshell CLI → gateway | `openshell gateway add https://openshell-gw.apps.<domain> --name openshell --oidc-issuer <realm-url> --oidc-audience openshell-dashboard` → envoy `https` (`tls-apps` `*.apps` cert) → GRPCRoute → openshell server `:8080` (gRPC, OIDC bearer) | works |
| c) oc port-forward | `oc -n coco-agents port-forward svc/agent-alice 18789:18789` (API server → kubelet → shim → CVM) | works |
| d) in-cluster | ClusterIP services (`openshell:8080`, `agent-alice:18789`) | works |
| HAProxy fallback | Route `openshell-services-apps` (reencrypt + externalCertificate) for `default--openclaw--openclaw-dashboard.openshell.apps.<domain>` — remove the `https-services` listener to fail back | fallback |

## Routing (envoy Gateway + zero-touch wildcard services)

Sandbox service URLs
(`https://{workspace}--{sandbox}--{service}.openshell.apps.<domain>`,
registered with `openshell service expose <sbx> <port> <name>`) need ZERO
per-service k8s objects — a new sandbox + expose is live immediately:

1. **DNS** — a wildcard DNSRecord for `*.openshell.apps.<domain>` (created
   by the envoy Gateway) points the whole tree at the gateway ELB.
2. **TLS** — terminates at the envoy listener `https-services` with the
   Let's Encrypt wildcard cert (`openshell-services-apps-tls`,
   `*.openshell.apps.<domain>`), issued by the platform `letsencrypt-ingress`
   Issuer (dns01 route53; the Route53 credentials come from vault via the
   hub-side ESO `eso-cert-aws.yaml` — no AWS values in git; no
   `hostedZoneID` — cert-manager discovers the zone). cert-manager renews
   automatically; the listener picks the renewal up live.
3. **Route** — HTTPRoute `openshell-services` (wildcard hostname,
   `openshell` ns) → the `openshell-http` Service → the openshell server
   `:8080` (BackendTLSPolicy re-encryption via the certgen-generated
   `openshell-backend-ca` ConfigMap).
4. **Host routing** — the server parses the
   `{workspace}--{sandbox}--{service}` host and proxies into the sandbox VM
   (`127.0.0.1:<port>`; base domain derived from the server cert's wildcard
   SAN — `pkiInitJob.serverDnsNames`; `AUTHORIZATION: strip`).

The gRPC control plane (openshell CLI, supervisor) rides the OTHER listener:
`https` (`openshell-gw.apps.<domain>`, platform `tls-apps` `*.apps` cert) →
GRPCRoute `openshell` → the `openshell` Service (`appProtocol: grpc` → h2
upstream). `server.disableTls: false` + `server.tls.enableMtls: false` —
BackendTLSPolicy re-encryption cannot present a client cert; OIDC bearer
auth (hub Keycloak realm) is the client identity.

**Why two listeners (and why the gateway is `openshell-gw.`):** a v1 Route
with `wildcardPolicy: Subdomain` claims `*.<ingress-domain>` — the ENTIRE
apps domain — regardless of the Route's host (router host_admitter: "route
openshift-authentication/oauth-openshift … blocking *.apps.<domain>"), so a
v1 wildcard Route for `*.openshell.apps.<domain>` is impossible. The Gateway
API HTTPRoute with a wildcard hostname is the dynamic routing. The gateway
hostname sits OUTSIDE the `openshell.apps.<domain>` tree because the
listener's hostname claim would otherwise conflict with the wildcard
services claim (HostAlreadyClaimed).

**Why `openshell-http` exists (WebSocket gotcha):** the `openshell` Service
has `appProtocol: grpc`, so the envoy negotiates an **h2** upstream — and an
h2 upstream cannot proxy the HTTP/1.1 `Upgrade`. A browser `wss://` arrives
at the backend as a plain GET (curl with Upgrade headers returns HTTP/2 200,
not 101) and the dashboard shows "Gateway unreachable". The `openshell-http`
Service targets the SAME pods/port without `appProtocol: grpc` → HTTP/1.1
upstream → WS upgrades proxy correctly. The HTTPRoute points at
`openshell-http`; the GRPCRoute keeps `openshell` (gRPC needs h2).

**HAProxy fallback:** Route `openshell-services-apps` (reencrypt +
externalCertificate) still serves its one specific host from the
`*.apps.<domain>` wildcard — remove the `https-services` listener to fail
back. Gotchas there: the inline `destinationCACertificate` regenerates on
every PKI re-issue (certgen is all-or-nothing — all three PKI secrets must
be deleted for a SAN change to take effect) — update the Route when the PKI
rotates or router→backend TLS fails with 503, and restart the BFF pod to
reload the regenerated CA.

```bash
# Routing objects (spoke):
oc -n openshift-ingress get gateway openshell-gateway   # ADDRESS = gateway ELB, PROGRAMMED True
oc -n openshell get httproute openshell-services \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}'  # Accepted/ResolvedRefs True
oc -n openshell get grpcroute openshell                 # declared hostname openshell-gw.apps.<domain>
oc -n openshell get svc openshell-http                  # the HTTP/1.1 backend

# Wildcard DNS + cert:
dig +short default--openclaw--openclaw-dashboard.openshell.apps.<domain>   # gateway ELB IPs
openssl s_client -connect <host>:443 -servername <host> -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer   # CN=*.openshell.apps.<domain>, Let's Encrypt

# WebSocket upgrade through the envoy — must be 101 (test with --http1.1:
# curl negotiates h2 with the envoy, and WS-over-h2 is not a thing):
curl --http1.1 -sk -i \
  -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' \
  https://default--openclaw--openclaw-dashboard.openshell.apps.<domain>/ | head -1
# HTTP/1.1 101 Switching Protocols
```

## Verification

```bash
# On the spoke:
oc get runtimeclass kata-remote                      # runtime class exists
oc get kataconfig default-kata-config                # installed
oc -n imperative get job initdata-gzipper            # initdata generated
oc -n imperative get cm initdata -o jsonpath='{.data.PCR8_HASH}'
oc -n imperative get secret coco-config -o jsonpath='{.data.KBS_URL}' | base64 -d

# Peer pods (OSC 1.13): networking ConfigMap + CAA DaemonSet on the node
oc -n openshift-sandboxed-containers-operator get cm coco-networking          # subnet/vpc/sg (plain values)
oc -n openshift-sandboxed-containers-operator get cm peer-pods-cm             # PODVM_AMI_ID + resolved {{fromConfigMap}} values
oc -n openshift-sandboxed-containers-operator get ds osc-caa-ds               # 1/1 on the node
oc -n openshift-sandboxed-containers-operator logs -l name=osc-caa-ds | grep -i "server started"

# CoCo feature gate + initdata (REQUIRED for the KBS round-trip):
oc -n openshift-sandboxed-containers-operator get cm osc-feature-gates \
  -o jsonpath='{.data.confidential}'      # "true" -> OSC sets DISABLECVM=false + preserves our INITDATA
oc -n openshift-sandboxed-containers-operator get cm peer-pods-cm \
  -o jsonpath='{.data.DISABLECVM}'        # "false" -> CAA launches SNP CVM pod VMs
oc -n openshift-sandboxed-containers-operator get cm peer-pods-cm \
  -o jsonpath='{.data.PODVM_INSTANCE_TYPE}'  # m6a.large (must support SEV-SNP)
oc -n openshift-sandboxed-containers-operator get cm peer-pods-cm \
  -o jsonpath='{.data.INITDATA}' | base64 -d | zcat | grep -c kbs  # >0: KBS URL present

# The end-to-end test is a sandboxed agent (openshell/coco-agents):
oc -n coco-agents get pods                           # agent pod Running on kata-remote
oc -n coco-agents get route agent-alice              # agent dashboard route

# Workload-namespace initdata CM — read by Kyverno on Pod CREATE, so it must
# match the imperative copy (a stale copy boots pod VMs with the old cert):
oc -n coco-agents get cm initdata -o jsonpath='{.data.RAW_HASH}'
oc -n imperative get cm initdata -o jsonpath='{.data.RAW_HASH}'   # must match

# KBS serving cert SAN — must cover the route hostname (the AA's rustls
# does hostname verification; a SAN miss = CreateContainerError):
openssl s_client -connect kbs.apps.sno.sandbox1254.opentlc.com:443 \
  -servername kbs.apps.sno.sandbox1254.opentlc.com </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName        # needs DNS:kbs.apps.sno.<domain>

# Attestation round-trip: the pod VM's CDH/AA must hit the KBS (hub):
oc -n trustee-operator-system logs deploy/trustee-deployment -c kbs \
  | grep -E "auth|attest|resource" | grep -v /live
# SUCCESS looks like (all 200, UA=attestation-agent-kbs-client):
#   "POST /kbs/v0/auth HTTP/1.1" 200
#   "POST /kbs/v0/attest HTTP/1.1" 200
#   "GET /kbs/v0/resource/default/security-policy/insecure HTTP/1.1" 200
```

## Cluster naming and pools

`placement-spoke-coco` matches clusters named `coco-*` (CEL selector in
`bootstrap/setup-cr.yaml`).

The coco pool uses the **hive-tenants chart** (self-contained per pool:
own AWS creds secret, guid-suffixed names, own install-config):

```bash
export KUBECONFIG=~/.kube/config.sno-test
export BASE_DOMAIN=<hub-base-domain>
export GUID=<tenant-guid>                       # e.g. g29zx
export INSTANCE_TYPE=m6i.4xlarge                # or m7i.8xlarge for 2x headroom
export ROOT_VOLUME_SIZE=400
export AWS_DEFAULT_REGION=us-east-2
export PULL_SECRET="$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)"

helm template hive-tenants applications/hive-tenants/charts/hive-tenants/ \
    --namespace=hive \
    --set clusterPoolName=coco \
    --set installConfigSecretTemplateRef=coco-install-config-template \
    --set baseDomain="${BASE_DOMAIN}" \
    --set-json globalPullSecret="${PULL_SECRET}" \
    --set installConfig="$(cat applications/hive-tenants/coco-install-config.yaml | envsubst)" \
    --set guid="${GUID}" \
    --set aws_access_key_id="${AWS_ACCESS_KEY_ID}" \
    --set aws_secret_access_key="${AWS_SECRET_ACCESS_KEY}" \
    --set sshKey="${SSH_PUBLIC_KEY}" | oc apply -f-
```

- `applications/hive-tenants/coco-install-config.yaml` — same env-var
  pattern as `prelude-install-config.yaml`: `baseDomain: $GUID-coco.$BASE_DOMAIN`,
  `$INSTANCE_TYPE` (set to **`m6i.4xlarge`** for the cheapest viable SNO,
  or `m7i.8xlarge` for 2× headroom), `$ROOT_VOLUME_SIZE`, `$AWS_DEFAULT_REGION`,
  `$USER_EMAIL`/`$USER_TEAM`/`$USER_USAGE`/`$USER_USAGE_DESCRIPTION`,
  `$SSH_PUBLIC_KEY`. SNO (`controlPlane.replicas: 1`,
  `compute.replicas: 0`), 400 GB gp3. NOTE: passed through `helm --set`,
  so it must not contain commas.
- The chart renders ClusterPool `coco-${GUID}`, install-config secret
  `coco-install-config-template-${GUID}` and its own AWS creds secret
  `aws-creds-${GUID}` (so the pool is independent of the shared
  `aws-creds`).
- Spawned clusters are named `coco-${GUID}-<random>` under the
  `${GUID}-coco.$BASE_DOMAIN` zone — still matched by the `coco-*` CEL
  selector.- Scale the pool to spawn coco spokes:
  `oc scale clusterpool coco-${GUID} -n cluster-pools --replicas=N`

## Planned SNO deployment (cheapest option)

**Decision**: SNO spoke on `m6i.4xlarge` or `m7i.8xlarge`, with peer pods
running on the SNO instance itself. This is the cheapest workable
configuration:

| Component | Cost (approx, varies by region) |
|---|---|
| SNO on `m6i.4xlarge` (16 vCPU/64 GiB) | ~$0.69–0.89/hr on-demand (~$500–640/mo 24/7); spot ~$0.30/hr |
| SNO on `m7i.8xlarge` (32 vCPU/128 GiB) | ~$1.61/hr on-demand (~$1,177/mo); spot ~$0.60/hr |
| Pod VM per **running** confidential pod | m6i.large ~$0.10/hr, m6i.xlarge ~$0.19/hr, t3.large ~$0.08/hr |
| (comparison) cheapest bare-metal TEE: `m6a.metal-48xl` | ~$4.60/hr (~$3,300/mo) **+ Dedicated Hosts** |
| (comparison) TDX `m7i.metal-24xl` | ~$4.84/hr (~$3,480/mo) **+ Dedicated Hosts** |

- **`m6i.4xlarge` is the cheapest viable SNO** (SNO needs 8 vCPU/32 GiB
  minimum; 16/64 leaves room for the peer-pod infra and light workloads).
- **`m7i.8xlarge` gives 2× headroom** if the SNO also runs RHOAI/LLM
  workloads locally — 2.3× the cost of the 4xlarge.
- **~7× cheaper than the smallest bare-metal TEE instance**, with no
  Dedicated Host requirement.
- Pod VMs are separate small EC2 instances that only exist while a
  confidential pod runs — that's the marginal cost per pod, on top of the
  SNO instance.
- **Trade-off**: no TEE (token-gated KBS only — see caveats below),
  single node (no HA), and spot SNOs can be reclaimed (the hub uses
  on-demand for this reason).
- No extra NAT config needed: the spoke's IPI-created NAT gateway handles
  peer-pod VM egress; EC2 quota needs standard on-demand vCPUs only
  (no Dedicated Hosts, no G/VT families for CPU agents).

## TEE options research (documented for future tracks)

| Path | Smallest AWS instance | Attestation stack |
|---|---|---|
| Peer pods, kata-remote (this repo) | `m6i.4xlarge` (16 vCPU/64 GiB) — no bare metal needed | token-gated KBS |
| Intel TDX, kata-cc (`kata-tdx` handler) | `m7i.metal-24xl` (96 vCPU/384 GiB, Sapphire Rapids) | Intel DCAP — PCCS required |
| AMD SEV-SNP, kata-cc (`kata-snp` handler) | `m6a.metal-48xl` (192 vCPU/768 GiB, Milan) | No PCCS — cert-chain (VCEK from AMD KDS) |
| Nitro Enclaves (different runtime model — not Kata) | parent `m5.2xlarge` (8 vCPU) | NSM attestation |

- **Peer pods (CAA) DO support TEE pod VMs without any TEE on the node**:
  the pod VM is a separate EC2 instance, so the worker node's CPU family
  is irrelevant. With the CoCo feature gate enabled the OSC sets
  `DISABLECVM=false` in peer-pods-cm and the CAA launches pod VMs as
  **AMD SEV-SNP CVMs** — `PODVM_INSTANCE_TYPE` must support SNP
  (`m6a.*`/`c6a.*`/`r6a.*` Milan+; verified available in us-east-2; this
  deployment uses `m6a.large`, the same 2 vCPU/8 GiB spec and ~same cost
  as `t3.large`). `t3.*` fails with "The specified instance type does not
  support AMD SEV-SNP". Attestation goes to the Trustee KBS
  `coco_as_builtin` service (verifies hardware evidence by TEE type). The
  kata-cc `kata-snp` handler / bare-metal rows below are the in-node Kata
  path and are NOT used here.
- **No smaller bare-metal TEE instance exists on AWS**: SEV-SNP requires
  Milan+ (all AMD `6a`/`7a` metals are 48xl; Naples `m5a` metals lack
  SNP); Intel TDX only on `m7i` metals (smallest = 24xl). Both require
  **Dedicated Hosts** (quota add).
- coco-pattern tested environments (v5.\*): OSC 1.12 + Trustee 1.1 GA +
  OCP 4.19.28+ + Kyverno 3.7. SNP SNO uses HPP storage, NFD
  `amd.feature.node.kubernetes.io/snp=true`, and the `kata-snp` handler
  with **no PCCS**. TDX SNO uses NFD `intel.tdx=true` with DCAP/PCCS.
- Community validation of CoCo on AWS bare metal:
  `aws-samples/howto-runtime-attestation-on-aws` (m6a.metal/m7a.metal,
  Kata 3.11 + CoCo 0.11, Ubuntu — the Ubuntu kernel ≥ 6.11 requirement is
  the OpenShift blocker; RHCOS relies on RHEL 9.4+ `kvm_amd` SNP host
  support instead).
- **Nitro Enclaves** (Red Hat blog, "Confidential computing on AWS Nitro
  Enclave with RHEL"): real small TEE — parent `m5.2xlarge` (8 vCPU/32
  GiB), enclaves configurable (e.g. 2 vCPU + 2 GB, max 4 per parent),
  attestation docs signed by the Nitro Security Module (`/dev/nsm`) with
  PCR0/1/2 EIF measurements. **Not adopted here**: enclaves are not K8s
  pods and involve no Kata (launched by `nitro-cli` from the parent node,
  vsock-only networking, no CoCo/KBS verifier, and `nitro-cli` +
  `nitro-enclaves-allocator` are not shipped for RHCOS — privileged
  DaemonSet glue + post-launch instance config would be required).
  Documented as a future track if TEE-hardened agents in enclaves become
  a requirement.

## CoCo + OpenShell dual sandbox research (2026-10-08)

**Verdict: supported end-to-end — one values line enables it.** An OpenShell
sandbox (application-layer policy: egress proxy, Landlock, seccomp) can run
INSIDE a CoCo pod VM (guest-kernel/host isolation), giving both layers
simultaneously. Red Hat validated exactly this "dual" mode on OCP 4.21
("Layered sandboxing for AI agents" 2026-07-16 + "Why your AI agent needs
two sandboxes" benchmark 2026-07-23):

| Attack | Kata only | OpenShell only | Both |
|---|---|---|---|
| Prompt injection exfiltration | DATA LEAKED | BLOCKED | BLOCKED |
| Container escape (CVE-2026-31431) | BLOCKED | HOST COMPROMISED | BLOCKED |

- **OpenShell native support (verified in the `~/git/OpenShell` source)**:
  the k8s driver sets `runtimeClassName` on the AgentSandbox pod template
  with precedence sandbox-template `platform_config.runtime_class_name` →
  per-sandbox `driver_config` → **gateway default
  `default_runtime_class_name`** (`driver.rs`, unit-tested; feature landed
  2026-06-03, PR #1729 — included in the deployed gateway 0.1.2). The CLI
  `openshell sandbox create` sends no runtime class, so the gateway default
  applies to every new sandbox.
- **The enablement change is one line** in
  `applications/openshell/overlay/gateway/values.yaml` under the existing
  `server:` block: `defaultRuntimeClassName: kata-remote`. The gateway chart
  already renders it (`templates/gateway-config.yaml` →
  `default_runtime_class_name` in `[openshell.drivers.kubernetes]` of
  `gateway.toml`; documented in the chart values). Rollout path: commit →
  ArgoCD → ACM policy → spoke; the gateway config checksum annotation
  forces a pod rollout; new sandboxes then boot as kata-remote pod VMs.
- **CoCo integration points already in place**: (1) global INITDATA on the
  spoke (`peer-pods-cm` `INITDATA: {{fromConfigMap "imperative" "initdata"
  "INITDATA"}}`) applies to ALL kata-remote pods regardless of namespace,
  so sandbox pods in the `openshell` ns get the same AA→KBS attestation
  chain automatically; (2) the `propagate-initdata-to-openshell` Kyverno
  policy (`applications/coco-kyverno-policies/overlay/spokes/propagation-initdata.yaml`)
  already clones the imperative initdata CMs into the `openshell` ns; (3)
  the initdata `policy.rego` is permissive for this workload (`default
  CreateContainerRequest := true`, no image restrictions) and the image
  security policy is `insecure`, so the sandbox base + supervisor images
  pull inside the pod VM; (4) OpenShell does NOT use kube exec for its
  control channel (mTLS to the supervisor boundary port 5500 via the paired
  supervisor pod), so the kata agent policy's exec whitelist (the two CDH
  status curls) does not block gateway management of the sandbox.
- **Caveats**: (1) the peer-pods webhook strips container resources, so
  each sandbox is one DEFAULT pod VM (`m6a.large`) counting against
  `PEERPODS_LIMIT_PER_NODE` — per-sandbox resource requests have no effect;
  (2) OpenShell's supervisor needs Landlock in the GUEST kernel (≥5.13) —
  verify the podvm image kernel before relying on filesystem isolation
  (`ami-056cc016bbe3cddc3`); (3) the KBS TLS cert SAN fix (below) is a hard
  prerequisite — a SAN miss kills kata-remote sandboxes with the same
  `CreateContainerError` as the coco-agents pods; (4) mixed mode works — a
  per-sandbox `driver_config`/`platform_config` runtime class overrides the
  gateway default, so some sandboxes can stay on runc.
- **Verification after enable**: create a sandbox (`openshell sandbox
  create -g <gateway> --name coco-test ...`), then
  `oc get pods -n openshell -o json | jq -r '.items[] |
  select(.spec.runtimeClassName=="kata-remote") | .metadata.name'` shows
  the sandbox workload pod, a pod VM appears (CAA DS logs on the node / the
  pod VM EC2 instance), and the KBS logs the attestation round-trip (same
  SUCCESS signature as Verification).

## Notes and caveats

- **PlacementBindings must set `metadata.namespace` explicitly in apps whose
  destination is not `openshift-gitops`** (e.g. `sandboxed-containers` →
  `openshift-sandboxed-containers-operator` with `CreateNamespace=true`): a
  namespace-less binding silently lands in the app's **destination**
  namespace instead of next to its Policy in `openshift-gitops`, the ACM
  propagator never sees it, and the policy silently never distributes —
  no status, no events, no errors. The ESO-created Policies and the
  policy-generator output carry explicit namespaces; only hand-written
  binding yamls lack one. (The `coco-kyverno-policies` app only gets away
  with it because its destination IS `openshift-gitops`.)
- **Per-spoke peer-pods credentials + AWS networking for peer pods** flow:
  credentials are hydrated ON the spoke from the Hive-managed
  `kube-system/aws-creds` Secret via ACM `{{fromSecret}}` (spoke-side, no
  vault) inside the `peer-pods-secret-spokes` ACM Policy; networking flows
  vault `coco/networking` → `peer-pods-secret-spokes` ESO (hub) bakes the
  keys (into the `coco-networking` **ConfigMap**) into the same Policy via
  `templateFrom` → both land on the spoke (sticky distribution) →
  peer-pods-cm reads the networking via `{{fromConfigMap ... "coco-networking" ...}}`.
  Do NOT use hub-side `{{hub fromSecret ... | base64dec hub}}` for these —
  `base64dec` fails at policy distribution and ACM bakes the Go error text
  into the value; and note ACM's `fromSecret` (hub- AND spoke-side) returns
  the base64-encoded Secret `.data` value, so Secret-backed values need
  decoding — `fromConfigMap` returns plain data and is the safe choice for
  non-credential identifiers. ACM template functions inside an ESO
  `templateFrom` literal must be escaped for the ESO v2 Go template engine
  (e.g. `{{"{{"}}fromSecret ...{{"}}"}}`), or ESO fails with "function
  not defined" at render time.
- **TEE on AWS — round-18 decision: full TEE CoCo**. This deployment now
  uses the OSC's native CVM path: feature gate on → `DISABLECVM=false` →
  SNP CVM pod VMs (`PODVM_INSTANCE_TYPE: m6a.large`). Hardware-rooted
  attestation (AA in the guest → SNP evidence → KBS `coco_as_builtin`) is
  in play; once it is verified end-to-end, the claim rules in
  `applications/trustee/overlay/hub/resource-policy.yaml` can be enabled
  and SNP reference values added to the KBS. (The pre-round-18 setup used
  `t3.large` pod VMs, which have no TEE — that caveat is historical.)
- **CAA rollouts sever existing kata-remote pod shims** (`dial unix
  /run/containernd/...: no such file`): after ANY CAA restart, delete the
  coco-agents pods for fresh sandboxes. Pods stuck in `Terminating` for a
  long time have **no finalizers and no kubelet progress** (the shim was
  severed) — force-delete them
  (`oc -n coco-agents delete pods --all --force --grace-period=0`) and
  terminate orphaned pod VMs left behind by the dead sandchains
  (`aws ec2 terminate-instances` for stray t3/m6a instances).
- **peer-pods-cm is ACM-managed and OSC-rendered — two drift traps**: (1) ACM
  policy enforcement continuously re-applies the committed value, so live CM
  patches revert within minutes — durable changes go through git (commit →
  ArgoCD → ACM → spoke). (2) The OSC renders the CM values into the
  osc-caa-ds **env template** and the CAA reads its config ONCE at startup
  from that env, so changing the CM alone does NOT reach the CAA: trigger a
  KataConfig reconcile (annotate the KataConfig or restart the OSC operator)
  to re-render the DS — then delete the coco-agents pods (shim severing,
  above). Emergency override without a reconcile: `oc set env ds/osc-caa-ds
  PODVM_INSTANCE_TYPE=m6a.large` (rolls the CAA with the explicit env).
- **Keycloak realms**: the per-spoke realm created by `spoke-realms` is
  **for agents only** (client `openshell-agents`). OCP on the spoke still
  validates against the HUB Keycloak via the existing
  `applications/policy-collection` `policy-oauth-sso` pattern (issuer =
  `KEYCLOAK_URL/realms/<cluster-name>` via `{{hub .ManagedClusterLabels.name hub}}`).
- **Image security policy**: `insecure` flavour accepts all images
  (dev/testing). Seed `securityPolicyConfig` with a signed policy for
  production.
- **GPU spokes** (L40S `g6.8xlarge`): peer-pod GPU config (OSC supports
  NVIDIA GPU peer pods) is a follow-up; the initial stack is CPU agents.
- The CoCo runtime manifests mirror `validatedpatterns/sandboxed-containers-chart`
  + `validatedpatterns/trustee-chart` (companion charts of the
  `validatedpatterns/coco-pattern` Azure pattern), ported to this repo's
  kustomize + ACM PolicyGenerator conventions.
- **Secrets rule**: every Secret is delivered via ExternalSecret from
  vault (see `applications/policy-collection` for the pattern). Never
  commit secret values or placeholder base64 blobs — values live in
  vault, seeded by the `secrets/vault-*` scripts.
- **KBS TLS cert SAN must cover the route hostname** (2026-10-08 fix): the
  cert-manager Certificate in `applications/trustee/overlay/hub/kbs-tls.yaml`
  originally had `dnsNames: [kbs]` only, so the KBS served a cert the AA's
  rustls hostname verification rejects (`kbs.apps.<domain>` != `kbs`) —
  every CoCo pod died with `CreateContainerError: ttrpc request error` and
  the KBS logged **zero** requests. Fix: the Certificate's `dnsNames`
  include `kbs.apps.<domain>`; cert-manager rotates → the cert is pushed to
  vault (`coco/kbs-tls-self-signed`) by `secrets/vault-coco` → the trustee
  ESOs pull it into `kbs-https-certificate/key` → the initdata pins the same
  cert, so client and server always match.
- **KBS route must set `spec.host`, not `subdomain`** (2026-10-08 fix):
  `applications/coco-discovery` `coco-urls-hub` policy publishes
  `KBS_URL: https://{{ $kbs.spec.host }}` to vault; with a subdomain-only
  route `spec.host` is empty and the URL rendered as `https://<no value>`,
  poisoning the whole chain (hub coco-config → vault `coco/urls` → spoke
  `coco-config` → initdata). Keycloak is unaffected (its route sets
  `spec.host`).
- **Vault write path is ONLY `secrets/vault-coco`**: never write to vault
  directly (vault CLI, pod exec, API). Add the needed `vault kv put` to the
  script and stop — vault is hydrated by running the script (same pattern as
  git: Mike is vault master). The PushSecret path
  (`push-kbs-certs`/`push-coco-urls`) also cannot update vault: the ESO
  vault role lacks `kv/metadata/*` (403 on the Replace existence check), so
  the scripts are the only write mechanism.
- **Workload-namespace initdata CM is namespace-local** (2026-10-08 trap):
  the Kyverno `inject-coco-initdata` policy reads the ConfigMap named by the
  pod's `coco.io/initdata-configmap` annotation **from the pod's own
  namespace** on Pod CREATE — there is no automated sync from
  `imperative/initdata` to workload namespaces. When `imperative/initdata`
  changes, update the workload copies (e.g. `oc -n <ns> get cm initdata -o
  yaml` from imperative → apply), then delete the workload pods (the policy
  targets Pods, so pod deletion picks up the latest initdata). Verify with
  the RAW_HASH comparison in Verification.
- **CoCo pod rollout ordering**: pod VMs provisioned BEFORE a CAA
  DaemonSet restart (or a peer-pods-cm change that re-renders it) boot with
  the OLD initdata/instance type — after any CAA/CM change, delete the
  coco-agents pods so the new CAA provisions them. CAA restarts also sever
  existing kata-remote shims (above).
- **openclaw/agent-alice images need onboarding + the gateway command**
  (2026-10-08 fix): two app-level issues, independent of CoCo (verified on
  non-kata pods). (1) The images exit 1 + empty logs until onboarded — run
  `openclaw onboard --non-interactive --accept-risk --skip-health` before
  start (idempotent; the config lives at `/sandbox/.openclaw/` on the pod's
  `sandbox` emptyDir, so it persists for the pod's lifetime). (2) The image
  default Cmd is bare `openclaw`, which is NOT the gateway — it exits after
  ~20s; the gateway is `openclaw gateway run`. The coco-agents deployments
  set `command: sh -c 'openclaw onboard --non-interactive --accept-risk
  --skip-health || true; exec openclaw gateway run'`. NOTE: do NOT set
  `fsGroup: 1000` on these pods — OpenShift restricted-v2 SCC rejects any
  fsGroup outside the namespace range (`coco-agents`:
  `1000870000/10000`) and the emptyDir is world-writable anyway. Exec into
  the CoCo containers is blocked by the kata agent policy (by design), so
  debug such containers via a throwaway non-kata pod with the same image.
