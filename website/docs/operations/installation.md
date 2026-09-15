---
slug: /installation
description: "Install Orka on Kubernetes and run a test task."
---

# Install Orka

Install the latest Orka release with Helm, then run a small test task.
These commands use your current Kubernetes context, name the installation `orka`,
and use the namespace `orka-system`.
For development, [build from source](../getting-started.md#option-b-current-main-from-source).

## Before you start

- Bash, Helm, kubectl, OpenSSL, curl, and jq.
- A Kubernetes cluster with no existing Orka installation or Orka CRDs,
  and permission to install cluster-wide resources.
- NetworkPolicy enforcement, a default StorageClass, and access to pull images
  from `ghcr.io`.
- [Vekil](provider-proxy.md) running with access to your model provider.
  Orka expects it at `http://vekil.vekil-system.svc:1337`.

## 1. Prepare the namespace

Create Orka's namespace and encryption key. The namespace label selects the
default agent execution mode, `harness-v2`.

```bash
kubectl create namespace orka-system
kubectl label namespace orka-system orka.ai/controller-mode=harness-v2

openssl rand 32 | kubectl -n orka-system create secret generic orka-agent-snapshot-key \
  --from-file=key=/dev/stdin
```

Back up this Secret with your data. Orka needs the same key to read saved agent
configuration after a restore.

Before continuing, complete the [webhook certificate setup](../reference/configuration.md#webhook-certificate).
The chart currently requires this Secret for Kubernetes to validate Orka resources.

## 2. Install with Helm

Expand the block below and run it to create `release-values.json`, the Helm
settings file. It downloads the latest release's image settings automatically.
You do not need to edit the block.

<details>
<summary>Generate the Helm settings file</summary>

```bash
curl --fail --location --output candidate.json \
  https://github.com/orka-agents/orka/releases/latest/download/candidate.json &&
jq -e --arg ca "$(kubectl -n orka-system get secret orka-webhook-tls -o jsonpath='{.data.ca\.crt}')" '
  def image: split("@") | {repository: .[0], digest: .[1]};
  if .schemaVersion != 1 or .repository != "orka-agents/orka"
    or (.version | test("^v[0-9]+[.][0-9]+[.][0-9]+$") | not)
  then error("invalid release metadata")
  elif $ca == "" then error("complete the webhook certificate setup first")
  else .images end |
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
' candidate.json > release-values.json
```

</details>

Install the chart from Orka's Helm repository:

```bash
helm repo add orka https://orka-agents.github.io/orka/charts
helm repo update orka
helm install orka orka/orka --namespace orka-system \
  --version "$(jq -er '.version | ltrimstr("v")' candidate.json)" \
  --values release-values.json --wait --timeout 10m
```

The chart version is read automatically to match the downloaded image settings.
Keep `release-values.json` with your installation records. See
[Release files](../reference/release-status.md#release-files) for details.

## 3. Check the installation

Check that the deployments are ready and the data volumes show `Bound`,
then run a container task. This test does not call a model.

```bash
kubectl -n orka-system get deployments,pvc

kubectl -n orka-system create -f - <<'YAML'
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

kubectl -n orka-system wait \
  --for=jsonpath='{.status.phase}'=Succeeded task/release-install-check --timeout=3m
```

When the command reports `condition met`, Orka has completed its first task.
Next, [run a coding agent](../getting-started.md#running-a-coding-agent)
or [connect to the API](../getting-started.md#give-yourself-an-api-client).
