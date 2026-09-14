---
slug: /upgrading
description: "Upgrading Orka, including the CRD step Helm will not do for you."
---

# Upgrading

Orka is pre-1.0. Before upgrading, check that the target release supports your
database layout and installed resources. Helm also requires a separate CRD update.

## v0.2.0 support boundary {#v020-support-boundary}

The v0.2.0 release gate tests a fresh `harness-v2` chart installation, a
controller restart on the same retained volumes, continued work after that
restart, and rejection of an opposite-mode upgrade without changing state.
Check the published release's `acceptance.json` for the result of those checks.

| Starting point or operation | v0.2.0 boundary |
| --- | --- |
| Fresh namespace and empty stores | Use the [release installation procedure](installation.md) and its exact chart and image digests. |
| Restart the same qualified version with its retained state and snapshot key | Covered by the bundled release gate. |
| Stock v0.1.3, an older release, or a pre-static controller | No in-place upgrade to v0.2.0. Retire the old installation or use a separate cluster. |
| An older static-mode build, even with the same mode | No historical source/target upgrade pair is advertised as qualified for v0.2.0. |
| Change `harness-v1` to `harness-v2`, or the reverse | Rejected. Use independent installations with new state. |
| Restore a lost installation from backups | Outside this release's qualification; tracked in [#505](https://github.com/orka-agents/orka/issues/505). |

Matching controller mode and SQLite layout are necessary conditions for an
upgrade, but do not prove a version pair is compatible. The broader upgrade
matrix remains in [#499](https://github.com/orka-agents/orka/issues/499). The
same-mode procedure later on this page applies only when the target release
explicitly qualifies the installed source version.

## Retire a stock v0.1.3 installation {#retire-a-stock-v013-installation}

Stock v0.1.3 predates static controller-mode identity. Its default controller
can watch the entire cluster, so a new namespace alone does not isolate a
v0.2.0 installation. The shared CRDs also change between these versions.
Use a separate cluster when the old installation must remain running during
the transition.

1. Inventory the old installation's producers, queued and active Tasks,
   Sessions, repository monitors, schedules, gateways, and external effects.
   Record its Kubernetes context, workload names, image references, and volumes.
2. Stop new submissions and automatic producers. Settle existing work through
   the old controller and wrapper using that version's procedures. Resolve
   active work and pending cleanup before removing workloads; a successful Task
   alone does not establish that all external effects have settled.
3. Preserve the old Kubernetes state, configuration, Secrets, and a consistent
   backup of its SQLite volume. Use a storage snapshot or stop writers before
   copying the database. Keep these records for the old installation; do not
   attach its PVC, database, wrapper ledger, or execution records to v0.2.0.
4. Install v0.2.0 in a separate cluster with new stores and credentials. Recreate
   the required configuration as new objects, verify a Task and its result,
   then route selected producers to the new API. Tasks and Sessions from
   v0.1.3 do not continue in v0.2.0.
5. After the transition, retire the old controller, wrapper, and producer
   workloads and revoke their unused credentials. Keep historical data and
   backups according to your retention policy.

When recreating transaction-token configuration, follow
[Transaction-token migration](../guides/transaction-token-migration.md) for
the current profile, TTS endpoint, and effective-tool grants.

If the same cluster must be reused, fully retire the old workloads before
changing its shared CRDs. Have the cluster's CRD owner inventory retained
objects and plan the schema change; do not apply the new CRDs while the old
controller is still running. New v0.2.0 workloads need a fresh namespace and
empty stores. The commands in [Install v0.2.0](installation.md) assume a cluster
without retained Orka CRDs, so they are not a same-cluster conversion procedure.

Do not add a static-mode label to the old namespace to bypass these checks.
The [static v1/v2 coexistence rules](harness-modes.md) describe installations
that already enforce those identities, not stock v0.1.3.

## Supported database layout

The supported starting point is the current SQLite layout. An empty database gets
the complete schema during startup. Opening an existing current-layout database
preserves its records, IDs, timestamps, and message and event ordering. Normal
restarts continue using the same database and accept new reads and writes.

Startup checks the existing tables, columns, defaults, constraints, and indexes.
An incompatible layout stops startup with an `unsupported SQLite schema` error.
Orka does not convert historical layouts, fill in historical records, reset the
database, or replace it with an empty file. This release includes no command for
converting historical SQLite layouts. Preserve an incompatible installation's
database and use a separate installation with a new store.

Release qualification must verify retained data and new work across repeated
controller restarts on a current-layout store. The upgrade and release checks
tracked in [#499](https://github.com/orka-agents/orka/issues/499) and
[#567](https://github.com/orka-agents/orka/issues/567) use this support boundary;
historical SQLite conversion is outside the supported upgrade matrix. Kubernetes
resource and runtime compatibility requirements still apply independently.

## The one thing that will bite you

**Helm never creates or updates CRDs during `helm upgrade`.** Files in a chart's `crds/`
directory are applied on install and ignored on every upgrade after that.

That is standard Helm behavior, not something Orka chose or can switch off. The result if
you skip the step: the controller runs new code against old CRD schemas, and any field the
new version added is silently dropped by the API server. Resources look accepted and do
nothing.

So: **apply the CRDs from the target chart yourself, before every upgrade** — including
when upgrading from a release that installed no CRDs at all.

## Procedure for a qualified same-mode upgrade

Confirm that the target release qualifies your source version before any of
these steps. This procedure does not provide a v0.1.3-to-v0.2.0 upgrade path.

Use a host with Bash, Helm, kubectl, and jq installed. Choose the target chart and
Kubernetes context before taking backups:

```bash
export TARGET_CHART='<path-or-reference-to-target-chart>'
export TARGET_CONTEXT='<kubeconfig-context>'
```

Use that context for the backup, CRD update, upgrade, and verification commands below.

### 1. Back up first

Back up both Kubernetes state and the controller's volume before upgrading:

- The controller's **SQLite store**, on its PersistentVolumeClaim. This holds transcripts,
  gateway delivery records, and artifact payloads.
- **Kubernetes objects**, including operator configuration and the controller-owned ACP
  execution, fencing, publication, and idempotency records.

The JSON exports below provide additional records for inspection and configuration
reference. They complement your cluster's backup system.

```bash
kubectl --context "$TARGET_CONTEXT" -n orka-system get \
  agents,providers,tools,skills,tasks,repositorymonitors,repositoryscans,\
outboundaccesspolicies,gateways,gatewaybindings,agentruntimes,substrateactorpools \
  -o json > orka-crs.json

# Cluster-scoped, so no -n:
kubectl --context "$TARGET_CONTEXT" get gatewayclasses -o json > orka-gatewayclasses.json
```

For an ACP install, also export the controller-owned control state:

```bash
kubectl --context "$TARGET_CONTEXT" -n orka-system get \
  runtimepools,controllerepochs,promptattempts,runtimesessioncontrols,\
publications,externaleffects \
  -o json > orka-acp-control-state.json

# BranchClaims are cluster-scoped:
kubectl --context "$TARGET_CONTEXT" get branchclaims -o json > orka-branchclaims.json
```

:::warning[Exports are not an ACP recovery procedure]
These JSON files alone do not safely restore in-flight execution or replay protection.
Do not use `kubectl apply` on controller-owned exports to reconstruct lost ACP authority.
A tested procedure for restoring Kubernetes state together with the controller volume
is follow-up work; this upgrade procedure keeps existing control resources in place.
:::

If you have the workspace provider API enabled, back up its resources too:

```bash
kubectl --context "$TARGET_CONTEXT" -n orka-system get \
  executionworkspaceclasses,executionworkspaceproviders,executionworkspacepools,\
executionworkspaces,runtimeproviderconfigs,runtimeworkspaceprofiles \
  -o json > orka-workspace-crs.json
```

Do not stop at the classes. A class is unusable without the
`RuntimeProviderConfig` and `RuntimeWorkspaceProfile` objects its `parametersRef` points
at, so a backup holding only classes, providers, and pools restores a set of resources
that cannot run anything.

Leave out any kind your cluster does not have; `kubectl` fails the whole command on an
unknown resource rather than skipping it.

:::danger[Do not copy the SQLite file from a running controller]
Copying `orka.db` while the controller is writing produces a backup that restores without
error and is missing records. Snapshot the whole PVC, or stop the controller first.
[Gateways](gateways.md) explains why this one matters more than it looks.
:::

### 2. Apply the target CRDs

From a checkout matching the version you are upgrading to:

```bash
scripts/apply-helm-crds.sh "$TARGET_CHART" "$TARGET_CONTEXT"
```

That patches each CRD with an optimistic-concurrency check and waits for `Established`.
The equivalent by hand is in the
[chart README](https://github.com/orka-agents/orka/blob/main/manifest_staging/charts/orka/README.md).

If a separate platform team or GitOps system owns CRDs in your cluster, do this step
through that system instead, wait for every Orka CRD to become `Established`, then
continue. Do not run two CRD apply workflows against one cluster.

### 3. Upgrade

```bash
helm upgrade orka "$TARGET_CHART" --kube-context "$TARGET_CONTEXT" \
  --namespace orka-system --wait --timeout 10m
```

On Azure Kubernetes Service, the admission controller adds namespace selectors to webhooks. If Helm 4 reports
an apply conflict with `admissionsenforcer` on those selectors, add `--server-side=false`
to the upgrade command. Client-side updates preserve those added selectors.

Keep the timeout longer than the controller's termination grace period plus time for
the replacement Pod to become Ready. The harness-v2 default grace period is six minutes;
increase the timeout if you configure a longer drain or need more rollout time.

### 4. Verify

```bash
# A Helm release named `orka` creates a Deployment named `orka-controller`.
kubectl --context "$TARGET_CONTEXT" -n orka-system rollout status deploy/orka-controller
kubectl --context "$TARGET_CONTEXT" get crd -o name | grep '\.orka\.ai$' | wc -l
```

The CRD count should match the target chart. Orka CRDs are the ones whose group ends in
`.orka.ai`; they carry no common label, so counting by name is the check that actually
works. [Release status](../reference/release-status.md) lists the count per version.

For targets that include `runtimepools.core.orka.ai`, also check the runtime pools.
Skip this check for v0.1.3, which has no RuntimePool CRD:

```bash
kubectl --context "$TARGET_CONTEXT" -n orka-system get runtimepools
```

Submit one small Task and confirm it reaches `Succeeded`.

## Values you cannot change on upgrade

The chart blocks these, because changing them would orphan data or split a control plane
in two:

| Value | Why it is fixed |
| --- | --- |
| `controller.mode` | The execution contract is the installation's identity. |
| `controller.watchNamespace` | Existing Tasks live there. |
| `controller.agentExecutionSnapshot.existingSecret` and `.key` | Retained snapshots become undecryptable. |
| `controller.acpRuntime.namespace` | Running pools live there. |
| The release fullname | Every owned resource is named from it. |

To change one, install a new release alongside the old one and migrate producers across.
See [Harness modes](harness-modes.md).

## `--skip-crds`

Use `--skip-crds` **only** when one designated owner already manages Orka's CRDs for the
cluster — a platform team, a GitOps controller, or a previous release whose CRDs were
retained after uninstall. Every other install should let Helm create them.

If you uninstalled a previous release, update its retained CRDs first, then install the
replacement with `--skip-crds`.

## Uninstall

```bash
helm uninstall orka --kube-context "$TARGET_CONTEXT" --namespace orka-system
```

That removes the release's resources and **keeps** the CRDs and every custom resource
stored under them — again, standard Helm `crds/` behavior, not a chart value.

:::danger[Deleting a CRD deletes its data]
Removing an Orka CRD deletes every custom resource of that kind across the cluster, with no
undo. Treat it as a deliberate cluster-wide data destruction step, performed only after the
resources are gone or backed up.
:::

## Migrating harness v1 to v2

This is not an upgrade. The two contracts run as separate installations, and Tasks do not
move between them. The procedure — stand v2 up, point producers at it, drain v1 — is in
[Harness modes](harness-modes.md).

For clusters still holding `orka.harness.v1` AgentRuntimes, `scripts/upgrade-orka-crds.sh`
performs the one-way cutover. It refuses to run while any v1 AgentRuntime, dependent Agent,
affected GatewayBinding, Task using the removed `gitSecretRef` fields, or legacy wrapper
workload remains, and it requires attested backups of both the store and the custom
resources before it will apply anything.

That script changes CRDs after its prerequisites are met. It does not convert
historical SQLite data, migrate Tasks or Sessions, or qualify a historical
release upgrade. Stock v0.1.3 follows the retirement procedure above.
