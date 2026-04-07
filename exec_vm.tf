locals {
  exec_vms_enabled = length(var.exec_vms) > 0
  # Per-VM OS detection
  exec_vm_is_windows = {
    for name, vm in var.exec_vms : name => can(regex("(?i)windows", vm.os_image))
  }
  # OpenClaw container image: custom or default from Artifact Registry
  openclaw_image = var.sandbox_image != "" ? var.sandbox_image : "${var.region}-docker.pkg.dev/${var.project_id}/openclaw-sandbox/openclaw:latest"
}

resource "google_compute_instance" "exec_vm" {
  for_each = var.exec_vms

  name         = "openclaw-exec-${each.key}"
  machine_type = each.value.machine_type
  zone         = var.zone
  project      = var.project_id

  tags = ["exec-vm"]

  labels = merge(var.labels, { exec_vm = each.key })

  boot_disk {
    initialize_params {
      image = each.value.os_image
      size  = each.value.boot_disk_size_gb
      type  = each.value.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.exec_vm_subnet[0].id
    # No access_config block = no external IP
  }

  service_account {
    email  = google_service_account.exec_vm[0].email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = local.exec_vm_is_windows[each.key] ? {
    windows-startup-script-ps1 = templatefile("${path.module}/scripts/windows_startup.ps1", {
      tls_fingerprint = data.external.tls_fingerprint.result.fingerprint
      developers_json = jsonencode({
        for name, config in var.developers : name => {
          active     = config.active
          gateway_ip = kubernetes_service.openclaw_gateway[name].status[0].load_balancer[0].ingress[0].ip
        }
      })
    })
  } : {
    startup-script = templatefile("${path.module}/scripts/linux_startup.sh", {
      tls_fingerprint = data.external.tls_fingerprint.result.fingerprint
      developers_json = jsonencode({
        for name, config in var.developers : name => {
          active     = config.active
          gateway_ip = kubernetes_service.openclaw_gateway[name].status[0].load_balancer[0].ingress[0].ip
        }
      })
    })
  }

  allow_stopping_for_update = true

  depends_on = [
    google_compute_subnetwork.exec_vm_subnet,
  ]
}
