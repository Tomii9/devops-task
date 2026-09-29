# Formlabs DevOps home assignment

## Author's remarks

There was a lot of freedom in technology choice, however, I believe tech stack should serve a purpose, a requirement. Since such requirements were not provided, I created 6 different profiles to serve different purposes, such as:
- balanced / default
- debug for the purpose of developer experience. Using a fat python image with common debugging tools preinstalled
- scalability for high traffic loads. Using gevent async workers, aggressive HPA scaling
- low latency for high responsiveness. Using guaranteed QoS, fixed replicas
- fault tolerance for high availability. Using hard zone anti-affinity, PDB, preStop hook
- cost efficiency when operating at scale. Using KEDA scale-to-zero, spot instances tolerations

The task said "no ingress deployment is needed", but ingress settings add a lot to the above requirements, so it was included.

Most behaviors verified to be working in a local kind cluster. What wasn't:

- scale out to 50 (my computer is strong, but not THAT strong)
- simulated AZs by labeling the 3 worker nodes with topology.kubernetes.io/zone=zone-a/b/c. However, testing actual outages was impossible due to AWS not accepting my credit card.
- node loss due to spot instance reclaim

## Solution

### Project structure

```
.
├── .github/workflows/
│   └── ci-cd.yaml                        # CI/CD pipeline (lint → test → build → scan → deploy)
├── helm/helloapp/
│   ├── Chart.yaml                         # Helm chart metadata
│   ├── values.yaml                        # Default balanced profile
│   ├── values-debug.yaml                  # 🔧 Debug: full toolkit, privileged, no probes
│   ├── values-scalability.yaml            # 📈 Scalability: gevent, HPA 2→50
│   ├── values-latency.yaml                # ⚡ Latency: Guaranteed QoS, fixed replicas
│   ├── values-fault-tolerance.yaml        # 🛡️ Fault tolerance: multi-zone, PDB, preStop
│   ├── values-cost.yaml                   # 💰 Cost: KEDA scale-to-zero, spot instances
│   └── templates/
│       ├── _helpers.tpl                   # Template helpers
│       ├── deployment.yaml                # Deployment (supports all profiles)
│       ├── service.yaml                   # ClusterIP Service
│       ├── hpa.yaml                       # HorizontalPodAutoscaler (conditional)
│       ├── pdb.yaml                       # PodDisruptionBudget (conditional)
│       ├── networkpolicy.yaml             # NetworkPolicy (conditional)
│       ├── serviceaccount.yaml            # ServiceAccount (conditional)
│       └── keda-scaledobject.yaml         # KEDA ScaledObject (conditional)
├── helloapp/
│   ├── __init__.py
│   ├── app.py                             # Flask application
│   └── test.py                            # Unit tests
├── Dockerfile                             # Production: multi-stage, hardened, precompiled
├── Dockerfile.debug                       # Debug: strace, gdb, tcpdump, debugpy
├── .dockerignore                          # Build context exclusions
├── requirements.txt                       # Python dependencies
├── build.sh                               # Original build script
├── run.sh                                 # Original run script
└── test.sh                                # Original test script
```

---

### 1. Docker image

**Technology: Docker with multi-stage builds**

Docker is the industry standard with the widest CI/CD ecosystem. `buildah` is a valid rootless/daemonless alternative, but Docker is more universally supported.

Two Dockerfiles are provided:

| File | Purpose | Base | Size |
|------|---------|------|------|
| `Dockerfile` | Production | `python:3.11-slim` | ~120 MB |
| `Dockerfile.debug` | Debugging | `python:3.11` (full) | ~950 MB |

**Production image features:**
- Multi-stage build — only runtime artifacts in the final image
- `python:3.11-slim` — Debian-based (full wheel compatibility), no bloat
- Non-root user (UID 1000) — prevents container-escape-to-root
- Precompiled bytecode — eliminates first-request JIT overhead
- Env-configurable Gunicorn — worker count, class, threads, timeouts all tunable via env vars
- gevent included — the scalability profile uses async workers at runtime

**Debug image features:**
- Full debugging toolkit: strace, gdb, ltrace, tcpdump, htop, curl, dig, vim, jq
- debugpy remote debugger (VS Code/PyCharm compatible on port 5678)
- Flask debug mode with auto-reload

```bash
# Build and run production image
docker build -t helloapp:latest .
docker run -p 8080:8080 helloapp:latest

# Build and run debug image
docker build -f Dockerfile.debug -t helloapp:debug .
docker run -p 8080:8080 -p 5678:5678 helloapp:debug
```

---

### 2. Kubernetes deployment (Helm chart)

**Technology: Helm**

Plain YAML works for single-service deploys, but this chart supports 5 different deployment profiles via `values-*.yaml` overrides. Helm enables:
- Templated configuration across environments
- Versioned releases with instant rollback (`helm rollback`)
- Conditional resources (HPA, PDB, NetworkPolicy, KEDA) toggled per profile

#### Deployment profiles

| Profile | Optimizes for | Replicas | Key technique |
|---------|--------------|----------|---------------|
| **Default** | Balanced | 1→10 (HPA) | Sensible defaults for most cases |
| **🔧 Debug** | Developer experience | 1 (fixed) | Privileged, no probes, debug tools |
| **📈 Scalability** | Max RPS | 2→50 (HPA) | gevent async workers, aggressive scale-up |
| **⚡ Latency** | P99 < 5ms | 3 (fixed) | Guaranteed QoS, no scaling variance |
| **🛡️ Fault tolerance** | Survive AZ failure | 3→9 (HPA) | Hard zone anti-affinity, PDB, preStop hook |
| **💰 Cost** | $0 at idle | 0→5 (KEDA) | Scale-to-zero, spot instance tolerations |

```bash
# Deploy with default (balanced) profile
helm install helloapp ./helm/helloapp

# Deploy with a specific profile
helm install helloapp ./helm/helloapp -f helm/helloapp/values-scalability.yaml

# Deploy debug variant
helm install helloapp-debug ./helm/helloapp \
  -f helm/helloapp/values-debug.yaml \
  --set image.tag=debug
```

#### Deploy to Minikube

```bash
minikube start
eval $(minikube docker-env)
docker build -t helloapp:latest .

helm install helloapp ./helm/helloapp
kubectl get pods -l app.kubernetes.io/name=helloapp
kubectl port-forward svc/helloapp-helloapp 8080:80
# Visit http://localhost:8080
```

#### Security hardening (enabled by default)

| Feature | Purpose |
|---------|---------|
| Non-root container (UID 1000) | Prevents container-escape-to-root |
| Read-only root filesystem | Prevents runtime file tampering |
| Drop ALL capabilities | Minimal Linux capabilities |
| No privilege escalation | Blocks `setuid` binaries |
| ServiceAccount (no auto-mount) | Prevents K8s API token theft |
| NetworkPolicy (ingress-only) | Denies all traffic except app port |

---

### 3. CI/CD pipeline (GitHub Actions)

**Technology: GitHub Actions**

Org is already on github. If original repo was on Gitlab, then it'd be gitlab CI

| Stage | Trigger | What it does |
|-------|---------|-------------|
| **Lint** | Push + PR | `flake8` static analysis |
| **Test** | Push + PR | `python -m unittest helloapp.test` |
| **Build** | Push only | Builds production + debug Docker images, pushes to GHCR |
| **Security scan** | Push only | Trivy scans for CVEs — **fails the build on HIGH/CRITICAL** |
| **Deploy** | Push only | `helm upgrade --install --atomic` (auto-rollback on failure) |

#### Setup for deployment

The deploy job needs cluster credentials:

1. Export kubeconfig: `cat ~/.kube/config | base64 -w 0`
2. Add as GitHub secret: `gh secret set KUBE_CONFIG`
3. Push to `main`/`master` — pipeline runs automatically

For local development, skip CI deploy and use `helm install` directly (see section 2).

## Original task

This repository contains a home assignment code for DevOps applicants for Formlabs.

See all open jobs at https://careers.formlabs.com/


### Task

0. Fork this repo.
1. Create a deployable docker image for the application.
    - Feel free to switch up technologies. For example you can use `buildah` instead of Docker.
2. Create a Kubernetes deployment and service for the application.
    - Just aim for the simplest setup, no ingress deployment is needed. Feel free to use Helm.
    - You can use [Minikube](https://minikube.sigs.k8s.io/docs/start/) or [k3s](https://k3s.io/) or any other Kubernetes distribution you are familiar with.
3. Create automation to build, test and deploy the application when a change happens in git.
    - Feel free to switch up technologies. For example you can use an Ansible playbook or a Jenkins pipeline.
4. Send us the fork where you did your work.

#### Notes

- Explain as much as possible in the commit message(s) and/or comments if needed. See more on commit messages [here](https://chris.beams.io/posts/git-commit/).
- It would be great if you'd also write about why you choose a certain technology if there are alternatives to consider.

---

