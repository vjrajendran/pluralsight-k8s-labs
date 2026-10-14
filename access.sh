# Sharing the clusters with other people - sourced by up.sh.
#
# users.txt, one person per line:
#   <name>  <role>  <public ip or CIDR, comma-separated>  <ssh public key>
# role: admin (cluster-admin) | edit (change workloads) | view (read-only)

USERS_FILE=$ROOT/users.txt
ACCESS_DIR=$RUN_DIR/access             # tokens per cluster
SHARE_DIR=$ROOT/share                  # bundles to send to each person

USER_NAMES=() USER_ROLES=() USER_IPS=() USER_KEYS=()

load_users() {
    [[ -f $USERS_FILE ]] || return 0
    local line name role ips key n=0 reserved=" root ubuntu admin sudo daemon bin sys sync nobody sshd syslog lxd www-data "
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        line=${line%%#*}
        read -r name role ips key <<<"$line"
        [[ -n ${name:-} ]] || continue

        [[ $name =~ ^[a-z][a-z0-9-]{1,30}$ && $reserved != *" $name "* ]] ||
            die "users.txt line $n: name '$name' must be lowercase letters/digits/-, and not a system account"
        [[ $role == admin || $role == edit || $role == view ]] ||
            die "users.txt line $n: role must be admin, edit or view (got '$role')"
        [[ $ips =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?,?)+$ ]] ||
            die "users.txt line $n: '$ips' is not an IPv4 address or CIDR"
        [[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+ ]] ||
            die "users.txt line $n: the last field must be an SSH public key (ssh-ed25519 AAAA...)"
        [[ " ${USER_NAMES[*]} " != *" $name "* ]] || die "users.txt line $n: '$name' is listed twice"

        USER_NAMES+=("$name") USER_ROLES+=("$role") USER_IPS+=("$ips") USER_KEYS+=("$key")
    done <"$USERS_FILE"
}

# Terraform list of every shared user's IP as a /32 (or the CIDR given)
shared_cidrs_json() {
    local ips ip out=()
    for ips in "${USER_IPS[@]}"; do
        for ip in ${ips//,/ }; do
            [[ $ip == */* ]] || ip=$ip/32
            out+=("\"$ip\"")
        done
    done
    echo "[$(IFS=,; echo "${out[*]}")]"
}

# Create / update / revoke accounts on one cluster's master1 and keep the tokens
grant_access() {
    local ctx=$1 ip=$2 pem=$3 users="" i out
    for i in "${!USER_NAMES[@]}"; do
        users+="${USER_NAMES[i]} ${USER_ROLES[i]} ${USER_KEYS[i]}"$'\n'
    done

    out=$({ printf 'USERS=%q\n' "$users"; cat "$ROOT/remote/grant-access.sh"; } |
        ssh -i "$pem" "${SSH_OPTS[@]}" "ubuntu@$ip" 'bash -s')

    mkdir -p "$ACCESS_DIR"
    (umask 077 && grep '^TOKEN ' <<<"$out" | cut -d' ' -f2- >"$ACCESS_DIR/$ctx.tokens" || true)
    echo "[$ctx] access: ${#USER_NAMES[@]} user(s)"
}

# Local port each person's tunnel uses for a cluster: lab1-c2 -> 16012
tunnel_port() {
    local ctx=$1 lab c
    lab=${ctx%%-*}
    c=${ctx##*-c}
    echo $((16000 + ${lab#lab} * 10 + c))
}

# share/<name>/: kubeconfig.yaml, tunnel.sh, README.txt
build_bundles() {
    rm -rf "${SHARE_DIR:?}"
    ((${#USER_NAMES[@]})) || return 0

    local i name role ctx file ip ca token port clusters users contexts tunnels first
    for i in "${!USER_NAMES[@]}"; do
        name=${USER_NAMES[i]} role=${USER_ROLES[i]}
        clusters="" users="" contexts="" tunnels="" first=""

        for file in "$KUBE_DIR"/*.yaml; do
            [[ -f $file ]] || continue
            ctx=$(basename "$file" .yaml)
            token=$(awk -v n="$name" '$1 == n { print $2 }' "$ACCESS_DIR/$ctx.tokens" 2>/dev/null)
            [[ -n $token ]] || continue
            ip=$(awk '$1 == "server:" { sub("https://", "", $2); sub(":6443", "", $2); print $2; exit }' "$file")
            ca=$(awk '$1 == "certificate-authority-data:" { print $2; exit }' "$file")
            port=$(tunnel_port "$ctx")
            first=${first:-$ctx}

            clusters+="- name: $ctx
  cluster:
    server: https://$ip:6443
    tls-server-name: kubernetes
    certificate-authority-data: $ca
- name: $ctx-tunnel
  cluster:
    server: https://127.0.0.1:$port
    tls-server-name: kubernetes
    certificate-authority-data: $ca
"
            users+="- name: $ctx-$name
  user:
    token: $token
"
            contexts+="- name: $ctx
  context: {cluster: $ctx, user: $ctx-$name}
- name: $ctx-tunnel
  context: {cluster: $ctx-tunnel, user: $ctx-$name}
"
            tunnels+="ssh \"\${OPTS[@]}\" -L $port:127.0.0.1:6443 $name@$ip &   # $ctx-tunnel
"
        done
        [[ -n $first ]] || continue

        local dir=$SHARE_DIR/$name
        (
            umask 077
            mkdir -p "$dir"
            cat >"$dir/kubeconfig.yaml" <<KUBE
apiVersion: v1
kind: Config
clusters:
${clusters}users:
${users}contexts:
${contexts}current-context: $first
KUBE

            cat >"$dir/tunnel.sh" <<TUNNEL
#!/usr/bin/env bash
# Opens an SSH tunnel to every cluster so the "-tunnel" contexts work.
# Keep it running; Ctrl-C closes the tunnels.
#   ./tunnel.sh [path to your SSH private key]
KEY=\${1:-\$HOME/.ssh/id_ed25519}
OPTS=(-i "\$KEY" -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
trap 'kill 0' EXIT
${tunnels}echo "Tunnels open - use the -tunnel contexts. Ctrl-C to close."
wait
TUNNEL
            chmod 700 "$dir/tunnel.sh"

            cat >"$dir/README.txt" <<README
Kubernetes access for $name (role: $role) - generated $(date '+%Y-%m-%d %H:%M')

These clusters run in a temporary lab sandbox. Expect a new bundle each day.
Keep kubeconfig.yaml private - it contains your access token.

1) Direct (from ${USER_IPS[i]}):

     export KUBECONFIG=\$PWD/kubeconfig.yaml
     kubectl config get-contexts
     kubectl --context $first get nodes

2) Through SSH - use this if direct says "x509: certificate signed by unknown
   authority" or times out (common on corporate VPNs that inspect TLS):

     ./tunnel.sh ~/.ssh/<your private key>       # keep it running
     kubectl --context $first-tunnel get nodes   # in another terminal

   SSH only allows the tunnel - there is no shell on the servers.
README
        )
    done
}

print_bundles() {
    ((${#USER_NAMES[@]})) || return 0
    echo
    echo "Shared access (send each person their folder):"
    local i
    for i in "${!USER_NAMES[@]}"; do
        if [[ -f $SHARE_DIR/${USER_NAMES[i]}/kubeconfig.yaml ]]; then
            printf "  %-12s %-6s share/%s/\n" "${USER_NAMES[i]}" "${USER_ROLES[i]}" "${USER_NAMES[i]}"
        else
            printf "  %-12s %-6s (no clusters - check the logs)\n" "${USER_NAMES[i]}" "${USER_ROLES[i]}"
        fi
    done
}
