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
├── Keycloak (per-spoke AGENT realms)       ├── openshell gateway + CoCo agents (kata-remote pods)
├── vault + ESO (pre-installed)             └── saw-users per-user agent fan-out
└── coco-discovery (ACM lookup of hub
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
| `applications/openshell` (gateway) | `placement-spoke-coco` | OpenShell gateway from `oci://ghcr.io/nvidia/openshell/helm-chart` |
| `applications/openshell` (agents) | `placement-spoke-coco` | CoCo agent pods (AIPCC OpenClaw, `runtimeClassName: kata-remote`) + governance interceptor |
| `applications/saw-users` | `placement-spoke-coco` | Per-user CoCo agent fan-out (adapted from secure-agent-workspace, no CNV) |
| `applications/spoke-realms` | hub | Creates a Keycloak realm per coco-* spoke **for agents only** (client `openshell-agents`) |

## Deployment sequence

1. **`trustee`** (hub) — KBS + secrets. Needs vault seeded (below).
2. **`coco-discovery`** (hub) — looks up the KBS/Keycloak routes and pushes KBS_URL/KEYCLOAK_URL to vault.
3. **`sandboxed-containers`** (spoke) — OSC operator + `KataConfig`. The KataConfig takes ~15–30 minutes to deploy the peer-pod machine image; check with `oc get kataconfig default-kata-config -o jsonpath='{.status}'`.
4. **`kyverno` + `coco-kyverno-policies`** (spoke) — initdata pipeline.
5. **`openshell` + `openshell-agents` + `saw-users`** (spoke) — agents.

Test with sandboxed agents after the infrastructure deploys.

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
| `peer-pods` | AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY for peer-pod VM lifecycle |
| `networking` | AWS_SUBNET_ID/AWS_VPC_ID/AWS_SG_IDS for peer pods (per spoke; OSC 1.13 requires them in peer-pods-cm) |
| `keycloak-admin` | username/password for the spoke-realms Job |
| `kbs-auth-public-key` | dummy publicKey (trustee 1.2 operator requirement) |

The KBS TLS certificate is pushed to vault by the trustee app's
PushSecret (`kv/ocp/sno/openshift-gitops/coco/kbs-tls-self-signed`) and
pulled by the spoke initdata Job via ESO.

### AWS IAM for peer pods

The `peer-pods` vault credentials need an IAM policy with:

- `ec2:RunInstances`, `ec2:CreateTags`, `ec2:TerminateInstances`
- `ec2:DescribeInstances`, `ec2:DescribeImages`, `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`
- `ec2:CreateNetworkInterface`, `ec2:DeleteNetworkInterface`, `ec2:DescribeNetworkInterfaces`
- EC2 quota adds per spoke (see `AWS_QUOTAS.md`): on-demand C/VT instances, Elastic IPs, VPCs

The spoke's IPI-created NAT gateway handles peer-pod egress (no extra
config needed — unlike the Azure CoCo pattern).

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

## Verification

```bash
# On the spoke:
oc get runtimeclass kata-remote                      # runtime class exists
oc get kataconfig default-kata-config                # installed
oc -n imperative get job initdata-gzipper            # initdata generated
oc -n imperative get cm initdata -o jsonpath='{.data.PCR8_HASH}'
oc -n imperative get secret coco-config -o jsonpath='{.data.KBS_URL}' | base64 -d

# The end-to-end test is a sandboxed agent (openshell/coco-agents):
oc -n coco-agents get pods                           # agent pod Running on kata-remote
oc -n coco-agents get route agent-alice              # agent dashboard route
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
- **Per-spoke AWS networking for peer pods** flows: vault
  `coco/networking` → `peer-pods-secret-spokes` ESO (hub) bakes creds (into
  the `peer-pods-secret` Secret) + networking keys (into the
  `coco-networking` **ConfigMap**) into the ACM Policy via `templateFrom` →
  both land on the spoke (sticky distribution) → peer-pods-cm reads the
  networking via `{{fromConfigMap ... "coco-networking" ...}}`.
  Do NOT use hub-side `{{hub fromSecret ... | base64dec hub}}` for these —
  `base64dec` fails at policy distribution and ACM bakes the Go error text
  into the value; and note ACM's `fromSecret` (hub- AND spoke-side) returns
  the base64-encoded Secret `.data` value, so Secret-backed values need
  decoding — `fromConfigMap` returns plain data and is the safe choice for
  non-credential identifiers.
- **TEE on AWS — is the attestation hassle worth it without TEE?** The
  pool's AWS instances are virtual (m6i/t3/g6); standard peer-pod VM
  instance types have **no TEE**, so hardware attestation cannot
  cryptographically prove anything. What the pipeline still gives:
  pod-VM isolation (image pulled inside the pod VM, invisible to the
  node), initdata binding (KBS cert + agent policy in the guest), secrets
  delivered only via the KBS round-trip, kata agent rego policy, and
  governance/Landlock. What it cannot give: hardware-rooted trust.
  - The KBS **resource policy is permissive by default** for this reason
    (non-TEE EAR claims default to failing values — enforcing them would
    deny all resource delivery). Resources stay token-gated. To enforce
    claims, use TEE pod VMs: AWS SEV-SNP is available on 7th-gen AMD
    instances (`m7a.*`/`c7a.*`/`r7a.*` via `PODVM_INSTANCE_TYPE`), then
    enable the claim rules in
    `applications/trustee/overlay/hub/resource-policy.yaml` and add SNP
    reference values to the KBS.
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
