---
slug: /installation
description: "Install v0.2.0 from its qualified chart and image digests in a fresh harness-v2 installation."
---

# Install v0.2.0

Use this procedure once the [v0.2.0 GitHub Release](https://github.com/orka-agents/orka/releases)
is published with `candidate.json`, `qualification.json`, `acceptance.json`, and
`orka-0.2.0.tgz`. The release workflow publishes these files after the packaged
chart and images pass qualification. Until publication, use the
[source installation](../getting-started.md#option-b-current-main-from-source)
for development.

This is a fresh `harness-v2` installation with a new namespace and empty stores.
For an existing Orka cluster, read the [upgrade support boundary](upgrading.md#v020-support-boundary)
first. Stock `v0.1.3` cannot be upgraded to this installation in place.

## Prerequisites

- Bash, curl, jq, `shasum`, Helm, kubectl, and OpenSSL.
- A Kubernetes context for a cluster without an existing Orka installation or
  retained Orka CRDs. The cluster must support the admission resources in the
  target chart, enforce NetworkPolicies, and pull images from `ghcr.io`.
- A default StorageClass that can provision the controller and Publisher's
  ReadWriteOnce volumes. If there is no default, set `store.persistence.storageClass`
  and `publisher.persistence.storageClass` in the values below.
- [Vekil](provider-proxy.md) running at `http://vekil.vekil-system.svc:1337`, with
  working provider authentication and the models you intend to use. The chart
  deploys Orka's authenticated proxy; Vekil is installed separately.

The commands use release name `orka`, controller namespace `orka-system`, and
runtime namespace `orka-runtimes`. Run them in the same Bash shell. Set the
context explicitly so each command reaches the intended cluster.

## Download the release bundle

```bash
set -euo pipefail
umask 077

export ORKA_CONTEXT='<your-kubeconfig-context>'
export ORKA_VERSION=v0.2.0
ORKA_INSTALL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orka-install.XXXXXX")"
cd "${ORKA_INSTALL_DIR}"

ORKA_RELEASE_URL="https://github.com/orka-agents/orka/releases/download/${ORKA_VERSION}"
curl --fail --location --output candidate.json "${ORKA_RELEASE_URL}/candidate.json"
curl --fail --location --output "orka-${ORKA_VERSION#v}.tgz" \
  "${ORKA_RELEASE_URL}/orka-${ORKA_VERSION#v}.tgz"

jq -e --arg version "${ORKA_VERSION}" '
  .schemaVersion == 1 and .repository == "orka-agents/orka"
  and .version == $version
  and .chart.file == ("orka-" + ($version | ltrimstr("v")) + ".tgz")
' candidate.json >/dev/null
jq -r '.chart | "\(.sha256)  \(.file)"' candidate.json | shasum -a 256 --check

ORKA_CHART="${ORKA_INSTALL_DIR}/orka-${ORKA_VERSION#v}.tgz"
```

Stop if a download or checksum check fails. The archive is the exact chart
tested for this release. `candidate.json` identifies its source commit and all
image digests; the Helm values below use those digests directly.

## Create the namespace and installation Secrets

Create a new namespace with its permanent controller mode claim. If this name
already exists, stop and inspect the existing installation before proceeding.
Do not relabel an old namespace to adopt it.

```bash
kubectl --context "${ORKA_CONTEXT}" create -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: orka-system
  labels:
    orka.ai/controller-mode: harness-v2
YAML

openssl rand 32 > agent-snapshot.key
kubectl --context "${ORKA_CONTEXT}" -n orka-system create secret generic orka-agent-snapshot-key \
  --from-file=key=agent-snapshot.key
```

Back up this 32-byte snapshot key with the installation's state. Retained
execution snapshots require the same key after a restart. Keep the key out of
Git and Helm values, and do not regenerate it when reusing a store.

The admission certificate must cover `orka-webhook.orka-system.svc`. Prepare
`tls.crt`, `tls.key`, and `ca.crt` from your certificate issuer, with
`DNS:orka-webhook.orka-system.svc` in the certificate's subject alternative names.
For local evaluation, this self-signed example creates those files:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
  -keyout tls.key -out tls.crt \
  -subj '/CN=orka-webhook.orka-system.svc' \
  -addext 'subjectAltName=DNS:orka-webhook.orka-system.svc,DNS:orka-webhook.orka-system.svc.cluster.local'
cp tls.crt ca.crt
```

Create the TLS Secret, then read only the public CA certificate for the
webhook's `caBundle`:

```bash
kubectl --context "${ORKA_CONTEXT}" -n orka-system create secret generic orka-webhook-tls \
  --type=kubernetes.io/tls \
  --from-file=tls.crt=tls.crt --from-file=tls.key=tls.key --from-file=ca.crt=ca.crt

ORKA_WEBHOOK_CA_BUNDLE="$(kubectl --context "${ORKA_CONTEXT}" -n orka-system \
  get secret orka-webhook-tls -o jsonpath='{.data.ca\.crt}')"
```

The chart creates its internal artifact, Publisher, provider-proxy, and
SCM-proxy authentication Secrets. Model-provider credentials remain in Vekil.
Keep the private files in this temporary directory protected until you have
stored the required backups, then remove the temporary copies.

## Install the chart with the release images

Generate a values file from the release manifest. This selects the controller,
both native workers, the Publisher, and all four ACP runtimes from the same
release. The file contains image references and the public CA certificate;
private keys stay in Kubernetes Secrets.

```bash
jq --arg ca "${ORKA_WEBHOOK_CA_BUNDLE}" '
  def image: split("@") | {repository: .[0], digest: .[1]};
  {
    controller: {
      mode: "harness-v2",
      watchNamespace: "orka-system",
      image: (.images.controller | image),
      agentExecutionSnapshot: {existingSecret: "orka-agent-snapshot-key", key: "key"},
      acpRuntime: {
        namespace: "orka-runtimes",
        codexImage: .images["acp-codex-runtime"],
        claudeImage: .images["acp-claude-runtime"],
        copilotImage: .images["acp-copilot-runtime"],
        opencodeImage: .images["acp-opencode-runtime"]
      }
    },
    workers: {
      ai: {image: (.images["ai-worker"] | image)},
      general: {image: (.images["general-worker"] | image)}
    },
    publisher: {enabled: true, image: (.images["workspace-publisher"] | image)},
    providerProxy: {enabled: true},
    store: {persistence: {enabled: true}},
    webhooks: {tls: {existingSecret: "orka-webhook-tls"}, caBundle: $ca}
  }
' candidate.json > release-values.json

helm install orka "${ORKA_CHART}" \
  --kube-context "${ORKA_CONTEXT}" --namespace orka-system \
  --values release-values.json --wait --timeout 10m
```

Helm creates the chart's 27 production CRDs on this fresh installation. The two
development-only `fake.workspace.orka.ai` CRDs are excluded. Optional workspace
providers remain disabled; installing their CRDs does not enable them.

## Verify the installation

```bash
kubectl --context "${ORKA_CONTEXT}" -n orka-system get deployments,pvc
kubectl --context "${ORKA_CONTEXT}" get crd -o name | grep -c '\.orka\.ai$'

kubectl --context "${ORKA_CONTEXT}" -n orka-system create -f - <<'YAML'
apiVersion: core.orka.ai/v1alpha1
kind: Task
metadata:
  name: release-install-check
spec:
  type: container
  command: ["/bin/sh", "-c", "printf ORKA_INSTALL_OK"]
  timeout: 3m
  retryPolicy:
    maxRetries: 0
YAML

kubectl --context "${ORKA_CONTEXT}" -n orka-system wait \
  --for=jsonpath='{.status.phase}'=Succeeded task/release-install-check --timeout=3m
```

The controller and Publisher PVCs must be `Bound`, the deployments must be
ready, and the Task must succeed. Follow
[Give yourself an API client](../getting-started.md#give-yourself-an-api-client)
using this same context and the Helm Service `svc/orka`. Read
`GET /api/v1/tasks/release-install-check/result?namespace=orka-system`; its result
must contain `ORKA_INSTALL_OK`.

This Task needs no model credentials. Before submitting coding-agent Tasks,
verify Vekil's readiness and your chosen models as described in
[Provider proxy](provider-proxy.md#verify-vekil-before-wiring-orka).

Keep `candidate.json` and `release-values.json` with the installation record.
The release's attached `acceptance.json` records the chart recovery and runtime
checks. See [Release qualification](../development/release-qualification.md)
for the coverage and [Upgrading](upgrading.md) before changing this installation.
