output "clusters" {
  value = {
    for name, c in module.cluster : "${terraform.workspace}-${name}" => {
      master_public_ip = c.master_public_ip
      private_ips      = c.private_ips
      ssh              = "ssh -i keys/${terraform.workspace}.pem ubuntu@${c.master_public_ip}"
    }
  }
}

# "lab1-c1 1.2.3.4" per line - read by up.sh (no jq needed)
output "masters" {
  value = join("\n", [for name, c in module.cluster : "${terraform.workspace}-${name} ${c.master_public_ip}"])
}

output "admin_cidr" {
  value = local.ssh_cidr
}

output "allowed_cidrs" {
  value = local.admin_cidrs
}
