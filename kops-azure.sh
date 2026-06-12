#!/bin/bash
# =============================================================================
#  Kubernetes Cluster Setup on Azure using kops
#  (Azure port of the classic AWS kops lab.)
#
#  WHAT THIS DOES
#    1. Installs kops (if missing) into ~/bin.
#    2. Generates an SSH key (if missing) for the cluster nodes.
#    3. Creates an Azure Storage Account + blob container to hold kops "state".
#    4. Creates a Kubernetes cluster (1 control-plane + 2 worker VMs by default).
#    5. Waits until the cluster is ready and prints the nodes.
#    If any step fails, it automatically rolls back what it created.
#
#  BEFORE YOU RUN — prerequisites
#    - Run this in Azure Cloud Shell (az + kubectl come pre-installed), or on a
#      machine where the Azure CLI and kubectl are installed.
#    - Log in first:            az login
#    - You need TWO permissions on the target resource group:
#        * "Contributor"                    (to create VMs + the storage account)
#        * "Storage Blob Data Contributor"  (kops reads/writes state via your
#                                            Azure AD identity, not a key)
#      If you lack the second one, ask an admin (an Owner) to grant it:
#        az role assignment create \
#          --assignee "<your-object-id>" \
#          --role "Storage Blob Data Contributor" \
#          --scope "/subscriptions/<sub-id>/resourceGroups/<rg-name>"
#      (Find your object id with:  az ad signed-in-user show --query id -o tsv)
#
#  HOW TO RUN
#    1. Edit the USER CONFIGURATION block below (at minimum, set USERNAME).
#    2. Make it executable:     chmod +x kops-azure.sh
#    3. Run it:                 ./kops-azure.sh
#    You can also override any setting without editing the file, e.g.:
#        USERNAME=alice AZURE_LOCATION=eastus NODE_COUNT=3 ./kops-azure.sh
#
#  COST WARNING
#    This creates real, billable Azure VMs (3 by default). Remember to delete
#    the cluster when you are done — the exact command is printed at the end.
# =============================================================================

# Safety flags:
#   -e  exit immediately if any command fails
#   -u  treat use of an unset variable as an error
#   -o pipefail  a pipeline fails if ANY command in it fails (not just the last)
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════╗
# ║   USER CONFIGURATION  —  EDIT THE VALUES BELOW                 ║
# ║   Every value can also be overridden at runtime via an env var ║
# ║   of the same name, e.g.:   AZURE_LOCATION=eastus ./kops-azure.sh
# ╚══════════════════════════════════════════════════════════════╝

# ---- Identity & placement -------------------------------------------------
# Your name – used to build the cluster and storage-account names.
# REQUIRED, no default: you must supply it (interactively, via env var, or here).
USERNAME="${USERNAME:-}"

# Azure subscription ID. Leave EMPTY ("") to auto-detect the active az login.
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-de5b8038-1724-4678-9a44-c5d55ed7f54f}"

# Azure region and the EXISTING resource group to deploy into. (required)
AZURE_LOCATION="${AZURE_LOCATION:-centralindia}"
RG_NAME="${RG_NAME:-Docker-FBS-Training}"

# kops availability zone. Leave EMPTY ("") to derive it as <region>-1.
KOPS_AZ="${KOPS_AZ:-}"

# ---- Cluster sizing (how many VMs and how big) ----------------------------
CONTROL_PLANE_COUNT="${CONTROL_PLANE_COUNT:-1}"          # number of master/control-plane VMs
CONTROL_PLANE_SIZE="${CONTROL_PLANE_SIZE:-Standard_D2s_v3}"   # master VM size (2 vCPU / 8 GB)
CONTROL_PLANE_VOLUME_SIZE="${CONTROL_PLANE_VOLUME_SIZE:-50}"  # master disk size in GB
NODE_COUNT="${NODE_COUNT:-2}"                            # number of worker VMs
NODE_SIZE="${NODE_SIZE:-Standard_D2s_v3}"               # worker VM size (2 vCPU / 8 GB)
NODE_VOLUME_SIZE="${NODE_VOLUME_SIZE:-50}"              # worker disk size in GB

# ---- Misc -----------------------------------------------------------------
# Blob container that stores kops state.
CONTAINER_NAME="${CONTAINER_NAME:-kops-state}"
# SSH key for the cluster nodes (auto-generated if it doesn't exist).
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
# Roll back any resources created if the script fails (true / false).
KOPS_CLEANUP_ON_FAILURE="${KOPS_CLEANUP_ON_FAILURE:-true}"
# Tag/label key used to stamp ownership on the Azure resources and the k8s nodes.
# Azure resources get  <key>=<username>;  each k8s node gets  <key>=<username>-<nodename>.
OWNER_TAG_KEY="${OWNER_TAG_KEY:-username}"

# ╔══════════════════════════════════════════════════════════════╗
# ║   END USER CONFIGURATION  —  nothing below needs editing       ║
# ╚══════════════════════════════════════════════════════════════╝

echo "=================================================="
echo "  Kubernetes Cluster Setup on Azure using Kops"
echo "=================================================="
echo ""

# ── Interactive configuration ─────────────────────────────────────────────
# Prompt the user for each setting, showing the current value (from the
# defaults above, or an env-var override) in [brackets]. Pressing Enter keeps
# that value. Auto-skipped when there's no terminal (e.g. piped/CI runs) or
# when INTERACTIVE=false, so non-interactive env-var overrides still work.
INTERACTIVE="${INTERACTIVE:-true}"

ask() {
  # $1 = variable name, $2 = human-readable prompt
  local _name="$1" _prompt="$2" _current _input
  _current="${!_name}"
  read -r -p "  ${_prompt} [${_current}]: " _input || _input=""
  printf -v "$_name" '%s' "${_input:-$_current}"
}

ask_required() {
  # Like ask(), but has no default and keeps re-asking until a value is typed.
  local _name="$1" _prompt="$2" _input
  while :; do
    read -r -p "  ${_prompt}: " _input || _input=""
    [ -n "$_input" ] && break
    echo "    ⚠️  This value is required — please enter it." >&2
  done
  printf -v "$_name" '%s' "$_input"
}

if [ "$INTERACTIVE" = "true" ] && [ -t 0 ]; then
  echo "Enter your settings (press Enter to accept the [default]):"
  echo ""
  ask_required USERNAME     "Your name (REQUIRED — names the cluster + storage account)"
  ask AZURE_SUBSCRIPTION_ID "Azure subscription ID (blank = auto-detect)"
  ask AZURE_LOCATION        "Azure region"
  ask RG_NAME               "Existing resource group to deploy into"
  ask KOPS_AZ               "Availability zone (blank = <region>-1)"
  ask CONTROL_PLANE_COUNT   "Number of control-plane VMs"
  ask CONTROL_PLANE_SIZE    "Control-plane VM size"
  ask NODE_COUNT            "Number of worker VMs"
  ask NODE_SIZE             "Worker VM size"
  echo ""
fi

# ── Validate & derive configuration ───────────────────────────────────────
# Subscription: auto-detect from the active az session if left empty.
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
  AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null || true)
fi

# Required values must be set (edited above or passed as an env var).
for _var in USERNAME AZURE_SUBSCRIPTION_ID AZURE_LOCATION RG_NAME; do
  if [ -z "${!_var}" ]; then
    echo "ERROR: '$_var' is empty. Edit the USER CONFIGURATION block at the top" >&2
    echo "       of this script (or pass it as an environment variable)." >&2
    [ "$_var" = "AZURE_SUBSCRIPTION_ID" ] && \
      echo "       Tip: run 'az login' so it can be auto-detected." >&2
    exit 1
  fi
done

# Derived values.
lower_username=$(echo "$USERNAME" | sed 's/ //g' | tr '[:upper:]' '[:lower:]')
date_now=$(date "+%F-%H-%M")
# kops on Azure requires the cluster name to end in .k8s.local for gossip DNS.
CLUSTER_NAME="${lower_username}-${date_now}.k8s.local"
# Storage account names: 3-24 chars, lowercase alphanumeric only.
SA_NAME=$(echo "${lower_username}kopsstate" | tr -cd '[:alnum:]' | cut -c1-20)
# Availability zone: derive as <region>-1 unless explicitly set above.
KOPS_AZ="${KOPS_AZ:-${AZURE_LOCATION}-1}"

echo "Your Kubernetes cluster name will be: $CLUSTER_NAME"
echo ""

# ── On-screen progress helper ─────────────────────────────────────────────
# Prints a clear, numbered banner before each phase so you can follow where
# the script is at a glance (useful amid kops' very verbose output).
STEP_NUM=0
STEP_TOTAL=7
step() {
  STEP_NUM=$((STEP_NUM + 1))
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  STEP ${STEP_NUM}/${STEP_TOTAL}:  $1"
  echo "════════════════════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────
# FAILURE CLEANUP
# If the script exits non-zero, tear down whatever it created so
# nothing is left billing. (Toggle via KOPS_CLEANUP_ON_FAILURE above.)
# ──────────────────────────────────────────────────────────────
# State flags – flipped to 1 as each resource is successfully created.
STORAGE_ACCOUNT_CREATED=0
CLUSTER_CREATED=0
BASHRC_APPENDED=0

cleanup_on_failure() {
  local exit_code=$?
  trap - EXIT                       # prevent re-entry
  [ "$exit_code" -eq 0 ] && exit 0  # successful run: nothing to undo

  if [ "$KOPS_CLEANUP_ON_FAILURE" != "true" ]; then
    echo ""
    echo "⚠️  Script failed (exit $exit_code). Cleanup is disabled (KOPS_CLEANUP_ON_FAILURE=$KOPS_CLEANUP_ON_FAILURE)."
    echo "    Any partially-created resources are still billing – remove them manually."
    exit "$exit_code"
  fi

  echo ""
  echo "❌  Script failed (exit $exit_code). Rolling back resources created in this run..."

  # 1. Delete the kops cluster (VMs, disks, networking).
  if [ "$CLUSTER_CREATED" -eq 1 ]; then
    echo ">>> Deleting kops cluster: $CLUSTER_NAME ..."
    kops delete cluster --name "$CLUSTER_NAME" --state "$KOPS_STATE_STORE" --yes \
      || echo "    (cluster delete failed – run manually: kops delete cluster --name $CLUSTER_NAME --state $KOPS_STATE_STORE --yes)"
  fi

  # 2. Delete the storage account (also removes the state container).
  if [ "$STORAGE_ACCOUNT_CREATED" -eq 1 ]; then
    echo ">>> Deleting storage account: $SA_NAME ..."
    az storage account delete --name "$SA_NAME" --resource-group "$RG_NAME" --yes \
      || echo "    (storage account delete failed – run manually: az storage account delete --name $SA_NAME --resource-group $RG_NAME --yes)"
  fi

  # 3. Remove the exports this run appended to ~/.bashrc (they point at
  #    now-deleted resources and contain the storage secret).
  if [ "$BASHRC_APPENDED" -eq 1 ] && [ -f "$HOME/.bashrc" ]; then
    echo ">>> Removing kops exports from ~/.bashrc ..."
    sed -i "/# >>> kops-azure ${SA_NAME} >>>/,/# <<< kops-azure ${SA_NAME} <<</d" "$HOME/.bashrc" \
      || echo "    (could not edit ~/.bashrc – remove the kops-azure ${SA_NAME} block manually)"
  fi

  echo ">>> Rollback complete."
  exit "$exit_code"
}
trap cleanup_on_failure EXIT

# ──────────────────────────────────────────────────────────────
# INSTALL DEPENDENCIES (no sudo – runs in Azure Cloud Shell)
# az and kubectl are pre-installed; we only need kops
# ──────────────────────────────────────────────────────────────
step "Checking tools (az / kubectl / kops)"

# Ensure ~/bin exists and is on PATH
mkdir -p "$HOME/bin"
export PATH="$HOME/bin:$PATH"

echo ">>> Azure CLI: $(az version --query '"azure-cli"' -o tsv)"
echo ">>> kubectl  : $(kubectl version --client --short 2>/dev/null || true)"

# kops
if ! command -v kops &>/dev/null; then
  echo ">>> Installing kops to ~/bin..."
  KOPS_VER=$(curl -fsSL https://api.github.com/repos/kubernetes/kops/releases/latest \
             | grep tag_name | cut -d '"' -f4)
  curl -fsSL "https://github.com/kubernetes/kops/releases/download/${KOPS_VER}/kops-linux-amd64" \
       -o "$HOME/bin/kops"
  chmod +x "$HOME/bin/kops"
else
  echo ">>> kops already installed: $(kops version)"
fi

echo ">>> All tools ready."

# ──────────────────────────────────────────────────────────────
# SSH KEY
# ──────────────────────────────────────────────────────────────
step "Preparing SSH key"
if [ ! -f "$SSH_KEY" ]; then
  echo ">>> Generating SSH key pair at $SSH_KEY..."
  mkdir -p "$(dirname "$SSH_KEY")"
  ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_KEY"
else
  echo ">>> SSH key already exists at $SSH_KEY"
fi

# ──────────────────────────────────────────────────────────────
# AZURE ACCOUNT (uses existing az login session)
# ──────────────────────────────────────────────────────────────
step "Selecting Azure subscription"
echo ">>> Setting active subscription..."
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
echo ">>> Using subscription: $AZURE_SUBSCRIPTION_ID"

# ──────────────────────────────────────────────────────────────
# AZURE STATE STORE (Blob Storage – replaces S3)
# ──────────────────────────────────────────────────────────────
step "Setting up kops state store (Azure Blob)"
echo ">>> Using existing resource group: $RG_NAME"

# Create the storage account only if it doesn't already exist, so the
# failure-cleanup never deletes a pre-existing account (and its state).
if az storage account show --name "$SA_NAME" --resource-group "$RG_NAME" --output none 2>/dev/null; then
  echo ">>> Storage account already exists, reusing: $SA_NAME"
else
  echo ">>> Creating storage account: $SA_NAME..."
  az storage account create \
    --name "$SA_NAME" \
    --resource-group "$RG_NAME" \
    --location "$AZURE_LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --output none
  STORAGE_ACCOUNT_CREATED=1   # only WE created it → safe to delete on failure

  # A brand-new account's control plane reports success BEFORE its data plane
  # (blob endpoint + DNS) is reachable. Wait for provisioning to finish so the
  # container create below doesn't hit "ResourceNotFound".
  echo ">>> Waiting for storage account to finish provisioning..."
  for (( i=0; i<20; i++ )); do
    _state=$(az storage account show --name "$SA_NAME" --resource-group "$RG_NAME" \
               --query provisioningState -o tsv 2>/dev/null || true)
    [ "$_state" = "Succeeded" ] && break
    sleep 5
  done
fi

# Create the blob container (uses your AAD identity). New-account DNS can still
# lag a few more seconds after provisioning, so retry on the transient
# "ResourceNotFound" instead of failing the whole run.
echo ">>> Ensuring blob container exists: $CONTAINER_NAME..."
for (( i=1; i<=12; i++ )); do
  if az storage container create \
       --name "$CONTAINER_NAME" \
       --account-name "$SA_NAME" \
       --auth-mode login \
       --output none 2>/tmp/kops_container_err; then
    break
  fi
  if [ "$i" -eq 12 ]; then
    echo "ERROR: blob container '$CONTAINER_NAME' could not be created after retries:" >&2
    cat /tmp/kops_container_err >&2
    exit 1
  fi
  echo "  ... storage endpoint not ready yet (attempt $i/12), retrying in 10s..."
  sleep 10
done

# ──────────────────────────────────────────────────────────────
# KOPS ENVIRONMENT VARIABLES
# kops (1.35+) talks to blob storage via your Azure AD identity, NOT a
# shared key. It reads the account from the state-store URL and *refuses*
# to run if AZURE_STORAGE_ACCOUNT is set, so we explicitly unset it.
# (Requires the "Storage Blob Data Contributor" role on the account.)
# ──────────────────────────────────────────────────────────────
export KOPS_STATE_STORE="azureblob://${SA_NAME}/${CONTAINER_NAME}"
unset AZURE_STORAGE_ACCOUNT AZURE_STORAGE_KEY

# kops on Azure reads the target subscription from this env var. It must be
# EXPORTED (not just a shell variable) so every kops command — create, update,
# validate, delete, and the failure-rollback — can see it.
export AZURE_SUBSCRIPTION_ID

# kops treats Azure as an ALPHA, feature-gated cloud, so every kops command
# (create / update / validate / delete) requires this flag to be exported.
export KOPS_FEATURE_FLAGS="${KOPS_FEATURE_FLAGS:-Azure}"

# Persist to ~/.bashrc (wrapped in markers so cleanup can remove it).
# No storage key is written – kops doesn't use one and it'd be a secret at rest.
{
  echo "# >>> kops-azure ${SA_NAME} >>>"
  echo "export KOPS_STATE_STORE=azureblob://${SA_NAME}/${CONTAINER_NAME}"
  echo "export KOPS_FEATURE_FLAGS=Azure"
  echo "export AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}"
  echo "# <<< kops-azure ${SA_NAME} <<<"
} >> "$HOME/.bashrc"
BASHRC_APPENDED=1

echo ">>> KOPS_STATE_STORE set to: $KOPS_STATE_STORE"

# ──────────────────────────────────────────────────────────────
# CREATE KUBERNETES CLUSTER
# ──────────────────────────────────────────────────────────────
step "Creating the cluster (provisions Azure VMs)"
echo ""
echo ">>> Creating Kubernetes cluster: $CLUSTER_NAME"
echo "    Cloud  : azure"
echo "    Region : $AZURE_LOCATION"
echo "    Zone   : $KOPS_AZ"
echo "    Masters: $CONTROL_PLANE_COUNT x $CONTROL_PLANE_SIZE"
echo "    Nodes  : $NODE_COUNT x $NODE_SIZE"
echo ""

# This is the step that provisions real (billable) Azure VMs.
# "--yes" tells kops to apply immediately instead of only printing a preview.
kops create cluster \
  --cloud=azure \
  --name="$CLUSTER_NAME" \
  --azure-subscription-id="$AZURE_SUBSCRIPTION_ID" \
  --azure-resource-group-name="$RG_NAME" \
  --zones="$KOPS_AZ" \
  --control-plane-count="$CONTROL_PLANE_COUNT" \
  --control-plane-size="$CONTROL_PLANE_SIZE" \
  --control-plane-volume-size="$CONTROL_PLANE_VOLUME_SIZE" \
  --node-count="$NODE_COUNT" \
  --node-size="$NODE_SIZE" \
  --node-volume-size="$NODE_VOLUME_SIZE" \
  --ssh-public-key="${SSH_KEY}.pub" \
  --cloud-labels="${OWNER_TAG_KEY}=${lower_username}" \
  --state="$KOPS_STATE_STORE" \
  --yes
CLUSTER_CREATED=1

step "Applying configuration & exporting kubeconfig"
echo ">>> Applying cluster configuration..."
kops update cluster "$CLUSTER_NAME" --yes --state="$KOPS_STATE_STORE"

# Export kubeconfig
kops export kubecfg --admin --state="$KOPS_STATE_STORE" --name="$CLUSTER_NAME"

# ──────────────────────────────────────────────────────────────
# VALIDATE CLUSTER
# The VMs take several minutes to boot and join the cluster, so we poll
# "kops validate cluster" up to 40 times (every 30s ≈ 20 minutes max).
# As soon as it reports "is ready" we stop and show the nodes.
# ──────────────────────────────────────────────────────────────
step "Waiting for the cluster to become ready"
echo ""
echo ">>> This takes ~10-15 minutes while the VMs boot and join..."
for (( x=0; x<40; x++ )); do
  echo "  ... validating cluster (attempt $((x+1))/40, elapsed ~$((x/2)) min)"
  # Run the check; save its output to status.txt and look for "is ready".
  if kops validate cluster --state="$KOPS_STATE_STORE" --name="$CLUSTER_NAME" > status.txt 2>/dev/null \
     && grep -q "is ready" status.txt; then
    echo ""
    echo "✅  Your cluster is now ready!"
    echo ""
    kubectl get nodes          # list the cluster nodes to confirm
    break
  else
    # Not ready yet. If this was the last attempt, give up and show why.
    if [ $x -eq 39 ]; then
      echo "❌  Cluster did not become ready in time. Check logs:"
      cat status.txt
      exit 1
    fi
    sleep 30                   # wait 30s before the next attempt
  fi
done

# ──────────────────────────────────────────────────────────────
# TAG / LABEL THE NODES WITH THE OWNER'S USERNAME
# Adds a Kubernetes label  <key>=<username>-<nodename>  to every node, e.g.
#   username=mehar-control-plane-centralindia-1000000
# (The Azure resources themselves are already tagged via --cloud-labels above.)
# ──────────────────────────────────────────────────────────────
echo ""
echo ">>> Labeling nodes with ${OWNER_TAG_KEY}=${lower_username}-<node> ..."
for node in $(kubectl get nodes -o name 2>/dev/null | sed 's|node/||'); do
  kubectl label node "$node" "${OWNER_TAG_KEY}=${lower_username}-${node}" --overwrite >/dev/null \
    && echo "    labeled: $node"
done
echo ""
kubectl get nodes -L "${OWNER_TAG_KEY}"   # show the new label column

echo ""
echo "=================================================="
echo "  Cluster name : $CLUSTER_NAME"
echo "  State store  : $KOPS_STATE_STORE (account: $SA_NAME)"
echo "  Resource group: $RG_NAME"
echo "=================================================="
echo ""
echo "Useful commands:"
echo "  kops get cluster --state=\$KOPS_STATE_STORE"
echo "  kubectl get nodes"
echo "  kops export kubeconfig --admin --state=\$KOPS_STATE_STORE --name=$CLUSTER_NAME"
echo ""
echo "To DELETE the cluster when done:"
echo "  kops delete cluster --name $CLUSTER_NAME --state \$KOPS_STATE_STORE --yes"

