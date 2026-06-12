#!/bin/bash
# =============================================================================
#  Reconnect to YOUR kops cluster  (companion to kops-azure.sh)
#
#  Run this ANY time you need kubectl access again — e.g.:
#    • you opened a fresh Cloud Shell / CLI (env vars & PATH are gone), or
#    • your admin certificate expired (~18h) and kubectl says "Unauthorized".
#
#  It does NOT create or delete anything. It only:
#    1. Puts kops on your PATH and sets the kops env vars.
#    2. Finds your cluster in your own state store (no need to remember the name).
#    3. Refreshes your kubectl admin credentials (long-lived, see TTL below).
#
#  HOW TO RUN
#    KOPS_USER=alice ./kops-connect.sh
#    …or just ./kops-connect.sh and type your username when asked.
#    (Use the SAME username you used to CREATE the cluster.)
#    NOTE: the variable is KOPS_USER, not USERNAME — 'USERNAME' is a reserved
#    shell variable (your OS login) and can't be overridden on the command line.
# =============================================================================
set -euo pipefail

# ---- Settings (match kops-azure.sh) ---------------------------------------
# Your kops username. We read KOPS_USER (USERNAME is reserved by the shell), and
# fall back to USERNAME only as a convenience if KOPS_USER wasn't given.
KOPS_USER="${KOPS_USER:-${USERNAME:-}}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-de5b8038-1724-4678-9a44-c5d55ed7f54f}"
CONTAINER_NAME="${CONTAINER_NAME:-kops-state}"
# How long the refreshed admin credential stays valid. Default 1 week so you
# only need to run this once for the whole training. Override if you want.
ADMIN_TTL="${ADMIN_TTL:-168h}"

# Ask for the username if it wasn't supplied.
if [ -z "$KOPS_USER" ] && [ -t 0 ]; then
  read -r -p "Enter your username (same one you created the cluster with): " KOPS_USER
fi
[ -z "$KOPS_USER" ] && { echo "ERROR: KOPS_USER is required (e.g. KOPS_USER=alice ./kops-connect.sh)." >&2; exit 1; }

# ---- Environment (so a fresh shell can find kops + talk to Azure) ----------
export PATH="$HOME/bin:$PATH"
export KOPS_FEATURE_FLAGS=Azure
export AZURE_SUBSCRIPTION_ID
az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null \
  || { echo "Not logged in. Run 'az login' first, then re-run this script." >&2; exit 1; }

# Derive your state-store storage account from your username — EXACTLY the way
# kops-azure.sh did, so it always matches what you created.
lower_username=$(echo "$KOPS_USER" | sed 's/ //g' | tr '[:upper:]' '[:lower:]')
SA_NAME=$(echo "${lower_username}kopsstate" | tr -cd '[:alnum:]' | cut -c1-20)
export KOPS_STATE_STORE="azureblob://${SA_NAME}/${CONTAINER_NAME}"
echo ">>> State store: $KOPS_STATE_STORE"

# ---- Find your cluster (no need to remember the timestamped name) ----------
CLUSTERS=$(kops get clusters 2>/dev/null | awk 'NR>1 && $1!="" {print $1}')
if [ -z "$CLUSTERS" ]; then
  echo "No clusters found in your state store. Either it was deleted, or the" >&2
  echo "username doesn't match the one you created it with." >&2
  exit 1
fi

# If there's exactly one, use it. If several, let you pick.
COUNT=$(echo "$CLUSTERS" | grep -c .)
if [ "$COUNT" -eq 1 ]; then
  CLUSTER="$CLUSTERS"
else
  echo "You have several clusters:"
  echo "$CLUSTERS" | nl -w2 -s'. '
  read -r -p "Pick a number: " _n
  CLUSTER=$(echo "$CLUSTERS" | sed -n "${_n}p")
  [ -z "$CLUSTER" ] && { echo "Invalid choice." >&2; exit 1; }
fi
echo ">>> Using cluster: $CLUSTER"

# ---- Refresh credentials & set kubectl context -----------------------------
kops export kubecfg --admin="$ADMIN_TTL" --name="$CLUSTER"
echo ">>> kubectl context set. Verifying..."
kubectl get nodes
echo ""
echo "✅ Connected to $CLUSTER (credential valid for $ADMIN_TTL)."
