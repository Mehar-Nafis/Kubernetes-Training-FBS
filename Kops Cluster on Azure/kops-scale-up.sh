#!/bin/bash
# =============================================================================
#  Scale UP your kops worker nodes  (control plane stays at 1)
#
#  Asks you how many WORKER nodes to run, then applies it. Intended to INCREASE
#  the cluster (e.g. more workers for a heavier exercise). The control plane is
#  left untouched at 1 — it is never scaled by this script.
#
#  HOW TO RUN
#    KOPS_USER=alice ./kops-scale-up.sh             # prompts for worker count
#    KOPS_USER=alice NODE_COUNT=3 ./kops-scale-up.sh     # non-interactive (3 workers)
#    …or just ./kops-scale-up.sh and type your username when asked.
#
#  NOTE
#    • The variable is KOPS_USER, not USERNAME (USERNAME is a reserved shell var).
#    • New VMs take ~3-5 min to boot and join. Watch: kubectl get nodes -w
# =============================================================================
set -euo pipefail

# How many worker nodes to run (override with NODE_COUNT=...; also the prompt default).
NODE_COUNT="${NODE_COUNT:-2}"

# ---- Identity & env --------------------------------------------------------
KOPS_USER="${KOPS_USER:-${USERNAME:-}}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-de5b8038-1724-4678-9a44-c5d55ed7f54f}"
CONTAINER_NAME="${CONTAINER_NAME:-kops-state}"
INTERACTIVE="${INTERACTIVE:-true}"

if [ -z "$KOPS_USER" ] && [ -t 0 ]; then
  read -r -p "Enter your username (same one you created the cluster with): " KOPS_USER
fi
[ -z "$KOPS_USER" ] && { echo "ERROR: KOPS_USER is required (e.g. KOPS_USER=alice ./kops-scale-up.sh)." >&2; exit 1; }

# Prompt for the worker count (showing the default in [brackets]; Enter keeps it).
if [ "$INTERACTIVE" = "true" ] && [ -t 0 ]; then
  read -r -p "  How many WORKER nodes? [${NODE_COUNT}]: " _input || _input=""
  NODE_COUNT="${_input:-$NODE_COUNT}"
  echo ""
fi
[[ "$NODE_COUNT" =~ ^[0-9]+$ ]] || { echo "ERROR: worker count must be a number." >&2; exit 1; }

export PATH="$HOME/bin:$PATH"
export KOPS_FEATURE_FLAGS=Azure
export AZURE_SUBSCRIPTION_ID
az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null \
  || { echo "Not logged in. Run 'az login' first, then re-run." >&2; exit 1; }

# Derive the state store from the username (exactly like kops-azure.sh).
lower_username=$(echo "$KOPS_USER" | sed 's/ //g' | tr '[:upper:]' '[:lower:]')
SA_NAME=$(echo "${lower_username}kopsstate" | tr -cd '[:alnum:]' | cut -c1-20)
export KOPS_STATE_STORE="azureblob://${SA_NAME}/${CONTAINER_NAME}"

# ---- Find the cluster and its WORKER instance group(s) ---------------------
CLUSTER=$(kops get clusters 2>/dev/null | awk 'NR>1 && $1!="" {print $1; exit}')
[ -z "$CLUSTER" ] && { echo "ERROR: no cluster found in $KOPS_STATE_STORE." >&2; exit 1; }
echo ">>> Cluster: $CLUSTER (control plane stays at 1; only workers change)"

WORKER_IGS=$(kops get ig --name="$CLUSTER" 2>/dev/null | awk '$2=="Node"{print $1}')
[ -z "$WORKER_IGS" ] && { echo "ERROR: no worker (Node) instance groups found." >&2; exit 1; }

# ---- Apply the new size to every worker pool -------------------------------
echo ">>> Scaling worker node(s) UP to: $NODE_COUNT"
for ig in $WORKER_IGS; do
  f="/tmp/ig-${ig}.yaml"
  kops get ig "$ig" --name="$CLUSTER" -o yaml > "$f"
  sed -i -E "s/^(\s*minSize:).*/\1 ${NODE_COUNT}/; s/^(\s*maxSize:).*/\1 ${NODE_COUNT}/" "$f"
  kops replace -f "$f"
  echo "    updated $ig -> min/max = $NODE_COUNT"
done

echo ">>> Applying changes (this provisions the new VMs)..."
kops update cluster --name="$CLUSTER" --yes

echo ""
echo "✅ Scaled '$CLUSTER' worker(s) up to $NODE_COUNT (control plane = 1)."
echo "   New VMs take ~3-5 min to join. Watch:  kubectl get nodes -w"
