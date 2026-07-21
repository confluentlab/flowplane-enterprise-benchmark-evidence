# Reproduce the local integration evidence

This directory preserves the scripts and canonical fixture used to create the successful local integration bundles. The scripts are inspectable evidence of the processing path, but they are not a standalone replacement for the Flowplane product source tree and Docker build context.

For the Connect + Flink walkthrough, see the [operational scripts behind the live Flowplane run](live-demo-flowplane/README.md). That guide links the runtime-registration, mapping-governance, deployment, raw-topic production, runtime-verification, and evidence-assembly scripts together with the actual mapping and payload fixtures.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7
- Docker Desktop with Linux containers
- Node.js and npm for JavaScript verifier/bridge dependencies
- JDK and Maven for runtime images built from source
- a checkout of the Flowplane control-plane repository

Install Node dependencies with `npm ci` in the asset directories that contain a `package-lock.json`. `node_modules` and Python bytecode are intentionally not copied into this evidence repository.

## Run one baseline proof

From the Flowplane verification workspace, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo\11-run-live-local-verification.ps1 `
  -FlowplaneRoot C:\path\to\flowplane-controlplane `
  -Execute `
  -Integration pulsar
```

Replace `pulsar` with an integration name from [`config/integrations.json`](live-local-verification/config/integrations.json). The copied top-level runner is [`11-run-live-local-verification.ps1`](11-run-live-local-verification.ps1); its supporting scripts are under [`live-local-verification/`](live-local-verification/).

## Run a 10,000-record, five-minute soak

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo\11-run-live-local-verification.ps1 `
  -FlowplaneRoot C:\path\to\flowplane-controlplane `
  -Execute `
  -Integration http-single `
  -ValidRecordCount 9900 `
  -InvalidRecordCount 100 `
  -MinimumDurationSeconds 300
```

The qualified soak integration names are `embedded-spring`, `http-single`, `http-batch`, `grpc-batch`, and `grpc-streaming`.

## Run provider-trigger proofs

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo\live-local-verification\Run-AzureQueueTriggerProof.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo\live-local-verification\Run-AzureEventHubTriggerProof.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\demo\live-local-verification\Run-GcpPubSubTriggerProof.ps1
```

Azure Queue uses Azurite. Azure Event Hubs uses Microsoft’s Event Hubs emulator plus Azurite for DLQ storage. GCP uses Google’s Pub/Sub emulator plus the documented envelope-only bridge because the emulator does not provide Eventarc.

## Understand the runtime-call pipeline

1. The verifier writes the canonical fixture only to the input broker, queue, stream, topic, or source database.
2. The deployed integration consumes that input.
3. The integration invokes the assigned Flowplane runtime or embeds the Flowplane JVM engine.
4. The integration or runtime publishes the actual runtime result to its output or DLQ destination.
5. The verifier reads those destinations and compares their canonical hashes and error contracts with independently simulated expectations.

For HTTP and gRPC surfaces, [`kafka-runtime-surface-bridge.mjs`](live-local-verification/adapters/kafka-runtime-surface-bridge.mjs) performs step 3 and transports the returned response in step 4. It does not implement the mapping. [`kafka-raw-only-verifier.mjs`](live-local-verification/adapters/kafka-raw-only-verifier.mjs) has only the raw Kafka producer target.

For GCP Pub/Sub, [`gcp-eventarc-bridge.mjs`](live-local-verification/assets/serverless-event-node/gcp-eventarc-bridge.mjs) changes only the incoming event envelope. The Java CloudEvent handler publishes the transformed and DLQ results.

## Verify preserved evidence

```bash
python scripts/validate-live-local-evidence.py
python scripts/regenerate-checksums.py
python scripts/validate-evidence.py
```

The first command verifies every imported per-bundle checksum, status, accounting record, content validation result, and write-boundary audit. The second and third commands refresh and verify the repository-wide checksum inventory.

## Capture-time command files

Every successful run bundle includes a `reproduce.ps1`. Those files are immutable capture records and may reference the original workstation’s absolute paths. Do not edit them to look portable; use the commands above for a new checkout.
