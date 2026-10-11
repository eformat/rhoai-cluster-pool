# Trusted agent workflows — the attestation proof story

**Purpose**: prove the point of CoCo + AMD SEV-SNP for the openclaw demo —
the agent runs inside a hardware-attested confidential VM, its secrets are
released only post-attestation, its code is launch-measured, and its behavior
is policy-enforced inside the TCB. This doc is the demo + slides source.
Runbook: [provider-setup-openclaw.md](provider-setup-openclaw.md) · Demo script:
[demo-flow.md](demo-flow.md).

---

## 1. The claim

> The openclaw agent executes inside a Confidential Container VM measured at
> boot by AMD SEV-SNP, verified by a remote KBS before any secret or policy is
> delivered. Nothing inside the VM — its credentials, its policy, its identity
> — is reachable from outside that attested boundary.

Cost note: SEV-SNP CVMs carry a ~10% surcharge — the premium buys this
guarantee.

## 2. Path A — the hardware claim is verified ✓

- `runtimeClass=kata-remote` — a real CoCo pod VM.
- KBS attestation round-trip complete:
  - `POST /kbs/v0/auth → 200`
  - `POST /kbs/v0/attest → 200` (UA = `attestation-agent-kbs-client/0.1.0`,
    3ms)
- The SNP evidence is VCEK-signed and verified by the attestation service
  (`attestation-service 0.1.0`, Confidential Containers).

## 3. The evidence — what the relying party recorded

**Location**: hub kubeconfig, `trustee-operator-system/trustee-deployment-*`
logs, at each `POST /kbs/v0/attest`. The verifier records the complete SNP
evidence — this is the deep artifact (no in-VM binary needed):

| Field (from the verified report) | Value | What it proves |
|---|---|---|
| `snp.measurement` | `7a89cceaaba0bbdddc4f775acca3ef15d1f9bf8abccdc6115cfad7fb8eae113df3ee0bb50efa34db9c53ae065b1dc766` | the launch measurement — the VM's initial state |
| `policy_debug_allowed` | `false` | a debugged VM cannot lie about its state |
| `platform_tsme_enabled` | `true` | transparent secure memory encryption active |
| `reported_tcb` | bootloader=4, microcode=222, snp=29, tee=0 | the firmware TCB levels |
| `nonce` | `pHh/Zve5PZ51+gXA1ISz+33PWzefZVFiM1SuOh7yCyA=` | fresh per-session challenge |
| `report_data` | `b8f3fb7be861b906a685557b641b58dd663dfb06949dcc93ad33d917adf04c12cf8…` | nonce+tee-pubkey **hashed into the hardware report** — replay-proof binding |
| `tee-pubkey` | EC P-256 (x/y, ECDH-ES+A256KW) | the attestation token is encrypted **to the TEE** — only the attested VM can decrypt it |
| EAR trust claims | hardware 97, configuration 36, executables 33 | the graded trust vector (see §5 — not yet affirming) |

And immediately after attest:
```
GET /kbs/v0/resource/default/security-policy/insecure → 200
```
**The attested VM received its security policy delivered post-attestation** —
the release gate works.

Replay-proof chain (say this on the slide): fresh nonce → hashed with the
TEE's public key into `report_data` → bound into the hardware-signed SNP
report → the verifier confirms the VM answered *this* challenge with *this*
key. A recording of a previous attestation cannot be replayed.

## 4. Why no attestation binary runs in the workload (the AWS contrast)

The AWS EC2 model ("Attest an Amazon EC2 instance with AMD SEV-SNP") runs a
`snpguest`-style binary on the instance host: request the report via
`/dev/sev-guest`, fetch the VCEK chain from the AMD KDS, verify the
measurement.

In our CoCo architecture that path is **blocked by good design**:
- The workload container has **no `/dev/sev-guest`** — `ls /dev/` returns
  *Permission denied*.
- The **AA (attestation-agent) mediates** attestation from the VM level — it
  is part of the TCB, outside the workload's reach.
- A compromised workload therefore **cannot mint its own reports** to a
  relying party. Passing the device through to the pod would show the report
  directly but would weaken exactly the guarantee being demoed.
- The KBS-side logs give the same artifact, in verified form.

**Slide line**: *"On EC2 the instance attests itself; in CoCo the workload
never touches the hardware root — a mediated agent inside the TCB does."*

## 5. The gap — "verified" does not yet mean "matches the expected image"

The EAR appraisal status is **`Contraindicated`** while resources are still
served. Three layers, each with a visible knob (all in the hub,
`trustee-operator-system`):

### Layer 1 — RVPS reference values (`rvps-reference-values` ConfigMap)
**Currently empty** (migrated metadata only). This is the Reference Value
Provider Service: the home for the *expected* launch measurement. Mounted into
the KBS pod at `…/storage/local_json/reference_value/` (volume
`reference-values`), which is empty today.

### Layer 2 — the attestation policy (`attestation-policy.v1.1`, `default_cpu.rego`)
**All conservative defaults, no recognition rules**:
```rego
default executables := 33   # "Runtime memory includes unrecognized executables"
default hardware := 97      # "Verifier does not recognize attester's hardware"
default configuration := 36 # "Security-relevant configuration unavailable"
```
No rule grades the SNP evidence up, so every claim falls to its default →
`Contraindicated`.

### Layer 3 — the resource policy (`resource-policy.v1.1`, `resource-policy.rego`)
**Claim enforcement is commented out** ("enable for TEE pod VMs"):
```rego
allow if {
    count(input.submods) > 0   # ← the only real check today
    not executable_failing     # ← all three rules commented out
    not configuration_failing
    not hardware_failing
}
```
That is why resources are served despite `Contraindicated`.

**Today's meaning of "verified"**: the report is *cryptographically valid*
(VCEK-signed, fresh nonce, correctly bound) — but nobody compares the
measurement to an expected reference.

## 6. Reference measurement pinning — the fix

**Step 1 — the reference value**: the verified measurement from a trusted
bring-up (the KBS log value):
```
7a89cceaaba0bbdddc4f775acca3ef15d1f9bf8abccdc6115cfad7fb8eae113df3ee0bb50efa34db9c53ae065b1dc766
```

**Step 2 — populate the RVPS**: add a reference-value file to the
`rvps-reference-values` ConfigMap data (the operator mounts it into the KBS's
`reference_value/` dir). Verify the exact `ReferenceValue` JSON schema for SNP
from upstream `attestation-service` source before applying. (Simpler demo
alternative: define the reference measurement directly in `default_cpu.rego`.)

**Step 3 — add the recognition rule** to `default_cpu.rego` (evidence path per
the EAR token: `submod["ear.veraison.annotated-evidence"]["snp"]["measurement"]`):
```rego
reference_measurement := "7a89cceaaba0bbdd…dc766"

hardware := 2 if {   # affirming value — recognized hardware
    some _, submod in input.submods
    submod["ear.veraison.annotated-evidence"]["snp"]["measurement"] == reference_measurement
}
```

**Step 4 — enable enforcement** in `resource-policy.rego`: uncomment the three
`*_failing` rules → resources only flow to VMs whose trust claims are in the
affirming range.

**Step 5 — re-attest** → EAR: `Affirming` (hardware graded up from 97) →
resources flow.

**Step 6 — the negative test (the best live demo)**: the same resource URL
from an unattested plain pod → no valid SNP evidence → hardware stays 97 →
`hardware_failing` → **KBS refuses**. One pod, one curl — the entire value
proposition.

## 7. What changes the launch measurement — the lifecycle answer

**Empirically confirmed 2026-10-09: 24 attestations against this KBS,
1 distinct measurement.** Every pod instance (test sandbox, openclaw sandbox,
multiple recreations) produced the identical measurement — that determinism is
what makes pinning viable.

The SEV-SNP launch digest covers the VM's **initial launch state** only:

| In the measurement | NOT in the measurement |
|---|---|
| Guest firmware (OVMF/EDK2) | Container images — pulled inside the VM post-attestation |
| Guest kernel | Security policy / KBS-delivered content |
| initrd (kata-agent, AA, pause rootfs) | Platform ConfigMaps |
| Kernel command line | Per-session data (nonce/tee-pubkey = `report_data`) |
| VM launch parameters (vCPU count, type) | `init_data` — all zeros in this deployment |

| Lifecycle change | Measurement? | Notes |
|---|---|---|
| New agent pod/VM instance (same runtime) | **No** | same measurement, fresh `report_data` — 24× confirmed |
| New container image build + upload (openclaw/sandbox runtime image) | **No** | post-attestation content; integrity via image-rs digest/signature checks (a separate mechanism) |
| New kata runtime / OVMF / guest kernel / initrd / cmdline | **YES** | the launch state changes → deliberate re-pin |
| New ConfigMap (attestation/resource policy, RVPS) | **No** | platform-side — changes the appraisal only |
| New sandbox policy content (via KBS) | **No** | post-attestation content; AA digest pinning |

**Slide line**: *"Enforcement is safe for normal lifecycle — new pods, new
images, new ConfigMaps are unaffected. The gate bites precisely on runtime
tampering: genuine hardware, unexpected code, refused."*

## 8. The governance posture — already "Manual" by design

Actual KBS config (`kbs-config` ConfigMap, `kbs-config.toml`):
```toml
[attestation_service.rvps_config]
type = "BuiltIn"              # RVPS embedded — not a networked service
storage_type = "LocalJson"    # reference values = a static local file

[admin]
authorization_mode = "DenyAll" # the admin API is locked
```

- Reference values can **only** change by someone deliberately editing the
  `rvps-reference-values` ConfigMap — there is no networked registration
  protocol to defend.
- Updating the runtime does **not** mean updating the operator: the runtime
  lives on the spoke (new measurement), the operator on the hub is the
  verifier, and the pin between them is pure data.
- Do not switch to a networked RVPS (`type = "Network"`, gRPC registration)
  — unnecessary and weaker for this story.

**Slide line**: *"The expected measurement is not configuration you maintain —
it is a claim the operator makes, once, in a trusted bring-up."*

## 9. Deliberate runtime upgrade — the re-pin moment

1. New pods attest with the **new** measurement → the KBS logs it.
2. Verify the new measurement matches the intended artifacts (staging run).
3. Add it to `rvps-reference-values` (or update the policy reference) →
   re-pinned.
4. Resources flow again. Old measurements can be kept for rollback or
   removed to force the upgrade.

---

## Demo checklist (task 9)

- [ ] Capture the KBS round-trip logs (attest + resource delivery) — done, see §3
- [ ] The negative test from an unattested plain pod → capture the refusal
- [ ] Apply the pinning stack (§6) → EAR `Affirming`
- [ ] Slide evidence: §3 table (the verified report), §7 (24 attestations /
      1 measurement), §4 (the mediated-AA contrast with AWS)
- [ ] Follow-up: reference-value JSON schema from upstream; container-image
      gating via image-rs (separate knob)
