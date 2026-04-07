###############################################################################
# OpenClaw on GCP -- Outputs
###############################################################################

output "gke_cluster_name" {
  description = "Name of the GKE Standard cluster."
  value       = google_container_cluster.primary.name
}

output "gke_cluster_endpoint" {
  description = "Endpoint for GKE Standard cluster."
  value       = google_container_cluster.primary.endpoint
}

output "exec_vms" {
  description = "Map of execution VM names to their internal IPs."
  value = {
    for name, vm in google_compute_instance.exec_vm : name => {
      instance_name = vm.name
      internal_ip   = vm.network_interface[0].network_ip
      os_image      = var.exec_vms[name].os_image
    }
  }
}

output "artifact_registry_url" {
  description = "Artifact Registry URL for pushing sandbox images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.sandbox.repository_id}"
}

output "gateway_token_secret" {
  description = "Secret Manager resource name for the gateway token."
  value       = google_secret_manager_secret.gateway_token.name
}

output "cloudbuild_service_account" {
  description = "Cloud Build service account email."
  value       = google_service_account.cloudbuild.email
}

output "secrets_configured" {
  description = "List of Secret Manager secrets created."
  sensitive   = true
  value = concat(
    [google_secret_manager_secret.gateway_token.secret_id],
    var.telegram_bot_token != "" ? [google_secret_manager_secret.telegram_bot_token[0].secret_id] : [],
    var.brave_api_key != "" ? [google_secret_manager_secret.brave_api_key[0].secret_id] : []
  )
}
