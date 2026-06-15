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
# Capture BOTH stdout and stderr and the exit code, so a failure here is
# explained instead of silently aborting the script (set -euo pipefail would
# otherwise kill us right after the line above, before we refresh credentials —
# which is the #1 reason this script "does nothing" and kubectl still says 401).
echo ">>> Looking up your cluster..."
if ! KOPS_OUT=$(kops get clusters 2>&1); then
  if echo "$KOPS_OUT" | grep -qi "no clusters found"; then
    echo "No clusters found in your state store ($KOPS_STATE_STORE)." >&2
    echo "Either it was deleted, or the username doesn't match the one you" >&2
    echo "created it with (you entered: $KOPS_USER)." >&2
    exit 1
  fi
  echo "" >&2
  echo "ERROR: kops could not read your state store:" >&2
  echo "    $KOPS_STATE_STORE" >&2
  echo "$KOPS_OUT" | sed 's/^/    /' >&2
  echo "" >&2
  echo "Most common cause: your Azure login/token expired (kops can't reach the" >&2
  echo "state-store blob). Fix it with:" >&2
  echo "    az login" >&2
  echo "then re-run:  KOPS_USER=$KOPS_USER ./kops-connect.sh" >&2
  exit 1
fi
CLUSTERS=$(echo "$KOPS_OUT" | awk 'NR>1 && $1!="" {print $1}')
if [ -z "$CLUSTERS" ]; then
  echo "No clusters found in your state store ($KOPS_STATE_STORE)." >&2
  echo "Either it was deleted, or the username doesn't match the one you" >&2
  echo "created it with (you entered: $KOPS_USER)." >&2
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
# This is the step that actually fixes a 401 ("server has asked for client to
# provide credentials") — it writes a fresh admin cert into your kubeconfig.
echo ">>> Refreshing admin credentials..."
if ! kops export kubecfg --admin="$ADMIN_TTL" --name="$CLUSTER"; then
  echo "" >&2
  echo "ERROR: failed to export admin kubeconfig for $CLUSTER." >&2
  echo "If this looks like an auth error, run 'az login' and retry." >&2
  exit 1
fi
echo ">>> kubectl context set. Verifying API access..."
if kubectl get nodes --request-timeout=20s; then
  echo ""
  echo "✅ Connected to $CLUSTER (credential valid for $ADMIN_TTL)."
else
  echo ""
  echo "⚠️  Credentials were refreshed, but the API didn't answer yet." >&2
  echo "    • If you JUST started the cluster, wait 1-2 min then: kubectl get nodes" >&2
  echo "    • If it stays unreachable, the control plane may still be coming up." >&2
  echo "    (This is no longer a credential problem — the kubeconfig is now valid.)" >&2
fi
