#!/usr/bin/env bash
# keycloak-setup.sh
# Configures the Keycloak coverline realm: clients, groups, GitHub IdP.
# Stores client secrets in Vault at secret/data/coverline/keycloak.
#
# Prerequisites:
#   - KEYCLOAK_URL exported (e.g. http://localhost:8080)
#   - KEYCLOAK_ADMIN_PASSWORD exported
#   - VAULT_ADDR and VAULT_TOKEN exported (Phase 3)
#   - kcadm.sh on PATH (ships with Keycloak — or use kubectl exec)
#   - GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET exported (GitHub OAuth App)

set -euo pipefail

REALM="coverline"
KEYCLOAK_URL="${KEYCLOAK_URL:?set KEYCLOAK_URL}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD}"
GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:?set GITHUB_CLIENT_ID}"
GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:?set GITHUB_CLIENT_SECRET}"

echo "==> Authenticating to Keycloak"
kcadm.sh config credentials \
  --server "$KEYCLOAK_URL" \
  --realm master \
  --user admin \
  --password "$KEYCLOAK_ADMIN_PASSWORD"

echo "==> Creating realm: $REALM"
kcadm.sh create realms \
  -s realm="$REALM" \
  -s enabled=true \
  -s displayName="CoverLine Platform" \
  -s registrationAllowed=false \
  -s resetPasswordAllowed=false 2>/dev/null || echo "  realm already exists, skipping"

echo "==> Creating groups"
for group in platform-admin developer viewer; do
  kcadm.sh create groups -r "$REALM" -s name="$group" 2>/dev/null || echo "  group $group already exists"
done

echo "==> Creating ArgoCD client"
ARGOCD_SECRET=$(openssl rand -base64 32)
kcadm.sh create clients -r "$REALM" \
  -s clientId=argocd \
  -s name="ArgoCD" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s secret="$ARGOCD_SECRET" \
  -s 'redirectUris=["https://argocd.coverline.internal/auth/callback"]' \
  -s 'webOrigins=["https://argocd.coverline.internal"]' \
  -s 'defaultClientScopes=["openid","email","profile","groups"]' 2>/dev/null || echo "  argocd client already exists"

echo "==> Creating Grafana client"
GRAFANA_SECRET=$(openssl rand -base64 32)
kcadm.sh create clients -r "$REALM" \
  -s clientId=grafana \
  -s name="Grafana" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s secret="$GRAFANA_SECRET" \
  -s 'redirectUris=["https://grafana.coverline.internal/login/generic_oauth"]' \
  -s 'webOrigins=["https://grafana.coverline.internal"]' \
  -s 'defaultClientScopes=["openid","email","profile","groups"]' 2>/dev/null || echo "  grafana client already exists"

echo "==> Adding groups scope mapper to realm"
# Add a groups claim so ArgoCD and Grafana can read group membership
kcadm.sh create client-scopes -r "$REALM" \
  -s name=groups \
  -s protocol=openid-connect \
  -s 'attributes={"include.in.token.scope":"true"}' 2>/dev/null || echo "  groups scope already exists"

GROUPS_SCOPE_ID=$(kcadm.sh get client-scopes -r "$REALM" --fields id,name \
  | python3 -c "import sys,json; [print(s['id']) for s in json.load(sys.stdin) if s['name']=='groups']")

kcadm.sh create client-scopes/"$GROUPS_SCOPE_ID"/protocol-mappers/models -r "$REALM" \
  -s name=groups \
  -s protocol=openid-connect \
  -s protocolMapper=oidc-group-membership-mapper \
  -s 'config={"full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","claim.name":"groups"}' \
  2>/dev/null || echo "  groups mapper already exists"

echo "==> Configuring GitHub as identity provider"
kcadm.sh create identity-provider/instances -r "$REALM" \
  -s alias=github \
  -s providerId=github \
  -s enabled=true \
  -s 'config.clientId='"$GITHUB_CLIENT_ID" \
  -s 'config.clientSecret='"$GITHUB_CLIENT_SECRET" \
  -s 'config.defaultScope=user:email read:org' \
  -s 'config.syncMode=FORCE' \
  2>/dev/null || echo "  GitHub IdP already exists"

echo "==> Storing client secrets in Vault"
vault kv put secret/coverline/keycloak \
  argocd_client_secret="$ARGOCD_SECRET" \
  grafana_client_secret="$GRAFANA_SECRET" \
  admin_password="$KEYCLOAK_ADMIN_PASSWORD"

echo ""
echo "==> Done. Client secrets stored in Vault at secret/data/coverline/keycloak"
echo ""
echo "Next steps:"
echo "  1. Create K8s secret for ArgoCD OIDC:"
echo "     kubectl create secret generic argocd-oidc-secret \\"
echo "       --from-literal=oidc.keycloak.clientSecret=\$ARGOCD_SECRET -n argocd"
echo ""
echo "  2. Upgrade ArgoCD with OIDC values:"
echo "     helm upgrade argocd argo/argo-cd -n argocd -f phase-7b-iam/argocd-oidc-values.yaml"
echo ""
echo "  3. Upgrade Grafana with OIDC values:"
echo "     helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \\"
echo "       -n monitoring -f phase-7b-iam/grafana-oidc-values.yaml"
