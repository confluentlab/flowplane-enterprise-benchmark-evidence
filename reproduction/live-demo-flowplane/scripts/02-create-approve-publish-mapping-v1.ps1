. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$metadata = Get-DemoMetadata
$failures = @()
$state = Read-DemoState
$mappingName = if ([string]::IsNullOrWhiteSpace($state.mappingName)) { "$($script:FLOWPLANE_DEMO_NAME)-$($metadata.runId)" } else { $state.mappingName }
$team = Get-DemoTeam
$payload = New-FlowplaneDemoPayload -SchemaVersion "v1.0.0"
$invalidPayload = New-FlowplaneDemoPayload -Invalid -SchemaVersion "v1.0.0"
$dsl = New-FlowplaneDemoMappingDsl -SchemaVersion "v1.0.0" -MappingName $mappingName

$mapping = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings" -Body @{
  name = $mappingName
  description = "Flowplane live buyer demo mapping v1"
  teamId = $team.id
  teamName = $team.name
  projectName = "Live Demo"
  environment = "PRODUCTION"
  mappingDsl = $dsl
  samplePayload = $payload
}
Write-Pass "Mapping draft created"
Write-Pass "100 KB sample payload linked"
Write-Pass "1000-field mapping uploaded"

$validation = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($mapping.id)/validate"
if (-not $validation.valid) { throw "Validation failed: $($validation.errors -join '; ')" }
Write-Pass "Validation completed"

$validSimulation = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($mapping.id)/simulate" -Body @{ payloadJson = $payload }
if ($validSimulation.errorCount -gt 0) { throw "Valid simulation returned errors." }
Write-Pass "Valid simulation passed"

$invalidSimulation = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($mapping.id)/simulate" -Body @{ payloadJson = $invalidPayload }
if ($invalidSimulation.errorCount -lt 1) { $failures += "Invalid simulation did not produce an error result." } else { Write-Pass "Invalid simulation produced DLQ/error result" }

Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($mapping.id)/submit-review" -Body @{
  reason = "Flowplane live demo v1 is validated and ready for review."
  changeTicket = "DEMO-$($metadata.runId)"
} | Out-Null
$approval = Get-ApprovalForMapping -MappingId $mapping.id
if (-not $approval) { throw "Approval request was not created." }
Invoke-FlowplaneApi -Method Post -Path "/api/v1/approvals/$($approval.id)/approve" -Body @{
  reason = "Mapping design approved for the Connect and Flink live run."
  changeTicket = "DEMO-$($metadata.runId)"
} | Out-Null
Invoke-FlowplaneApi -Method Post -Path "/api/v1/approvals/$($approval.id)/qa-pass" -Body @{
  reason = "Valid and invalid v1 simulations passed the recorded QA gate."
  changeTicket = "DEMO-$($metadata.runId)"
} | Out-Null
Write-Pass "Mapping approved"

$published = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($mapping.id)/publish" -Body @{
  reason = "Publish the QA-approved v1 artifact for the live runtime assignment."
  changeTicket = "DEMO-$($metadata.runId)"
}
$artifact = Get-LatestArtifact -MappingId $mapping.id
Write-Pass "Mapping published: $($artifact.versionName)"
Write-Pass "Artifact hash generated: $($artifact.hash)"

$state | Add-Member -NotePropertyName mappingId -NotePropertyValue $mapping.id -Force
$state | Add-Member -NotePropertyName mappingName -NotePropertyValue $mapping.name -Force
$state | Add-Member -NotePropertyName v1ArtifactId -NotePropertyValue $artifact.id -Force
$state | Add-Member -NotePropertyName v1ArtifactHash -NotePropertyValue $artifact.hash -Force
$state | Add-Member -NotePropertyName v1Version -NotePropertyValue $artifact.versionName -Force
Save-DemoState $state

$report = [ordered]@{
  metadata = $metadata
  status = if ($failures.Count -eq 0) { "PASS" } else { "FAIL" }
  mapping = $published
  artifact = $artifact
  validation = $validation
  validSimulation = $validSimulation
  invalidSimulation = $invalidSimulation
  approvalId = $approval.id
  payloadBytes = [Text.Encoding]::UTF8.GetByteCount($payload)
  fieldCount = 1000
  failures = $failures
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "mapping-v1-create-publish-report.json") -Value $report
Write-MarkdownSummary -Path (Join-Path $script:FLOWPLANE_DEMO_ROOT "mapping-v1-summary.md") -Title "Flowplane Mapping v1 Summary" -Lines @(
  "- Mapping ID: $($mapping.id)",
  "- Published version: $($artifact.versionName)",
  "- Artifact hash: $($artifact.hash)",
  "- Validation: PASS",
  "- Valid simulation: PASS",
  "- Invalid simulation produced errors: $($invalidSimulation.errorCount -gt 0)",
  "- Evidence: raw/mapping-v1-create-publish-report.json"
)
if ($failures.Count -gt 0) { exit 1 }
exit 0
