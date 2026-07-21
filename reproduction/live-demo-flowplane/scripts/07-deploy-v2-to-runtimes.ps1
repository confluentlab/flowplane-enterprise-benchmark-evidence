. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$metadata = Get-DemoMetadata
$state = Read-DemoState
$targets = @(Get-FlowplaneDemoRuntimeTargets)
if (-not $state.v2ArtifactHash) { throw "Run 06-create-approve-publish-mapping-v2.ps1 first." }
if ($targets.Count -ne 2) { throw "The live demo must contain exactly one Kafka Connect connector and one Flink job." }

$connectRuntimeId = @($targets | Where-Object startupKind -eq "kafka-connect" | Select-Object -First 1).runtimeId
$flinkRuntimeId = @($targets | Where-Object startupKind -eq "flink" | Select-Object -First 1).runtimeId

$replayResponse = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes/$connectRuntimeId/replays"
$replays = if ($null -ne $replayResponse.value) { @($replayResponse.value) } else { @($replayResponse) }
$candidateReplay = @($replays | Where-Object {
  $_.replayMode -eq "CANDIDATE" -and
  $_.candidateArtifactId -eq $state.v2ArtifactId -and
  $_.status -eq "COMPLETED"
} | Select-Object -First 1)
if ($candidateReplay.Count -ne 1) {
  throw "A completed Connect candidate replay for artifact $($state.v2ArtifactId) is required before v2 deployment. Queue it from Simulation Studio."
}

$schemaResponse = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes/$flinkRuntimeId/schema-checks"
$schemaChecks = if ($null -ne $schemaResponse.value) { @($schemaResponse.value) } else { @($schemaResponse) }
$schemaCheck = @($schemaChecks | Where-Object {
  $_.mappingId -eq $state.mappingId -and
  $_.topic -eq "flowplane.demo.orders.flink.transformed" -and
  $_.status -eq "PASSED"
} | Select-Object -First 1)
if ($schemaCheck.Count -ne 1) {
  throw "A passed Flink downstream schema check is required before v2 deployment. Run it from Mapping Editor."
}

$governancePolicy = Invoke-FlowplaneApi -Method Get -Path "/api/v1/approvals/policies"
if ($governancePolicy.replayRequiredForProduction -ne $false) {
  throw "The demo policy must use one explicit Connect replay and a separate Flink schema gate; all-runtime replay is still enabled."
}

$gateEvidence = [ordered]@{
  metadata = $metadata
  status = "PASS"
  connectConnectorReplay = $candidateReplay[0]
  flinkJobSchemaCheck = $schemaCheck[0]
  governancePolicy = [ordered]@{
    replayRequiredForProduction = $governancePolicy.replayRequiredForProduction
    enforcement = "This script requires one completed Connect candidate replay and one passed Flink downstream schema check before deployment."
  }
  runtimeSemantics = [ordered]@{
    connect = "individual Kafka Connect connector"
    flink = "individual Flink job"
  }
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-runtime-gates-report.json") -Value $gateEvidence

$runtimeIds = @($targets.runtimeId)
$deploy = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($state.mappingId)/deploy" -Body @{
  runtimeIds = $runtimeIds
  rolloutPercent = 100
  requireReplayGate = $false
  reason = "Promote v1.1.0 after Connect replay and Flink downstream schema gates passed."
  changeTicket = "DEMO-$($metadata.runId)"
}
$runtimeStates = Wait-FlowplaneRuntimeAssignments -ExpectedVersion $state.v2Version -TimeoutSeconds 120
$assignments = @($deploy.targets)
if ($assignments.Count -ne 2) { throw "Expected exactly two v2 assignments, found $($assignments.Count)." }

$report = [ordered]@{
  metadata = $metadata
  status = "PASS"
  preDeploymentGates = $gateEvidence
  deploy = $deploy
  runtimeAssignments = $assignments
  runtimeStates = $runtimeStates
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "deploy-v2-report.json") -Value $report
Write-MarkdownSummary -Path (Join-Path $script:FLOWPLANE_DEMO_ROOT "deploy-v2-summary.md") -Title "Flowplane v2 Deployment Summary" -Lines @(
  "- Mapping version: $($state.v2Version)",
  "- Connect candidate replay: COMPLETED",
  "- Flink downstream schema check: PASSED",
  "- Runtime assignments: $($assignments.Count) (one connector, one job)",
  "- Evidence: raw/deploy-v2-report.json"
)
Write-Pass "Connect replay and Flink schema gates verified"
Write-Pass "v2 assigned to one connector and one Flink job"
exit 0
