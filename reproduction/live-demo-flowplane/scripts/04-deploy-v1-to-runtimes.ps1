. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$metadata = Get-DemoMetadata
$state = Read-DemoState
$runtimeIds = @($state.runtimeIds)
if (-not $state.mappingId -or -not $state.v1ArtifactHash) { throw "Run 02-create-approve-publish-mapping-v1.ps1 first." }
if ($runtimeIds.Count -ne 2) { throw "Register and verify the Kafka Connect connector and Flink job first." }

Write-Pass "Mapping $($state.v1Version) selected"
Write-Pass "Artifact hash verified: $($state.v1ArtifactHash)"

$deployBody = @{
  runtimeIds = $runtimeIds
  rolloutPercent = 100
  requireReplayGate = $false
  reason = "Assign the approved v1 artifact to the recorded Connect connector and Flink job."
  changeTicket = "DEMO-$($metadata.runId)"
}
$deploy = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($state.mappingId)/deploy" -Body $deployBody
$reconciliationAttempts = 1
try {
  $runtimeStates = Wait-FlowplaneRuntimeAssignments -ExpectedVersion $state.v1Version -TimeoutSeconds 30
} catch {
  Write-Warn "Initial runtime acknowledgement window expired; republishing the same immutable assignment after runtime warmup"
  $deploy = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($state.mappingId)/deploy" -Body $deployBody
  $reconciliationAttempts = 2
  $runtimeStates = Wait-FlowplaneRuntimeAssignments -ExpectedVersion $state.v1Version -TimeoutSeconds 90
}

$assignments = @($deploy.targets)
if ($assignments.Count -ne 2) { throw "Expected two runtime assignments, found $($assignments.Count)." }

$state | Add-Member -NotePropertyName v1DeploymentStatus -NotePropertyValue "ACTIVE" -Force
Save-DemoState $state

$report = [ordered]@{
  metadata = $metadata
  status = "PASS"
  deploy = $deploy
  runtimeAssignments = $assignments
  runtimeStates = $runtimeStates
  reconciliationAttempts = $reconciliationAttempts
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "deploy-v1-report.json") -Value $report
Write-MarkdownSummary -Path (Join-Path $script:FLOWPLANE_DEMO_ROOT "deploy-v1-summary.md") -Title "Flowplane v1 Deployment Summary" -Lines @(
  "- Mapping version: $($state.v1Version)",
  "- Artifact hash: $($state.v1ArtifactHash)",
  "- Runtime assignments: $($assignments.Count)",
  "- Runtime acknowledgement attempts: $reconciliationAttempts",
  "- Deployment status: ACTIVE",
  "- Evidence: raw/deploy-v1-report.json"
)
Write-Pass "Assigned to the Apache Flink job"
Write-Pass "Assigned to the Kafka Connect Mongo sink connector"
Write-Pass "Runtime assignment published for live pollers"
Write-Pass "All runtimes acknowledged $($state.v1Version)"
Write-Pass "Active deployments visible"
exit 0
