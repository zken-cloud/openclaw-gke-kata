resource "kubernetes_namespace" "openclaw" {
  metadata {
    name = "openclaw"
  }
}

# Gateway TLS certificate as K8s secret
resource "kubernetes_secret" "gateway_tls" {
  metadata {
    name      = "openclaw-gateway-tls"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }

  data = {
    "gateway-cert.pem" = tls_self_signed_cert.gateway_tls.cert_pem
    "gateway-key.pem"  = tls_private_key.gateway_tls.private_key_pem
  }

  type = "Opaque"
}

# Gateway auth token as K8s secret (sourced from Secret Manager value)
resource "kubernetes_secret" "gateway_token" {
  metadata {
    name      = "openclaw-gateway-token"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }

  data = {
    token = local.gateway_auth_token
  }

  type = "Opaque"
}

resource "kubernetes_service_account" "openclaw_brain" {
  metadata {
    name      = "openclaw-brain"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.openclaw_brain.email
    }
  }
}

# LiteLLM proxy config for Vertex AI via ADC (Workload Identity)
resource "kubernetes_config_map" "litellm_config" {
  metadata {
    name      = "litellm-config"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }

  data = {
    "litellm_config.yaml" = yamlencode({
      model_list = [
        {
          model_name = "gemini-3.1-pro-preview"
          litellm_params = {
            model           = "vertex_ai/gemini-3.1-pro-preview"
            vertex_project  = var.project_id
            vertex_location = "global"
          }
        },
        {
          model_name = "gemini-3.1-flash-lite-preview"
          litellm_params = {
            model           = "vertex_ai/gemini-3.1-flash-lite-preview"
            vertex_project  = var.project_id
            vertex_location = "global"
          }
        }
      ]
      general_settings = {
        master_key = "sk-litellm-local-only"
      }
    })
  }
}

# Per-developer PVCs
resource "kubernetes_persistent_volume_claim" "openclaw_pvc" {
  for_each = var.developers

  metadata {
    name      = "openclaw-pvc-${each.key}"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      developer = each.key
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

# Shared LiteLLM proxy deployment (runs under Kata)
resource "kubernetes_deployment" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      component = "litellm"
    }
  }

  wait_for_rollout = false

  depends_on = [time_sleep.kata_ready]

  spec {
    replicas = 1

    selector {
      match_labels = {
        app       = "openclaw"
        component = "litellm"
      }
    }

    template {
      metadata {
        labels = {
          app       = "openclaw"
          component = "litellm"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.openclaw_brain.metadata[0].name
        runtime_class_name   = "kata-clh"

        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          fs_group        = 65534
        }

        container {
          name  = "litellm"
          image = "ghcr.io/berriai/litellm@sha256:7c311546c25e7bb6e8cafede9fcd3d0d622ac636b5c9418befaa32e85dfb0186"

          args = ["--config", "/app/config/litellm_config.yaml", "--port", "4000"]

          port {
            container_port = 4000
          }

          volume_mount {
            name       = "litellm-config"
            mount_path = "/app/config"
            read_only  = true
          }
        }

        volume {
          name = "litellm-config"
          config_map {
            name = kubernetes_config_map.litellm_config.metadata[0].name
          }
        }
      }
    }
  }
}

# LiteLLM internal service
resource "kubernetes_service" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      component = "litellm"
    }
  }

  spec {
    selector = {
      app       = "openclaw"
      component = "litellm"
    }

    port {
      port        = 4000
      target_port = 4000
    }
  }
}

# Per-developer OpenClaw deployments with Kata Containers
resource "kubernetes_deployment" "openclaw_brain" {
  for_each = var.developers

  metadata {
    name      = "openclaw-brain-${each.key}"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      component = "brain"
      developer = each.key
    }
  }

  wait_for_rollout = false

  depends_on = [time_sleep.kata_ready]

  spec {
    replicas = each.value.active ? 1 : 0

    selector {
      match_labels = {
        app       = "openclaw"
        component = "brain"
        developer = each.key
      }
    }

    template {
      metadata {
        labels = {
          app       = "openclaw"
          component = "brain"
          developer = each.key
        }
      }

      spec {
        service_account_name = kubernetes_service_account.openclaw_brain.metadata[0].name
        runtime_class_name   = "kata-clh"

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          fs_group        = 10001
        }

        container {
          name  = "openclaw"
          image = local.openclaw_image

          port {
            container_port = 18789
          }

          env {
            name  = "OPENCLAW_STATE_DIR"
            value = "/app/workspace/.openclaw-state"
          }
          env {
            name  = "NODE_TLS_REJECT_UNAUTHORIZED"
            value = "0"
          }
          env {
            name  = "MODEL_PRIMARY"
            value = var.model_primary
          }
          env {
            name  = "MODEL_FALLBACKS"
            value = var.model_fallbacks
          }
          env {
            name  = "VERTEXAI_PROJECT"
            value = var.project_id
          }
          env {
            name  = "VERTEXAI_LOCATION"
            value = var.region
          }
          env {
            name = "GATEWAY_AUTH_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gateway_token.metadata[0].name
                key  = "token"
              }
            }
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/app/workspace"
          }

          volume_mount {
            name       = "gateway-tls"
            mount_path = "/app/tls"
            read_only  = true
          }

        }

        volume {
          name = "workspace"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.openclaw_pvc[each.key].metadata[0].name
          }
        }

        volume {
          name = "gateway-tls"
          secret {
            secret_name = kubernetes_secret.gateway_tls.metadata[0].name
          }
        }
      }
    }
  }
}

# Per-developer gateway services (for execution VM node host to connect)
# Uses Internal Load Balancer so the VM can reach gateway pods from the VPC
# Only created when execution VM is enabled
resource "kubernetes_service" "openclaw_gateway" {
  for_each = local.exec_vms_enabled ? var.developers : {}

  metadata {
    name      = "openclaw-gateway-${each.key}"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app       = "openclaw"
      component = "brain"
      developer = each.key
    }
    annotations = {
      "networking.gke.io/load-balancer-type"                     = "Internal"
      "networking.gke.io/internal-load-balancer-allow-global-access" = "true"
    }
  }

  spec {
    selector = {
      app       = "openclaw"
      component = "brain"
      developer = each.key
    }

    type = "LoadBalancer"

    port {
      port        = 18789
      target_port = 18789
    }
  }
}
