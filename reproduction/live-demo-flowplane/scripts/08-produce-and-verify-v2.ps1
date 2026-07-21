. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$metadata = Get-DemoMetadata
$state = Read-DemoState
if (-not $state.v2ArtifactHash) { throw "Run the v2 publish and deployment steps first." }

$targets = @(Get-FlowplaneDemoRuntimeTargets)
$runtimeIds = @($targets.runtimeId)
$runtimeStates = @(Wait-FlowplaneRuntimeAssignments -ExpectedVersion $state.v2Version -TimeoutSeconds 120)
if ($runtimeStates.Count -ne 2) { throw "Expected one assigned connector and one assigned Flink job before v2 production." }

$validPayload = New-FlowplaneDemoPayload -SchemaVersion "v1.1.0"
$invalidPayload = New-FlowplaneDemoPayload -Invalid -SchemaVersion "v1.1.0"
$skipSourceProduce = $env:FLOWPLANE_DEMO_SKIP_SOURCE_PRODUCE -eq "true"
if ($skipSourceProduce) {
  $sourceProduce = [ordered]@{ topic = $state.rawTopic; produced = 0; mode = "development resume; existing raw records verified" }
  Write-Warn "Development resume: skipped source production"
} else {
  $sourceProduce = Write-FlowplaneKafkaRecords -Topic $state.rawTopic -Records @($validPayload, $invalidPayload)
  Write-Pass "Two v2 source records produced to the raw topic only"
}

$rawTopicRecords = @(Read-FlowplaneKafkaRecords -Topic $state.rawTopic -MaxMessages 20)
$runtimeEvidence = @(Wait-FlowplaneDemoRuntimeOutputs -VersionLabel "v2" -TimeoutSeconds 240 -RuntimeIds $runtimeIds)
if ($runtimeEvidence.Count -ne 2) { throw "Expected v2 evidence from exactly two runtime downstreams." }

$flinkTarget = $targets | Where-Object startupKind -eq "flink" | Select-Object -First 1
$connectTarget = $targets | Where-Object startupKind -eq "kafka-connect" | Select-Object -First 1
$flinkEvidence = $runtimeEvidence | Where-Object runtimeId -eq $flinkTarget.runtimeId | Select-Object -First 1
$connectEvidence = $runtimeEvidence | Where-Object runtimeId -eq $connectTarget.runtimeId | Select-Object -First 1
if (-not $flinkEvidence -or -not $connectEvidence) { throw "Flink or Kafka Connect v2 evidence is missing." }
if ($rawTopicRecords.Count -ne 4) { throw "Expected four preserved raw records across v1 and v2, found $($rawTopicRecords.Count)." }
if ([int]$flinkEvidence.outputRecordCount -ne 1 -or [int]$flinkEvidence.dlqRecordCount -ne 1) { throw "Flink v2 must produce exactly one transformed record and one matching DLQ record." }
if ([int]$connectEvidence.mongoDocumentCount -ne 1 -or [int]$connectEvidence.dlqRecordCount -ne 1) { throw "Kafka Connect v2 must produce exactly one Mongo document and one matching DLQ record." }

$dlqDocuments = @($targets | ForEach-Object {
  $safe = ConvertTo-FlowplaneSafeName $_.runtimeId
  Read-Json (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-$safe-dlq-output.json")
})
$artifactHashMatches = @($dlqDocuments | Where-Object { $_.artifact.artifactHash -ne $state.v2ArtifactHash }).Count -eq 0
$mappingVersionMatches = @($dlqDocuments | Where-Object { $_.artifact.artifactVersion -ne $state.v2Version }).Count -eq 0
$runtimeIdentityMatches = @($dlqDocuments | Where-Object { $runtimeIds -notcontains $_.runtime.id }).Count -eq 0
$runProvenanceMatches = @($runtimeEvidence | Where-Object { $_.sourceRecordRunId -ne $state.runId }).Count -eq 0
if (-not ($artifactHashMatches -and $mappingVersionMatches -and $runtimeIdentityMatches -and $runProvenanceMatches)) {
  throw "v2 downstream provenance did not match this run, its runtimes, version, and artifact hash."
}

$v1Output = Read-Json (Join-Path $script:FLOWPLANE_DEMO_RAW "v1-transformed-output.json")
$v2Output = Read-Json (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-transformed-output.json")
$newFieldsPresent = $null -ne $v2Output.customerRiskBand -and $v2Output.mappingSchemaVersion -eq "v1.1.0"
if (-not $newFieldsPresent) { throw "The Flink v2 output does not contain the expected governed schema change." }
$diff = [ordered]@{
  v1ArtifactHash = $state.v1ArtifactHash
  v2ArtifactHash = $state.v2ArtifactHash
  artifactHashChanged = ($state.v1ArtifactHash -ne $state.v2ArtifactHash)
  expectedNewFields = @("customerRiskBand", "mappingSchemaVersion")
  newFieldsPresent = $newFieldsPresent
  v1 = $v1Output
  v2 = $v2Output
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v1-v2-output-diff.json") -Value $diff

$topicEvidence = [ordered]@{
  sourceProduce = $sourceProduce
  producerWriteBoundary = @($state.rawTopic)
  preservedV1AndV2RawRecordCount = $rawTopicRecords.Count
  transformedRecordsSource = "Flink job"
  mongoRecordsSource = "Kafka Connect connector"
  dlqRecordsSource = "runtime-owned error policy"
  runtimeDownstreams = $runtimeEvidence
  runtimeStatesBeforeProduce = $runtimeStates
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-kafka-topic-evidence.json") -Value $topicEvidence

$parity = [ordered]@{
  artifactHashMatches = $artifactHashMatches
  mappingVersionMatches = $mappingVersionMatches
  runtimeIdentityMatches = $runtimeIdentityMatches
  runProvenanceMatches = $runProvenanceMatches
  schemaChangeVisible = $newFieldsPresent
  flinkTransformedRecordCount = [int]$flinkEvidence.outputRecordCount
  flinkDlqRecordCount = [int]$flinkEvidence.dlqRecordCount
  connectMongoDocumentCount = [int]$connectEvidence.mongoDocumentCount
  connectDlqRecordCount = [int]$connectEvidence.dlqRecordCount
  verifiedRuntimeCount = $runtimeEvidence.Count
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-runtime-parity-report.json") -Value $parity

$report = [ordered]@{
  metadata = $metadata
  status = "PASS"
  runtimeWriteBoundary = "The demo producer wrote only to the raw topic. The Flink job and Connect connector produced downstream evidence."
  outputDiff = $diff
  parity = $parity
  kafkaTopicEvidence = $topicEvidence
  runtimeDownstreams = $runtimeEvidence
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-output-report.json") -Value $report
Write-MarkdownSummary -Path (Join-Path $script:FLOWPLANE_DEMO_ROOT "v2-verification-summary.md") -Title "Flowplane v2 Verification Summary" -Lines @(
  "- Raw producer destination: $($state.rawTopic) only",
  "- Flink transformed/DLQ records: $($parity.flinkTransformedRecordCount)/$($parity.flinkDlqRecordCount)",
  "- Kafka Connect Mongo/DLQ records: $($parity.connectMongoDocumentCount)/$($parity.connectDlqRecordCount)",
  "- v2 schema change visible: $newFieldsPresent",
  "- Evidence: raw/v2-output-report.json"
)
Write-Pass "v2 outputs verified from the Flink job and Kafka Connect connector"
exit 0
