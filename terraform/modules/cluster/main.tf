locals {
  worker_names = ["client1", "client2"] # deploy.sh / inventory expect exactly these two
}

# ---------------------------------------------------------------
# Security group
# ---------------------------------------------------------------

resource "aws_security_group" "k8s" {
  name_prefix = "${var.name}-"
  description = "k8s lab cluster ${var.name}"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from you and shared users"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  ingress {
    description = "Kubernetes API from you and shared users"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  ingress {
    description = "All traffic between nodes of this cluster (kubelet, etcd, flannel VXLAN, NodePorts)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------
# Instances
# ---------------------------------------------------------------

resource "aws_instance" "workers" {
  count = length(local.worker_names)

  ami                    = var.ami_id
  instance_type          = var.worker_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.k8s.id]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.name}-${local.worker_names[count.index]}"
    Cluster = var.name
    Role    = "worker"
  }
}

resource "aws_instance" "master" {
  ami                    = var.ami_id
  instance_type          = var.master_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.k8s.id]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.name}-master1"
    Cluster = var.name
    Role    = "control-plane"
  }
}

# ---------------------------------------------------------------
# Bootstrap: clone the Ansible repo on master1 and run deploy.sh
# ---------------------------------------------------------------

resource "terraform_data" "bootstrap" {
  # Re-run if any instance is replaced
  triggers_replace = concat([aws_instance.master.id], aws_instance.workers[*].id)

  connection {
    type        = "ssh"
    host        = aws_instance.master.public_ip
    user        = "ubuntu"
    private_key = var.private_key
    timeout     = "5m"
  }

  # Same key lets master1 reach the workers - no PEM pasting
  provisioner "file" {
    content     = var.private_key
    destination = "/home/ubuntu/.ssh/k8s_cluster_key"
  }

  # deploy.sh output also goes to ~/deploy.log on master1, because Terraform
  # may hide provisioner output when the connection uses a sensitive key.
  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo 'Waiting for cloud-init to finish (apt lock)...'",
      "cloud-init status --wait > /dev/null || true",
      "chmod 600 /home/ubuntu/.ssh/k8s_cluster_key",
      "sudo apt-get update -qq",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git",
      "rm -rf /home/ubuntu/k8-cluster-automation",
      "git clone --branch ${var.repo_branch} --depth 1 ${var.repo_url} /home/ubuntu/k8-cluster-automation",
      "chmod +x /home/ubuntu/k8-cluster-automation/deploy.sh",
      join(" ", [
        "MASTER_IP=${aws_instance.master.private_ip}",
        "CLIENT1_IP=${aws_instance.workers[0].private_ip}",
        "CLIENT2_IP=${aws_instance.workers[1].private_ip}",
        "CLUSTER_KEY=/home/ubuntu/.ssh/k8s_cluster_key",
        "bash -o pipefail -c '/home/ubuntu/k8-cluster-automation/deploy.sh 2>&1 | tee /home/ubuntu/deploy.log'",
      ]),
    ]
  }
}
