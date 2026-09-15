# Orka Helm chart

## Install

Follow the [installation guide](https://orka-agents.github.io/orka/docs/installation)
to install a published release. It covers the required image digests, encryption
key, webhook certificate, and model connection. The installation is named `orka`
and uses the `orka-system` namespace.

Published charts are available through [GitHub Releases](https://github.com/orka-agents/orka/releases)
and the Helm repository at `https://orka-agents.github.io/orka/charts`.

For development, follow [Build from source](https://orka-agents.github.io/orka/docs/getting-started#option-b-current-main-from-source).
That guide uses `manifest_staging/charts/orka` from a source checkout.

## Configuration

The chart installs the exact cross-namespace ingress policy for Vekil. The
chart-managed provider proxy itself always runs in the Helm release namespace. Leave
`controller.acpRuntime.providerProxyNamespace` empty or set it to that release
namespace. The only supported upstream is
`http://vekil.vekil-system.svc:1337` (an optional trailing slash is normalized);
alternate hosts, namespaces, and ports are rejected because the chart does not
create matching NetworkPolicies.

`service.port` is the controller Service port used by controller and Publisher Service URLs. `controller.apiPort` is only the controller container listener and Service target port.

### SCM proxy NetworkPolicy portability boundary

The SCM proxy NetworkPolicy excludes RFC 1918 and reserved address ranges, but
Kubernetes does not define whether Service destination NAT runs before or
after `ipBlock` evaluation. Some CNI and cloud combinations can therefore
reach the `kubernetes.default` transport through its ClusterIP despite those
exclusions. This does not grant API authorization: the SCM proxy Pod and
ServiceAccount do not mount a service-account token, service links are disabled,
Orka grants that identity no API RBAC, and the proxy refuses to start if the
conventional Kubernetes service-account token path exists. The proxy itself
accepts only exact configured SCM hostnames and rejects non-public DNS answers
and connected peers. Clusters requiring TCP-level API denial must add and
validate a CNI- or cloud-native pre-DNAT or Service-aware egress control;
standard NetworkPolicy cannot guarantee this portably.

### Coordinated authentication Secret rotation

The Publisher and SCM egress proxy read their authentication material at process startup. Rotate each Secret and its non-secret rollout marker in the same Helm upgrade:

- When rotating `publisher.auth.existingSecret` (or the chart-managed publisher auth values), bump `publisher.auth.rolloutNonce`. The marker is added only to the controller and Publisher Pod templates so both restart onto the same credential generation.
- When rotating `scmEgressProxy.auth.existingSecret` (or the chart-managed SCM proxy token), bump `scmEgressProxy.auth.rolloutNonce`. The marker is added only to the Publisher and SCM proxy Pod templates.

The nonce is a revision label, not a credential. Never put Secret content in it. A coordinated upgrade may briefly fail closed while Pods roll, but it avoids an indefinite split generation.

The harness-v1 wrapper likewise keeps execution authority and transport
material separate. `harnessV1.auth.existingSecret` contains only the bearer
token and is immutable while v1 work exists. `harnessV1.tls.existingSecret`
contains `tls.crt`, `tls.key`, and `ca.crt`. A TLS Secret name change is a
wrapper Pod-template change and automatically uses the existing drained
rollover. For same-name certificate renewal, update the TLS Secret and bump
`harnessV1.tls.rolloutNonce` in the Helm upgrade; the hook drains the live
wrapper before both wrapper and controller restart. Keep the updated `ca.crt`
able to verify the certificate currently being served during that drain, or
rotate to a versioned TLS Secret so the hook can mount the prior CA.

CRDs are cluster-scoped and shared by every Orka release. Use `--skip-crds`
only when a designated platform or GitOps workflow already manages compatible
Orka CRDs for the cluster.

## Controller mode

New installations use `controller.mode=harness-v2`. This selects how Orka runs
coding agents and is separate from the Orka release version. Keep the mode and
the namespace's `orka.ai/controller-mode` label unchanged after installation.

Run one Orka installation per namespace. Set `controller.watchNamespace` to
the Helm installation's namespace, `orka-system` in the installation guide.
Use a distinct Helm name for every installation in the same cluster.

The `harness-v1` compatibility mode is for existing integrations that require it.
If you need both modes on one cluster, follow the advanced
[controller mode guide](https://orka-agents.github.io/orka/docs/operations/harness-modes).
It covers separate installation names, namespaces, storage, and CRD ownership.

## Upgrade

Orka currently supports new installations only. Upgrades between versions are
not yet supported. Use the steps below only when the target release publishes
a tested upgrade procedure for your installed version.
See [Upgrading](https://orka-agents.github.io/orka/docs/upgrading) for details.

The chart requires the controller and its namespace label to keep the same mode
and watch namespace. It rejects upgrades that change or lack those settings.

Helm installs files from `crds/` only during installation. It does not create or
update them during `helm upgrade`.

Apply the exact CRD specs from the target chart before upgrading the
controller. The first apply creates missing CRDs and transfers ownership of
present fields; the guarded JSON Patch then replaces each `spec` so fields
removed by the target version do not remain from an older Helm manager:

```bash
set -euo pipefail

TARGET_CHART='<path-to-chart.tgz>'
TARGET_CONTEXT='<your-kubeconfig-context>'
TARGET_CRDS="$(mktemp)"
trap 'rm -f "$TARGET_CRDS"' EXIT

helm show crds "$TARGET_CHART" > "$TARGET_CRDS"
kubectl --context "$TARGET_CONTEXT" apply \
  --server-side \
  --force-conflicts \
  --field-manager=orka-crd-lifecycle \
  -f "$TARGET_CRDS"

kubectl --context "$TARGET_CONTEXT" create --dry-run=client -f "$TARGET_CRDS" -o json | \
  jq -c '{name: .metadata.name, spec: .spec}' | \
  while IFS= read -r target; do
    name="$(jq -er '.name' <<< "$target")"
    spec="$(jq -ec '.spec' <<< "$target")"
    resource_version="$(kubectl --context "$TARGET_CONTEXT" get crd "$name" -o jsonpath='{.metadata.resourceVersion}')"
    patch="$(jq -cn --arg rv "$resource_version" --argjson spec "$spec" \
      '[{"op":"test","path":"/metadata/resourceVersion","value":$rv},{"op":"replace","path":"/spec","value":$spec}]')"
    kubectl --context "$TARGET_CONTEXT" patch crd "$name" --type=json -p "$patch"
    kubectl --context "$TARGET_CONTEXT" wait --for=condition=Established --timeout=60s "crd/$name"
  done

helm upgrade orka "$TARGET_CHART" \
  --namespace orka-system \
  --kube-context "$TARGET_CONTEXT" \
  --wait
```

A matching Orka source checkout provides the same guarded flow as
`scripts/apply-helm-crds.sh "$TARGET_CHART" "$TARGET_CONTEXT"`. Do not run
competing CRD apply workflows for the same cluster.

If another system owns the CRDs, perform the CRD-first step through that system,
wait for all production CRDs from the target chart to become `Established`,
and then upgrade Orka.

If a previous release was uninstalled, update its retained CRDs first and install
the replacement release with `--skip-crds`.

## Uninstall and deletion

Uninstall can delete stored data. Helm deletes the chart's persistent volume
claims, including `orka-store` and `orka-workspace-publisher`. If their volumes
use the `Delete` reclaim policy, Kubernetes also deletes the stored data. Back up
the data and encryption key, and verify your recovery plan before uninstalling.

Orka's CRDs and custom resources stay in the cluster. Keeping them does not
preserve the data stored in volumes.

Deleting a CRD also deletes every custom resource stored under that kind. Delete
Orka CRDs only as an explicit cluster-wide data-destruction operation after the
resources have been removed or backed up.

## Chart development

This chart is generated from `cmd/build/helmify`. Edit the generator inputs and
run `make manifests` to update `manifest_staging/charts/orka`.
Do not edit generated chart copies directly.

The chart packages all production Orka CRDs under `crds/`. The development-only
`fake.workspace.orka.ai` CRDs are available separately from a matching source
checkout at `config/development/fake-workspace-provider`.
