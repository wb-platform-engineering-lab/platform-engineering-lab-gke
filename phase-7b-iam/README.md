# Phase 7b — Identity & Access Management (Keycloak SSO)

> **IAM concepts introduced:** Keycloak, OIDC, Realms, Clients, Identity Federation, Group-based RBAC | **Builds on:** Phase 6 ArgoCD, Phase 7 Observability, Phase 3 Vault

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Keycloak** | Open-source Identity and Access Management server | Single source of truth for all platform identities — one login for every tool |
| **Realm** | Isolated identity namespace within Keycloak | Separates CoverLine platform users from Keycloak's own admin users |
| **OIDC client** | A registered application that delegates auth to Keycloak | ArgoCD and Grafana trust Keycloak tokens instead of managing their own users |
| **Identity federation** | Keycloak delegates upstream auth to GitHub | Engineers log in with their GitHub account — no new password to manage |
| **Group-based RBAC** | Keycloak groups map to roles in downstream tools | One group assignment controls access across ArgoCD, Grafana, and future tools |
| **Client secrets in Vault** | OIDC client secrets stored in Phase 3 Vault | No plaintext credentials in Helm values or Kubernetes ConfigMaps |

---

## The problem

> *CoverLine — 75,000 members. November.*
>
> The security audit found fourteen shared credentials. ArgoCD had a single admin password stored in a team Notion doc. Grafana had `admin/admin` on the monitoring cluster — the default had never been changed. Two contractors who left six months ago still had active sessions in both tools.
>
> When the lead platform engineer left to join another company, the team spent an afternoon manually rotating passwords across every tool. There was no central record of who had access to what. There was no audit log of who had done what.
>
> The CISO wrote one line in the incident report: *"We have twelve tools and twelve separate user databases. This is not a security posture. This is chaos."*

The decision: a single identity provider. Keycloak sits in the middle — GitHub authenticates the engineer, Keycloak issues the token, every tool trusts Keycloak. One offboarding action revokes access everywhere.

---

## Architecture

```
Engineer opens ArgoCD or Grafana
    │
    └── Redirected to Keycloak (coverline realm)
            │
            └── Keycloak redirects to GitHub OAuth
                    │
                    └── Engineer logs in with GitHub account
                            │
                            └── GitHub returns identity to Keycloak
                                    │
                                    └── Keycloak issues OIDC token with group claims
                                            │
                                            ├── ArgoCD validates token → maps /platform-admin → role:admin
                                            └── Grafana validates token → maps /platform-admin → Admin role

Keycloak groups:
  /platform-admin  → ArgoCD: role:admin    | Grafana: Admin
  /developer       → ArgoCD: role:readonly | Grafana: Editor
  /viewer          → ArgoCD: role:readonly | Grafana: Viewer

Secrets flow:
  keycloak-setup.sh generates client secrets
      └── vault kv put secret/coverline/keycloak argocd_client_secret=... grafana_client_secret=...
              └── kubectl create secret from vault → K8s Secret
                      └── ArgoCD / Grafana Helm values reference K8s Secret
```

---

## Repository structure

```
phase-7b-iam/
├── keycloak-values.yaml       ← Bitnami Keycloak Helm values
├── keycloak-setup.sh          ← Creates realm, clients, groups, GitHub IdP + stores secrets in Vault
├── argocd-oidc-values.yaml    ← ArgoCD Helm values: direct OIDC to Keycloak + RBAC policy
└── grafana-oidc-values.yaml   ← Grafana values: generic_oauth pointing to Keycloak
```

---

## Prerequisites

- Phase 3 Vault running (`VAULT_ADDR` and `VAULT_TOKEN` exported)
- Phase 6 ArgoCD installed in the `argocd` namespace
- Phase 7 kube-prometheus-stack installed in the `monitoring` namespace
- PostgreSQL running (Phase 4) — Keycloak will use it as its database
- A GitHub OAuth App created at https://github.com/settings/developers:
  - Homepage URL: `http://keycloak.coverline.internal`
  - Callback URL: `http://keycloak.coverline.internal/realms/coverline/broker/github/endpoint`
- `kcadm.sh` available (download Keycloak locally, or `kubectl exec` into the Keycloak pod)

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
kubectl create namespace keycloak
```

---

## Challenge 1 — Provision the Keycloak database

Keycloak needs a dedicated PostgreSQL database. The existing PostgreSQL StatefulSet (Phase 4) can host it.

### Step 1: Create the keycloak database

```bash
kubectl exec -it postgresql-0 -- psql -U coverline -c "CREATE DATABASE keycloak;"
```

### Step 2: Verify

```bash
kubectl exec -it postgresql-0 -- psql -U coverline -c "\l"
```

Expected: `keycloak` listed alongside `coverline`.

---

## Challenge 2 — Deploy Keycloak

### Step 1: Create the admin password secret from Vault

```bash
# Generate and store admin password in Vault
KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -base64 24)
vault kv put secret/coverline/keycloak admin_password="$KEYCLOAK_ADMIN_PASSWORD"

# Create K8s secret for Keycloak to read at startup
kubectl create secret generic keycloak-admin \
  --from-literal=admin-password="$KEYCLOAK_ADMIN_PASSWORD" \
  -n keycloak
```

### Step 2: Install Keycloak

```bash
helm upgrade --install keycloak bitnami/keycloak \
  --namespace keycloak \
  -f phase-7b-iam/keycloak-values.yaml \
  --set auth.existingSecret=keycloak-admin \
  --set auth.adminUser=admin
```

### Step 3: Wait for Keycloak to be ready

```bash
kubectl rollout status deployment/keycloak -n keycloak
```

### Step 4: Port-forward to verify

```bash
kubectl port-forward svc/keycloak 8080:80 -n keycloak &
curl -s http://localhost:8080/realms/master | jq '.realm'
```

Expected: `"master"`

---

## Challenge 3 — Configure the coverline realm

Run the setup script to create the realm, clients, groups, and GitHub identity provider. Client secrets are generated and stored in Vault automatically.

### Step 1: Export environment variables

```bash
export KEYCLOAK_URL=http://localhost:8080
export KEYCLOAK_ADMIN_PASSWORD=$(vault kv get -field=admin_password secret/coverline/keycloak)
export GITHUB_CLIENT_ID=<your-github-oauth-app-client-id>
export GITHUB_CLIENT_SECRET=<your-github-oauth-app-client-secret>
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=<your-vault-token>
```

### Step 2: Run the setup script

```bash
chmod +x phase-7b-iam/keycloak-setup.sh
bash phase-7b-iam/keycloak-setup.sh
```

The script creates:
- Realm `coverline`
- Groups: `/platform-admin`, `/developer`, `/viewer`
- OIDC clients: `argocd`, `grafana` (with generated secrets)
- Groups protocol mapper (adds `groups` claim to tokens)
- GitHub as an identity provider
- Stores `argocd_client_secret` and `grafana_client_secret` in Vault

### Step 3: Assign yourself to the platform-admin group

Open the Keycloak admin console at `http://localhost:8080`:

1. Select realm `coverline`
2. Go to **Users** → find your user (log in with GitHub once to auto-create it)
3. Go to **Groups** tab → join `/platform-admin`

### Step 4: Verify the token contains groups

```bash
# Get a token for testing
TOKEN=$(curl -s -X POST \
  "http://localhost:8080/realms/coverline/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=argocd&client_secret=$(vault kv get -field=argocd_client_secret secret/coverline/keycloak)&username=<your-user>&password=<password>&scope=openid groups" \
  | jq -r '.access_token')

# Decode and inspect the groups claim
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq '.groups'
```

Expected: `["/platform-admin"]`

---

## Challenge 4 — Enable SSO for ArgoCD

### Step 1: Create the OIDC secret in the argocd namespace

```bash
ARGOCD_SECRET=$(vault kv get -field=argocd_client_secret secret/coverline/keycloak)
kubectl create secret generic argocd-oidc-secret \
  --from-literal=oidc.keycloak.clientSecret="$ARGOCD_SECRET" \
  -n argocd
```

### Step 2: Upgrade ArgoCD with OIDC values

```bash
helm upgrade argocd argo/argo-cd \
  -n argocd \
  -f phase-7b-iam/argocd-oidc-values.yaml
```

### Step 3: Restart ArgoCD server

```bash
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd
```

### Step 4: Test SSO login

```bash
kubectl port-forward svc/argocd-server 8443:443 -n argocd &
```

Open `https://localhost:8443` — you should see a "Log in via Keycloak" button alongside the local admin login. Click it, authenticate with GitHub, and verify you land in ArgoCD with admin rights (if your GitHub user is in `/platform-admin`).

### Step 5: Verify RBAC in ArgoCD

```bash
argocd account get-user-info --grpc-web
```

Expected output shows your GitHub email and the `platform-admin` group.

---

## Challenge 5 — Enable SSO for Grafana

### Step 1: Create the OIDC secret in the monitoring namespace

```bash
GRAFANA_SECRET=$(vault kv get -field=grafana_client_secret secret/coverline/keycloak)
kubectl create secret generic grafana-oidc-secret \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="$GRAFANA_SECRET" \
  -n monitoring
```

### Step 2: Upgrade the kube-prometheus-stack

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f phase-7-observability/kube-prometheus-stack-values.yaml \
  -f phase-7b-iam/grafana-oidc-values.yaml
```

### Step 3: Restart Grafana

```bash
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n monitoring
kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring
```

### Step 4: Test SSO login

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &
```

Open `http://localhost:3000` — you should see a "Sign in with Keycloak" button. After GitHub authentication, verify your Grafana role matches your Keycloak group (`/platform-admin` → Admin).

### Step 5: Verify role mapping

In Grafana: go to **Configuration → Users** — your user should show `Admin` role assigned automatically from the groups claim.

---

## Challenge 6 — Offboarding test

The key promise of SSO: one action revokes access everywhere.

### Step 1: Remove a user from a group in Keycloak

In the Keycloak admin console:
1. Go to **Users** → select a test user
2. **Groups** tab → leave `/platform-admin`
3. Add to `/viewer` instead

### Step 2: Verify access changed in ArgoCD

The change takes effect on the next token refresh (default: 5 minutes). To force it immediately:

```bash
# Log out and log back in via SSO
argocd logout localhost:8443
argocd login localhost:8443 --sso
```

The user now has `role:readonly` in ArgoCD — they can view applications but cannot sync or delete.

### Step 3: Verify access changed in Grafana

Log out and log back in. The user now has the `Viewer` role — dashboards are read-only, no edit access.

---

## Teardown

```bash
helm uninstall keycloak -n keycloak
kubectl delete namespace keycloak
kubectl delete secret argocd-oidc-secret -n argocd
kubectl delete secret grafana-oidc-secret -n monitoring

# Revert ArgoCD to local auth
helm upgrade argocd argo/argo-cd -n argocd --reuse-values \
  --set configs.cm."oidc\.config"=""

# Revert Grafana
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f phase-7-observability/kube-prometheus-stack-values.yaml
```

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| Keycloak pod (e2-small equivalent) | included in node cost |
| **Phase 7b additional cost** | **$0** |

> Keycloak runs as a pod on the existing GKE cluster. No additional GCP resources required.

---

## Production considerations

### 1. Run Keycloak with at least 2 replicas and a dedicated PostgreSQL
A single Keycloak pod is a single point of failure for every tool. In production, run 2+ replicas with `CACHE_OWNERS_COUNT` and `CACHE_OWNERS_AUTH_SESSIONS_COUNT` set to the replica count. Use a dedicated Cloud SQL instance — not the same database as the application.

### 2. Enable TLS end-to-end
This lab uses plain HTTP behind nginx. In production, Keycloak must serve HTTPS — browsers block mixed-content OAuth redirects. Use cert-manager with a Let's Encrypt or internal CA issuer, and set `production: true` in the Bitnami values.

### 3. Disable the local admin account after SSO is stable
ArgoCD and Grafana both have local admin accounts that bypass SSO. Once SSO is verified and group assignments are correct, disable them:
- ArgoCD: set `admin.enabled: "false"` in `argocd-cm`
- Grafana: set `auth.disable_login_form: true` in `grafana.ini`

Keep an emergency break-glass procedure documented.

### 4. Set token lifetimes explicitly
Default Keycloak token lifetimes are generous. For a platform tool, 15-minute access tokens with 8-hour refresh tokens are reasonable. Short-lived tokens limit the blast radius of a stolen token.

### 5. Extend Keycloak SSO to all platform tools
Once the pattern is established (Keycloak realm → client → RBAC mapping), adding new tools is a 15-minute task. Backstage (Phase 11), Argo Workflows, and any future platform tools should all delegate to the same Keycloak realm — one identity graph for the entire platform.

### 6. Audit logs
Keycloak logs every login, token issuance, and group change. In production, ship these logs to the observability stack (Phase 7) or a SIEM. Combined with Vault's audit log (Phase 3) and Kubernetes audit logs (Phase 10), you have a complete access audit trail across every layer of the platform.

---

## Outcome

Every platform tool — ArgoCD, Grafana, and any tool added later — uses the same login. Engineers authenticate with their GitHub account. A single group assignment in Keycloak controls what they can do across the entire platform. Offboarding is one action, not twelve. The client secrets never appear in Git or Helm values — they live in Vault and are loaded at deploy time.

---

[Back to main README](../README.md) | [Next: Phase 8 — Advanced Kubernetes](../phase-8-advanced-k8s/README.md)
