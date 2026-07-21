# Evidence index

| Evidence set | Captured | Classification | Status | Primary artifacts |
|---|---|---|---|---|
| Governed Connect + Flink walkthrough | 2026-07-20 | Captioned local live run | `PASS` within the documented two-runtime scope | [walkthrough](../docs/live-demo.md), [video](../assets/flowplane-live-screen-demo-motion.mp4), [provenance](live-demo/video-manifest.json) |
| Core engine, 1 MiB | 2026-07-17 | Controlled JMH | `MEASURED_NOT_QUALIFIED` | [summary](core-engine/summary.md), [results](core-engine/results.csv), [qualification](core-engine/qualification-results.json) |
| Payload scaling, 1–64 MiB | 2026-07-18 | Controlled JMH | `MEASURED` | [summary](payload-scaling/summary.md), [results](payload-scaling/results.csv), [regression](payload-scaling/regression.json) |
| Kafka/Flink soak | 2026-07-11 | Local Docker live run | `LIVE_LOCAL_VERIFIED` | [summary](kafka-soak/summary.md), [producer](kafka-soak/producer-results.json), [consumer](kafka-soak/consumer-results.json) |
| Live Flink, 1 MiB | 2026-07-18 | Local Docker live probe | `LIVE_LOCAL_VERIFIED` | [summary](live-flink-runtime/summary.md), [latency](live-flink-runtime/latency-results.json), [allocation](live-flink-runtime/allocation-results.json) |
| Runtime output parity | 2026-07-12 | In-process contract test | `CONTRACT_VERIFIED` | [summary](runtime-parity/summary.md), [matrix](runtime-parity/parity-matrix.csv), [raw report](runtime-parity/parity-output-report.json) |
| Integration/runtime baselines | 2026-07-20 through 2026-07-21 | Local Docker live runs | `LIVE_LOCAL_VERIFIED` | [overview](integration-proofs/EVIDENCE-OVERVIEW.md), [index](integration-proofs/README.md) |
| Core-surface stability soaks | 2026-07-21 | Five local Docker live runs; 10,000 records and at least five minutes each | `LIVE_LOCAL_VERIFIED` | [runtime table](integration-proofs/EVIDENCE-OVERVIEW.md#flowplane-runtime-and-protocol-surfaces) |
| Azure/GCP provider triggers | 2026-07-21 | Local emulator and function-handler runs | `PASS` within the documented trigger contract | [trigger table](integration-proofs/EVIDENCE-OVERVIEW.md#provider-trigger-proofs) |
| Historical integration attempts | through 2026-07-19 | Preserved failed or incomplete runs | `INCOMPLETE` / `PRESERVED_FAILURE` | [historical attempts](historical-attempts/README.md) |

All timestamps, scopes, and statuses refer only to the preserved runs. See the [claims matrix](claims-matrix.csv), [methodology](../docs/benchmark-methodology.md), [interpretation guide](../docs/benchmark-interpretation.md), and [checksums](checksums.sha256).

The tagged-release [manifest](manifest.json) binds the original benchmark release runs. The newer local-integration supplement is indexed by its [evidence overview](integration-proofs/EVIDENCE-OVERVIEW.md), captured [execution matrix](live-local-supplement/audit/execution-matrix.csv), per-bundle manifests, and per-bundle SHA-256 inventories. Incomplete and failed runs remain available under [historical attempts](historical-attempts/README.md).
