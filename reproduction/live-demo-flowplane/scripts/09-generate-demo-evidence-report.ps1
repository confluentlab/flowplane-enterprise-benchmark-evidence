. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$metadata = Get-DemoMetadata
$state = Read-DemoState
$required = @(
  "preflight-build-report.json",
  "runtime-write-boundary-report.json",
  "reset-state-report.json",
  "connect-ui-registration-report.json",
  "flink-registration-report.json",
  "runtime-registration-report.json",
  "mapping-v1-create-publish-report.json",
  "deploy-v1-report.json",
  "v1-output-report.json",
  "v1-runtime-downstream-evidence.json",
  "mapping-v2-create-publish-report.json",
  "mapping-v1-v2-diff.json",
  "v2-runtime-gates-report.json",
  "deploy-v2-report.json",
  "v2-output-report.json",
  "v2-runtime-downstream-evidence.json",
  "v1-v2-output-diff.json"
)

$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:FLOWPLANE_DEMO_RAW $_)) })
$failures = @()
$targets = @(Get-FlowplaneDemoRuntimeTargets)
if ($targets.Count -ne 2) { $failures += "Runtime target definition is not exactly one connector and one Flink job." }

$mappings = Invoke-FlowplaneApi -Method Get -Path "/api/v1/mappings?page=0&size=1000"
$demoMappings = @(@($mappings.items) | Where-Object { $_.name -eq $state.mappingName })
if ($demoMappings.Count -ne 1) { $failures += "Expected one demo mapping, found $($demoMappings.Count)." }

$artifactVersions = @()
if ($state.mappingId) {
  $artifactResponse = Invoke-FlowplaneApi -Method Get -Path "/api/v1/mappings/$($state.mappingId)/artifacts"
  $artifacts = if ($artifactResponse.items) { @($artifactResponse.items) } else { @($artifactResponse) }
  $artifactVersions = @($artifacts | ForEach-Object versionName)
}
foreach ($expected in @("v1.0.0", "v1.1.0")) {
  if ($artifactVersions -notcontains $expected) { $failures += "Missing mapping artifact $expected." }
}
if (-not $state.v1ArtifactHash -or -not $state.v2ArtifactHash -or $state.v1ArtifactHash -eq $state.v2ArtifactHash) {
  $failures += "The v1 and v2 artifact hashes are missing or identical."
}

$runtimeReport = if (Test-Path (Join-Path $script:FLOWPLANE_DEMO_RAW "runtime-registration-report.json")) { Read-Json (Join-Path $script:FLOWPLANE_DEMO_RAW "runtime-registration-report.json") } else { $null }
if ($runtimeReport -and ([int]$runtimeReport.runtimeCount -ne 2 -or [int]$runtimeReport.assignmentCount -ne 0)) {
  $failures += "Idle registration proof does not show two runtimes with zero assignments."
}
$v1RuntimeEvidence = if (Test-Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v1-runtime-downstream-evidence.json")) { @(Read-Json (Join-Path $script:FLOWPLANE_DEMO_RAW "v1-runtime-downstream-evidence.json")) } else { @() }
$v2RuntimeEvidence = if (Test-Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-runtime-downstream-evidence.json")) { @(Read-Json (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-runtime-downstream-evidence.json")) } else { @() }
if ($v1RuntimeEvidence.Count -ne 2) { $failures += "Expected two v1 runtime downstream proofs, found $($v1RuntimeEvidence.Count)." }
if ($v2RuntimeEvidence.Count -ne 2) { $failures += "Expected two v2 runtime downstream proofs, found $($v2RuntimeEvidence.Count)." }

$uiPath = Join-Path $script:FLOWPLANE_DEMO_ROOT "ui-verification-report.json"
$uiReport = if (Test-Path $uiPath) { Read-Json $uiPath } else { $null }
if ($uiReport -and $uiReport.status -ne "PASS") { $failures += "Browser UI verification did not pass." }

$status = if ($missing.Count -eq 0 -and $failures.Count -eq 0) { "PASS" } else { "FAIL" }
$report = [ordered]@{
  metadata = $metadata
  status = $status
  state = $state
  runtimeDefinition = [ordered]@{
    count = 2
    kafkaConnect = "individual Mongo sink connector registered live in Flowplane UI"
    flink = "individual Flink job registered by captioned background automation"
    clustersAreRuntimes = $false
  }
  registrationProof = $runtimeReport
  governanceGates = if (Test-Path (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-runtime-gates-report.json")) { Read-Json (Join-Path $script:FLOWPLANE_DEMO_RAW "v2-runtime-gates-report.json") } else { $null }
  oneMappingProof = [ordered]@{
    matchingMappingCount = $demoMappings.Count
    mappingId = $state.mappingId
    artifactVersions = $artifactVersions
    hashesDiffer = ($state.v1ArtifactHash -ne $state.v2ArtifactHash)
  }
  downstreamProof = [ordered]@{ v1 = $v1RuntimeEvidence; v2 = $v2RuntimeEvidence }
  producerBoundary = "Raw Kafka topic only; no demo script writes a transformed, DLQ, or Mongo downstream."
  requiredEvidence = $required
  missingEvidence = $missing
  validationFailures = $failures
  uiVerification = $uiReport
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_ROOT "live-demo-report.json") -Value $report

Write-MarkdownSummary -Path (Join-Path $script:FLOWPLANE_DEMO_ROOT "live-demo-summary.md") -Title "Flowplane Connect + Flink Live Demo" -Lines @(
  "- Status: $status",
  "- Run ID: $($metadata.runId)",
  "- Git commit: $($metadata.gitCommit)",
  "- Runtime scope: one Kafka Connect connector + one Flink job",
  "- Connect registration: live UI",
  "- Flink registration: captioned background step",
  "- Idle proof before assignment: $($runtimeReport.status)",
  "- Connect candidate replay + Flink schema check: raw/v2-runtime-gates-report.json",
  "- Producer boundary: raw topic only",
  "- Missing evidence: $($missing.Count)",
  "- Validation failures: $($failures.Count)"
)

if ($status -ne "PASS") {
  Write-Fail "Evidence report failed: missing=$($missing -join ', '); validation=$($failures -join '; ')"
  exit 1
}
Write-Pass "Final Connect + Flink evidence report generated"
exit 0
