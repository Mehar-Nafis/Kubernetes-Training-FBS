#!/bin/bash
# =============================================================================
#  Kubernetes Cluster TEARDOWN on Azure (companion to kops-azure.sh)
#
#  WHAT THIS DOES
#    1. Finds the kops cluster(s) registered in your Azure blob state store
#       (read-only — just to show you what will be removed).
#    2. Deletes ONLY the resources your create script made, identified by their
#       unique signature:  name contains  <username>…k8s.local  OR  tag
#       username=<username>.  This removes the VM scale sets, disks, LB, public
#       IPs, NSG, route table, NAT gateway, VNet/subnet and ASGs of YOUR cluster.
#    3. Removes the cluster's now-dangling role assignment (its identity is gone).
#    4. Deletes the state-store storage account and removes the env exports
#       this lab added to ~/.bashrc.
#
#  SAFETY  (this is the important part — read it)
#    - It does NOT run 'kops delete cluster'. On Azure, kops deletes at the
#      RESOURCE-GROUP level and will try to delete OTHER users' resources
#      (e.g. every NSG in the RG). In a SHARED resource group that is unsafe.
#    - It only ever deletes resources whose name/tag matches YOUR username, the
#      kops storage account, and role assignments whose principal no longer
#      exists. It NEVER touches the shared resource group ('Docker-FBS-Training')
#      or anyone else's resources.
#    - It prints exactly what it will delete and asks for confirmation (skip: FORCE=true).
#
#  HOW TO RUN
#    1. Set USERNAME below to the same name you used in kops-azure.sh.
#    2. chmod +x kops-azure-cleanup.sh
#    3. ./kops-azure-cleanup.sh
#    Non-interactive example:
#       USERNAME=mehar FORCE=true ./kops-azure-cleanup.sh
# =============================================================================

set -euo pipefail

# ╔══════════════════════════════════════════════════════════════╗
# ║   USER CONFIGURATION  —  EDIT THE VALUES BELOW                 ║
# ║   (each can also be overridden via an env var of the same name)║
# ╚══════════════════════════════════════════════════════════════╝

# Your name – MUST match what you used when creating the cluster.
# REQUIRED, no default: it scopes the teardown, so only the cluster belonging to
# THIS username (<username>…k8s.local) is deleted. Supply it interactively, via
# env var, or here.
# NOTE: pass it as KOPS_USER, not USERNAME — 'USERNAME' is a reserved shell
# variable (your OS login) and can't be overridden on the command line.
USERNAME="${KOPS_USER:-${USERNAME:-}}"

# Azure subscription ID. Leave EMPTY ("") to auto-detect the active az login.
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"

# The EXISTING (shared) resource group the cluster was deployed into.
RG_NAME="${RG_NAME:-Docker-FBS-Training}"

# Blob container that stores kops state (matches kops-azure.sh).
CONTAINER_NAME="${CONTAINER_NAME:-kops-state}"

# Ownership tag key stamped on resources by kops-azure.sh (must match it).
# Used as an extra way to find this user's resources for deletion.
OWNER_TAG_KEY="${OWNER_TAG_KEY:-username}"

# Also delete the state-store storage account after the cluster is gone? (true/false)
DELETE_STORAGE_ACCOUNT="${DELETE_STORAGE_ACCOUNT:-true}"

# Set FORCE=true to skip the "are you sure?" confirmation prompt.
FORCE="${FORCE:-false}"

# ╔══════════════════════════════════════════════════════════════╗
# ║   END USER CONFIGURATION  —  nothing below needs editing       ║
# ╚══════════════════════════════════════════════════════════════╝

echo "=================================================="
echo "  Kubernetes Cluster TEARDOWN on Azure (kops)"
echo "=================================================="
echo ""

# ── Interactive configuration ─────────────────────────────────────────────
# Prompt for the username to tear down (and a few other settings), showing the
# current value in [brackets]; Enter keeps it. USERNAME has no default and is
# required — it scopes the deletion to <username>…k8s.local. Auto-skipped when
# there's no terminal (piped/CI) or INTERACTIVE=false, so env-var runs still work.
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

# Subscription picker: list the subscriptions this login can see and let the user
# pick the one their cluster lives in (must match what they used at create time).
# With one subscription it's selected automatically; the choice is made active so
# the state-store lookup below targets the right place.
ask_subscription() {
  local _names=() _ids=() _defs=() _n _id _def _input i mark n
  echo "  Fetching your Azure subscriptions..."
  while IFS=$'\t' read -r _n _id _def; do
    [ -z "$_id" ] && continue
    _names+=("$_n"); _ids+=("$_id"); _defs+=("$_def")
  done < <(az account list --query "[?state=='Enabled'].[name,id,isDefault]" -o tsv 2>/dev/null)

  n=${#_ids[@]}
  if [ "$n" -eq 0 ]; then
    echo "  (couldn't list subscriptions — are you logged in? 'az login') Falling back to free text / auto-detect."
    ask AZURE_SUBSCRIPTION_ID "Azure subscription ID (blank = auto-detect)"
    return
  fi
  if [ "$n" -eq 1 ]; then
    AZURE_SUBSCRIPTION_ID="${_ids[0]}"
    echo "  Only one subscription — using: ${_names[0]} (${_ids[0]})"
    az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true
    return
  fi

  echo "  You have $n subscriptions — pick the one your cluster is in (number), type an ID, or Enter to keep [${AZURE_SUBSCRIPTION_ID}]:"
  for (( i=0; i<n; i++ )); do
    mark=" "; [ "${_defs[$i]}" = "True" ] && mark="*"
    printf "      %2d)%s %s  (%s)\n" "$((i+1))" "$mark" "${_names[$i]}" "${_ids[$i]}"
  done
  echo "      (* = your current default subscription)"
  read -r -p "  Subscription [${AZURE_SUBSCRIPTION_ID}]: " _input || _input=""
  if [ -z "$_input" ]; then
    :
  elif [[ "$_input" =~ ^[0-9]+$ ]] && [ "$_input" -ge 1 ] && [ "$_input" -le "$n" ]; then
    AZURE_SUBSCRIPTION_ID="${_ids[$((_input-1))]}"
  else
    AZURE_SUBSCRIPTION_ID="$_input"
  fi
  [ -n "$AZURE_SUBSCRIPTION_ID" ] && az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true
}

if [ "$INTERACTIVE" = "true" ] && [ -t 0 ]; then
  echo "Enter the cluster to tear down (press Enter to accept the [default]):"
  echo ""
  ask_required USERNAME     "Username whose cluster to delete (REQUIRED)"
  ask_subscription                                 # list/select the subscription the cluster is in
  ask RG_NAME               "Resource group the cluster is in"
  ask DELETE_STORAGE_ACCOUNT "Also delete the kops state-store storage account? (true/false)"
  echo ""
fi

# ── On-screen progress helper ─────────────────────────────────────────────
STEP_NUM=0
STEP_TOTAL=6
step() {
  STEP_NUM=$((STEP_NUM + 1))
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  STEP ${STEP_NUM}/${STEP_TOTAL}:  $1"
  echo "════════════════════════════════════════════════════════════"
}

# Make kops/az reachable and set the Azure feature flag kops requires.
export PATH="$HOME/bin:$PATH"
export KOPS_FEATURE_FLAGS=Azure

# ── STEP 1: validate config & Azure login ─────────────────────────────────
step "Validating configuration & Azure login"

if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
  AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null || true)
fi
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
  echo "ERROR: No subscription. Set AZURE_SUBSCRIPTION_ID or run 'az login'." >&2
  exit 1
fi
if [ -z "$USERNAME" ]; then
  echo "ERROR: USERNAME is empty. Set it to the name used when creating the cluster." >&2
  exit 1
fi

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

# Storage-account name is derived from the username, exactly like kops-azure.sh.
lower_username=$(echo "$USERNAME" | sed 's/ //g' | tr '[:upper:]' '[:lower:]')
SA_NAME=$(echo "${lower_username}kopsstate" | tr -cd '[:alnum:]' | cut -c1-20)
RG_SCOPE="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}"

# kops reads the account from the URL and refuses to run if this env var is set.
unset AZURE_STORAGE_ACCOUNT AZURE_STORAGE_KEY 2>/dev/null || true
export KOPS_STATE_STORE="azureblob://${SA_NAME}/${CONTAINER_NAME}"

echo ">>> Subscription : $AZURE_SUBSCRIPTION_ID"
echo ">>> Resource group: $RG_NAME (shared — will NOT be deleted)"
echo ">>> State store  : $KOPS_STATE_STORE"

# Helper: list resource IDs in the RG that belong to this user's cluster(s).
# Matches two independent ways, so it catches everything:
#   1. By NAME  — every kops resource carries the '...k8s.local' suffix + username.
#   2. By TAG   — kops-azure.sh stamps  ${OWNER_TAG_KEY}=<username>  on each resource.
# Both are specific to this user, so it never touches another student's resources.
scan_orphans() {
  {
    az resource list -g "$RG_NAME" \
      --query "[?contains(name,'${lower_username}') && contains(name,'k8s.local')].id" -o tsv 2>/dev/null
    az resource list -g "$RG_NAME" \
      --query "[?tags.${OWNER_TAG_KEY}=='${lower_username}'].id" -o tsv 2>/dev/null
  } | sort -u || true
}

# ── STEP 2: discover cluster(s) in the state store ────────────────────────
step "Finding clusters in the state store"

CLUSTERS=""
STATE_STORE_EXISTS=false
if az storage account show --name "$SA_NAME" --resource-group "$RG_NAME" --output none 2>/dev/null; then
  STATE_STORE_EXISTS=true
  # Use -o json (a VALID format — 'name' is NOT valid) and parse with jq.
  # Crucially, distinguish a genuine error from an empty store: on a real
  # error we ABORT rather than risk deleting the state store with live VMs.
  set +e
  CLUSTERS_JSON=$(kops get clusters --state="$KOPS_STATE_STORE" -o json 2>/tmp/kops_get_err.txt)
  KOPS_RC=$?
  set -e
  if [ "$KOPS_RC" -eq 0 ] && [ -n "$CLUSTERS_JSON" ]; then
    CLUSTERS=$(echo "$CLUSTERS_JSON" | jq -r '.[].metadata.name' 2>/dev/null || true)
  elif grep -qiE "no clusters found" /tmp/kops_get_err.txt 2>/dev/null; then
    CLUSTERS=""                       # genuinely empty state store
  elif [ "$KOPS_RC" -ne 0 ]; then
    echo "ERROR: could not read the state store ($KOPS_STATE_STORE):" >&2
    sed 's/^/   /' /tmp/kops_get_err.txt >&2
    echo "Aborting — nothing deleted (so no live resources get orphaned)." >&2
    exit 1
  fi
else
  echo ">>> State store account '$SA_NAME' not found — will scan the RG directly."
fi

if [ -n "$CLUSTERS" ]; then
  echo ">>> Cluster(s) registered in state store:"
  echo "$CLUSTERS" | sed 's/^/      - /'
else
  echo ">>> No clusters registered in the state store."
fi

ORPHANS=$(scan_orphans)
[ -n "$ORPHANS" ] && echo ">>> $(echo "$ORPHANS" | grep -c .) cluster resource(s) present in $RG_NAME."

# ── STEP 3: confirmation ──────────────────────────────────────────────────
step "Confirmation"
if [ -z "$CLUSTERS" ] && [ -z "$ORPHANS" ] && [ "$STATE_STORE_EXISTS" = "false" ]; then
  echo ">>> Nothing to delete — environment already clean. Exiting."
  exit 0
fi
echo "About to delete — ONLY resources matching YOUR cluster:"
echo "  • All ${lower_username}…k8s.local resources in $RG_NAME (name- and tag-scoped)"
echo "  • Dangling kops role assignments (principal already deleted)"
[ "$DELETE_STORAGE_ACCOUNT" = "true" ] && [ "$STATE_STORE_EXISTS" = "true" ] && \
  echo "  • State-store storage account: $SA_NAME"
echo "  • The kops env exports in ~/.bashrc"
echo ""
echo "This will NOT run 'kops delete cluster' and will NOT touch the shared"
echo "resource group, other students' resources, or anything not named/tagged for you."
echo ""
if [ "$FORCE" != "true" ]; then
  read -rp "Type 'yes' to proceed: " CONFIRM
  [ "$CONFIRM" = "yes" ] || { echo ">>> Aborted. Nothing was deleted."; exit 0; }
fi

# ── STEP 4: delete THIS user's cluster resources (scoped by name + tag) ────
# We deliberately do NOT run 'kops delete cluster' here. On Azure, kops operates
# at the RESOURCE-GROUP level: it enumerates every resource of each type in the
# RG and tries to delete them — including OTHER users' network security groups
# and anything else it finds. In a SHARED resource group that is dangerous and
# has destroyed (or nearly destroyed) other students' resources.
#
# Instead we delete ONLY resources that carry this user's unique signature:
#   • name contains  <username>…k8s.local   (kops names every resource this way), or
#   • tag  ${OWNER_TAG_KEY}=<username>       (stamped by kops.sh via --cloud-labels).
# scan_orphans() encodes exactly that filter, so this can NEVER touch another
# student's resources — only the ones your create script made.
step "Deleting your cluster's resources (scoped to ${lower_username}…k8s.local)"
TARGETS=$(scan_orphans)
if [ -z "$TARGETS" ]; then
  echo ">>> No ${lower_username}…k8s.local resources found in $RG_NAME — already clean."
else
  echo ">>> Found $(echo "$TARGETS" | grep -c .) resource(s) belonging to your cluster:"
  echo "$TARGETS" | sed 's|.*/||; s/^/      - /'
  # Capture THIS cluster's managed-identity principal IDs BEFORE deleting the
  # scale sets (deleting them destroys the identities, so we can't read the IDs
  # afterwards). Step 5 uses these to remove ONLY this cluster's role
  # assignment(s) — never another student's live identity.
  CLUSTER_PRINCIPALS=$(echo "$TARGETS" | grep -i "virtualMachineScaleSets" | while IFS= read -r id; do
    [ -n "$id" ] && az resource show --ids "$id" --query "identity.principalId" -o tsv 2>/dev/null
  done | grep -v '^$' | sort -u)
  # Delete VM scale sets first so their instances/NICs/OS disks/identities are
  # released, which then lets the dependent networking resources delete cleanly.
  echo "$TARGETS" | grep -i "virtualMachineScaleSets" | while IFS= read -r id; do
    [ -n "$id" ] && az resource delete --ids "$id" >/dev/null 2>&1 && echo "   deleted a VM scale set"
  done
  # Retry-delete the remainder until all of YOUR resources are gone (handles
  # inter-resource dependencies, e.g. subnet must go before its vnet).
  for attempt in 1 2 3 4 5 6 7 8; do
    TARGETS=$(scan_orphans)
    [ -z "$TARGETS" ] && { echo "   ✅ all of your cluster's resources are gone."; break; }
    echo "   attempt $attempt: $(echo "$TARGETS" | grep -c .) remaining, deleting..."
    echo "$TARGETS" | xargs -r -n1 -P4 -I{} az resource delete --ids {} >/dev/null 2>&1 || true
    sleep 8
    if [ "$attempt" -eq 8 ]; then
      LEFT=$(scan_orphans)
      [ -n "$LEFT" ] && {
        echo "   ⚠️  Some of your resources are still present (may be mid-deletion):" >&2
        echo "$LEFT" | sed 's|.*/||; s/^/        - /' >&2
        echo "   Re-run this script in a minute to finish." >&2
      }
    fi
  done
fi

# ── STEP 5: remove THIS cluster's role assignment(s) ──────────────────────
# kops gave this cluster's managed identity a role assignment on the shared RG.
# We remove ONLY the assignments whose principalId matches the identities we
# captured in step 4 (this cluster's own scale sets). Matching by exact
# principalId needs NO Graph/directory lookup, so it can never touch another
# student's identity.
#
# DO NOT revert this to "delete every assignment whose principalName is
# null/empty". Non-admin callers can't resolve service-principal names via the
# Graph API, so principalName comes back null for EVERY live identity — that old
# logic deleted other students' live cluster roles and silently broke their
# clusters on the next stop/start (etcd-manager could no longer find its disks).
step "Removing this cluster's role assignment(s)"
if [ -n "${CLUSTER_PRINCIPALS:-}" ]; then
  removed=0
  for pid in $CLUSTER_PRINCIPALS; do
    RAS=$(az role assignment list --scope "$RG_SCOPE" \
      --query "[?principalId=='$pid'].id" -o tsv 2>/dev/null || true)
    [ -z "$RAS" ] && continue
    echo "$RAS" | xargs -r -n1 -I{} az role assignment delete --ids {} >/dev/null 2>&1 \
      && removed=$((removed + $(echo "$RAS" | grep -c .)))
  done
  if [ "$removed" -gt 0 ]; then
    echo "   ✅ removed $removed role assignment(s) belonging to this cluster's identity."
  else
    echo ">>> No role assignments found for this cluster's identity."
  fi
else
  echo ">>> Could not determine this cluster's identity (scale sets already deleted?)."
  echo "    Skipping role-assignment cleanup to avoid touching other clusters."
  echo "    If a dangling assignment truly remains, delete it by its exact principalId:"
  echo "      az role assignment list --scope \"$RG_SCOPE\" --query \"[?principalId=='<id>'].id\" -o tsv"
fi

# ── STEP 6: delete the state store & tidy ~/.bashrc ───────────────────────
step "Removing state store & local env exports"
if [ "$DELETE_STORAGE_ACCOUNT" = "true" ] && [ "$STATE_STORE_EXISTS" = "true" ]; then
  echo ">>> Deleting storage account: $SA_NAME ..."
  az storage account delete --name "$SA_NAME" --resource-group "$RG_NAME" --yes \
    && echo "    deleted." \
    || echo "    (delete failed — remove manually: az storage account delete --name $SA_NAME --resource-group $RG_NAME --yes)"
elif [ "$DELETE_STORAGE_ACCOUNT" != "true" ]; then
  echo ">>> Keeping storage account '$SA_NAME' (DELETE_STORAGE_ACCOUNT=false)."
else
  echo ">>> Storage account '$SA_NAME' already gone."
fi

if [ -f "$HOME/.bashrc" ]; then
  echo ">>> Cleaning kops exports from ~/.bashrc ..."
  sed -i "/# >>> kops-azure ${SA_NAME} >>>/,/# <<< kops-azure ${SA_NAME} <<</d" "$HOME/.bashrc" \
    || echo "    (could not edit ~/.bashrc — remove the kops-azure ${SA_NAME} block manually)"
fi

# ── Final verification ────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo "  Cleanup complete. Verifying nothing is left..."
echo "=================================================="
LEFT=$(az resource list --resource-group "$RG_NAME" \
        --query "[?contains(name,'${lower_username}') && contains(name,'k8s.local')].name" -o tsv 2>/dev/null || true)
if [ -z "$LEFT" ]; then
  echo "✅  No cluster resources matching '${lower_username}' remain in $RG_NAME."
else
  echo "⚠️  Some resources still present (may be mid-deletion):"
  echo "$LEFT" | sed 's/^/      - /'
  echo "   Re-run this script in a minute to finish the sweep."
fi
echo ""
echo "Done."
