# Kubernetes on Azure with kops — Setup & Teardown Guide

This guide explains how to stand up, operate, and tear down a Kubernetes cluster
on Azure using the scripts in this folder:

| Script | Purpose |
|---|---|
| [`kops-azure.sh`](kops-azure.sh) | **Create** the cluster (storage state store + 1 control‑plane + 2 worker VMs) |
| [`kops-connect.sh`](kops-connect.sh) | **Reconnect** — restore kubectl access in a fresh shell or after the admin cert expires |
| [`kops-scale-up.sh`](kops-scale-up.sh) / [`kops-scale-down.sh`](kops-scale-down.sh) | **Scale** the number of worker nodes up or down |
| [`kops-stop.sh`](kops-stop.sh) / [`kops-start.sh`](kops-start.sh) | **Stop / start** the whole cluster (power off all VMs to pause billing, then resume) |
| [`kops-azure-cleanup.sh`](kops-azure-cleanup.sh) | **Delete** the cluster and all of its Azure resources |

> **All the operate/teardown scripts take `KOPS_USER`, not `USERNAME`.** `USERNAME`
> is a reserved shell variable (your OS login) and silently overrides anything you
> pass on the command line, so the scripts read `KOPS_USER` (e.g.
> `KOPS_USER=alice ./kops-connect.sh`). Run any of them with no argument and they'll
> prompt for the username instead.

---

## 1. Prerequisites (tools & environment)

- **Run it in Azure Cloud Shell** (recommended) — `az` and `kubectl` come pre‑installed.
  On a normal machine you must install the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
  and [kubectl](https://kubernetes.io/docs/tasks/tools/) yourself.
- **kops** — the setup script auto‑installs it to `~/bin` if missing (no sudo needed).
- **You must be logged in:**
  ```bash
  az login
  ```
- **jq** — used by the cleanup script (pre‑installed in Cloud Shell).

> kops treats Azure as an **alpha** cloud, so every kops command needs
> `export KOPS_FEATURE_FLAGS=Azure`. **The scripts set this for you** — you only
> need it if you run kops commands manually.

---

## 2. Access / permissions required ⭐ (the important part)

Your Azure identity needs **three** roles, all scoped to the **existing resource
group** you deploy into (`Docker-FBS-Training`). You normally cannot grant these
yourself — ask an **Owner / User Access Administrator** to run the commands below.

| Role | Why kops needs it |
|---|---|
| **Contributor** | Create the storage account, VMs, network, load balancer, disks, etc. |
| **Storage Blob Data Contributor** | kops stores cluster *state* in Azure Blob and authenticates with **your Azure AD identity** (it does **not** use a storage key). Without this you get `403 AuthorizationPermissionMismatch`. |
| **Role‑assignment write** (least‑privilege custom role, or *User Access Administrator*, or *Owner*) | kops creates a managed identity for the cluster and **assigns it a role** on the RG. Without this you get `403 AuthorizationFailed` on `Microsoft.Authorization/roleAssignments/write`. |

### How to request access (3 steps)

**Step 1 — You: tell your admin who you are.**
Just give your admin your **Azure login email (UPN)** and the resource group name.
You do *not* need to look up an object id — granting by email works exactly the
same (Azure resolves the email to your identity internally; the resulting role
assignment is identical either way).

> Optional — if you want your object id anyway:
> `az ad signed-in-user show --query "{email:userPrincipalName, objectId:id}" -o table`

**Step 2 — Admin: grant the three roles.**
The admin (who must be **Owner** or **User Access Administrator**) sets the values
at the top and runs the rest. This uses your **email** as the assignee:

```bash
# ---- admin sets these ----
USER_EMAIL=you@crimsoncloud.in                  # the user's Azure login (UPN)
SUB=de5b8038-1724-4678-9a44-c5d55ed7f54f        # subscription
RG=Docker-FBS-Training                           # resource group
SCOPE="/subscriptions/$SUB/resourceGroups/$RG"

# (a) Contributor — create the VMs, storage, network, etc.
az role assignment create --assignee "$USER_EMAIL" --role "Contributor" --scope "$SCOPE"

# (b) Storage Blob Data Contributor — kops reads/writes its state in Blob via the user's AAD identity
az role assignment create --assignee "$USER_EMAIL" --role "Storage Blob Data Contributor" --scope "$SCOPE"

# (c) Least-privilege role-assignment rights — CREATE the custom role ONCE per subscription:
az role definition create --role-definition '{
  "Name": "kops Role Assignment Manager",
  "Description": "Lets kops create/delete role assignments within one RG only",
  "Actions": [
    "Microsoft.Authorization/roleAssignments/read",
    "Microsoft.Authorization/roleAssignments/write",
    "Microsoft.Authorization/roleAssignments/delete"
  ],
  "AssignableScopes": [ "/subscriptions/'"$SUB"'/resourceGroups/'"$RG"'" ]
}'
# ...then assign it to the user:
az role assignment create --assignee "$USER_EMAIL" --role "kops Role Assignment Manager" --scope "$SCOPE"
```

Notes for the admin:
- **Create the custom role in (c) only once per subscription.** For the 2nd, 3rd…
  user, the `az role definition create` will say *"already exists"* — that's fine,
  **skip it** and just run the final assignment line. (A new role definition can
  take ~1 min to propagate; if the assignment says *"role not found"*, wait & retry.)
- **Simpler (broader) alternative to (c):** grant **User Access Administrator**
  (or **Owner**) on the RG instead — one command, no custom role:
  `az role assignment create --assignee "$USER_EMAIL" --role "User Access Administrator" --scope "$SCOPE"`
- **If email resolution fails** (`WARNING: Failed to query ... Graph API`), the admin
  falls back to the object-id form (no Graph lookup needed):
  `az role assignment create --assignee-object-id <OID> --assignee-principal-type User --role "<role>" --scope "$SCOPE"`

**Step 3 — You: verify it worked.**
```bash
az role assignment list --assignee you@crimsoncloud.in \
  --scope /subscriptions/de5b8038-1724-4678-9a44-c5d55ed7f54f/resourceGroups/Docker-FBS-Training \
  --query "[].roleDefinitionName" -o tsv
```
> ⚠️ **Group-inherited roles do NOT appear in this list** — so you may only see
> `Contributor` even when all three are granted. That's expected. The **reliable
> proof is functional**: run `./kops-azure.sh`; if it clears Step 5 (cluster
> creation) with no `403`, all three roles are working.

---

## 3. Configure the scripts

Both scripts have a **`USER CONFIGURATION`** block at the top. You can set values
three ways, in order of convenience:

1. **Interactive prompts (default).** Just run `./kops-azure.sh` — it asks you for
   each setting and shows the current default in `[brackets]`; press **Enter** to
   keep it. `USERNAME` has **no default and is required** — the prompt repeats until
   you enter one. Disable prompting with `INTERACTIVE=false` (or when piped / no
   terminal, it skips prompts automatically and uses env values/defaults — but a
   missing `USERNAME` then aborts the run).
2. **Environment variables** of the same name (override a default without editing):
   `USERNAME=alice NODE_COUNT=3 ./kops-azure.sh`. An env value becomes the default
   shown at its prompt, so you can still Enter-through it.
3. **Edit the file** — change the defaults in the `USER CONFIGURATION` block directly.

| Variable | Default | Notes |
|---|---|---|
| `USERNAME` | *(none — **required**)* | **You must set this.** Names the cluster + storage account. The script keeps re‑prompting until you enter it (interactive), or aborts if it's empty (non‑interactive/env). |
| `AZURE_SUBSCRIPTION_ID` | *(empty)* | Empty = auto‑detected from `az login`. |
| `AZURE_LOCATION` | `centralindia` | Azure region. |
| `RG_NAME` | `Docker-FBS-Training` | **Existing** resource group to deploy into. |
| `KOPS_AZ` | *(empty)* | Empty = derived as `<region>-1`. |
| `CONTROL_PLANE_COUNT` / `_SIZE` / `_VOLUME_SIZE` | `1` / `Standard_D2s_v3` / `50` | Control‑plane sizing. |
| `NODE_COUNT` / `NODE_SIZE` / `NODE_VOLUME_SIZE` | `2` / `Standard_D2s_v3` / `50` | Worker sizing. |
| `CONTAINER_NAME` | `kops-state` | Blob container for kops state. |
| `SSH_KEY` | `~/.ssh/id_rsa` | Node SSH key (auto‑generated if missing). |
| `OWNER_TAG_KEY` | `username` | Tag/label key stamped on resources & nodes. |
| `KOPS_CLEANUP_ON_FAILURE` | `true` | Auto‑roll‑back if setup fails partway. |
| `DELETE_STORAGE_ACCOUNT` *(cleanup only)* | `true` | Also delete the state store on teardown. |
| `FORCE` *(cleanup only)* | `false` | Skip the “type yes” confirmation. |

**For this environment, `USERNAME` is the only value you *must* provide** — every
other setting has a sensible default.

---

## 4. Pre‑flight checks — test prerequisites *before* you run

The setup script uses `set -euo pipefail`, so it **stops at the first failure** —
and some of its checks (login, permissions) only happen *after* it has already
created a billable storage account. Spend 30 seconds verifying these **first**;
each row tells you the command and exactly what a healthy result looks like.

| # | What you're testing | Command | Expected (healthy) result |
|---|---|---|---|
| 1 | Azure CLI installed | `command -v az` | A path, e.g. `/usr/bin/az`. Empty = install the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli). |
| 2 | kubectl installed | `command -v kubectl` | A path, e.g. `/usr/local/bin/kubectl`. Empty = install [kubectl](https://kubernetes.io/docs/tasks/tools/). |
| 3 | You're logged in | `az account show --query user.name -o tsv` | Your email (e.g. `mehar@crimsoncloud.in`). Error / blank = run `az login`. |
| 4 | Correct subscription active | `az account show --query id -o tsv` | `de5b8038-1724-4678-9a44-c5d55ed7f54f`. Different = `az account set --subscription de5b8038-…`. |
| 5 | Resource group exists & you can read it | `az group show -n Docker-FBS-Training --query name -o tsv` | `Docker-FBS-Training`. `403`/not‑found = wrong RG or missing **Contributor**. |
| 6 | Blob (state) access works | `az storage account list -g Docker-FBS-Training -o table` | A table (even empty) with **no `403`**. `403 AuthorizationPermissionMismatch` = missing **Storage Blob Data Contributor** (see section 2). |
| 7 | kops present (optional) | `command -v kops` | A path, or empty — the script auto‑installs it to `~/bin` if missing. |

**Copy‑paste pre‑flight (runs all checks at once):**
```bash
echo "1/6 az:        $(command -v az || echo MISSING)"
echo "2/6 kubectl:   $(command -v kubectl || echo MISSING)"
echo "3/6 logged in: $(az account show --query user.name -o tsv 2>/dev/null || echo 'NOT LOGGED IN — run: az login')"
echo "4/6 sub id:    $(az account show --query id -o tsv 2>/dev/null)  (want de5b8038-1724-4678-9a44-c5d55ed7f54f)"
echo "5/6 RG read:   $(az group show -n Docker-FBS-Training --query name -o tsv 2>/dev/null || echo 'NO ACCESS — need Contributor')"
echo "6/6 blob read: $(az storage account list -g Docker-FBS-Training -o tsv >/dev/null 2>&1 && echo OK || echo 'FAILED — need Storage Blob Data Contributor')"
```

> The one thing these checks **cannot** confirm is the **role‑assignment write**
> right (role c in section 2) — there's no safe read‑only test for it. Its proof
> is functional: if `./kops-azure.sh` clears cluster creation with no
> `403 …roleAssignments/write`, that role is working too.

✅ **All rows healthy → you're clear to run the setup script below.**

---

## 5. Run the SETUP script

```bash
chmod +x kops-azure.sh
./kops-azure.sh
```

What it does (7 on‑screen steps): checks tools → prepares SSH key → selects
subscription → creates the blob state store → **creates the cluster (real VMs)**
→ applies config / exports kubeconfig → waits ~10–15 min until all nodes are
`Ready`, then labels the nodes and prints them.

Run non‑interactively / with overrides:
```bash
USERNAME=alice AZURE_LOCATION=eastus NODE_COUNT=3 ./kops-azure.sh
```

**Expected total time:** ~15–18 minutes (most of it waiting for the VMs to boot
and join). When it finishes you'll see all 3 nodes `Ready`.

### Tags / labels applied
- **Azure resources:** tag `username=<username>` (visible in the Portal).
- **Kubernetes nodes:** label `username=<username>-<nodename>`
  (e.g. `username=mehar-control-plane-centralindia-1000000`).
  > Node names themselves are **not** changed — the label is added alongside.
  > Labels live on the node object, so a replaced VMSS instance loses the label
  > until you re‑run the labeling.

---

## 6. Use the cluster

```bash
kubectl get nodes                 # list nodes
kubectl get nodes -L username     # show the username label column
kubectl get pods -A               # system pods (Cilium, CoreDNS, etc.)
```
`kubectl` is already pointed at the new cluster (kops set the context).

---

## 7. Reconnect later (fresh shell or expired cert)

The training runs all week, so you'll often come back to a **new Cloud Shell**
(env vars + PATH gone) or find the **admin certificate expired** (`kubectl` says
`Unauthorized` / `couldn't get current server API group list`). The kops admin
credential is short‑lived (~18 h by default).

One script fixes both — it sets up the environment, finds your cluster (no need to
remember the timestamped name), and refreshes your credentials for **a full week**:

```bash
KOPS_USER=alice ./kops-connect.sh        # or just ./kops-connect.sh and type your name
```

It does **not** create or delete anything — it's read‑only + a credential refresh,
safe to run as often as you like. Override the credential lifetime with
`ADMIN_TTL=...` (default `168h`).

> **Manual equivalent** (if you'd rather not use the script): set
> `export PATH="$HOME/bin:$PATH"; export KOPS_FEATURE_FLAGS=Azure` and your
> `KOPS_STATE_STORE` (it's also saved in `~/.bashrc`), then
> `kops export kubecfg --admin=168h --name=<your-cluster>`.

---

## 8. Scale the worker nodes up / down

Change **how many worker VMs** run while the cluster stays up. The **control plane
is fixed at 1** and is never touched — only the worker pool changes. Each script
**prompts you for the worker count** (Enter keeps the shown default), or takes it
as an env var to skip the prompt:

```bash
KOPS_USER=alice ./kops-scale-down.sh                 # asks for worker count (default 1)
KOPS_USER=alice NODE_COUNT=0 ./kops-scale-down.sh    # → 0 workers (cluster still up, pods Pending)

KOPS_USER=alice ./kops-scale-up.sh                   # asks for worker count (default 2)
KOPS_USER=alice NODE_COUNT=3 ./kops-scale-up.sh      # → 3 workers
```

Each script auto‑detects your worker instance group (role `Node`), sets its
`minSize`/`maxSize`, and runs `kops update cluster --yes`. Scaling **up** takes
~3–5 min for new VMs to join (`kubectl get nodes -w`); scaling **down**, a removed
node briefly shows `NotReady` before it drops off the list (clear a stale entry
with `kubectl delete node <name>` if needed).

> 💡 Scaling workers to 0 **still bills the control‑plane VM**. To stop *all*
> compute billing, use **stop** (section 9), not scale‑down.

---

## 9. Stop / start the whole cluster (pause billing)

To shut everything down overnight/weekend and resume later, **stop** the cluster —
this *deallocates* (powers off) **all** VMs including the control plane, so compute
billing stops, while disks, etcd data, and the API IP are preserved.

```bash
KOPS_USER=alice ./kops-stop.sh           # power EVERYTHING off (compute billing → $0)
KOPS_USER=alice ./kops-start.sh          # power it back on, same cluster as before
```

`kops-start.sh` starts the control plane first (so etcd/API is up), then the
workers, and the cluster returns at the **same size it was stopped at**.

After starting, wait ~3–5 min then `kubectl get nodes`. If the API is unreachable,
refresh creds with `./kops-connect.sh` (section 7).

> **Stop/start vs scale (don't confuse them):**
> - **stop/start** = power switch for the *entire* cluster (control plane + workers). Use this to pause cost.
> - **scale up/down** = change the *number of workers* while the cluster keeps running.
>
> Never take the **control plane** to 0 via scaling — that deletes the master and
> risks losing etcd. `kops-stop.sh` (deallocate) is the safe way to get to zero
> running VMs.
>
> ⚠️ If you scaled workers down before stopping, the cluster resumes at that smaller
> size. To get back to the full **1 control‑plane + 2 workers**, run
> `./kops-scale-up.sh` after starting.

---

## 10. Run the CLEANUP script (delete everything)

> ⚠️ The cluster bills **continuously** (3 VMs + disks + load balancer + public
> IPs). Delete it when you're done.

```bash
chmod +x kops-azure-cleanup.sh
./kops-azure-cleanup.sh
```

It **prompts you for the username** whose cluster to tear down (required — it
scopes the whole teardown), plus the resource group and whether to delete the
state store. Then (6 steps): validates login → lists your cluster in the state
store (read-only, just to show you) → **asks you to type `yes`** → **deletes only
the resources whose name/tag matches that username** (`<username>…k8s.local`):
VM scale sets first, then networking, with retries for dependencies → removes the
cluster's dangling role assignment → deletes the storage account and cleans
`~/.bashrc` → verifies nothing remains.

```bash
chmod +x kops-azure-cleanup.sh
./kops-azure-cleanup.sh            # asks for the username, then tears that cluster down
```

Useful variants (env vars skip the matching prompt — use `KOPS_USER`, not `USERNAME`):
```bash
KOPS_USER=alice ./kops-azure-cleanup.sh                # tear down alice's cluster
KOPS_USER=mehar FORCE=true ./kops-azure-cleanup.sh     # no confirmation prompt
DELETE_STORAGE_ACCOUNT=false KOPS_USER=mehar ./kops-azure-cleanup.sh  # keep the state store
INTERACTIVE=false KOPS_USER=mehar ./kops-azure-cleanup.sh             # no prompts at all
```

### Safety guarantees of the cleanup script
- **Does NOT run `kops delete cluster`.** On Azure, kops deletes at the
  *resource-group* level and will try to delete **other users'** resources
  (e.g. every NSG in the shared RG). The script avoids it entirely and instead
  deletes only resources matching `<username>…k8s.local` by name **and** the
  `username=<username>` tag — so it can never touch another student's resources.
- Only removes **your** cluster's resources + your kops storage account +
  role assignments whose principal no longer exists (harmless dangling entries).
- **Never** deletes the shared resource group or anyone else's resources.

> ⚠️ **Do not run two teardowns for the same username at once** — both derive the
> same `<username>kopsstate` storage-account name and will fight over it. Same
> applies to running setup and cleanup for one username simultaneously.

---

## 11. Cost warning 💸

The default cluster = **3 × `Standard_D2s_v3` VMs** (2 vCPU / 8 GB each) + managed
disks + a load balancer + 2 public IPs, billed per‑hour until deleted. Always run
the cleanup script when finished.

---

## 12. Troubleshooting (issues you may hit)

| Symptom | Cause | Fix |
|---|---|---|
| `azure support is currently alpha … export KOPS_FEATURE_FLAGS=Azure` | Feature gate | The scripts set this; if running kops manually, `export KOPS_FEATURE_FLAGS=Azure`. |
| `403 AuthorizationFailed … resourcegroups/write` (creating an RG named after the cluster) | kops tried to create a **new** RG | The script passes `--azure-resource-group-name="$RG_NAME"` to deploy into the existing RG. Ensure `RG_NAME` is an RG you have Contributor on. |
| `403 AuthorizationPermissionMismatch` on blob | Missing **Storage Blob Data Contributor** | Get the role granted (section 2). |
| `403 AuthorizationFailed … roleAssignments/write` | Missing role‑assignment rights | Get the custom role / UAA / Owner granted (section 2). |
| `unset AZURE_STORAGE_ACCOUNT` error from kops | `AZURE_STORAGE_ACCOUNT` is set in your env | kops reads the account from the state‑store URL; the scripts `unset` it. |
| Cluster never becomes `Ready` (validate loop times out) | VMs slow to boot / API not up | Check `cat status.txt`; inspect the scale sets in the Portal; re‑run validation: `kops validate cluster --wait 15m`. |
| “I don't see any VMs in the Portal” | kops uses **VM Scale Sets**, not standalone VMs | Look under **Virtual machine scale sets**, or open the RG. Instances: scale set → **Instances**. |
| `kubectl` says `Unauthorized` / `couldn't get current server API group list` | Admin certificate expired (~18 h) | Refresh creds: `KOPS_USER=<you> ./kops-connect.sh` (section 7). |
| `USERNAME=alice ./script` seems to use the wrong name | `USERNAME` is a **reserved** shell variable (your OS login) and can't be overridden | Use **`KOPS_USER`** instead: `KOPS_USER=alice ./script`. |
| A node stuck `NotReady` after scaling down | The removed worker's VM is gone but its node object lingers | Usually self‑clears; force it with `kubectl delete node <name>`. |
| After `./kops-start.sh`, `kubectl` can't reach the API | API endpoint/creds need refreshing | Wait ~3–5 min, then `KOPS_USER=<you> ./kops-connect.sh`. |

### Decoding node names
`control-plane-centralindia-1000000` = `<scale-set>` + `<instance index>`:
- `control-plane-centralindia-`**`1`** → the **`1`** is the availability **zone** (`centralindia-1`).
- `000000` → the 6‑char VMSS **instance index** (instance 0; next is `000001`, …).

---

## 13. Quick reference (this environment)

| Item | Value |
|---|---|
| Subscription | `de5b8038-1724-4678-9a44-c5d55ed7f54f` (Microsoft Azure Sponsorship) |
| Resource group | `Docker-FBS-Training` (centralindia, **shared**) |
| Your object id | `e0be7df5-7140-4e49-8cb3-e27c2684bb46` |
| State store | `azureblob://<username>kopsstate/kops-state` |
| Cluster name | `<username>-<YYYY-MM-DD-HH-MM>.k8s.local` |
| kops version | 1.35.1 · Kubernetes v1.35.5 |

### Command cheat‑sheet (replace `alice` with your username)

| Task | Command |
|---|---|
| Create the cluster | `./kops-azure.sh` |
| Reconnect (fresh shell / expired cert) | `KOPS_USER=alice ./kops-connect.sh` |
| Scale workers down (prompts for worker count) | `KOPS_USER=alice ./kops-scale-down.sh` |
| Scale workers up (prompts for worker count) | `KOPS_USER=alice ./kops-scale-up.sh` |
| Stop the whole cluster (pause billing) | `KOPS_USER=alice ./kops-stop.sh` |
| Start it again | `KOPS_USER=alice ./kops-start.sh` |
| Delete the cluster | `KOPS_USER=alice ./kops-azure-cleanup.sh` |

> Daily rhythm for the week: `kops-connect.sh` when you open a new shell →
> `kops-stop.sh` when you leave → `kops-start.sh` (then `kops-connect.sh` if needed)
> when you come back → `kops-azure-cleanup.sh` on the final day.
