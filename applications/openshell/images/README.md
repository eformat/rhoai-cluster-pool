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
podman build -f Dockerfile.openclaw-fix -t quay.io/eformat/openshell-openclaw:0.1.2 .
podman push quay.io/eformat/openshell-openclaw:0.1.2   # then make public on quay
```

Use `quay.io/eformat/openshell-openclaw:0.1.2` as the sandbox workload image
in the dashboard's Create sandbox modal.

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
`custom-0.1.2-deadline` branch of `/home/mike/git/OpenShell`:

```bash
cd /home/mike/git/OpenShell   # branch custom-0.1.2-deadline
cargo build --release --target x86_64-unknown-linux-musl -p openshell-sandbox
install -Dm0755 target/x86_64-unknown-linux-musl/release/openshell-sandbox \
    deploy/docker/.build/prebuilt-binaries/amd64/openshell-sandbox
podman build --platform linux/amd64 -f deploy/docker/Dockerfile.sandbox \
    -t quay.io/eformat/openshell-sandbox:0.1.2 .
podman push quay.io/eformat/openshell-sandbox:0.1.2   # then make public on quay
```

## Gateway image (0.1.2 + deadline patches)

Same tree, glibc build with staged libs (see
`/home/mike/git/OpenShell/deploy/docker/Dockerfile.gateway-patched`):

```bash
cd /home/mike/git/OpenShell   # branch custom-0.1.2-deadline
cargo build --release -p openshell-gateway
cp target/release/openshell-gateway deploy/docker/.build/prebuilt-binaries/amd64/
podman build -f deploy/docker/Dockerfile.gateway-patched \
    -t quay.io/eformat/openshell-gateway:0.1.2-deadline.2 .
podman push quay.io/eformat/openshell-gateway:0.1.2-deadline.2
```

Requires `deploy/docker/.build/libs/{libz3.so.4.16,libgmp.so.10}` (committed in
the OpenShell repo) — the gateway binary links z3 4.16 while the base image's
Fedora snapshot ships 4.15.
