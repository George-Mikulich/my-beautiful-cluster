variable "gke_num_nodes" {
  default     = 2
  description = "number of gke nodes"
}

variable "zone" {
  default     = "us-west1-c"
  description = "gcp zone"
}

variable "region" {
  default     = "us-west1"
  description = "gcp region"
}

variable "project_id" {
  default     = "my-beautiful-cluster2"
  description = "project ID"
}

variable "gke_username" {
  default     = ""
  description = "gke username"
}

variable "gke_password" {
  default     = ""
  description = "gke password"
}