#!/usr/bin/env bash
#
# Install RHCL 1.4 MCP Gateway on OpenShift (for RHOAI 3.5 testing)
# Based on: Red Hat Connectivity Link 1.4 — Install the MCP gateway
#
set -euo pipefail

MCP_SYSTEM="${MCP_SYSTEM:-mcp-system}"
GATEWAY_NS="${GATEWAY_NS:-gateway-system}"
GATEWAY_PUBLIC_HOST="${GATEWAY_PUBLIC_HOST:-}"
GATEWAY_CLASS="${GATEWAY_CLASS:-}"

if [[ -z "$GATEWAY_PUBLIC_HOST" ]]; then
  echo "==> GATEWAY_PUBLIC_HOST not set — auto-detecting from cluster DNS config..."
  BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
  if [[ -z "$BASE_DOMAIN" ]]; then
    echo "ERROR: Could not determine cluster base domain via 'oc get dns cluster'."
    echo "  Set it manually: export GATEWAY_PUBLIC_HOST=mcp.apps.<baseDomain>"
    exit 1
  fi
  GATEWAY_PUBLIC_HOST="mcp.apps.${BASE_DOMAIN}"
  echo "==> Auto-detected GATEWAY_PUBLIC_HOST=$GATEWAY_PUBLIC_HOST"
fi

if [[ -z "$GATEWAY_CLASS" ]]; then
  echo "==> GATEWAY_CLASS not set — auto-detecting an Accepted GatewayClass..."
  for gc in $(oc get gatewayclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    if [[ "$(oc get gatewayclass "$gc" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')" == "True" ]]; then
      GATEWAY_CLASS="$gc"
      break
    fi
  done
  if [[ -z "$GATEWAY_CLASS" ]]; then
    echo "ERROR: No Accepted GatewayClass found. Set it manually: export GATEWAY_CLASS=<gatewayClassName>"
    exit 1
  fi
  echo "==> Auto-detected GATEWAY_CLASS=$GATEWAY_CLASS"
fi

echo "==> Using MCP_SYSTEM=$MCP_SYSTEM  GATEWAY_NS=$GATEWAY_NS  GATEWAY_CLASS=$GATEWAY_CLASS  GATEWAY_PUBLIC_HOST=$GATEWAY_PUBLIC_HOST"

# ── Step 1: Create namespaces ──
echo "==> Creating namespaces..."
oc create ns "$MCP_SYSTEM" --dry-run=client -o yaml | oc apply -f -
oc create ns "$GATEWAY_NS" --dry-run=client -o yaml | oc apply -f -

# ── Step 2: Install MCP Gateway operator via OLM ──
echo "==> Creating Subscription and OperatorGroup..."
oc apply -n "$MCP_SYSTEM" -f 01-subscription.yaml

echo "==> Waiting for Subscription installPlan..."
oc wait --for=jsonpath='{.status.installPlanRef.name}' subscription mcp-gateway -n "$MCP_SYSTEM" --timeout=120s

ip=$(oc get subscription mcp-gateway -n "$MCP_SYSTEM" -o jsonpath='{.status.installPlanRef.name}')
echo "==> Waiting for InstallPlan $ip to complete..."
oc wait --for=condition=Installed installplan -n "$MCP_SYSTEM" "$ip" --timeout=120s

echo "==> Waiting for CSV to succeed..."
oc wait csv -n "$MCP_SYSTEM" -l operators.coreos.com/mcp-gateway."$MCP_SYSTEM"="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s || true

# ── Step 3: Create Gateway ──
echo "==> Creating Gateway (class=$GATEWAY_CLASS)..."
sed "s|<GATEWAY_CLASS>|${GATEWAY_CLASS}|g" 02-gateway.yaml | oc apply -f -

echo "==> Waiting for Gateway to be Accepted..."
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True gateway mcp-gateway -n "$GATEWAY_NS" --timeout=120s || \
  echo "WARNING: Gateway not Accepted yet — check 'oc describe gateway mcp-gateway -n $GATEWAY_NS'"

# The gateway controller creates the Service <gateway-name>-<gatewayclass-name>.
GW_SVC="mcp-gateway-${GATEWAY_CLASS}"
echo "==> Waiting for gateway Service ${GW_SVC}..."
oc wait --for=jsonpath='{.spec.clusterIP}' service "$GW_SVC" -n "$GATEWAY_NS" --timeout=120s

# No LoadBalancer provider on this cluster — expose the gateway Service (ClusterIP)
# via an OpenShift Route, same as the MaaS gateway ClusterIP mode, then patch the
# Service's LoadBalancer status so the gateway controller records the external
# hostname in gateway.status.addresses.
echo "==> Creating Route for external access..."
sed "s|<GATEWAY_PUBLIC_HOST>|${GATEWAY_PUBLIC_HOST}|g" 08-gateway-route.yaml | oc apply -f -

echo "==> Patching gateway Service LoadBalancer status with the Route hostname..."
oc patch service "$GW_SVC" -n "$GATEWAY_NS" --subresource=status --type=merge \
  -p "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"hostname\":\"${GATEWAY_PUBLIC_HOST}\"}]}}}"

# ── Step 4: ReferenceGrant (cross-namespace) ──
echo "==> Creating ReferenceGrant..."
oc apply -f 03-reference-grant.yaml

# ── Step 5: MCPGatewayExtension ──
echo "==> Creating MCPGatewayExtension (publicHost=$GATEWAY_PUBLIC_HOST)..."
sed "s|<GATEWAY_PUBLIC_HOST>|${GATEWAY_PUBLIC_HOST}|g" 04-mcp-gateway-extension.yaml | oc apply -f -

echo "==> Waiting for MCPGatewayExtension to be ready..."
oc wait --for=condition=Ready mcpgatewayextension/mcp-gateway-extension -n "$MCP_SYSTEM" --timeout=120s || \
  echo "WARNING: MCPGatewayExtension not Ready yet — check 'oc describe mcpgatewayextension mcp-gateway-extension -n $MCP_SYSTEM'"

# ── Step 6: Verify ──
echo ""
echo "==> Verification"
echo "--- HTTPRoute ---"
oc get httproute -n "$MCP_SYSTEM" || true
echo ""
echo "--- EnvoyFilter ---"
oc get envoyfilter -n "$GATEWAY_NS" -l app.kubernetes.io/managed-by=mcp-gateway-controller 2>/dev/null || true
echo ""
echo "--- Gateway status ---"
oc get gateway mcp-gateway -n "$GATEWAY_NS" -o yaml | grep -A 20 "^status:" || true
echo ""
echo "--- External Route ---"
oc get route mcp-gateway-external -n "$GATEWAY_NS" || true

echo ""
echo "==> MCP Gateway install complete."
echo "    To deploy a test MCP server:"
echo "      oc apply -f 05-test-namespace.yaml -f 06-test-configmap.yaml -f 07-test-mcp-server.yaml"
echo ""
echo "    To verify the MCP endpoint:"
echo "      curl -v http://${GATEWAY_PUBLIC_HOST}/mcp"
