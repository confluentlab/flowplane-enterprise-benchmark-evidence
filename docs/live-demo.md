# Flowplane live Kafka Connect + Flink walkthrough

This captioned 19½-minute recording shows a complete local Flowplane workflow with one Kafka Connect Mongo sink and one Apache Flink job. It is a product walkthrough and a preserved evidence artifact: every claim below is limited to the recorded run and the verification material associated with that run.

[![Open the full Flowplane live walkthrough](../assets/flowplane-live-demo-poster.jpg)](../assets/flowplane-live-screen-demo-motion.mp4)

**[Watch the full video](../assets/flowplane-live-screen-demo-motion.mp4)** · **[Inspect its provenance manifest](../evidence/live-demo/video-manifest.json)**

The recording has no audio track. Its explanations are embedded as persistent lower-third captions, so the full workflow remains understandable when viewed silently.

## What the run demonstrates

One governed mapping is compiled into immutable artifacts and assigned to two separately deployed data-plane runtimes:

- a Kafka Connect Mongo sink connector with two physical tasks; and
- an Apache Flink job with its own execution instance.

Both runtimes independently consume the same raw Kafka stream. Flowplane governs the transformation semantics and artifact lifecycle. Kafka Connect and Flink retain responsibility for transport, delivery, acknowledgements, runtime execution, and downstream writes.

The run demonstrates:

- an initially unassigned and idle runtime state;
- live registration of the connector and Flink job;
- valid and intentionally invalid simulation before deployment;
- approval, publication, and assignment of mapping version 1.0.0;
- one valid and one invalid raw event processed independently by each runtime;
- runtime-created transformed output, structured DLQ outcomes, and Mongo sink output;
- publication of mapping version 1.1.0 with three visible schema additions;
- a completed Connect candidate replay with no unexpected differences or contract violations;
- a passed Flink downstream schema compatibility check;
- gated deployment and runtime verification of version 1.1.0; and
- physical-instance telemetry, artifact provenance, version comparison, and audit history.

## Chapter guide

| Time | Chapter | What to inspect |
|---:|---|---|
| [00:00](../assets/flowplane-live-screen-demo-motion.mp4#t=0) | Clean operational state | Empty demo workspace, zero Connect connectors, and no assigned runtime work |
| [01:25](../assets/flowplane-live-screen-demo-motion.mp4#t=85) | Register Kafka Connect | Flowplane registration, UI-supplied command, two running connector tasks |
| [02:28](../assets/flowplane-live-screen-demo-motion.mp4#t=148) | Register Flink | Visible job-submission command, logical runtime, and physical execution identity |
| [03:52](../assets/flowplane-live-screen-demo-motion.mp4#t=232) | Govern and deploy v1 | Simulation, intentional validation failure, publication, and two-runtime assignment |
| [07:14](../assets/flowplane-live-screen-demo-motion.mp4#t=434) | Verify v1 runtime processing | Raw-only producer, Flink transformed/DLQ records, Connect DLQ, and Mongo document |
| [10:58](../assets/flowplane-live-screen-demo-motion.mp4#t=658) | Publish v2 | Version 1.1.0, immutable artifact identity, and three visible output additions |
| [11:30](../assets/flowplane-live-screen-demo-motion.mp4#t=690) | Connect candidate replay | Historical raw-input evaluation inside the connector wrapper |
| [12:20](../assets/flowplane-live-screen-demo-motion.mp4#t=740) | Flink schema gate | Candidate comparison and the live job's downstream compatibility result |
| [12:58](../assets/flowplane-live-screen-demo-motion.mp4#t=778) | Deploy and verify v2 | Gated assignment, raw-only v2 inputs, runtime-owned outputs, and updated Mongo document |
| [18:05](../assets/flowplane-live-screen-demo-motion.mp4#t=1085) | Evidence verdict and audit | Accounting verdict, governance events, mapping lifecycle, and closing proof |

## Proof boundary

The producer scripts shown in the recording write one valid and one intentionally invalid event per version only to `flowplane.demo.orders.raw`. They do not insert transformed records, DLQ records, or Mongo documents.

```text
raw-only producer
  -> flowplane.demo.orders.raw
     -> Flink job + assigned Flowplane artifact
        -> transformed Kafka topic or Flink DLQ topic
     -> Kafka Connect + assigned Flowplane artifact
        -> Mongo sink document or Connect DLQ topic
```

The control plane manages artifact publication and assignment. The separately deployed runtimes poll for assigned artifacts, verify and execute them in the data plane, and report bounded telemetry and lifecycle state. Production payload processing does not need to traverse the control plane.

For version 1.0.0, the preserved run summary records one transformed and one DLQ outcome from Flink, plus one Mongo document and one DLQ outcome from Kafka Connect. Version 1.1.0 repeats that valid/invalid pattern and visibly adds `customerRiskBand`, `mappingSchemaVersion`, and `runtimeMetadataField` to the successful output.

The Connect replay gate evaluated two historical records. Its recorded result contained one expected schema difference and one expected transform failure from the invalid fixture, with zero unexpected differences and zero contract violations. “Completed replay” therefore describes the compatibility gate result; it does not mean that every historical input transformed successfully.

## Artifact and recording identity

| Item | Preserved value |
|---|---|
| Run ID | `flowplane-live-demo-20260720T110755Z-894bc2cb` |
| Source revision | `10a26df4d7ed6a41f8076a5d7280d73db543c13a` |
| Mapping ID | `6a5e03bf0c305eb209b46297` |
| Version 1.0.0 artifact | `sha256:bcd0e68c98032a6eef6ee610cef82538a73cf607a077365cbf56d2c4a51d7ad9` |
| Version 1.1.0 artifact | `sha256:1919e736455fa02b2ff0bfcfa71abcc9040bd29a90eded897ffe8bbe603b8835` |
| Video | H.264 MP4, 1920 × 1200, 25 fps, 1170.28 seconds |
| Video SHA-256 | `b1826dfb3af0f478e2c83f64f8d51da87679a1447a392860944c7cdbc234a091` |

The final video adds 58 persistent lower-third explanations to the recorded screen capture. The overlays explain operator actions and evidence meaning; they do not replace or alter the runtime results visible in the underlying capture.

## Scope and limitations

This recording proves the documented local run, not production scale, managed-cloud equivalence, universal connector compatibility, or vendor certification. It covers one Kafka Connect connector, one Flink job, two mapping versions, synthetic fixtures, and the displayed local infrastructure. Performance claims and the larger integration matrix use separate evidence sets.

The source demo metadata records the Git revision but does not record a clean/dirty worktree verdict or immutable container image digests. The revision is therefore source attribution, not a clean-build or image-identity claim. Artifact SHA-256 values and the final video SHA-256 are preserved explicitly.

The video is intentionally explanatory. Its provenance manifest binds the media file to the recorded run, artifact hashes, runtime targets, chapter structure, and file digest. For record-level accounting and broader qualification claims, use the [integration evidence overview](../evidence/integration-proofs/EVIDENCE-OVERVIEW.md), [claims matrix](../evidence/claims-matrix.csv), and [evidence classification guide](evidence-classification.md).
