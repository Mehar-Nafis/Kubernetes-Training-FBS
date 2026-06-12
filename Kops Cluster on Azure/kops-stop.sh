#!/bin/bash
# =============================================================================
#  STOP your kops cluster (deallocate ALL VMs — control plane + workers)
#
#  Powers off every VM in YOUR cluster so COMPUTE billing stops, while keeping
#  the cluster fully intact (disks, etcd data, API load-balancer IP all persist).
#  Resume later with ./kops-start.sh — it comes back as the SAME cluster.
#
#  This is the correct "everything to 0" for a nightly/weekend shutdown. It does
#  NOT scale capacity to 0 (which would DELETE the master and risk losing etcd).
#
#  HOW TO RUN
#    KOPS_USER=alice ./kops-stop.sh
#    …or just ./kops-stop.sh and type your username when asked.
#
#  COST NOTE
#    Deallocated VMs cost $0 for compute. You still pay a small amount for the
#    managed disks. To stop ALL charges, delete the cluster (kops-azure-cleanup.sh).
# =============================================================================
set -euo pipefail

KOPS_USER="${KOPS_USER:-${USERNAME:-}}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-de5b8038-1724-4678-9a44-c5d55ed7f54f}"
RG_NAME="${RG_NAME:-Docker-FBS-Training}"
CONTAINER_NAME="${CONTAINER_NAME:-kops-state}"

if [ -z "$KOPS_USER" ] && [ -t 0 ]; then
  read -r -p "Enter your username (same one you created the cluster with): " KOPS_USER
fi
[ -z "$KOPS_USER" ] && { echo "ERROR: KOPS_USER is required (e.g. KOPS_USER=alice ./kops-stop.sh)." >&2; exit 1; }

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

# Every VM Scale Set whose name carries this cluster's signature (control + nodes).
VMSS=$(az vmss list -g "$RG_NAME" --query "[?contains(name,'${CLUSTER}')].name" -o tsv 2>/dev/null)
[ -z "$VMSS" ] && { echo "ERROR: no VM Scale Sets found for $CLUSTER." >&2; exit 1; }

echo ">>> Deallocating (powering off) these scale sets:"
echo "$VMSS" | sed 's/^/      - /'
for s in $VMSS; do
  echo ">>> Stopping $s ..."
  az vmss deallocate -g "$RG_NAME" -n "$s" --output none
done

echo ""
echo "✅ '$CLUSTER' is fully stopped — compute billing has ceased."
echo "   Resume anytime with:  KOPS_USER=$lower_username ./kops-start.sh"
