terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.74.0"
    }
  }

  backend "gcs" {
    bucket = "0b1741a806748971-bucket-tfstate"
    prefix = "terraform/state"
  }

  required_version = ">= 0.14"
}

# --------------------------------------------
# VPC network and subnets --------------------
# --------------------------------------------

locals {
  subnet_range = {
    default    = "10.10.0.0/24"
    staging    = "10.10.2.0/24"
    production = "10.10.3.0/24"
  }
  net_name = "${terraform.workspace}-${var.project_id}"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_compute_network" "vpc" {
  name                    = "${local.net_name}-vpc"
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${local.net_name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = local.subnet_range[terraform.workspace]
}

# --------------------------------------------------------------
# NAT router ---------------------------------------------------
# --------------------------------------------------------------

resource "google_compute_router" "router" {
  project = var.project_id
  name    = "${terraform.workspace}-nat-router"
  network = google_compute_network.vpc.name
  region  = var.region
}

module "cloud-nat" {
  source                             = "terraform-google-modules/cloud-nat/google"
  version                            = "~> 5.0"
  project_id                         = var.project_id
  region                             = var.region
  router                             = google_compute_router.router.name
  name                               = "${terraform.workspace}-nat-config"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# --------------------------------------------------------------
# GKE cluster --------------------------------------------------
# --------------------------------------------------------------

locals {
  machine_types = {
    default    = "e2-standard-2"
    staging    = "n2-standard-1"
    production = "n2-standard-2"
  }
  cluster_name = "${terraform.workspace}-${var.project_id}-gke"
}

resource "google_container_cluster" "primary" {
  name     = local.cluster_name
  location = var.zone

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  ip_allocation_policy {
  }
}

# Private Node Pool
resource "google_container_node_pool" "primary_nodes" {
  name     = local.cluster_name
  location = var.zone
  cluster  = google_container_cluster.primary.name

  node_count = var.gke_num_nodes

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    labels = {
      env = var.project_id
    }

    machine_type = local.machine_types[terraform.workspace]
    tags         = ["gke-node", local.cluster_name]
    metadata = {
      disable-legacy-endpoints = "true"
    }
    disk_size_gb = 50
  }
  network_config {
    enable_private_nodes = true
  }
}

# -------------------------------------
# Kubernetes provider -----------------
# -------------------------------------

data "google_client_config" "current" {}

provider "kubernetes" {
  load_config_file = false

  host     = google_container_cluster.primary.endpoint
  username = var.gke_username
  password = var.gke_password

  client_certificate     = google_container_cluster.primary.master_auth.0.client_certificate
  client_key             = google_container_cluster.primary.master_auth.0.client_key
  cluster_ca_certificate = google_container_cluster.primary.master_auth.0.cluster_ca_certificate
  token                  = data.google_client_config.current.access_token
}

# -------------------------------------------------------
# Bucket for tfstate ------------------------------------
# -------------------------------------------------------

# Enable the Cloud Storage service account to encrypt/decrypt Cloud KMS keys
data "google_project" "project" {
}

resource "google_kms_key_ring" "terraform_state" {
  name     = "${random_id.bucket_prefix.hex}-bucket-tfstate"
  location = "us"
}

resource "google_kms_crypto_key" "terraform_state_bucket" {
  name            = "test-terraform-state-bucket"
  key_ring        = google_kms_key_ring.terraform_state.id
  rotation_period = "86400s"

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_project_iam_member" "default" {
  project = data.google_project.project.project_id
  role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member  = "serviceAccount:service-${data.google_project.project.number}@gs-project-accounts.iam.gserviceaccount.com"
}
# [END storage_kms_encryption_tfstate]

# [START storage_bucket_tf_with_versioning]
resource "random_id" "bucket_prefix" {
  byte_length = 8
}

resource "google_storage_bucket" "default" {
  name          = "${random_id.bucket_prefix.hex}-bucket-tfstate"
  force_destroy = false
  location      = "US"
  storage_class = "STANDARD"
  versioning {
    enabled = true
  }
  encryption {
    default_kms_key_name = google_kms_crypto_key.terraform_state_bucket.id
  }
  depends_on = [
    google_project_iam_member.default
  ]
}