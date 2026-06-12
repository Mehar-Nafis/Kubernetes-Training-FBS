#!/bin/bash
# =============================================================================
#  START your kops cluster (power the VMs back on after ./kops-stop.sh)
#
#  Brings every deallocated VM in YOUR cluster back online. Because stop only
#  *deallocated* (didn't delete) the scale sets, they resume at their previous
#  size — i.e. the SAME 1 control-plane + 2 workers you had before.
#
#  HOW TO RUN
#    KOPS_USER=alice ./kops-start.sh
#    …or just ./kops-start.sh and type your username when asked.
#
#  AFTER IT STARTS
#    Give it ~3-5 min, then verify:  kubectl get nodes
#    If kubectl can't reach the API, refresh creds:  KOPS_USER=alice ./kops-connect.sh
# =============================================================================
set -euo pipefail

KOPS_USER="${KOPS_USER:-${USERNAME:-}}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-de5b8038-1724-4678-9a44-c5d55ed7f54f}"
RG_NAME="${RG_NAME:-Docker-FBS-Training}"
CONTAINER_NAME="${CONTAINER_NAME:-kops-state}"

if [ -z "$KOPS_USER" ] && [ -t 0 ]; then
  read -r -p "Enter your username (same one you created the cluster with): " KOPS_USER
fi
[ -z "$KOPS_USER" ] && { echo "ERROR: KOPS_USER is required (e.g. KOPS_USER=alice ./kops-start.sh)." >&2; exit 1; }

export PATH="$HOME/bin:$PATH"
export KOPS_FEATURE_FLAGS=Azure
export AZURE_SUBSCRIPTION_ID
az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null \
  || { echo "Not logged in. Run 'az login' first, then re-run." >&2; exit 1; }

# Find this user's cluster name from their state store.
lower_username=$(echo "$KOPS_USER" | sed 's/ //g' | tr '[:upper:]' '[:lower:]')
SA_NAME=$(echo "${lower_username}kopsstate" | tr -cd '[:alnum:]' | cut -c1-20)
export KOPS_STATE_STORE="azureblob://${SA_NAME}/${CONTAINER_NAME}"
CLUSTER=$(kops get clusters 2>/dev/null | awk 'NR>1 && $1!="" {print $1; exit}')
[ -z "$CLUSTER" ] && { echo "ERROR: no cluster found in $KOPS_STATE_STORE." >&2; exit 1; }
echo ">>> Cluster: $CLUSTER"

# Start the control-plane scale set FIRST so the API/etcd is up before workers.
VMSS_ALL=$(az vmss list -g "$RG_NAME" --query "[?contains(name,'${CLUSTER}')].name" -o tsv 2>/dev/null)
[ -z "$VMSS_ALL" ] && { echo "ERROR: no VM Scale Sets found for $CLUSTER." >&2; exit 1; }
VMSS_CP=$(echo "$VMSS_ALL" | grep -i "control-plane\|master" || true)
VMSS_NODES=$(echo "$VMSS_ALL" | grep -vi "control-plane\|master" || true)

start_one() { echo ">>> Starting $1 ..."; az vmss start -g "$RG_NAME" -n "$1" --output none; }

for s in $VMSS_CP;    do start_one "$s"; done
for s in $VMSS_NODES; do start_one "$s"; done

echo ""
echo "✅ '$CLUSTER' is starting back up (1 control-plane + its workers)."
echo "   Wait ~3-5 min, then:  kubectl get nodes"
echo "   API unreachable? refresh creds:  KOPS_USER=$lower_username ./kops-connect.sh"
