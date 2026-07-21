# Operational scripts behind the live Flowplane run

This directory contains the scripts and fixtures that performed the Flowplane work shown in the Connect + Flink walkthrough. It intentionally excludes FFmpeg commands, Remotion code, motion graphics, captions, and narration data.

The preserved workflow covers runtime preparation and registration, mapping governance, artifact deployment, raw-topic production, runtime-owned downstream verification, promotion gates, and final evidence assembly.

## Execution order

| Order | Script | What it does |
|---:|---|---|
| Shared | [`FlowplaneDemo.Common.ps1`](scripts/FlowplaneDemo.Common.ps1) | Provides the Flowplane API client, mapping and payload builders, Kafka helpers, runtime definitions, Mongo readers, and verification functions used by every stage |
| 0 | [`00-prepare-connect-flink-demo.ps1`](scripts/00-prepare-connect-flink-demo.ps1) | Confirms the local services, builds and deploys the Connect SMT and Flink runtime, registers the downstream schema, and records artifact hashes |
| 1 | [`01-reset-demo-state.ps1`](scripts/01-reset-demo-state.ps1) | Removes prior demo mappings, connectors, jobs, topics, and Mongo sink documents while preserving tenant and authentication ownership records |
| Guard | [`assert-runtime-write-boundary.ps1`](scripts/assert-runtime-write-boundary.ps1) | Rejects unapproved producer calls and verifies that demo scripts write only to the raw Kafka topic |
| 2 | [`02-create-approve-publish-mapping-v1.ps1`](scripts/02-create-approve-publish-mapping-v1.ps1) | Creates mapping v1, validates it, runs valid and invalid simulations, submits it for review, approves it, and publishes the immutable artifact |
| 3a | [`03-apply-connect-ui-registration.ps1`](scripts/03-apply-connect-ui-registration.ps1) | Applies the Flowplane UI-issued runtime profile to the MongoDB Kafka Connect sink and waits for its worker and tasks |
| 3b | [`03-register-flink-job.ps1`](scripts/03-register-flink-job.ps1) | Registers the Flink logical runtime and submits the live Flink job with renewable runtime authentication |
| 3c | [`03-verify-idle-runtimes.ps1`](scripts/03-verify-idle-runtimes.ps1) | Confirms that the connector and Flink job are online, idle, and unassigned before deployment |
| 4 | [`04-deploy-v1-to-runtimes.ps1`](scripts/04-deploy-v1-to-runtimes.ps1) | Assigns the same v1 artifact to the connector and Flink job and verifies their acknowledgements |
| 5 | [`05-produce-and-verify-v1.ps1`](scripts/05-produce-and-verify-v1.ps1) | Produces one valid and one invalid v1 payload to the raw topic only, then reads runtime-created Kafka, DLQ, and Mongo results |
| 6 | [`06-create-approve-publish-mapping-v2.ps1`](scripts/06-create-approve-publish-mapping-v2.ps1) | Creates, simulates, approves, and publishes mapping v2 while preserving the v1 artifact |
| 7 | [`07-deploy-v2-to-runtimes.ps1`](scripts/07-deploy-v2-to-runtimes.ps1) | Requires a completed Connect candidate replay and passed Flink schema check before assigning v2 |
| 8 | [`08-produce-and-verify-v2.ps1`](scripts/08-produce-and-verify-v2.ps1) | Produces the valid and invalid v2 payloads to the raw topic only and verifies the new runtime-owned outputs and DLQs |
| 9 | [`09-generate-demo-evidence-report.ps1`](scripts/09-generate-demo-evidence-report.ps1) | Checks the required reports, runtime scope, artifacts, producer boundary, UI result, and missing-evidence count before issuing the final verdict |

The screen recorder invoked these operational stages in this order while it navigated the UI. The recorder and all post-production code are intentionally omitted because they do not create Flowplane mappings, register runtimes, produce source events, or verify downstream results.

## Mapping and payload fixtures

| Fixture | Meaning |
|---|---|
| [`mapping-v1.yaml`](fixtures/mapping-v1.yaml) | Governed mapping version 1.0.0 extracted from the preserved mapping report |
| [`mapping-v2.yaml`](fixtures/mapping-v2.yaml) | Governed mapping version 1.1.0 with new `customerRiskBand` and `runtimeMetadataField` outputs; the existing `mappingSchemaVersion` output carries the new version value |
| [`payload-v1-valid.json`](fixtures/payload-v1-valid.json) | Valid v1 source payload used by simulation and raw-topic production |
| [`payload-v1-invalid.json`](fixtures/payload-v1-invalid.json) | Invalid v1 raw Kafka record preserved by the run; the empty event ID triggers the documented field errors |
| [`payload-v2-valid.json`](fixtures/payload-v2-valid.json) | Valid v2 source payload used by simulation and raw-topic production |
| [`payload-v2-invalid.json`](fixtures/payload-v2-invalid.json) | Invalid v2 payload reconstructed with the exact inspected payload builder and run identity; see the provenance limitation below |
| [`runtime-and-topic-state.json`](fixtures/runtime-and-topic-state.json) | Recorded runtime IDs, destinations, mapping ID, artifact IDs, versions, and artifact hashes for this run |

The payloads are intentionally wide: each contains 1,000 `wide.fieldNNNN` values plus padding so the live workflow exercises a substantial mapping and approximately 100 KiB source record.

## Write boundary

```text
payload-v1-*.json or payload-v2-*.json
  -> flowplane.demo.orders.raw
     -> Flink job + assigned Flowplane artifact
        -> flowplane.demo.orders.flink.transformed
        -> flowplane.demo.orders.flink.dlq
     -> Kafka Connect Mongo sink + assigned Flowplane artifact
        -> flowplane_sink.flowplane_demo_orders_connect
        -> flowplane.demo.orders.connect.dlq
```

Only [`05-produce-and-verify-v1.ps1`](scripts/05-produce-and-verify-v1.ps1) and [`08-produce-and-verify-v2.ps1`](scripts/08-produce-and-verify-v2.ps1) call the Kafka producer helper, and both target the raw topic. The scripts read downstream destinations after the separately running Flink and Connect runtimes process the inputs. They do not insert transformed, DLQ, or Mongo results.

## Running the scripts

These files retain their original source-tree-relative paths and require a complete Flowplane control-plane checkout, the local Docker quality stack, built Java runtime artifacts, and runtime credentials. They are evidence and an execution reference, not a standalone copy of the Flowplane product.

From `scripts/demo` in a complete checkout, the operational stages are:

```powershell
.\01-reset-demo-state.ps1
.\00-prepare-connect-flink-demo.ps1
.\assert-runtime-write-boundary.ps1
.\02-create-approve-publish-mapping-v1.ps1
# Register Connect through the Flowplane UI, then apply its generated profile:
.\03-apply-connect-ui-registration.ps1 -ProfileJson <ui-generated-profile.json>
.\03-register-flink-job.ps1
.\03-verify-idle-runtimes.ps1
.\04-deploy-v1-to-runtimes.ps1
.\05-produce-and-verify-v1.ps1
.\06-create-approve-publish-mapping-v2.ps1
# Request the Connect replay and Flink schema check through Flowplane.
.\07-deploy-v2-to-runtimes.ps1
.\08-produce-and-verify-v2.ps1
.\assert-runtime-write-boundary.ps1 -PostRun
.\09-generate-demo-evidence-report.ps1
```

Run-issued runtime client secrets and UI-generated private profiles are not included. The registration scripts require those values through environment variables or explicit local input files. The shared helper still shows the quality stack's documented local-only JWT fallback string; it is not a captured or production credential.

## Provenance boundary

The run records source revision `10a26df4d7ed6a41f8076a5d7280d73db543c13a`, but the operational scripts were collected from a dirty development worktree and their execution-time SHA-256 values were not recorded. This publication is therefore classified `SOURCE_INSPECTED`, not as a byte-for-byte historical build attestation.

The exact collection state, fixture derivation, and current file hashes are preserved in [`source-snapshot.json`](source-snapshot.json). All files are also covered by the repository-wide [checksum inventory](../../evidence/checksums.sha256) and central evidence validator.
