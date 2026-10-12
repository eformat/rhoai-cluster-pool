# Start the openclaw gateway for OpenShell sandbox main-process sessions.
#
# Installed as /etc/profile.d/openshell-openclaw.sh in the
# quay.io/eformat/openshell-openclaw image.
#
# WHY: OpenShell sandboxes created without a command override (e.g. from the
# dashboard's Create sandbox modal) run an interactive login shell as the
# canonical main process — the workload image CMD/Entrypoint is never
# consulted (MainProcessConfig::scratch resolves a login shell via
# resolve_agent_spec). A login shell sources this file (bash -l reads
# /etc/profile.d/), so starting the gateway here makes UI-provisioned
# sandboxes serve the openclaw dashboard without any CLI override.
#
# GUARD: later login shells (exec/TUI sessions) source this file too; skip
# when the gateway is already running (pidfile + kill -0 — no procps
# dependency). If the gateway died, the next login shell starts a fresh one.
# The main process writes the pidfile at provision time, before any exec
# session, so exec sessions always see it alive and skip.
#
# CONFIG PATCH (0.1.5): before the gateway starts, ensure
# gateway.trustedProxies is set in the workspace openclaw.json. The OpenShell
# service relay delivers proxied requests (OpenShift router -> gateway ->
# supervisor relay) with a loopback peer inside the VM; openclaw rejects
# forwarded headers from untrusted peers ("Proxy client attribution is
# required"). The relay peer is always 127.0.0.1, so the value is universal.
# Only set when absent so a user-customized value wins. JSON-safe via node
# (present in the image); skips silently when node or the config is missing
# (onboard creates the config). The patch runs AFTER onboard so a regenerated
# config is still patched.
#
# The invocation matches the proven CLI create override exactly
# (sh -c 'openclaw onboard ... || true; exec openclaw gateway run'),
# backgrounded as a subshell so the login-shell prompt is not blocked, with
# output to a workspace log for debugging. gateway.controlUi.allowedOrigins
# remains a per-sandbox manual step (the service URL varies with
# workspace/sandbox name) — one-liner in the image README.

# Ensure gateway.trustedProxies in the workspace openclaw config.
__openclaw_patch_config() {
  command -v node >/dev/null 2>&1 || return 0
  [ -f "$__openclaw_home/.openclaw/openclaw.json" ] || return 0
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    let d;
    try { d = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { process.exit(0); }
    if (!d.gateway || typeof d.gateway !== "object") d.gateway = {};
    if (!Array.isArray(d.gateway.trustedProxies)) d.gateway.trustedProxies = ["127.0.0.1", "::1"];
    try { fs.writeFileSync(p, JSON.stringify(d, null, 2)); } catch (e) {}
  ' "$__openclaw_home/.openclaw/openclaw.json"
}

if [ -f /tmp/openclaw-gateway.pid ] \
   && kill -0 "$(cat /tmp/openclaw-gateway.pid 2>/dev/null)" 2>/dev/null; then
  return 0 2>/dev/null || exit 0
fi

__openclaw_home="${HOME:-/sandbox}"
mkdir -p "$__openclaw_home/.openclaw" 2>/dev/null

( openclaw onboard --non-interactive --accept-risk --skip-health || true
  __openclaw_patch_config
  exec openclaw gateway run ) >>"$__openclaw_home/.openclaw/gateway.log" 2>&1 &

echo $! > /tmp/openclaw-gateway.pid 2>/dev/null
unset __openclaw_home
