###############################################################################
# OpenClaw on GCP -- Terraform Variables
# Secure-by-default values for all configurable parameters.
###############################################################################

# ──────────────────────────────────────────────────────────────────────────────
# Project & Region
# ──────────────────────────────────────────────────────────────────────────────

variable "project_id" {
  description = "GCP project ID where all resources will be created."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources (Artifact Registry, Secret Manager)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the Compute Engine instance."
  type        = string
  default     = "us-central1-c"
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking
# ──────────────────────────────────────────────────────────────────────────────

variable "network_name" {
  description = "Name of the VPC network."
  type        = string
  default     = "openclaw-vpc"
}

variable "gke_subnet_cidr" {
  description = "CIDR range for the GKE subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "master_authorized_cidrs" {
  description = "Additional CIDR blocks allowed to access the GKE control plane (e.g. admin IPs, CI/CD runners). GKE and exec-VM subnets are added automatically."
  type = map(string)
  default = {}
}

variable "exec_vm_subnet_cidr" {
  description = "CIDR range for the execution VM subnet. Only used when exec_vms is non-empty."
  type        = string
  default     = "10.20.0.0/24"
}

variable "gke_pods_cidr" {
  description = "Secondary CIDR range for GKE Pods."
  type        = string
  default     = "10.100.0.0/16"
}

variable "gke_services_cidr" {
  description = "Secondary CIDR range for GKE Services."
  type        = string
  default     = "10.101.0.0/16"
}

# ──────────────────────────────────────────────────────────────────────────────
# Compute (GKE)
# ──────────────────────────────────────────────────────────────────────────────

variable "gke_cluster_name" {
  description = "Name of the GKE Standard cluster."
  type        = string
  default     = "openclaw-cluster"
}

variable "gke_machine_type" {
  description = "Machine type for GKE node pool. Must support nested virtualization (N2 series)."
  type        = string
  default     = "n2-standard-4"
}

variable "gke_node_count" {
  description = "Number of nodes per zone in the GKE node pool."
  type        = number
  default     = 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Execution VMs (optional -- empty by default)
# Add VMs for executing OS-native commands (Windows and/or Linux).
# The OS type (Windows vs Linux) is auto-detected from the image name.
# ──────────────────────────────────────────────────────────────────────────────

variable "exec_vms" {
  description = "Map of execution VMs to create. Each VM runs per-developer node hosts that connect back to gateway pods. The OS is auto-detected from the image (images containing 'windows' use PowerShell startup, others use bash)."
  type = map(object({
    machine_type      = optional(string, "e2-standard-2")
    boot_disk_size_gb = optional(number, 50)
    boot_disk_type    = optional(string, "pd-balanced")
    os_image          = string
  }))
  default = {}
}

# ──────────────────────────────────────────────────────────────────────────────
# Secrets
# ──────────────────────────────────────────────────────────────────────────────

variable "telegram_bot_token" {
  description = "Telegram bot token (stored in Secret Manager, never in plaintext config). Leave empty to skip Telegram integration."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gateway_auth_token" {
  description = "OpenClaw gateway auth token. Leave empty to auto-generate a 48-char hex token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "brave_api_key" {
  description = "Brave Search API key (optional). Leave empty to disable."
  type        = string
  sensitive   = true
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────────
# OpenClaw Configuration
# ──────────────────────────────────────────────────────────────────────────────

variable "openclaw_version" {
  description = "OpenClaw npm package version to install."
  type        = string
  default     = "latest"
}

variable "sandbox_image" {
  description = "Docker image for OpenClaw brain pods. When empty (default), uses the image from the project's Artifact Registry built by scripts/build_and_push.sh. Set to a custom image to use a pre-built image."
  type        = string
  default     = ""
}

variable "model_primary" {
  description = "Primary model identifier for OpenClaw agents."
  type        = string
  default     = "litellm/gemini-3.1-pro-preview"
}

variable "model_fallbacks" {
  description = "Fallback model identifiers (JSON array)."
  type        = string
  default     = "[\"litellm/gemini-3.1-flash-lite-preview\"]"
}

variable "developers" {
  description = "Map of developer names to their configuration. Each developer gets a dedicated OpenClaw pod, PVC, and SSH key."
  type = map(object({
    active = bool
  }))
  default = {
    "default" = { active = true }
  }
}

variable "deployer_service_account" {
  description = "Service account email for the deployer (granted IAP tunnel access). Leave empty to skip."
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Labels
# ──────────────────────────────────────────────────────────────────────────────

variable "labels" {
  description = "Labels to apply to all resources."
  type        = map(string)
  default = {
    app         = "openclaw"
    managed-by  = "terraform"
    environment = "production"
  }
}
