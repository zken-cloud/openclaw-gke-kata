# Technical Product Requirements Document (PRD): OpenClaw Enterprise Deployment on GCP GKE

**Author:** Platform Engineering Team
**Last Updated:** April 2, 2026
**Status:** Implemented and E2E Verified
**Target Audience:** DevOps Engineers, Security Architects, Platform Engineers

## 1. Executive Summary

This document specifies the architecture and requirements for deploying OpenClaw on Google Cloud Platform for a multi-tenant engineering team. The deployment uses a hybrid architecture: OpenClaw "brain" pods run on a **GKE Standard cluster with Kata Containers** (Linux, VM-level isolation), while "hands" execute commands on a shared **Windows Server VM** via TLS WebSocket node host connections. All infrastructure is codified in Terraform, private-by-default, and secured via IAP, Workload Identity, Secret Manager, and defense-in-depth controls.

### Key Differences from Initial Design

| Aspect | Original PRD | Current Implementation |
|--------|-------------|----------------------|
| GKE mode | Autopilot | Standard (required for Kata Containers nested virtualization) |
| Isolation | gVisor | Kata Containers (`kata-clh` RuntimeClass) via Helm chart |
| Windows connectivity | SSH/WinRM from pods | TLS WebSocket via `openclaw node run` + Internal Load Balancers |
| Multi-tenancy | Not specified | Per-developer pods, PVCs, ILBs, and node host processes |
| LLM access | Direct API keys | LiteLLM proxy + Vertex AI via Workload Identity (no API keys) |
| Region | asia-east1 | asia-southeast1 |
| Container user | root | Non-root (UID 10001) with pod securityContext |
| State backend | Local | GCS with versioning |

## 2. Architectural Overview

### 2.1 Core Components

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Agent Compute (Brain) | GKE Standard + Kata Containers | Per-developer AI agent pods with VM-level isolation |
| LLM Gateway | LiteLLM Proxy (Kata pod) | Routes requests to Vertex AI Gemini models via Workload Identity |
| Execution Compute (Hands) | GCE Windows Server 2022 Core | Per-developer node host processes execute Windows commands |
| Networking | Custom VPC, Cloud NAT, ILBs | Private networking, no public IPs, per-developer Internal LBs |
| Security | IAP, Workload Identity, Secret Manager | Zero-trust access, managed credentials, per-secret IAM |
| Storage | GKE PVCs (10Gi), Secret Manager, Artifact Registry | Persistent workspaces, secrets, container images |
| Orchestration | Terraform + Helm | Infrastructure as Code, Kata via official Helm chart |

### 2.2 Network Flow

```
Developer Laptop
    |
    | gcloud / kubectl via IAP tunnel
    v
GCP Project (Private VPC: openclaw-vpc)
    |
    +-- GKE Subnet (10.10.0.0/24)
    |     +-- Pods (10.100.0.0/16)
    |     |     +-- openclaw-brain-alice (Kata VM)
    |     |     +-- openclaw-brain-bob   (Kata VM)
    |     |     +-- litellm              (Kata VM)
    |     +-- Services (10.101.0.0/16)
    |     |     +-- litellm (ClusterIP :4000)
    |     |     +-- openclaw-gateway-alice (ILB :18789)
    |     |     +-- openclaw-gateway-bob   (ILB :18789)
    |     +-- Node Pool: kata-pool (N2, nested virt enabled)
    |
    +-- Windows Subnet (10.20.0.0/24)
    |     +-- openclaw-gateway VM (10.20.0.2)
    |           +-- Scheduled Task: OpenClaw-Node-alice
    |           +-- Scheduled Task: OpenClaw-Node-bob
    |
    +-- Cloud NAT (outbound only)
    +-- Cloud Router
```

**Connection Flow:**
1. Developer connects via `kubectl exec -it` through IAP tunnel
2. OpenClaw agent pod processes user messages, calls Vertex AI via LiteLLM proxy
3. Agent dispatches Windows commands over TLS WebSocket to paired node host
4. Node host executes on Windows and returns results
5. All outbound traffic routes through Cloud NAT (no public IPs)

### 2.3 Multi-Tenancy Model

Each developer in `var.developers` gets:
- Dedicated Kubernetes Deployment (`openclaw-brain-{name}`, replicas controlled by `active` flag)
- Dedicated PVC (`openclaw-pvc-{name}`, 10Gi ReadWriteOnce)
- Dedicated Internal Load Balancer service (`openclaw-gateway-{name}`)
- Dedicated Windows node host scheduled task (`OpenClaw-Node-{name}`)
- Isolated state directory (`/app/workspace/.openclaw-state` on PVC)

Shared across all developers:
- LiteLLM proxy deployment (single instance)
- Windows VM (shared execution environment)
- Gateway TLS certificate and auth token
- GKE cluster and node pool

## 3. Security Requirements

### 3.1 Network Security

- [x] Custom VPC with no auto-created subnets
- [x] Default-deny ingress firewall rule (priority 65534)
- [x] SSH allowed only from IAP range (35.235.240.0/20)
- [x] Windows-to-GKE traffic restricted to port 18789 from Windows subnet only
- [x] Private GKE cluster (private nodes, no public node IPs)
- [x] Master authorized networks restricted to VPC subnets and admin CIDRs
- [x] Cloud NAT for outbound internet (no public IPs on any resource)
- [x] VPC flow logs enabled with full metadata
- [x] Internal Load Balancers for pod-to-VM communication (not NodePort/public)

### 3.2 Identity and Access Management

- [x] Dedicated service accounts: `openclaw-brain`, `openclaw-windows`, `gke-nodes-sa`, `openclaw-cloudbuild`
- [x] Workload Identity: KSA `openclaw-brain` bound to GSA `openclaw-brain`
- [x] Per-secret IAM bindings (not project-wide `secretAccessor`)
- [x] Least-privilege roles (no `editor`, `owner`, or `admin` roles)
- [x] Optional deployer SA with IAP tunnel access

### 3.3 Compute Security

- [x] Kata Containers (VM-level isolation) for all OpenClaw and LiteLLM pods
- [x] Non-root container user (UID 10001) with `runAsNonRoot` pod securityContext
- [x] Shielded VMs (Secure Boot, vTPM, Integrity Monitoring) on Windows VM
- [x] GKE node auto-repair and auto-upgrade enabled
- [x] GKE release channel: REGULAR (automatic security patches)
- [x] Cluster deletion protection enabled
- [x] Container vulnerability scanning enabled (containerscanning.googleapis.com)
- [x] LiteLLM image pinned to SHA256 digest

### 3.4 Secrets Management

- [x] All credentials in GCP Secret Manager (gateway token, Telegram token, Brave API key)
- [x] Auto-generated 48-char hex gateway token if not provided
- [x] Sensitive Terraform variables use `TF_VAR_*` environment variables (not in .tfvars)
- [x] Remote Terraform state in GCS bucket with versioning
- [x] TLS self-signed certificate with SHA256 fingerprint pinning
- [x] Gateway auth token fetched from Secret Manager at runtime (Windows node hosts)

### 3.5 Application Security

- [x] Gateway enforces allowlist exec security (`safeBins` whitelist)
- [x] Node host uses full exec security (accepts commands approved by gateway)
- [x] Restricted `envsubst` (only named variables: `$MODEL_PRIMARY,$MODEL_FALLBACKS,$GATEWAY_AUTH_TOKEN`)
- [x] TLS WebSocket connections with certificate fingerprint validation
- [x] Log redaction for sensitive patterns (API keys, tokens, credentials)
- [x] Plugins enabled but empty allowlist (no plugins loaded by default)
- [x] Browser tool explicitly denied

## 4. Infrastructure Components

### 4.1 Terraform Files

| File | Purpose |
|------|---------|
| `main.tf` | Provider config, GCS backend, API enablement |
| `gke.tf` | GKE Standard cluster, Kata node pool, release channel, master auth networks |
| `kata.tf` | Kata Containers Helm chart (v3.28.0) |
| `kubernetes.tf` | Namespace, deployments, services, PVCs, ConfigMaps, Secrets |
| `network.tf` | VPC, subnets, Cloud NAT, firewall rules |
| `windows_vm.tf` | Windows Server 2022 VM with startup script |
| `iam.tf` | Service accounts, IAM bindings, Workload Identity |
| `storage.tf` | TLS cert, Secret Manager secrets, Artifact Registry |
| `variables.tf` | All input variables with defaults |
| `outputs.tf` | Deployment outputs |

### 4.2 Scripts

| Script | Purpose |
|--------|---------|
| `scripts/entrypoint.sh` | Container entrypoint: config templating, state setup, exec approvals, gateway start |
| `scripts/windows_startup.ps1` | Windows VM: Node.js install, OpenClaw install, Secret Manager fetch, per-developer node hosts |
| `scripts/build_and_push.sh` | Build Docker image via Cloud Build, push to Artifact Registry |

### 4.3 Configuration

| File | Purpose |
|------|---------|
| `Dockerfile` | OpenClaw container image (node:22-slim, non-root user UID 10001) |
| `openclaw.json.template` | Gateway config template (TLS, auth, LiteLLM, exec security, models) |

## 5. Operational Workflows

### 5.1 Developer Experience

1. Developer authenticates: `gcloud auth login`
2. Get kubeconfig: `gcloud container clusters get-credentials openclaw-cluster --region asia-southeast1`
3. Connect to pod TUI: `kubectl exec -it -n openclaw openclaw-brain-alice-xxxxx -- npx openclaw tui`
4. Interact with AI agent; agent dispatches Windows commands automatically
5. Workspace persists across pod restarts (PVC-backed)

### 5.2 Adding a Developer

1. Add entry to `var.developers` map in `terraform.tfvars`
2. Run `terraform apply`
3. Terraform creates: pod, PVC, ILB service
4. Windows startup script creates: node host scheduled task
5. Node host auto-pairs with gateway pod

### 5.3 Deactivating a Developer

1. Set `active = false` in `var.developers`
2. Run `terraform apply`
3. Pod scaled to 0 replicas (PVC preserved)
4. Windows node host task stopped and unregistered

### 5.4 Secret Rotation

```bash
# Rotate gateway token
echo -n "NEW_TOKEN" | gcloud secrets versions add openclaw-gateway-token --data-file=-

# Restart pods and Windows node hosts
kubectl rollout restart deployment -n openclaw -l component=brain

# Windows node hosts auto-refresh token from Secret Manager on restart
gcloud compute instances reset openclaw-gateway --zone=asia-southeast1-a
```

## 6. Success Criteria

All criteria verified as of April 2, 2026:

- [x] `terraform apply` completes without errors
- [x] Private GKE cluster and Windows VM running with no public IPs
- [x] Kata Containers providing VM-level pod isolation
- [x] Per-developer pods running as non-root (UID 10001)
- [x] LiteLLM proxy routing to Vertex AI via Workload Identity
- [x] Windows node hosts paired with gateway pods over TLS WebSocket
- [x] Agent command execution on Windows verified (alice: `hostname` -> `openclaw-gateway`)
- [x] Agent command execution on Windows verified (bob: `hostname` -> `openclaw-gateway`)
- [x] Gateway enforcing allowlist exec security
- [x] Persistent state across pod restarts (PVC + OPENCLAW_STATE_DIR)
- [x] Terraform state in GCS backend with versioning
- [x] Container vulnerability scanning enabled

## 7. Environment Configuration

| Parameter | Value |
|-----------|-------|
| GCP Project | `test-claw-project` |
| Region | `asia-southeast1` |
| Zone | `asia-southeast1-a` |
| GKE Cluster | `openclaw-cluster` (Standard, not Autopilot) |
| Node Pool | `kata-pool` (N2-standard-4, nested virt) |
| Windows VM | `openclaw-gateway` (e2-standard-2, Server 2022 Core) |
| Windows Internal IP | `10.20.0.2` |
| LLM Models | Gemini 3.1 Pro Preview (primary), Flash Lite Preview (fallback) |
| LLM Route | Pod -> LiteLLM (:4000) -> Vertex AI (global) |
| Kata Version | 3.28.0 (Helm chart) |
| State Bucket | `test-claw-project-tf-state` |

## 8. Known Limitations and Future Work

### Known Limitations

- **Single Windows VM**: All developers share one Windows VM. Vertical scaling only (increase machine type).
- **Secure boot disabled on Kata pool**: Required for nested virtualization. Integrity monitoring still active.
- **GKE API endpoint public** (with master authorized networks): Full private endpoint requires VPN/bastion.
- **10-year TLS certificate**: Should be reduced to 90 days with auto-rotation for production.
- **No NetworkPolicies**: Pod-to-pod communication unrestricted within cluster.

### Future Work

- [ ] Browser/desktop app capability testing on Windows node hosts
- [ ] NetworkPolicies for pod-to-pod traffic restriction
- [ ] Windows VM golden image pipeline (automated monthly rebuilds)
- [ ] Multiple Windows VMs with developer-to-VM affinity
- [ ] Pod resource limits (CPU/memory) per developer
- [ ] TLS certificate auto-rotation (cert-manager or external)
- [ ] VPC Service Controls perimeter
- [ ] Cloud Armor WAF for external-facing services (if added)
- [ ] Telegram channel integration (token in Secret Manager, config in template)
- [ ] Embedding provider for agent memory
