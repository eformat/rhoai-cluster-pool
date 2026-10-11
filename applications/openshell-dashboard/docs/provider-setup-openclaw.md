# MaaS provider setup for openclaw (glm-5.3-flash)

Validated end-to-end 2026-10-09: openclaw agent turn answered through RHOAI MaaS
`publishers/prelude-maas/models/glm-53-flash` from the Control UI
("pong — Done in 7 seconds · 51 output tokens").

OpenShell providers are backed by **custom provider profiles** — a gateway with
zero imported profiles rejects `provider create` with `provider profile
'<name>' not found`. The sequence below is the full working path.

## 0. Prerequisites

- Port-forward running: `oc port-forward svc/openshell -n openshell 8080:8080`
- CLI registered + logged in (`openshell gateway add` / `openshell gateway login`)
- The `openclaw` sandbox **Running** (created with `--policy` + digest-pinned image)

## 1. Author the provider profile (laptop)

File: `applications/openshell-dashboard/provider-profiles/openai.yaml`

```yaml
id: openai
display_name: OpenAI-compatible (RHOAI MaaS)
description: OpenAI-compatible chat completions API served by RHOAI MaaS
category: other
credentials:
  - name: OPENAI_API_KEY
    required: true
    auth_style: bearer
    header_name: Authorization
endpoints:
  - host: maas.apps.ocp.cloud.rhai-tmm.dev
    port: 443
    protocol: rest
    access: read-write
    enforcement: audit
binaries: []
```

Gotcha: the `tls:` field must be **omitted** — lint rejects any value
(`unknown tls value`; omit the field for automatic TLS detection).

## 2. Lint + import the profile (gateway level, laptop)

```bash
openshell profile lint   --file applications/openshell-dashboard/provider-profiles/openai.yaml -g openshell
openshell profile import --file applications/openshell-dashboard/provider-profiles/openai.yaml -g openshell
# → Imported 1 provider profile.  (profile list: openai | provider | OTHER | user | workspace)
```

## 3. Create the provider (workspace level, laptop)

```bash
openshell provider create -g openshell \
  --name openai --type openai \
  --credential "OPENAI_API_KEY=<api-key>" \
  --config "OPENAI_BASE_URL=https://maas.apps.ocp.cloud.rhai-tmm.dev/v1"
# → ✓ Created provider openai  (1 credential key, 1 config key)
```

- `-g openshell` = the gateway; `--workspace` defaults to `default` →
  workspace-scoped (`SOURCE=user, SCOPE=workspace`).
- `--type openai` resolves the imported profile id.
- Credential hygiene: `--credential "OPENAI_API_KEY"` (key without value) reads
  from the local env instead of landing the secret in shell history.
- `openshell provider update openai -g openshell --credential …` rotates the
  credential later (bumps the provider resource version).

## 4. Attach to the running sandbox (laptop — no recreate needed)

```bash
openshell sandbox provider attach openclaw openai -g openshell --wait
```

The sandbox applies it dynamically; `--wait` confirms:

```
credentials_installed: true
launch_environment_installed: true
policy_active: true
```

Verify: `openshell sandbox provider status openclaw openai -g openshell` →
`ready`; inside the VM, `env` shows
`OPENAI_API_KEY=openshell://resolve/…` — a **workspace-level reference, never
the real key**. Note the injection is for **future processes**: processes that
started before the attach (e.g. the boot-time gateway) do not gain the env var.

The dashboard's Providers tab does the same via the
"Select a provider to attach" dropdown → **Attach**.

## 5. Point openclaw at MaaS (inside the sandbox)

All of these are dynamic — "Change will apply without restarting the gateway".

```bash
# 5a. Base URL
openshell sandbox exec openclaw -- openclaw config set models.providers.openai.baseUrl https://maas.apps.ocp.cloud.rhai-tmm.dev/v1

# 5b. Register the model entry (manual — the hosted catalog is unreachable, see gotchas)
openshell sandbox exec openclaw -- sh -c 'echo "{\"models\":{\"providers\":{\"openai\":{\"models\":[{\"id\":\"publishers/prelude-maas/models/glm-53-flash\",\"name\":\"GLM 5.3 Flash\"}]}}}}" | openclaw config patch --stdin'

# 5c. Default model
openshell sandbox exec openclaw -- openclaw models set openai/publishers/prelude-maas/models/glm-53-flash
```

## 6. Wire the credential — the key insight

Store the **placeholder itself**, expanded from the injected env:

```bash
openshell sandbox exec openclaw -- sh -c 'openclaw config set models.providers.openai.apiKey "$OPENAI_API_KEY"'
```

Why this works (docs/how-it-works/providers/overview.mdx in the OpenShell
source): the agent process never sees real credentials — OpenShell replaces
each credential with an **opaque placeholder token** in the agent's
environment, and the sandbox **proxy resolves recognized placeholders in
`Authorization: Bearer <placeholder>` immediately before forwarding**. The
credential is injected workspace-side on the way out, matching the provider
profile's `auth_style: bearer` / `header_name: Authorization`.

## 7. Test

```bash
openshell sandbox exec openclaw -- openclaw agent -m 'Reply with exactly one word: pong' --json
# → "ok": true, "text": "pong"
```

Then from the Control UI: pick **GLM 5.3 Flash** in the model selector and send
a message.

## Gotchas (don't repeat)

| Attempt | Result |
|---|---|
| `apiKey` as SecretRef `--ref-provider default --ref-source env --ref-id OPENAI_API_KEY` | ❌ `secret reference was not found` — "default" is not a configured secrets provider, and the boot-time gateway process predates the attach so its env lacks the variable |
| Dummy key `sk-dummy-…` as apiKey | ❌ MaaS **HTTP 401** — not a recognized placeholder; forwarded as-is to the upstream |
| **Placeholder from `$OPENAI_API_KEY`** | ✅ proxy resolves it — the documented mechanism |
| `openclaw models refresh` | ❌ blocked — `catalog.openclaw.ai` resolves to a DNS-relay private IP and is not in the policy (default-deny working); register model entries manually via `config patch` |
| `openclaw models scan` | ❌ OpenRouter-specific; also policy-blocked |
| `openshell inference set` | ❌ no such subcommand in this CLI version |

## Gateway TLS migration (2026-10-10) — the KEK rotation cascade

The gateway now serves TLS behind the OpenShift Gateway API (see the plan file
task 8 for the full topology). Any **helm upgrade re-runs pkiInitJob, which
regenerates the credential-storage KEK** — three stale-encryption failures
cascade, in this order:

1. **The sandbox's default credential storage** (gateway DB
   `credential.gateway-encrypted`): the supervisor's startup fails with
   "encrypted with a different key-encryption key" → the phase sticks at
   Starting. Fix: delete the stale row from the gateway's `openshell.db`
   `objects` table — the runtime re-initializes its store with the new KEK.
2. **The provider's stored credential**: the delivery goes
   `credentials_withheld` (no `OPENAI_API_KEY` in the sandbox). Fix:
   `sandbox provider detach` → `provider delete` → `provider create` →
   re-attach — re-encrypted with the new KEK.
3. **The CLI's stale mTLS materials**: `~/.config/openshell/gateways/<gw>/mtls/`
   (the old chart CA) makes the OIDC path trust the chart CA →
   "invalid peer certificate: UnknownIssuer" against the edge's Let's Encrypt
   cert (curl verifies fine). Fix: archive the `mtls/` dir — the CLI falls
   through to native/enabled roots → Connected.

Also: a deleted credential object is referenced **by ID** in the supervisor's
config — re-attach the provider after deleting to re-store it. And a recreated
sandbox needs the FULL re-configuration (steps 5–7 below + the origin
one-liner + the expose).

## Flipping MaaS to enforce (audit → enforce)

The endpoint starts `enforcement: audit` (records, does not block). The audit
trail that justifies the flip is the sandbox proxy's OCSF output
(`openshell logs openclaw`):

```
NET:OPEN  ALLOWED /usr/bin/node-26(0) -> maas.apps.ocp.cloud.rhai-tmm.dev:443  [policy:_provider_openai engine:opa]
HTTP:POST ALLOWED POST .../v1/chat/completions                                 [policy:_provider_openai engine:l7]
```

The flip flow — with three gotchas:

1. **`profile update` requires the current `resource_version`** — export first,
   edit the export, then update:
   ```bash
   openshell profile export openai -o yaml -g openshell > openai-export.yaml
   # edit: enforcement: audit -> enforce
   openshell profile update --file openai-export.yaml openai -g openshell
   ```
2. **Endpoint ambiguity**: the sandbox policy's own MaaS endpoint(s) (authored
   YAML `maas` + any `policy update --add-endpoint` copies) overlap the
   provider profile's `_provider_openai` endpoint — conflicting `enforcement`
   values fail the ambiguity validation. Remove the policy-owned copies first:
   ```bash
   openshell policy update openclaw -g openshell --remove-endpoint "maas.apps.ocp.cloud.rhai-tmm.dev:443"
   ```
   Keep the authored sandbox policy free of a `maas` endpoint — the provider
   profile owns MaaS egress (see the comment in `sandbox-policy/openclaw.yaml`).
3. **`binaries: []` means NO binary is allowed in enforce mode.** Once the
   policy enforces, every call fails with
   `binary '/usr/bin/node-26' not allowed in policy '_provider_openai'`
   until the profile lists the binaries. Use the **kernel-resolved** path
   (`readlink -f /usr/bin/node` → `/usr/bin/node-26`):
   ```yaml
   binaries:
     - /usr/bin/node
     - /usr/bin/node-26
   ```

Verified end state: `ALLOWED /usr/bin/node-26(0) -> maas.apps…:443
[policy:_provider_openai engine:opa]` + L7 POST allowed, in **enforce**, agent
turns still succeed.

## Proposals (advisor-proposed rules)

Blocked requests surface advisor-proposed rules in the dashboard's Proposals
tab (view-only) with confidence scores. Approve/deny is **CLI-only** in this
version:

```bash
# list pending proposals (chunk ids + rules)
openshell rule get openclaw -g openshell --status pending

# deny with a reason (the reason surfaces in the audit/risk flow)
openshell rule reject openclaw -g openshell --chunk-id <chunk-id> --reason "Demo beat: default-deny — least privilege"

# other commands: rule approve / approve-all / clear / history
```

Demo outcome (2026-10-09): all 5 advisor proposals denied with reasons —
`allow_example_com_443` (default-deny beat), `allow_telemetry_openclaw_ai_443`
(telemetry egress), `allow_clawhub_ai_443` + `allow_openrouter_ai_443`
(unused services), `allow_api_github_com_443` (redundant — the authored policy
already allows `api.github.com:443` rest read-only enforce). MaaS access comes
from the provider profile, not a proposal.

## Task-3 validated flow: clone + advice (2026-10-09)

Web-console prompts + CLI checks (all passed):

1. Prompt: "Clone https://github.com/octocat/Hello-World into
   /sandbox/.openclaw/workspace/hello-world, then list the files."
   - The agent hit `SSL verification (self-signed cert in chain)` and
     **auto-fixed**: retried with `http.sslVerify=false` and completed.
     Expected behavior — the proxy terminates all transparent TLS (how the L7
     engine inspects) and re-signs with its own CA, which the guest does not
     trust. No proxy CA is exposed in the VM (`/etc/openshell/` has no CA
     file), so per-clone `sslVerify=false` is the practical path today;
     trusting the proxy CA in the sandbox image is the proper follow-up.
   - Checks: `openshell logs openclaw | grep github.com` (git → github.com:443
     L4 allowed), clone present in the workspace,
     `rule get --status pending` stayed empty (github is policy-allowed).
2. Prompt: "Read the README file in the hello-world repo and give me two
   concrete improvements as coding advice."
   - Checks: `openshell logs openclaw | grep maas.apps` (node-26 → MaaS ALLOWED
     in enforce + L7 POST), `openclaw audit` rows succeeded.



