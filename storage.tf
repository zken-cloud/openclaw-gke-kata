locals {
  gateway_auth_token = var.gateway_auth_token != "" ? var.gateway_auth_token : random_id.gateway_token.hex

}

resource "random_id" "gateway_token" {
  byte_length = 24
}

# Gateway TLS certificate (self-signed, managed by Terraform)
resource "tls_private_key" "gateway_tls" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "gateway_tls" {
  private_key_pem = tls_private_key.gateway_tls.private_key_pem

  subject {
    common_name = "openclaw-gateway"
  }

  validity_period_hours = 87600 # 10 years

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# Write cert to local file for fingerprint computation
resource "local_file" "gateway_cert" {
  content  = tls_self_signed_cert.gateway_tls.cert_pem
  filename = "${path.module}/.terraform/gateway-cert.pem"
}

# Compute SHA256 fingerprint of the DER-encoded cert
data "external" "tls_fingerprint" {
  program = ["bash", "-c", "echo '{\"fingerprint\": \"'$(openssl x509 -in ${local_file.gateway_cert.filename} -noout -fingerprint -sha256 2>/dev/null | sed 's/sha256 Fingerprint=//;s/://g' | tr '[:upper:]' '[:lower:]')'\"}' "]
  depends_on = [local_file.gateway_cert]
}

# Artifact Registry for sandbox images
resource "google_artifact_registry_repository" "sandbox" {
  location      = var.region
  repository_id = "openclaw-sandbox"
  description   = "Private Docker images for OpenClaw sandbox containers"
  format        = "DOCKER"
  project       = var.project_id

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"

    most_recent_versions {
      keep_count = 5
    }
  }

  labels = var.labels
}

# Secret Manager Secrets

resource "google_secret_manager_secret" "gateway_token" {
  secret_id = "openclaw-gateway-token"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = var.labels

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "gateway_token" {
  secret      = google_secret_manager_secret.gateway_token.id
  secret_data = local.gateway_auth_token
}

resource "google_secret_manager_secret" "brave_api_key" {
  count = var.brave_api_key != "" ? 1 : 0

  secret_id = "openclaw-brave-api-key"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = var.labels

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "brave_api_key" {
  count = var.brave_api_key != "" ? 1 : 0

  secret      = google_secret_manager_secret.brave_api_key[0].id
  secret_data = var.brave_api_key
}

resource "google_secret_manager_secret" "telegram_bot_token" {
  count = var.telegram_bot_token != "" ? 1 : 0

  secret_id = "openclaw-telegram-bot-token"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = var.labels

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "telegram_bot_token" {
  count = var.telegram_bot_token != "" ? 1 : 0

  secret      = google_secret_manager_secret.telegram_bot_token[0].id
  secret_data = var.telegram_bot_token
}
