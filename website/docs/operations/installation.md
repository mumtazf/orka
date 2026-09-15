---
slug: /installation
description: "Install Orka on Kubernetes and run a test task."
---

# Install Orka

Install a published Orka release with Helm, then run a small test task.
These steps name the installation `orka` and use the namespace `orka-system`.
For development, [build from source](../getting-started.md#option-b-current-main-from-source).

## Before you start

- Bash, Helm, kubectl, OpenSSL, curl, and jq.
- A Kubernetes cluster with no existing Orka installation or Orka CRDs,
  and permission to install cluster-wide resources.
- NetworkPolicy enforcement, a default StorageClass, and access to pull images
  from `ghcr.io`.
- [Vekil](provider-proxy.md) running with access to your model provider.
  Orka expects it at `http://vekil.vekil-system.svc:1337`.

## 1. Choose your cluster and release

Run the steps in one Bash shell. Replace the two placeholders below:

- `ORKA_CONTEXT`: your cluster connection name from `kubectl config get-contexts`.
- `ORKA_VERSION`: a published [release tag](https://github.com/orka-agents/orka/releases), including the leading `v`.

```bash
set -euo pipefail
umask 077

export ORKA_CONTEXT='<your-kubeconfig-context>'
export ORKA_VERSION='<release-tag>'
mkdir orka-install
cd orka-install

helm repo add orka https://orka-agents.github.io/orka/charts
helm repo update orka
```

## 2. Prepare the namespace and Secrets

Create Orka's namespace and encryption key. The namespace label selects the
default agent execution mode, `harness-v2`.

```bash
kubectl --context "${ORKA_CONTEXT}" create namespace orka-system
kubectl --context "${ORKA_CONTEXT}" label namespace orka-system orka.ai/controller-mode=harness-v2

openssl rand 32 > agent-snapshot.key
kubectl --context "${ORKA_CONTEXT}" -n orka-system create secret generic orka-agent-snapshot-key \
  --from-file=key=agent-snapshot.key
```

Back up `agent-snapshot.key` securely. Orka needs the same key to read saved
agent configuration after a restart or restore.

The webhook lets Kubernetes check Orka resources. It needs `tls.crt`, `tls.key`,
and the issuer's certificate `ca.crt`, valid for `orka-webhook.orka-system.svc`.
Use your certificate issuer, or create a self-signed certificate for a test cluster:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
  -keyout tls.key -out tls.crt \
  -subj '/CN=orka-webhook.orka-system.svc' \
  -addext 'subjectAltName=DNS:orka-webhook.orka-system.svc,DNS:orka-webhook.orka-system.svc.cluster.local'
cp tls.crt ca.crt
```

Save the certificate in Kubernetes:

```bash
kubectl --context "${ORKA_CONTEXT}" -n orka-system create secret generic orka-webhook-tls \
  --type=kubernetes.io/tls \
  --from-file=tls.crt=tls.crt --from-file=tls.key=tls.key --from-file=ca.crt=ca.crt
```

Keep private keys out of Git and Helm values. Orka creates its other internal
Secrets automatically; model credentials stay in Vekil.

## 3. Install with Helm

Expand the block below and run it to create `release-values.json`, the Helm
settings file. It selects the matching release images automatically and refers
to the Secrets you created. You do not need to edit the block.

<details>
<summary>Generate the Helm settings file</summary>

```bash
curl --fail --location \
  "https://github.com/orka-agents/orka/releases/download/${ORKA_VERSION}/candidate.json" |
jq -e --arg version "${ORKA_VERSION}" --arg ca "$(openssl base64 -A -in ca.crt)" '
  def image: split("@") | {repository: .[0], digest: .[1]};
  if .schemaVersion != 1 or .repository != "orka-agents/orka" or .version != $version
  then error("release metadata does not match the selected version") else .images end |
  {
    controller: {
      mode: "harness-v2",
      watchNamespace: "orka-system",
      image: (.controller | image),
      agentExecutionSnapshot: {existingSecret: "orka-agent-snapshot-key", key: "key"},
      acpRuntime: {
        namespace: "orka-runtimes",
        codexImage: .["acp-codex-runtime"],
        claudeImage: .["acp-claude-runtime"],
        copilotImage: .["acp-copilot-runtime"],
        opencodeImage: .["acp-opencode-runtime"]
      }
    },
    workers: {
      ai: {image: (.["ai-worker"] | image)},
      general: {image: (.["general-worker"] | image)}
    },
    publisher: {enabled: true, image: (.["workspace-publisher"] | image)},
    providerProxy: {enabled: true},
    store: {persistence: {enabled: true}},
    webhooks: {tls: {existingSecret: "orka-webhook-tls"}, caBundle: $ca}
  }
' > release-values.json
```

</details>

Install the chart from Orka's Helm repository:

```bash
helm install orka orka/orka --version "${ORKA_VERSION#v}" \
  --kube-context "${ORKA_CONTEXT}" --namespace orka-system \
  --values release-values.json --wait --timeout 10m
```

Keep `release-values.json` with your installation records.
See [Release files](../reference/release-status.md#release-files) for details
about the image settings.

## 4. Check the installation

Check that the deployments are ready and the data volumes show `Bound`,
then run a container task. This test does not call a model.

```bash
kubectl --context "${ORKA_CONTEXT}" -n orka-system get deployments,pvc

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

When the command reports `condition met`, Orka has completed its first task.
Next, [run a coding agent](../getting-started.md#running-a-coding-agent)
or [connect to the API](../getting-started.md#give-yourself-an-api-client).
