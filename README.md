# Pluralsight K8s Labs

One command builds kubeadm Kubernetes clusters in several Pluralsight AWS sandboxes at once.

Each sandbox is limited to **9 EC2 instances** (stopped instances count). Each cluster uses 3 instances (`master1`, `client1`, `client2`), so:

| Sandboxes | Clusters per sandbox | Total clusters |
| --------- | -------------------- | -------------- |
| 1         | 3                    | 3              |
| 3         | 3                    | **9**          |

Other sandbox rules this project follows: only us-east-1 and us-west-2; t2/t3/t3a/t4g in micro, small or medium sizes; volumes of 100 GB or less. Every node is a `t3.medium`.

## Daily use

1. Start your Pluralsight sandboxes and copy each one's access key and secret.
2. Paste them into `labs.env`. The first time, create the file with `cp labs.env.example labs.env`.
3. Run:

   ```bash
   ./up.sh
   ```

All labs build in parallel, which takes roughly 10–15 minutes. Follow one lab's progress with `tail -f .labs/lab1.log`.

When it finishes:

```bash
export KUBECONFIG=~/.kube/pluralsight.yaml
kubectl config get-contexts          # lab1-c1, lab1-c2, lab1-c3, lab2-c1, ...
kubectl --context lab2-c1 get nodes
```

SSH to a master: `ssh -i keys/lab1.pem ubuntu@<master public ip>`. The IPs are in `terraform -chdir=terraform output clusters`; run that with `TF_WORKSPACE=lab1` set.

### Other commands

| Command | What it does |
| ------- | ------------ |
| `./up.sh lab2` | Build or repair only lab2 |
| `./up.sh` (again, same day) | Safe to re-run. Existing clusters are kept and missing ones are created |
| `./down.sh lab1` | Destroy lab1's clusters early. Sandboxes also clean themselves up when they expire |

## Sharing the clusters

Give a developer or tester access to every cluster:

1. Ask them for their **public IP** (for example from `curl https://checkip.amazonaws.com`) and their **SSH public key** (the contents of `~/.ssh/id_ed25519.pub`). If they don't have a key yet, they can create one with `ssh-keygen -t ed25519`.
2. Add a line to `users.txt`. The first time, create it with `cp users.txt.example users.txt`:

   ```text
   # name     role    ip              key
   alice      admin   203.0.113.10    ssh-ed25519 AAAAC3Nza... alice@laptop
   ```

3. Run `./up.sh`. When the clusters already exist it takes about a minute.
4. Send them the folder `share/<name>/`, privately, because it contains their access token. Inside:
   - `kubeconfig.yaml`
   - `tunnel.sh`
   - `README.txt` with their instructions

On every cluster, each person gets:

| What | Detail |
| ---- | ------ |
| Kubernetes account | A ServiceAccount `lab-access/<name>` with a token, bound to a ClusterRole |
| Firewall | Their IP is allowed on SSH (22) and the Kubernetes API (6443) |
| SSH | A tunnel-only account on `master1` using their key. It has no shell and no sudo, and can only forward to the API server |

Each person can connect in two ways:
- **Direct:** the context `lab1-c1`.
- **SSH tunnel:** run `tunnel.sh`, then use the context `lab1-c1-tunnel`. The tunnel is for networks that intercept TLS, such as a corporate VPN. On those networks the direct context fails with `x509: certificate signed by unknown authority`.

**Roles.** Change the role in `users.txt` and re-run `./up.sh`. The old binding is replaced.

| Role | ClusterRole | Can do |
| ---- | ----------- | ------ |
| `admin` | `cluster-admin` | Everything |
| `edit` | `edit` | Create and change workloads in any namespace. No RBAC, nodes or namespaces |
| `view` | `view` | Read-only. No secrets |

**Revoking access.** Delete the person's line and re-run `./up.sh`. Their token stops working, and their SSH account, firewall rule and bundle are removed.

**Each day:** new sandboxes mean new IPs and new tokens. After the morning `./up.sh`, send the regenerated `share/` folders again. If someone's IP changes, update `users.txt` and re-run.

## How it works

- **One Terraform workspace per lab** (`lab1`, `lab2`, `lab3`), each using its own keys from `labs.env`.
- **New-sandbox detection.** `up.sh` remembers each lab's AWS account ID. If the keys belong to a new sandbox, it discards the old state, SSH key and kubeconfigs, because Pluralsight has already deleted those resources.
- **Instance-limit check.** Before creating anything, `up.sh` counts the instances already in the sandbox. It stops with a clear message if the new clusters would go over 9, so the sandbox's abuse monitoring never triggers.
- **Cluster build.** Terraform creates the key pair and, for each cluster, a security group and 3 instances. It then SSHes into `master1`, clones [k8-cluster-automation](https://github.com/rvinodrajendran/k8-cluster-automation) and runs its `deploy.sh` in non-interactive mode (containerd, kubeadm, Flannel, worker join). The output is also saved to `~/deploy.log` on `master1`.
- **Kubeconfigs.** Each cluster's admin kubeconfig is copied to `~/.kube/pluralsight/<lab>-<cluster>.yaml` and merged into `~/.kube/pluralsight.yaml`. Your own `~/.kube/config` is not touched. The API server's certificate only lists the private IP, so the kubeconfig connects to the public IP and checks the certificate against the name `kubernetes`, which kubeadm always includes.
- **Access.** SSH (22) and the Kubernetes API (6443) are open only to your current public IP. If your IP changes, re-run `./up.sh`.

## Settings (`labs.env`)

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `REGION` | `us-east-1` | `us-east-1` or `us-west-2` |
| `CLUSTERS_PER_LAB` | `3` | 1–3 |
| `LABn_CLUSTERS` | — | Override for one lab, for example when it already runs other instances |

Instance types, disk size and the Ansible repo/branch are Terraform variables in [terraform/variables.tf](terraform/variables.tf).

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `AWS rejected the keys` | The sandbox restarted or the keys were mistyped. Paste the current keys into `labs.env` |
| `not enough room: N other instance(s)` | Terminate the other instances in that sandbox, or set `LABn_CLUSTERS` lower |
| A cluster fails during deploy | `ssh -i keys/labN.pem ubuntu@<ip> cat deploy.log`, then `./up.sh labN` |
| `kubectl` times out | Your public IP changed. Re-run `./up.sh` to update the security groups |
| `x509: certificate signed by unknown authority` | A firewall or VPN is intercepting TLS. Turn off the VPN, or use an SSH tunnel to `master1` (shared users: `tunnel.sh`) |
| A shared user can't connect | Their IP in `users.txt` is out of date. Ask them for the current one and re-run `./up.sh` |

## Layout

```text
up.sh / down.sh / lib.sh     entry points
access.sh                    users.txt -> accounts, firewall rules, share/ bundles
remote/grant-access.sh       runs on each master1: ServiceAccounts, RBAC, tunnel-only SSH users
labs.env.example             template for daily keys (labs.env is git-ignored)
users.txt.example            template for shared users (users.txt is git-ignored)
terraform/                   root config: key pair, N x cluster module
terraform/modules/cluster/   security group, 3 instances, deploy.sh bootstrap
keys/  .labs/  share/        generated: SSH keys, logs, tokens, bundles (git-ignored)
```
