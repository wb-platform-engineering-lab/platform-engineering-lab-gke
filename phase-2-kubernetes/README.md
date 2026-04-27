# Phase 2 — Kubernetes Core

> **Kubernetes concepts introduced:** Deployment, Service, ConfigMap, Ingress | **Builds on:** Phase 1 GKE cluster

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-2-kubernetes/quiz.html)

---

## Kubernetes concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Deployment** | Declares desired pod count and rolling update strategy | Kubernetes reconciles reality to match — restarts crashed pods, stages rollouts safely |
| **Service (ClusterIP)** | Stable internal DNS name and IP for a set of pods | Pods are ephemeral; their IPs change on restart. Services give other pods a fixed address |
| **ConfigMap** | Key-value config injected as environment variables | Separates configuration from container images — no rebuild to change a setting |
| **Ingress** | HTTP routing rules at the cluster edge | One external IP routes traffic to multiple internal services based on path |
| **nginx Ingress Controller** | Implements the Ingress spec using nginx | GKE does not include an Ingress controller by default — you install one |

---

## The problem

> *CoverLine — 200 members. The logistics client is live.*
>
> The first corporate client went live on a Monday. By Wednesday, they had 200 employee members submitting claims. By Thursday, the backend was struggling.
>
> A developer pushed a config change. The single Docker container running the backend restarted. For 90 seconds, every claim submission returned an error. 23 members tried to submit. 23 members saw a blank screen. Four of them emailed support.
>
> The post-mortem was short: one container, one point of failure, zero redundancy.
>
> The team tried running two containers behind a load balancer. It worked, until a deploy took both containers down simultaneously. They tried staggering restarts manually. It worked, until someone forgot the procedure at 11 PM.
>
> *"We need something that manages containers for us. Something that knows how to restart them, roll them out safely, and keep a minimum number running at all times."*

The decision: Kubernetes. Run the platform on GKE. Let the orchestrator handle restarts, rollouts, and replicas.

---

## Architecture

```
Internet
    │
    └── GCP LoadBalancer (external IP)
            │
            └── nginx Ingress Controller
                    ├── /         → frontend Service :3000
                    └── /api/*    → backend Service  :5000
                                          │
                                          └── ConfigMap: coverline-config
                                              (BACKEND_URL, ENVIRONMENT, LOG_LEVEL)

Deployments:
  frontend   2 replicas   readiness + liveness probes   100m CPU / 128Mi RAM
  backend    2 replicas   readiness + liveness probes   100m CPU / 128Mi RAM
```

With 2 replicas per Deployment, Kubernetes keeps at least one pod running during a rolling update. A pod crash triggers an automatic restart. A bad image tag is detected by the readiness probe — traffic is never routed to a pod that hasn't passed its health check.

---

## Repository structure

```
phase-2-kubernetes/
├── configmap.yaml          ← shared environment config (BACKEND_URL, LOG_LEVEL)
├── ingress.yaml            ← HTTP routing rules (/ → frontend, /api → backend)
├── backend/
│   ├── deployment.yaml     ← 2 replicas, probes, resource limits, ConfigMap ref
│   └── service.yaml        ← ClusterIP on port 5000
└── frontend/
    ├── deployment.yaml     ← 2 replicas, probes, resource limits, ConfigMap ref
    └── service.yaml        ← ClusterIP on port 3000
```

---

## Prerequisites

GKE cluster from Phase 1 running with `kubectl` configured:

```bash
gcloud container clusters get-credentials platform-eng-lab-will-dev-gke \
  --region us-central1 --project platform-eng-lab-will
kubectl get nodes
```

---

## Architecture Decision Records

- `docs/decisions/adr-006-deployment-over-bare-pods.md` — Why Deployments over bare Pods for workload management
- `docs/decisions/adr-007-clusterip-with-ingress.md` — Why ClusterIP Services with an Ingress controller over LoadBalancer Services per workload
- `docs/decisions/adr-008-nginx-ingress-over-gce-ingress.md` — Why nginx Ingress controller over the GKE-native GCE Ingress
- `docs/decisions/adr-009-configmap-for-env-config.md` — Why ConfigMaps over hardcoded environment variables in manifests

---

## Challenge 1 — Deploy the nginx Ingress controller

The nginx Ingress controller is a Deployment that watches Ingress resources and configures nginx to forward traffic. GKE does not install one by default.

### Step 1: Install the controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml
```

### Step 2: Wait for the controller pod to be ready

```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

### Step 3: Confirm the LoadBalancer has an external IP

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

Expected output (the `EXTERNAL-IP` may take 1–2 minutes to assign):

```
NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)
ingress-nginx-controller   LoadBalancer   10.30.x.x     35.193.x.x      80:xxxxx/TCP
```

---

## Challenge 2 — Apply the ConfigMap

The ConfigMap holds shared configuration injected into both the backend and frontend containers as environment variables. Neither Deployment hardcodes these values.

### Step 1: Review the manifest

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coverline-config
  namespace: default
data:
  BACKEND_URL: "http://backend:5000"
  ENVIRONMENT: "dev"
  LOG_LEVEL: "info"
```

`BACKEND_URL` uses the Kubernetes DNS name `backend` — the Service name resolves to the backend ClusterIP within the cluster.

### Step 2: Apply

```bash
kubectl apply -f phase-2-kubernetes/configmap.yaml
```

### Step 3: Verify

```bash
kubectl describe configmap coverline-config
```

---

## Challenge 3 — Deploy the backend

### Step 1: Review the manifest

```yaml
# backend/deployment.yaml (key decisions)
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: backend
          image: us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:v1
          envFrom:
            - configMapRef:
                name: coverline-config
          readinessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "250m"
              memory: "256Mi"
```

| Decision | Config | Why |
|---|---|---|
| 2 replicas | `replicas: 2` | One pod can restart without dropping traffic |
| Readiness probe | `httpGet /health` | Traffic is only routed to pods that pass the health check |
| Liveness probe | `httpGet /health` | Kubernetes restarts pods that stop responding |
| Resource limits | `cpu: 250m, memory: 256Mi` | Prevents one pod consuming all node resources and evicting others |

### Step 2: Apply

```bash
kubectl apply -f phase-2-kubernetes/backend/
```

### Step 3: Verify pods are running

```bash
kubectl get pods -l app=backend
```

Expected:
```
NAME                       READY   STATUS    RESTARTS   AGE
backend-xxxx               1/1     Running   0          30s
backend-yyyy               1/1     Running   0          30s
```

---

## Challenge 4 — Deploy the frontend

### Step 1: Apply

```bash
kubectl apply -f phase-2-kubernetes/frontend/
```

### Step 2: Verify

```bash
kubectl get pods -l app=frontend
kubectl get svc frontend
```

Both pods should be `Running` and the Service should show `ClusterIP` with port 3000.

---

## Challenge 5 — Apply the Ingress and verify routing

### Step 1: Review the manifest

```yaml
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: coverline-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 3000
          - path: /api(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: backend
                port:
                  number: 5000
```

The `rewrite-target: /$2` annotation strips `/api` from the path before forwarding to the backend. A request to `/api/health` reaches the backend as `/health`.

### Step 2: Apply

```bash
kubectl apply -f phase-2-kubernetes/ingress.yaml
```

### Step 3: Get the Ingress IP

```bash
kubectl get ingress coverline-ingress
```

Expected:
```
NAME                CLASS   HOSTS   ADDRESS         PORTS   AGE
coverline-ingress   nginx   *       35.193.x.x      80      1m
```

### Step 4: Test the endpoints

```bash
INGRESS_IP=$(kubectl get ingress coverline-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl http://$INGRESS_IP/
curl http://$INGRESS_IP/api/health
curl http://$INGRESS_IP/api/data
```

---

## Challenge 6 — Simulate a bad deploy and roll back

This challenge reproduces the class of incident that triggered the move to Kubernetes.

### Step 1: Simulate a bad deploy

```bash
kubectl set image deployment/backend backend=us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:broken
```

### Step 2: Watch the rollout fail

```bash
kubectl get pods -l app=backend -w
```

You should see new pods enter `ImagePullBackOff` or `ErrImagePull` while the original pods remain running. Kubernetes never cuts over to the broken pods because they fail the readiness probe.

### Step 3: Inspect the failure

```bash
kubectl describe pod -l app=backend | grep -A5 "Events:"
```

### Step 4: Roll back

```bash
kubectl rollout undo deployment/backend
kubectl rollout status deployment/backend
```

Expected:
```
Waiting for deployment "backend" rollout to finish: 1 out of 2 new replicas have been updated...
deployment "backend" successfully rolled out
```

### Step 5: Verify traffic is restored

```bash
curl http://$INGRESS_IP/api/health
```

---

## Teardown

```bash
kubectl delete -f phase-2-kubernetes/
```

The nginx Ingress controller and its LoadBalancer are managed by bootstrap — they persist across phases.

---

## Cost breakdown

Phase 2 adds no GCP costs beyond the cluster from Phase 1. The nginx LoadBalancer is already provisioned by bootstrap.

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| nginx LoadBalancer | included in bootstrap |
| **Phase 2 additional cost** | **$0** |

---

## Kubernetes concept: Deployments and the reconciliation loop

Kubernetes does not execute commands — it reconciles state. When you apply a Deployment, you declare *what you want*: 2 replicas of this container image. The control plane continuously compares the desired state to the actual state and makes changes to close the gap.

This has a concrete consequence: if a pod crashes, Kubernetes restarts it — not because you told it to, but because the actual state (1 pod) no longer matches the desired state (2 pods). The same loop handles rolling updates: Kubernetes starts new pods, waits for them to pass the readiness probe, then terminates old pods. A bad image never fully replaces the old version because the new pods never pass the health check.

---

## Production considerations

### 1. Add PodDisruptionBudgets
This lab allows Kubernetes to remove all pods from a Deployment simultaneously during a node upgrade. A PDB guarantees a minimum number of replicas remain available during voluntary disruptions:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: backend-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: backend
```

### 2. Implement NetworkPolicies
By default, every pod in the cluster can reach every other pod. In production, a compromised frontend pod can connect directly to PostgreSQL. NetworkPolicies restrict traffic: only the backend can reach the database, only the frontend can reach the backend.

### 3. Use dedicated namespaces
This lab deploys everything into `default`. In production, each service team should have its own namespace to isolate resources, apply ResourceQuotas, and limit blast radius during incidents.

### 4. Configure Ingress with TLS
This lab exposes services over plain HTTP. In production, terminate TLS at the Ingress. cert-manager with Let's Encrypt automates certificate provisioning and renewal on GKE.

### 5. Set `revisionHistoryLimit`
Kubernetes keeps 10 old ReplicaSets per Deployment by default. With frequent deploys, set `revisionHistoryLimit: 3` to limit storage consumed by old versions.

---

## Outcome

The CoverLine backend and frontend run as Kubernetes Deployments with 2 replicas each. A bad deploy leaves the existing pods running — traffic never routes to an unhealthy pod. A one-command rollback restores the previous version. External traffic reaches both services through a single nginx Ingress IP.

---

[Back to main README](../README.md) | [Next: Phase 4 — CI/CD](../phase-3-cicd/README.md)
