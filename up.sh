#!/usr/bin/env bash
#
# Build Kubernetes clusters in every Pluralsight AWS sandbox listed in labs.env.
#
#   ./up.sh              every lab with keys in labs.env (in parallel)
#   ./up.sh lab2         just one lab
#
# Pluralsight allows 9 EC2 instances per sandbox, so each lab holds up to
# 3 clusters (master1 + client1 + client2). Re-running is safe: a lab whose
# sandbox is unchanged is just brought up to date; a new sandbox starts clean.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/access.sh"

MAX_INSTANCES=9
NODES_PER_CLUSTER=3

# Write a kubeconfig for one cluster. kubeadm's API certificate only lists the
# private IP, so connect to the public IP and verify the cert as "kubernetes",
# a name kubeadm always includes.
write_kubeconfig() {
    local ctx=$1 ip=$2 pem=$3 conf
    # -n: don't let ssh read the caller's while-loop input
    conf=$(ssh -n -i "$pem" "${SSH_OPTS[@]}" "ubuntu@$ip" cat .kube/config)
    field() { awk -v k="$1:" '$1 == k { print $2; exit }' <<<"$conf"; }

    mkdir -p "$KUBE_DIR"
    (umask 077; cat > "$KUBE_DIR/$ctx.yaml" <<KUBE
apiVersion: v1
kind: Config
clusters:
- name: $ctx
  cluster:
    server: https://$ip:6443
    tls-server-name: kubernetes
    certificate-authority-data: $(field certificate-authority-data)
users:
- name: $ctx-admin
  user:
    client-certificate-data: $(field client-certificate-data)
    client-key-data: $(field client-key-data)
contexts:
- name: $ctx
  context:
    cluster: $ctx
    user: $ctx-admin
current-context: $ctx
KUBE
    )
}

deploy_lab() {
    local lab=$1 p=${1^^}
    local clusters_var="${p}_CLUSTERS"
    local clusters=${!clusters_var:-${CLUSTERS_PER_LAB:-3}}

    use_lab "$lab"
    echo "[$lab] $(date +%H:%M:%S) checking keys"

    # Catch keys mangled by copy/paste (e.g. shortened with "…" in a chat app)
    if [[ ! $AWS_ACCESS_KEY_ID =~ ^[A-Z0-9]{20}$ ]]; then
        echo "[$lab] ${p}_AWS_ACCESS_KEY_ID should be 20 letters/digits - it has ${#AWS_ACCESS_KEY_ID}. Copy it again from the sandbox page."
        return 1
    fi
    if [[ ! $AWS_SECRET_ACCESS_KEY =~ ^[A-Za-z0-9/+]{40}$ ]]; then
        local odd=${AWS_SECRET_ACCESS_KEY//[A-Za-z0-9\/+]/}
        echo "[$lab] ${p}_AWS_SECRET_ACCESS_KEY should be 40 characters - it has ${#AWS_SECRET_ACCESS_KEY}${odd:+, including '$odd'}."
        echo "[$lab] It was probably shortened when it was copied. Copy it again from the sandbox page."
        return 1
    fi

    local account
    if ! account=$(aws sts get-caller-identity --query Account --output text); then
        echo "[$lab] AWS rejected the keys - paste today's keys for $lab into labs.env"
        return 1
    fi

    # Pluralsight wipes a sandbox when it expires, so yesterday's state is stale
    if [[ "$(cat "$RUN_DIR/$lab.account" 2>/dev/null)" != "$account" ]]; then
        echo "[$lab] new sandbox (account $account) - starting from clean state"
        rm -f "$TF_DIR/terraform.tfstate.d/$lab"/terraform.tfstate* "$KEY_DIR/$lab.pem" "$KUBE_DIR/$lab"-*.yaml \
            "$ACCESS_DIR/$lab"-*.tokens
        echo "$account" > "$RUN_DIR/$lab.account"
    fi

    # Stay under the 9 instance cap (stopped instances count too)
    local total=0 ours=0 r states=Name=instance-state-name,Values=pending,running,stopping,stopped
    for r in us-east-1 us-west-2; do
        total=$((total + $(aws ec2 describe-instances --region "$r" --filters "$states" \
            --query 'length(Reservations[].Instances[])' --output text)))
        ours=$((ours + $(aws ec2 describe-instances --region "$r" --filters "$states" \
            Name=tag:Project,Values=pluralsight-k8s-labs "Name=tag:Lab,Values=$lab" \
            --query 'length(Reservations[].Instances[])' --output text)))
    done
    local others=$((total - ours)) needed=$((clusters * NODES_PER_CLUSTER))
    if (( others + needed > MAX_INSTANCES )); then
        echo "[$lab] not enough room: $others other instance(s) already in this sandbox +"
        echo "[$lab] $needed for $clusters cluster(s) > Pluralsight limit of $MAX_INSTANCES."
        echo "[$lab] Terminate the other instances or set ${p}_CLUSTERS lower in labs.env."
        return 1
    fi

    echo "[$lab] $(date +%H:%M:%S) creating $clusters cluster(s) in $REGION"
    local -a vars=(-var "clusters=$clusters" -var "region=$REGION" -var "shared_cidrs=$(shared_cidrs_json)")
    if ! tf apply -auto-approve -input=false "${vars[@]}"; then
        # Usually a dropped SSH session during a bootstrap. The install is
        # safe to re-run, so give everything one more go.
        echo "[$lab] $(date +%H:%M:%S) apply failed - retrying once"
        tf apply -auto-approve -input=false "${vars[@]}"
    fi

    echo "[$lab] $(date +%H:%M:%S) fetching kubeconfigs and sharing access"
    rm -f "$KUBE_DIR/$lab"-*.yaml "$ACCESS_DIR/$lab"-*.tokens
    local ctx ip
    while read -r ctx ip || [[ -n $ctx ]]; do  # last line has no newline
        write_kubeconfig "$ctx" "$ip" "$KEY_DIR/$lab.pem"
        grant_access "$ctx" "$ip" "$KEY_DIR/$lab.pem"
    done < <(tf output -raw masters)

    echo "[$lab] $(date +%H:%M:%S) done"
}

select_labs "$@"
lock_labs
load_users
init_terraform

echo "Started $(date +%H:%M). Progress per lab: tail -f .labs/<lab>.log"
declare -A pids
for lab in "${LABS[@]}"; do
    ( deploy_lab "$lab" ) > "$RUN_DIR/$lab.log" 2>&1 &
    pids[$lab]=$!
    echo "  $lab -> .labs/$lab.log"
done

failed=()
for lab in "${LABS[@]}"; do
    if wait "${pids[$lab]}"; then
        echo "✓ $lab ready ($(date +%H:%M))"
    else
        echo "✗ $lab failed - last lines of .labs/$lab.log:"
        tail -n 15 "$RUN_DIR/$lab.log" | sed 's/^/    /'
        failed+=("$lab")
    fi
done

merge_kubeconfigs
build_bundles

echo
echo "Clusters (kubeconfig: $MERGED_KUBECONFIG)"
if [[ -f $MERGED_KUBECONFIG ]]; then
    for ctx in $(KUBECONFIG=$MERGED_KUBECONFIG kubectl config get-contexts -o name | sort); do
        ready=$(KUBECONFIG=$MERGED_KUBECONFIG kubectl --context "$ctx" --request-timeout=10s get nodes --no-headers 2>/dev/null \
            | awk '$2 == "Ready" { n++ } END { print n + 0 }' || true)
        printf "  %-10s %s/3 nodes Ready\n" "$ctx" "$ready"
    done
    echo
    echo "Use them with:"
    echo "  export KUBECONFIG=$MERGED_KUBECONFIG"
    echo "  kubectl --context lab1-c1 get nodes"
fi

print_bundles

if [[ ${#failed[@]} -gt 0 ]]; then
    echo
    echo "Failed: ${failed[*]} - fix labs.env if needed, then re-run: ./up.sh ${failed[*]}"
    exit 1
fi
