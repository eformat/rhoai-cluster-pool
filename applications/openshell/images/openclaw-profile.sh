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
# The invocation matches the proven CLI create override exactly
# (sh -c 'openclaw onboard ... || true; exec openclaw gateway run'),
# backgrounded as a subshell so the login-shell prompt is not blocked, with
# output to a workspace log for debugging.

if [ -f /tmp/openclaw-gateway.pid ] \
   && kill -0 "$(cat /tmp/openclaw-gateway.pid 2>/dev/null)" 2>/dev/null; then
  return 0 2>/dev/null || exit 0
fi

__openclaw_home="${HOME:-/sandbox}"
mkdir -p "$__openclaw_home/.openclaw" 2>/dev/null

( openclaw onboard --non-interactive --accept-risk --skip-health || true
  exec openclaw gateway run ) >>"$__openclaw_home/.openclaw/gateway.log" 2>&1 &

echo $! > /tmp/openclaw-gateway.pid 2>/dev/null
unset __openclaw_home
