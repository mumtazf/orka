---
slug: /release-status
description: "Release artifacts, CRD inventory, and the boundary between v0.1.3 and v0.2.0."
---

# Release status

These docs describe current source, including the v0.2.0 installation contract.
Check [GitHub Releases](https://github.com/orka-agents/orka/releases) for published
v0.2.0 artifacts. Documentation for a candidate does not mean it has been released.

The v0.1.3 tag uses an older execution path. Instructions for RuntimePools,
static controller modes, and current workspace providers do not apply to it.

## Which one am I running?

```bash
# Neither install creates a Deployment named plain `orka`: a Helm release named `orka`
# creates `orka-controller`, and the release manifest creates `orka-controller-manager`.
kubectl -n orka-system get deploy -l app.kubernetes.io/name=orka \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'

# Orka CRDs carry no common label, so count them by group instead.
kubectl get crd -o name | grep -c '\.orka\.ai$'
```

| CRDs in the bundle | Source |
| --- | --- |
| 17 | v0.1.3 |
| 27 | current source and the v0.2.0 candidate |
| 12 | a stale `charts/orka/` snapshot from the repo root — see the warning below |

Counts describe each bundle, not a reliable installed-version detector. CRDs
are shared across a cluster and can remain after uninstall. Check the running
image and chart version too. The two `fake.workspace.orka.ai` development CRDs
are excluded from the 27-CRD production bundle.

## What v0.1.3 does not have

The ACP execution path and runtime pools landed after v0.1.3. That release already
included the `AgentRuntime` CRD and the `orka.harness.v1` contract for external runtimes.

| | v0.1.3 | `main` |
| --- | --- | --- |
| Container tasks (`type: container`) | Yes | Yes |
| Native AI tasks (`type: ai`) | Yes | Yes |
| Chat and compatibility APIs | Yes | Yes |
| Repository monitors, scans, gateways | Yes | Yes |
| Coding-agent tasks (`type: agent`) | Yes, on a per-Task Job with a harness wrapper | Yes |
| Coding agents over [ACP](glossary.md#running-coding-agents) | **No** | Yes |
| `RuntimePool` / `RuntimeSession` | **No** | Yes |
| `PromptAttempt`, `ControllerEpoch`, `Publication`, `BranchClaim`, `ExternalEffect` | **No** | Yes |
| `RuntimeProviderConfig`, `RuntimeWorkspaceProfile`, `RuntimeSessionControl` | **No** | Yes |
| `ExecutionWorkspaceCheckpoint` | **No** | Yes, behind the workspace-provider gates |
| [Harness modes](../operations/harness-modes.md) (`orka.ai/controller-mode`) | **No** | Yes |
| `--watch-namespace` | Optional; empty watches the whole cluster | **Required** |

Ten CRDs are new on `main`. If a page here mentions a `RuntimePool`, a supervisor, a
prompt attempt, or clean-room publication, it does not apply to v0.1.3. v0.1.3 does run
`type: agent` Tasks — what it lacks is the ACP execution path that replaced the older
per-Task Job.

## Installing v0.1.3

No clone needed:

```bash
# The manifest mounts a harness-wrapper-auth Secret but does not create it,
# so make the namespace and that Secret first or the Pods never start.
kubectl create namespace orka-system
kubectl -n orka-system create secret generic harness-wrapper-auth \
  --from-literal=token="$(openssl rand -hex 32)"

kubectl apply -f https://raw.githubusercontent.com/orka-agents/orka/v0.1.3/deploy/orka.yaml
```

Or with Helm:

```bash
helm repo add orka https://orka-agents.github.io/orka/charts
helm repo update
helm install orka orka/orka --version 0.1.3 \
  --namespace orka-system --create-namespace
```

The v0.1.x release workflow published these images and chart artifacts from
version tags. Those releases have no GitHub Release entries.

## Installing v0.2.0

Follow [Install v0.2.0](../operations/installation.md) once its GitHub Release is
published. Use the attached chart and `candidate.json` image digests together.
The installation needs a claimed namespace, new persistent stores, a snapshot
encryption key, admission TLS, and the provider proxy.

Stock v0.1.3 requires [retirement or a separate cluster](../operations/upgrading.md#retire-a-stock-v013-installation).
An in-place static-v2 upgrade is unsupported. The v0.2.0 gate qualifies fresh
installation, retained-state recovery on the same version, and opposite-mode
rejection. Historical same-mode upgrades and full backup restoration remain
outside the advertised support boundary.

## Installing `main`

Ordinary `main` pushes do not publish release images. Build from your checkout
for development, following [Getting started](../getting-started.md#option-b-current-main-from-source).
Release builds use an explicitly prepared release-branch commit.

:::warning[Do not install from `charts/orka/` or `deploy/orka.yaml` at the repo root]
Those are promoted release snapshots, refreshed on `release-X.Y` during
preparation. The `main` checkout still holds the v0.1.1 snapshot with 12 CRDs.
Check the chart version and image references before using any source snapshot.

Build from `manifest_staging/charts/orka/` instead — that is the chart regenerated from
current source by `make manifests`.
:::

## Version support

Orka is pre-1.0.

- CRD schemas may change between minor releases. Diff the CRDs before upgrading, and follow
  [Upgrading](../operations/upgrading.md) — Helm will not update CRDs for you.
- Release branches use `release-X.Y`. A patch release must qualify its own
  candidate; an earlier version's evidence does not qualify later changes.
- No release is supported for production use yet.

## Release publication

Starting with v0.2.0, a maintainer dispatches **Prepare Release** from `main`
with the requested version. It prepares the release branch, builds the images
and chart, and requests qualification approval. After qualification passes,
publication approval allows the workflow to tag the exact candidate, promote
its image digests, publish its chart, and create a GitHub Release with evidence.
A tag push alone does not start this flow.

See [Release automation and qualification](../development/release-qualification.md)
for the approvals and retry procedure. The published assets are:

| Asset | Contents |
| --- | --- |
| `candidate.json` | Version, source commit, build identity, image digests, and chart checksum |
| `orka-<version>.tgz` | The exact packaged chart used in qualification |
| `qualification.json` | Qualification run and attempt, with evidence hashes |
| `acceptance.json` | Runtime, local publication, chart recovery, and cleanup results |

The qualification report records live GitHub publication as untested. Local
Git publication and GitHub API fixtures provide the required publication
coverage without stored repository tokens. Review those limits along with
the [upgrade support boundary](../operations/upgrading.md#v020-support-boundary).
