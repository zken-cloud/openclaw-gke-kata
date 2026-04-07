# Service Account for OpenClaw (GKE Brain)
resource "google_service_account" "openclaw_brain" {
  account_id   = "openclaw-brain"
  display_name = "OpenClaw Brain Service Account"
  project      = var.project_id
}

# Service Account for Execution VM (Hands)
resource "google_service_account" "exec_vm" {
  count = local.exec_vms_enabled ? 1 : 0

  account_id   = "openclaw-exec-vm"
  display_name = "OpenClaw Execution VM Service Account"
  project      = var.project_id
}
# Service Account for GKE Nodes
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes-sa"
  display_name = "GKE Autopilot Node Service Account"
  project      = var.project_id
}

# Grant permissions to GKE Node Service Account
resource "google_project_iam_member" "gke_node_default_sa" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_node_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Per-secret IAM: Brain SA can access only specific secrets (not project-wide secretAccessor)
resource "google_secret_manager_secret_iam_member" "brain_gateway_token_accessor" {
  secret_id = google_secret_manager_secret.gateway_token.secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openclaw_brain.email}"
}

resource "google_secret_manager_secret_iam_member" "brain_telegram_accessor" {
  count     = var.telegram_bot_token != "" ? 1 : 0
  secret_id = google_secret_manager_secret.telegram_bot_token[0].secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openclaw_brain.email}"
}

resource "google_secret_manager_secret_iam_member" "brain_brave_accessor" {
  count     = var.brave_api_key != "" ? 1 : 0
  secret_id = google_secret_manager_secret.brave_api_key[0].secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openclaw_brain.email}"
}

# Grant OpenClaw Brain access to logging and monitoring
resource "google_project_iam_member" "brain_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.openclaw_brain.email}"
}

resource "google_project_iam_member" "brain_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.openclaw_brain.email}"
}

# Workload Identity Binding
resource "google_service_account_iam_binding" "workload_identity_user" {
  service_account_id = google_service_account.openclaw_brain.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${google_container_cluster.primary.workload_identity_config[0].workload_pool}[openclaw/openclaw-brain]"
  ]
}

# Service Account for Cloud Build
resource "google_service_account" "cloudbuild" {
  account_id   = "openclaw-cloudbuild"
  display_name = "OpenClaw Cloud Build Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "cloudbuild_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_project_iam_member" "cloudbuild_ar_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_project_iam_member" "cloudbuild_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_project_iam_member" "cloudbuild_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

# Grant OpenClaw Brain access to Vertex AI (for LiteLLM Gemini models)
resource "google_project_iam_member" "brain_vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.openclaw_brain.email}"
}

# Execution VM logging access
resource "google_project_iam_member" "exec_vm_logging_writer" {
  count   = local.exec_vms_enabled ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.exec_vm[0].email}"
}

# Execution VM monitoring access
resource "google_project_iam_member" "exec_vm_monitoring_writer" {
  count   = local.exec_vms_enabled ? 1 : 0
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.exec_vm[0].email}"
}

# Per-secret IAM: Execution VM can access gateway token from Secret Manager
resource "google_secret_manager_secret_iam_member" "exec_vm_gateway_token_accessor" {
  count     = local.exec_vms_enabled ? 1 : 0
  secret_id = google_secret_manager_secret.gateway_token.secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.exec_vm[0].email}"
}

# IAP access for deployer (if provided)
resource "google_project_iam_member" "iap_access" {
  count   = var.deployer_service_account != "" ? 1 : 0
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${var.deployer_service_account}"
}
