. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$metadata = Get-DemoMetadata
$state = Read-DemoState
if (-not $state.mappingId -or -not $state.v1ArtifactHash) { throw "Run v1 publish/deploy scripts first." }

$targets = @(Get-FlowplaneDemoRuntimeTargets)
$runtimeIds = @($targets.runtimeId)
$rawTopic = $state.rawTopic
$runtimeStates = @(Wait-FlowplaneRuntimeAssignments -ExpectedVersion $state.v1Version -TimeoutSeconds 120)
if ($runtimeStates.Count -ne 2) { throw "Expected two assigned runtimes before v1 production." }
Write-Pass "Kafka Connect connector and Flink job are assigned v1 before production"

$validPayload = New-FlowplaneDemoPayload -SchemaVersion "v1.0.0"
$invalidPayload = New-FlowplaneDemoPayload -Invalid -SchemaVersion "v1.0.0"
$skipSourceProduce = $env:FLOWPLANE_DEMO_SKIP_SOURCE_PRODUCE -eq "true"
if ($skipSourceProduce) {
  $sourceProduce = [ordered]@{ topic = $rawTopic; produced = 0; mode = "development resume; existing raw records verified" }
  Write-Warn "Development resume: skipped source production"
} else {
  $sourceProduce = Write-FlowplaneKafkaRecords -Topic $rawTopic -Records @($validPayload, $invalidPayload)
  Write-Pass "Two source records produced to the raw topic only"
}

$rawTopicRecords = @(Read-FlowplaneKafkaRecords -Topic $rawTopic -MaxMessages 10)
$runtimeEvidence = @(Wait-FlowplaneDemoRuntimeOutputs -VersionLabel "v1" -TimeoutSeconds 240 -RuntimeIds $runtimeIds)
if ($runtimeEvidence.Count -ne 2) { throw "Expected v1 evidence from exactly two runtime downstreams, found $($runtimeEvidence.Count)." }

$flinkTarget = $targets | Where-Object startupKind -eq "flink" | Select-Object -First 1
$connectTarget = $targets | Where-Object startupKind -eq "kafka-connect" | Select-Object -First 1
$flinkEvidence = $runtimeEvidence | Where-Object runtimeId -eq $flinkTarget.runtimeId | Select-Object -First 1
$connectEvidence = $runtimeEvidence | Where-Object runtimeId -eq $connectTarget.runtimeId | Select-Object -First 1
if (-not $flinkEvidence -or -not $connectEvidence) { throw "Flink or Kafka Connect downstream evidence is missing." }
if ($rawTopicRecords.Count -ne 2) { throw "Expected exactly two raw Kafka records for v1, found $($rawTopicRecords.Count)." }
if ([int]$flinkEvidence.outputRecordCount -ne 1 -or [int]$flinkEvidence.dlqRecordCount -ne 1) { throw "Flink v1 must produce exactly one transformed record and one matching DLQ record." }
if ([int]$connectEvidence.mongoDocumentCount -ne 1 -or [int]$connectEvidence.dlqRecordCount -ne 1) { throw "Kafka Connect v1 must produce exactly one Mongo document and one matching DLQ record." }

$dlqDocuments = @($targets | ForEach-Object {
  $safe = ConvertTo-FlowplaneSafeName $_.runtimeId
  Read-Json (Join-Path $script:FLOWPLANE_DEMO_RAW "v1-$safe-dlq-output.json")
})
$artifactHashMatches = @($dlqDocuments | Where-Object { $_.artifact.artifactHash -ne $state.v1ArtifactHash }).Count -eq 0
$mappingVersionMatches = @($dlqDocuments | Where-Object { $_.artifact.artifactVersion -ne $state.v1Version }).Count -eq 0
$runtimeIdentityMatches = @($dlqDocuments | Where-Object { $runtimeIds -notcontains $_.runtime.id }).Count -eq 0
$runProvenanceMatches = @($runtimeEvidence | Where-Object { $_.sourceRecordRunId -ne $state.runId }).Count -eq 0
if (-not ($artifactHashMatches -and $mappingVersionMatches -and $runtimeIdentityMatches -and $runProvenanceMatches)) {
  throw "v1 downstream provenance did not match the current run, runtimes, version, and artifact hash."
}

$topicEvidence = [ordered]@{
  sourceProduce = $sourceProduce
  producerWriteBoundary = @($rawTopic)
  transformedRecordsSource = "Flink job"
  mongoRecordsSource = "Kafka Connect connector"
  dlqRecordsSource = "Runtime-owned Flowplane error policy"
  rawTopic = $rawTopic
  rawRecordCount = $rawTopicRecords.Count
  rawRecords = $rawTopicRecords
  runtimeDownstreams = $runtimeEvidence
  runtimeStatesBeforeProduce = $runtimeStates
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v1-kafka-topic-evidence.json") -Value $topicEvidence

$parity = [ordered]@{
  artifactHashMatches = $artifactHashMatches
  mappingVersionMatches = $mappingVersionMatches
  runtimeIdentityMatches = $runtimeIdentityMatches
  runProvenanceMatches = $runProvenanceMatches
  kafkaSourceRecordCount = $rawTopicRecords.Count
  flinkTransformedRecordCount = [int]$flinkEvidence.outputRecordCount
  flinkDlqRecordCount = [int]$flinkEvidence.dlqRecordCount
  connectMongoDocumentCount = [int]$connectEvidence.mongoDocumentCount
  connectDlqRecordCount = [int]$connectEvidence.dlqRecordCount
  verifiedRuntimeCount = $runtimeEvidence.Count
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v1-runtime-parity-report.json") -Value $parity

$report = [ordered]@{
  metadata = $metadata
  status = "PASS"
  runtimeWriteBoundary = "The demo producer wrote only to the raw topic. Flink wrote Kafka output; Kafka Connect wrote Mongo output; each runtime wrote its own DLQ."
  parity = $parity
  kafkaTopicEvidence = $topicEvidence
  runtimeDownstreams = $runtimeEvidence
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v1-output-report.json") -Value $report
Write-MarkdownSummary -Path (Join-Path $script:FLOWPLANE_DEMO_ROOT "v1-verification-summary.md") -Title "Flowplane v1 Verification Summary" -Lines @(
  "- Raw producer destination: $rawTopic only",
  "- Flink transformed/DLQ records: $($parity.flinkTransformedRecordCount)/$($parity.flinkDlqRecordCount)",
  "- Kafka Connect Mongo/DLQ records: $($parity.connectMongoDocumentCount)/$($parity.connectDlqRecordCount)",
  "- Current-run provenance: $runProvenanceMatches",
  "- Runtime/artifact/version provenance: $runtimeIdentityMatches/$artifactHashMatches/$mappingVersionMatches",
  "- Evidence: raw/v1-output-report.json"
)
Write-Pass "v1 outputs verified from the Flink job and Kafka Connect connector"
exit 0
