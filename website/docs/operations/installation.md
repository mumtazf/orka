---
slug: /installation
description: "Install Orka on Kubernetes and run a test task."
---

# Install Orka

This guide installs a published Orka release on Kubernetes using Helm.
For development, [build from source](../getting-started.md#option-b-current-main-from-source).

## Before you start

- Bash, curl, jq, `shasum`, Helm, kubectl, and OpenSSL.
- A cluster with no existing Orka installation or Orka CRDs. CRDs define
  Kubernetes resource types, such as Orka Tasks. You need permission to install
  them and the admission webhooks that check these resources.
- NetworkPolicy enforcement and access to pull images from `ghcr.io`.
- A StorageClass for persistent data volumes.
- [Vekil](provider-proxy.md) running at `http://vekil.vekil-system.svc:1337`
  with access to your model provider. Orka uses it to connect coding agents to models.

Run the steps in one Bash shell. Use `kubectl config get-contexts` to find the
cluster connection name to use for `ORKA_CONTEXT` below.

## 1. Download and check the release

Choose a published [release](https://github.com/orka-agents/orka/releases) with a
Helm chart and `candidate.json`. Set `ORKA_VERSION` below to its tag, including
the leading `v`.

The chart is Orka's install package. `candidate.json` lists the release files
and images. The checks below verify the chart checksum and require a fixed
image digest for each component.

```bash
set -euo pipefail
umask 077

export ORKA_CONTEXT='<your-kubeconfig-context>'
export ORKA_VERSION='<release-tag>'
ORKA_INSTALL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orka-install.XXXXXX")"
cd "${ORKA_INSTALL_DIR}"

ORKA_RELEASE_URL="https://github.com/orka-agents/orka/releases/download/${ORKA_VERSION}"
curl --fail --location --output candidate.json "${ORKA_RELEASE_URL}/candidate.json"
curl --fail --location --output "orka-${ORKA_VERSION#v}.tgz" \
  "${ORKA_RELEASE_URL}/orka-${ORKA_VERSION#v}.tgz"

jq -e --arg version "${ORKA_VERSION}" '
  .images as $images
  | .schemaVersion == 1 and .repository == "orka-agents/orka"
  and .version == $version
  and .chart.file == ("orka-" + ($version | ltrimstr("v")) + ".tgz")
  and all([
    "controller", "ai-worker", "general-worker", "workspace-publisher",
    "acp-codex-runtime", "acp-claude-runtime", "acp-copilot-runtime", "acp-opencode-runtime"
  ][]; . as $role | $images[$role]
    | type == "string" and test("^ghcr[.]io/orka-agents/orka"
      + (if $role == "controller" then "" else "/" + $role end)
      + "@sha256:[0-9a-f]{64}$"))
' candidate.json >/dev/null
jq -r '.chart | "\(.sha256)  \(.file)"' candidate.json | shasum -a 256 --check

ORKA_CHART="${ORKA_INSTALL_DIR}/orka-${ORKA_VERSION#v}.tgz"
```

Stop if any download or validation check fails.

## 2. Create the namespace and encryption key

Orka's controller runs in `orka-system`. The `harness-v2` label selects how it
runs coding agents. The namespace must be new, and the label must stay unchanged.

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

This key encrypts saved agent configuration. Keep it with your backups, outside
Git and Helm values. Reuse the same key when restarting with existing data.

## 3. Set up the webhook certificate

Kubernetes calls Orka's webhook to check resources. It needs a TLS certificate
valid for `orka-webhook.orka-system.svc`.

Use `tls.crt`, `tls.key`, and the issuer's certificate `ca.crt` from your
certificate issuer. For a test cluster, this self-signed example creates them:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
  -keyout tls.key -out tls.crt \
  -subj '/CN=orka-webhook.orka-system.svc' \
  -addext 'subjectAltName=DNS:orka-webhook.orka-system.svc,DNS:orka-webhook.orka-system.svc.cluster.local'
cp tls.crt ca.crt
```

Save the certificate in Kubernetes and read its public CA certificate for Helm:

```bash
kubectl --context "${ORKA_CONTEXT}" -n orka-system create secret generic orka-webhook-tls \
  --type=kubernetes.io/tls \
  --from-file=tls.crt=tls.crt --from-file=tls.key=tls.key --from-file=ca.crt=ca.crt

ORKA_WEBHOOK_CA_BUNDLE="$(kubectl --context "${ORKA_CONTEXT}" -n orka-system \
  get secret orka-webhook-tls -o jsonpath='{.data.ca\.crt}')"
```

Orka creates its other internal Secrets automatically. Model credentials stay
in Vekil. Remove temporary private key files after backing them up securely.

## 4. Install Orka

Create a Helm settings file. It selects the eight images used by this installation
by digest, a fixed image ID. Private keys stay in Kubernetes Secrets.

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
```

If your cluster has no default StorageClass, set `store.persistence.storageClass`
and `publisher.persistence.storageClass` in this file before installing.

```bash
helm install orka "${ORKA_CHART}" \
  --kube-context "${ORKA_CONTEXT}" --namespace orka-system \
  --values release-values.json --wait --timeout 10m
```

Helm installs the CRDs included in the chart. Coding agents use `orka-runtimes`
as their namespace. Optional workspace providers stay disabled.

## 5. Run a test task

Check that the deployments are ready and the data volumes show `Bound`.
List the installed CRDs, then run a container task that prints a known result:

```bash
kubectl --context "${ORKA_CONTEXT}" -n orka-system get deployments,pvc
kubectl --context "${ORKA_CONTEXT}" get crd -o name | grep '\.orka\.ai$'

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

To read the result, connect to Orka's API. Leave this command running:

```bash
kubectl --context "${ORKA_CONTEXT}" -n orka-system port-forward svc/orka 8080:8080
```

In a second Bash terminal, use the same cluster connection name and read the result:

```bash
export ORKA_CONTEXT='<your-kubeconfig-context>'
ORKA_TOKEN="$(kubectl --context "${ORKA_CONTEXT}" -n orka-system create token orka-client)"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${ORKA_TOKEN}" \
  'http://localhost:8080/api/v1/tasks/release-install-check/result?namespace=orka-system'
```

The response should contain `ORKA_INSTALL_OK`. This test does not call a model.
Stop the port-forward with Ctrl-C when finished.

Keep `candidate.json` and `release-values.json` with your installation records.
To run a coding-agent task next, [check your model connection](provider-proxy.md#verify-vekil-before-wiring-orka).
