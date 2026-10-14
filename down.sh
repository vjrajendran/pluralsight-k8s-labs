#!/usr/bin/env bash
#
# Destroy the clusters in one or more labs (sandboxes also expire on their own).
#
#   ./down.sh            every lab with keys in labs.env
#   ./down.sh lab2       just one lab

set -euo pipefail
source "$(dirname "$0")/lib.sh"

select_labs "$@"
init_terraform

for lab in "${LABS[@]}"; do
    echo "=== $lab"
    (
        use_lab "$lab"
        account=$(aws sts get-caller-identity --query Account --output text)
        if [[ "$(cat "$RUN_DIR/$lab.account" 2>/dev/null)" != "$account" ]]; then
            echo "Keys are for a different sandbox than the one $lab's state belongs to - nothing to destroy."
            exit 0
        fi
        tf destroy -auto-approve -input=false -var "region=$REGION"
    )
    rm -f "$KUBE_DIR/$lab"-*.yaml
done

merge_kubeconfigs
