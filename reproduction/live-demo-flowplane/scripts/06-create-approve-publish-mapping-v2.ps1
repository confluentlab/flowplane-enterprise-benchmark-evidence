. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$metadata = Get-DemoMetadata
$state = Read-DemoState
if (-not $state.mappingId -or -not $state.v1ArtifactHash) { throw "Run v1 publish script first." }

$current = Invoke-FlowplaneApi -Method Get -Path "/api/v1/mappings/$($state.mappingId)"
$mappingName = if ([string]::IsNullOrWhiteSpace($state.mappingName)) { $script:FLOWPLANE_DEMO_NAME } else { $state.mappingName }
$v2Dsl = New-FlowplaneDemoMappingDsl -SchemaVersion "v1.1.0" -MappingName $mappingName
$v2Payload = New-FlowplaneDemoPayload -SchemaVersion "v1.1.0"
$invalidPayload = New-FlowplaneDemoPayload -Invalid -SchemaVersion "v1.1.0"

Invoke-FlowplaneApi -Method Put -Path "/api/v1/mappings/$($state.mappingId)/draft" -Body @{
  mappingDsl = $v2Dsl
  samplePayload = $v2Payload
  expectedUpdatedAt = $current.updatedAt
} | Out-Null
Write-Pass "Mapping v2 draft created from v1"
Write-Pass "Schema/output change applied"

$validation = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($state.mappingId)/validate"
if (-not $validation.valid) { throw "Validation failed: $($validation.errors -join '; ')" }
Write-Pass "Validation completed"

$validSimulation = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($state.mappingId)/simulate" -Body @{ payloadJson = $v2Payload }
if ($validSimulation.errorCount -gt 0) { throw "Valid v2 simulation returned errors." }
Write-Pass "Valid simulation passed"

$invalidSimulation = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($state.mappingId)/simulate" -Body @{ payloadJson = $invalidPayload }
if ($invalidSimulation.errorCount -lt 1) { throw "Invalid v2 simulation did not produce an error result." }
Write-Pass "Invalid simulation produced DLQ/error result"

Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($state.mappingId)/submit-review" -Body @{
  reason = "Flowplane live demo v1.1.0 schema change is validated and ready for review."
  changeTicket = "DEMO-$($metadata.runId)"
} | Out-Null
$approval = Get-ApprovalForMapping -MappingId $state.mappingId
Invoke-FlowplaneApi -Method Post -Path "/api/v1/approvals/$($approval.id)/approve" -Body @{
  reason = "Versioned mapping change approved for runtime replay and schema gates."
  changeTicket = "DEMO-$($metadata.runId)"
} | Out-Null
Invoke-FlowplaneApi -Method Post -Path "/api/v1/approvals/$($approval.id)/qa-pass" -Body @{
  reason = "Valid and invalid v1.1.0 simulations passed the recorded QA gate."
  changeTicket = "DEMO-$($metadata.runId)"
} | Out-Null
Write-Pass "Mapping approved"

$published = Invoke-FlowplaneApi -Method Post -Path "/api/v1/mappings/$($state.mappingId)/publish" -Body @{
  reason = "Publish the QA-approved v1.1.0 candidate for replay and schema validation."
  changeTicket = "DEMO-$($metadata.runId)"
}
$artifact = Get-LatestArtifact -MappingId $state.mappingId
if ($artifact.hash -eq $state.v1ArtifactHash) { throw "v2 artifact hash matched v1 artifact hash." }
Write-Pass "Mapping published: $($artifact.versionName)"
Write-Pass "New artifact hash generated: $($artifact.hash)"
Write-Pass "Artifact hash differs from v1"

$diff = @{
  addedFields = @("customerRiskBand", "mappingSchemaVersion", "runtimeMetadataField")
  v1ArtifactHash = $state.v1ArtifactHash
  v2ArtifactHash = $artifact.hash
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "mapping-v1-v2-diff.json") -Value $diff

$state | Add-Member -NotePropertyName v2ArtifactId -NotePropertyValue $artifact.id -Force
$state | Add-Member -NotePropertyName v2ArtifactHash -NotePropertyValue $artifact.hash -Force
$state | Add-Member -NotePropertyName v2Version -NotePropertyValue $artifact.versionName -Force
Save-DemoState $state

$report = [ordered]@{
  metadata = $metadata
  status = "PASS"
  mapping = $published
  artifact = $artifact
  validation = $validation
  validSimulation = $validSimulation
  invalidSimulation = $invalidSimulation
  diff = $diff
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "mapping-v2-create-publish-report.json") -Value $report
Write-MarkdownSummary -Path (Join-Path $script:FLOWPLANE_DEMO_ROOT "mapping-v2-summary.md") -Title "Flowplane Mapping v2 Summary" -Lines @(
  "- Published version: $($artifact.versionName)",
  "- v1 artifact hash: $($state.v1ArtifactHash)",
  "- v2 artifact hash: $($artifact.hash)",
  "- Added visible fields: customerRiskBand, mappingSchemaVersion, runtimeMetadataField",
  "- Evidence: raw/mapping-v2-create-publish-report.json"
)
exit 0
