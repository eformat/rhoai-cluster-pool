# Container images (openshell / coco sandbox integration)

Locally-built container images for the openshell CoCo sandbox demo. These are
NOT rebuilt by CI — build and push by hand when needed.

## `Dockerfile.openclaw-fix`

Derivative of the aipcc openclaw agent image with `/sandbox` made
world-readable (`chmod -R a+rX`) so the OpenShell `seed-workspace` init
container (running as the pod's SCC-assigned UID 1000860000) can copy the
workdir into the workspace PVC. See the Dockerfile header for the full
failure signature.

```bash
podman build -f Dockerfile.openclaw-fix -t quay.io/eformat/openshell-openclaw:0.1.5 .
podman push quay.io/eformat/openshell-openclaw:0.1.5   # then make public on quay
```

Use `quay.io/eformat/openshell-openclaw:0.1.5` as the sandbox workload image.
The image CMD is NOT used as the sandbox main process — OpenShell runs the
supervisor runtime as the pod command, and an empty CreateSandbox command
override resolves to a login shell (`bash -l`), never the image CMD. 0.1.5
installs `/etc/profile.d/openshell-openclaw.sh` (from `openclaw-profile.sh`),
which the login-shell main process sources at startup: it patches
`gateway.trustedProxies=["127.0.0.1","::1"]` into the workspace openclaw.json
(after onboard, only when absent), then starts the openclaw gateway (guarded
by a pidfile so exec/TUI sessions never double-start it). The dashboard's
Create sandbox modal therefore works with no command override (0.1.5+), given
the sandbox policy is attached at create time; the CLI `--` override remains
the explicit alternative:

```bash
openshell sandbox create --name <name> --from quay.io/eformat/openshell-openclaw:0.1.5 -- \
  sh -c 'openclaw onboard --non-interactive --accept-risk --skip-health || true; exec openclaw gateway run'
```

Per-sandbox manual step (the service URL varies with workspace/sandbox name):
set `gateway.controlUi.allowedOrigins` to the service URL origin via a node
one-liner in an exec session — picked up dynamically, no restart. The sandbox
policy (`../sandbox-policy/openclaw.yaml`) must be attached at create time,
else Landlock denies `/opt/openclaw` ("Permission denied" in
`/sandbox/.openclaw/gateway.log`).

Verify after provisioning: `curl https://<workspace>--<sandbox>--<service>.<domain>/`
must return the openclaw control UI (HTTP 200), not 502 "Service endpoint is
not reachable". The gateway log lands in
`/sandbox/.openclaw/gateway.log` inside the sandbox.

Upstream note: the aipcc base image should ship `/sandbox` world-readable
(the community `ghcr.io/nvidia/openshell-community/sandboxes/base` does) —
the chmod is only needed until that is fixed upstream.

## Sandbox RUNTIME image (openshell-sandbox 0.1.2)

The gateway's driver stages the sandbox runtime into every VM from
`sandbox_runtime_image` (pinned via `sandboxRuntime.image` in
`applications/openshell/overlay/gateway/values.yaml` to
`quay.io/eformat/openshell-sandbox:0.1.2`). No official runtime image matches
the 0.1.2 supervisor protocol (all published tags were built 2026-09-11..13,
predating the confirmation refactor), so it is built from the
`custom-0.1.2-deadline` branch of `~/git/OpenShell`:

```bash
cd ~/git/OpenShell   # branch custom-0.1.2-deadline
cargo build --release --target x86_64-unknown-linux-musl -p openshell-sandbox
install -Dm0755 target/x86_64-unknown-linux-musl/release/openshell-sandbox \
    deploy/docker/.build/prebuilt-binaries/amd64/openshell-sandbox
podman build --platform linux/amd64 -f deploy/docker/Dockerfile.sandbox \
    -t quay.io/eformat/openshell-sandbox:0.1.2 .
podman push quay.io/eformat/openshell-sandbox:0.1.2   # then make public on quay
```

## Gateway image (0.1.2 + deadline patches)

Same tree, glibc build with staged libs (see
`~/git/OpenShell/deploy/docker/Dockerfile.gateway-patched`):

```bash
cd ~/git/OpenShell   # branch custom-0.1.2-deadline
cargo build --release -p openshell-gateway
cp target/release/openshell-gateway deploy/docker/.build/prebuilt-binaries/amd64/
podman build -f deploy/docker/Dockerfile.gateway-patched \
    -t quay.io/eformat/openshell-gateway:0.1.2-deadline.2 .
podman push quay.io/eformat/openshell-gateway:0.1.2-deadline.2
```

Requires `deploy/docker/.build/libs/{libz3.so.4.16,libgmp.so.10}` (committed in
the OpenShell repo) — the gateway binary links z3 4.16 while the base image's
Fedora snapshot ships 4.15.

## Supervisor image (0.1.2 + attach-timeout window)

The per-sandbox control-plane pod. The official
`ghcr.io/nvidia/openshell/supervisor:0.1.2` hard-codes a 5-minute attach
timeout (`ATTACH_REQUEST_TIMEOUT`,
`crates/openshell-sandbox-backend/src/runtime.rs`): a CoCo pod VM takes ~5 min
to provision (CVM boot + workspace seed + agent start), which consumes the
supervisor's whole wait window — it exits with "boundary idempotent control
request timed out" 3 seconds BEFORE the boundary comes up, and the gateway
then marks the sandbox Ready from the workload pod phase alone (the CR says
Ready but the boundary is dead).

Paired with the runtime.rs change that makes the timeout env-overridable
(`OPENSHELL_ATTACH_REQUEST_TIMEOUT_MS`, default stays 5 min — mirroring the
gateway's `OPENSHELL_PROVISIONING_REPAIR_WINDOW_MS` pattern); this image bakes
900000 (15 min, matching the gateway's `provisioningRepairWindowMs`
chart value). The driver's fixed supervisor pod env list does not set that
var, so the image ENV reaches the supervisor — no driver change or gateway
rebuild needed.

```bash
cd ~/git/OpenShell   # branch custom-0.1.2-deadline (runtime.rs change committed)
Z3_SYS_Z3_HEADER=/usr/include/z3/z3.h cargo build --release --target x86_64-unknown-linux-musl -p openshell-supervisor
cp target/x86_64-unknown-linux-musl/release/openshell-supervisor deploy/docker/.build/prebuilt-binaries/amd64/

# context = the OpenShell repo root (the COPY path is relative to it)
podman build -f ~/git/rhoai-cluster-pool/applications/openshell/images/Dockerfile.supervisor \
    --platform linux/amd64 -t quay.io/eformat/openshell-supervisor:0.1.2-t15 .
podman push quay.io/eformat/openshell-supervisor:0.1.2-t15   # then make public on quay
```

Used via `supervisor.image` in
`applications/openshell/overlay/gateway/values.yaml`.

Upstream note: the attach timeout should be env-overridable in the official
supervisor (same treatment as the gateway's repair window) — file upstream
once verified.
