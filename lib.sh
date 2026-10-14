# Shared by up.sh and down.sh

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TF_DIR=$ROOT/terraform
RUN_DIR=$ROOT/.labs                    # per-lab logs and sandbox account ids
KEY_DIR=$ROOT/keys
KUBE_DIR=$HOME/.kube/pluralsight       # one kubeconfig per cluster
MERGED_KUBECONFIG=$HOME/.kube/pluralsight.yaml
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)

unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN TF_WORKSPACE

if [[ ! -f $ROOT/labs.env ]]; then
    echo "labs.env not found - run: cp labs.env.example labs.env  and paste today's keys"
    exit 1
fi
# Only comments, blank lines and NAME=value (no spaces, $ or backticks in the
# value) - catches terminal output or other text pasted into the file
bad=$(grep -nvE '^[[:space:]]*(#.*)?$|^[A-Za-z_][A-Za-z0-9_]*=('"'"'[^'"'"']*'"'"'|"[^"$`]*"|[^[:space:]'"'"'"$`]*)[[:space:]]*(#.*)?$' "$ROOT/labs.env" | cut -c1-70 || true)
if [[ -n $bad ]]; then
    echo "labs.env has lines that aren't NAME=value - remove them and run again:" >&2
    echo "$bad" | sed 's/^/    line /' >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ROOT/labs.env"
REGION=${REGION:-us-east-1}

# Labs named on the command line, or every lab with keys in labs.env
select_labs() {
    LABS=("$@")
    if [[ ${#LABS[@]} -eq 0 ]]; then
        local n var
        for n in $(seq 1 9); do
            var="LAB${n}_AWS_ACCESS_KEY_ID"
            if [[ -n "${!var:-}" ]]; then LABS+=("lab$n"); fi
        done
    fi
    if [[ ${#LABS[@]} -eq 0 ]]; then
        echo "No lab keys found in labs.env"
        exit 1
    fi
}

# Point the AWS CLI and Terraform at one lab's sandbox
use_lab() {
    local p=${1^^}
    local key="${p}_AWS_ACCESS_KEY_ID" secret="${p}_AWS_SECRET_ACCESS_KEY"
    export AWS_ACCESS_KEY_ID=${!key:?"$key missing in labs.env"}
    export AWS_SECRET_ACCESS_KEY=${!secret:?"$secret missing in labs.env"}
    export AWS_REGION=$REGION
    export TF_WORKSPACE=$1
}

tf() {
    terraform -chdir="$TF_DIR" "$@"
}

init_terraform() {
    mkdir -p "$RUN_DIR"
    tf init -input=false >/dev/null
    local lab
    for lab in "${LABS[@]}"; do
        if [[ ! -d $TF_DIR/terraform.tfstate.d/$lab ]]; then
            tf workspace new "$lab" >/dev/null
        fi
    done
    tf workspace select default >/dev/null
}

# Rebuild ~/.kube/pluralsight.yaml from the per-cluster files
merge_kubeconfigs() {
    local files
    files=$(find "$KUBE_DIR" -maxdepth 1 -name '*.yaml' 2>/dev/null | sort | paste -sd:)
    if [[ -z $files ]]; then
        rm -f "$MERGED_KUBECONFIG"
        return
    fi
    (umask 077; KUBECONFIG=$files kubectl config view --flatten > "$MERGED_KUBECONFIG")
}
