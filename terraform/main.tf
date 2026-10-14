# ---------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  ssh_cidr      = var.ssh_cidr != "" ? var.ssh_cidr : "${chomp(data.http.my_ip.response_body)}/32"
  admin_cidrs   = distinct(concat([local.ssh_cidr], var.shared_cidrs))
  cluster_names = [for i in range(var.clusters) : "c${i + 1}"]
}

# ---------------------------------------------------------------
# One SSH key per sandbox, shared by its clusters
# ---------------------------------------------------------------

resource "tls_private_key" "lab" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "lab" {
  key_name_prefix = "${terraform.workspace}-"
  public_key      = tls_private_key.lab.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.root}/../keys/${terraform.workspace}.pem"
  content         = tls_private_key.lab.private_key_openssh
  file_permission = "0400"
}

# ---------------------------------------------------------------
# Clusters: lab1-c1, lab1-c2, ...
# ---------------------------------------------------------------

module "cluster" {
  source   = "./modules/cluster"
  for_each = toset(local.cluster_names)

  name                 = "${terraform.workspace}-${each.key}"
  ami_id               = data.aws_ami.ubuntu.id
  vpc_id               = data.aws_vpc.default.id
  key_name             = aws_key_pair.lab.key_name
  private_key          = tls_private_key.lab.private_key_openssh
  admin_cidrs          = local.admin_cidrs
  master_instance_type = var.master_instance_type
  worker_instance_type = var.worker_instance_type
  root_volume_size     = var.root_volume_size
  repo_url             = var.repo_url
  repo_branch          = var.repo_branch
}
