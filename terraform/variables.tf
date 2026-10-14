variable "region" {
  description = "Pluralsight sandboxes only allow us-east-1 and us-west-2"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "Pluralsight AWS sandboxes only allow us-east-1 and us-west-2."
  }
}

variable "clusters" {
  description = "Clusters to create in this sandbox. Each uses 3 instances; Pluralsight allows 9."
  type        = number
  default     = 3

  validation {
    condition     = var.clusters >= 1 && var.clusters <= 3
    error_message = "A Pluralsight sandbox fits 1-3 clusters (9 EC2 instance limit, 3 per cluster)."
  }
}

variable "master_instance_type" {
  description = "Control plane needs >= 2 vCPU and ~2 GB RAM for kubeadm preflight"
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "Pluralsight allows t2/t3/t3a/t4g in micro, small and medium"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "GB per node (Pluralsight max is 100)"
  type        = number
  default     = 20
}

variable "ssh_cidr" {
  description = "CIDR allowed to reach SSH and the Kubernetes API. Empty = auto-detect your public IP."
  type        = string
  default     = ""
}

variable "shared_cidrs" {
  description = "Extra CIDRs (people you share the clusters with) - up.sh fills this from users.txt"
  type        = list(string)
  default     = []
}

variable "repo_url" {
  description = "Ansible repo cloned onto each master1 (its deploy.sh must support CLUSTER_KEY mode)"
  type        = string
  default     = "https://github.com/rvinodrajendran/k8-cluster-automation.git"
}

variable "repo_branch" {
  type    = string
  default = "main"
}
