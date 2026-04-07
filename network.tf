resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "gke_subnet" {
  name                     = "${var.network_name}-gke-subnet"
  ip_cidr_range            = var.gke_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = var.gke_pods_cidr
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = var.gke_services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "exec_vm_subnet" {
  count = local.exec_vms_enabled ? 1 : 0

  name                     = "${var.network_name}-exec-vm-subnet"
  ip_cidr_range            = var.exec_vm_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Firewall Rules

# Deny all ingress by default
resource "google_compute_firewall" "deny_all_ingress" {
  name    = "${var.network_name}-deny-all-ingress"
  network = google_compute_network.vpc.id

  direction = "INGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
}

# Allow SSH via IAP
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.network_name}-allow-iap-ssh"
  network = google_compute_network.vpc.id

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
}

# Allow execution VM to connect to GKE node network (for Internal Load Balancer gateway services)
resource "google_compute_firewall" "allow_exec_vm_to_gke" {
  count = local.exec_vms_enabled ? 1 : 0

  name    = "${var.network_name}-allow-exec-vm-to-gke"
  network = google_compute_network.vpc.id

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["18789"]
  }

  source_ranges = [var.exec_vm_subnet_cidr]
}
