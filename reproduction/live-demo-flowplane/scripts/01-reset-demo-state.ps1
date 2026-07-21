. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$metadata = Get-DemoMetadata -IgnoreExistingState
$failures = @()
$resetDetails = $null
$kafkaResetDetails = @()
$runtimeProfiles = @()
$remainingMappings = @()
$stoppedRuntimeContainers = @()
$removedConnectors = @()
$remainingConnectors = @()
$mongoSinkReset = $null
$cancelledFlinkJobs = @()
$revokedRuntimeIds = @()
$flinkClusterReset = $null

try {
  $existingRuntimes = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes?page=0&size=1000"
  foreach ($runtime in @($existingRuntimes.items)) {
    if ([string]::IsNullOrWhiteSpace([string]$runtime.id)) { continue }
    $escapedRuntimeId = [Uri]::EscapeDataString([string]$runtime.id)
    Invoke-FlowplaneApi -Method Post -Path "/api/v1/auth/revocations/runtimes/$escapedRuntimeId" -Body @{
      reason = "Local demo clean-state reset"
    } | Out-Null
    $revokedRuntimeIds += [string]$runtime.id
  }
  Write-Pass "Existing runtime access tokens revoked"
} catch {
  $failures += "Runtime token revocation failed: $($_.Exception.Message)"
  Write-Fail "Existing runtime access tokens revoked"
}

try {
  $overviewJson = (& docker exec flowplane-flink-jobmanager curl -fsS "http://localhost:8081/jobs/overview") -join ""
  if ($LASTEXITCODE -ne 0) { throw "Flink REST job listing failed with exit code $LASTEXITCODE." }
  $runningJobs = @((ConvertFrom-Json $overviewJson).jobs | Where-Object {
    $_.name -eq "flowplane-flink-kafka-e2e" -and $_.state -in @("CREATED", "RUNNING", "RESTARTING", "FAILING", "CANCELLING")
  })
  foreach ($job in $runningJobs) {
    & docker exec flowplane-flink-jobmanager flink cancel ([string]$job.jid) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to cancel Flink job $($job.jid)." }
    $cancelledFlinkJobs += [string]$job.jid
  }
  $deadline = (Get-Date).AddSeconds(45)
  do {
    $remainingJson = (& docker exec flowplane-flink-jobmanager curl -fsS "http://localhost:8081/jobs/overview") -join ""
    if ($LASTEXITCODE -ne 0) { throw "Flink REST verification failed with exit code $LASTEXITCODE." }
    $remainingDemoJobs = @((ConvertFrom-Json $remainingJson).jobs | Where-Object {
      $_.name -eq "flowplane-flink-kafka-e2e" -and $_.state -in @("CREATED", "RUNNING", "RESTARTING", "FAILING", "CANCELLING")
    })
    if ($remainingDemoJobs.Count -gt 0) { Start-Sleep -Milliseconds 750 }
  } while ($remainingDemoJobs.Count -gt 0 -and (Get-Date) -lt $deadline)
  if ($remainingDemoJobs.Count -gt 0) {
    throw "Flink cleanup timed out with active demo jobs: $(@($remainingDemoJobs.jid) -join ', ')"
  }
  if ($cancelledFlinkJobs.Count -ne $runningJobs.Count) {
    throw "Flink cleanup count mismatch: found $($runningJobs.Count), cancelled $($cancelledFlinkJobs.Count)."
  }
  if ($runningJobs.Count -gt 0) {
    Write-Pass "Previous Flowplane Flink jobs cancelled and terminal"
  } else {
    Write-Pass "No previous Flowplane Flink jobs were active"
  }

  & docker restart flowplane-flink-jobmanager | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Restarting the Flink JobManager failed." }
  & docker restart flowplane-flink-taskmanager | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Restarting the Flink TaskManager failed." }

  $clusterDeadline = (Get-Date).AddSeconds(120)
  $jobsAfterRestart = @()
  $taskManagersAfterRestart = @()
  do {
    try {
      $jobsAfterRestartJson = (& docker exec flowplane-flink-jobmanager curl -fsS "http://localhost:8081/jobs/overview") -join ""
      $taskManagersAfterRestartJson = (& docker exec flowplane-flink-jobmanager curl -fsS "http://localhost:8081/taskmanagers") -join ""
      if ($LASTEXITCODE -eq 0) {
        $jobsAfterRestart = @((ConvertFrom-Json $jobsAfterRestartJson).jobs)
        $taskManagersAfterRestart = @((ConvertFrom-Json $taskManagersAfterRestartJson).taskmanagers)
      }
    } catch {}
    if ($jobsAfterRestart.Count -gt 0 -or $taskManagersAfterRestart.Count -ne 1) { Start-Sleep -Seconds 2 }
  } while (($jobsAfterRestart.Count -gt 0 -or $taskManagersAfterRestart.Count -ne 1) -and (Get-Date) -lt $clusterDeadline)
  if ($jobsAfterRestart.Count -ne 0 -or $taskManagersAfterRestart.Count -ne 1) {
    throw "Flink cluster did not restart cleanly: jobs=$($jobsAfterRestart.Count), taskManagers=$($taskManagersAfterRestart.Count)."
  }
  $flinkClusterReset = [ordered]@{
    status = "READY"
    visibleJobs = 0
    taskManagers = 1
    taskSlots = 2
  }
  Write-Pass "Flink history cleared with one TaskManager and zero jobs"
} catch {
  $failures += "Flink job cleanup failed: $($_.Exception.Message)"
  Write-Fail "Previous Flowplane Flink jobs cancelled"
}

try {
  $stoppedRuntimeContainers = Remove-FlowplaneDemoRuntimeContainers
  Write-Pass "Live demo runtime containers removed"
} catch {
  $failures += "Runtime container cleanup failed: $($_.Exception.Message)"
  Write-Fail "Live demo runtime containers removed"
}

try {
  $removedConnectors = Remove-FlowplaneDemoConnectors
  $connectorsResponse = Invoke-FlowplaneConnect -Method Get -Path "/connectors"
  $remainingConnectors = if ($connectorsResponse.Count -eq 0) { @() } else { @($connectorsResponse) }
  if ($remainingConnectors.Count -ne 0) {
    throw "Kafka Connect worker must be empty for the recording, but $($remainingConnectors.Count) connector(s) remain: $($remainingConnectors -join ', ')"
  }
  Write-Pass "Kafka Connect worker reset to zero connectors"
} catch {
  $failures += "Kafka Connect cleanup failed: $($_.Exception.Message)"
  Write-Fail "Live demo Kafka Connect connectors removed"
}

try {
  $mongoSinkReset = Reset-FlowplaneDemoMongoSink
  Write-Pass "Mongo downstream collection reset"
} catch {
  $failures += "Mongo downstream reset failed: $($_.Exception.Message)"
  Write-Fail "Mongo downstream collection reset"
}

try {
  $js = @"
const preservedCollections = ["teams", "users", "revoked_tokens", "session_revocations"];
const collectionsToClear = [
  "activations",
  "approval_requests",
  "artifacts",
  "audit_events",
  "dictionaries",
  "field_failures",
  "governance_policies",
  "mapping_drafts",
  "mappings",
  "release_evidence_bundles",
  "replay_requests",
  "runtime_execution_instances",
  "runtime_instances",
  "runtime_metrics",
  "runtime_registration_profiles",
  "runtime_telemetry_events",
  "schema_check_requests",
  "shadow_validation_runs",
  "simulation_runs"
];
const counts = {};
for (const name of collectionsToClear) {
  counts[name] = db.getCollection(name).deleteMany({}).deletedCount;
}
const preservedCounts = {};
for (const name of preservedCollections) {
  preservedCounts[name] = db.getCollection(name).countDocuments({});
}
print(JSON.stringify({ mode: "LOCAL_CONTROL_PLANE_FULL_RESET", preservedCollections, preservedCounts, counts }));
"@
  $resetScriptPath = Join-Path ([IO.Path]::GetTempPath()) "flowplane-demo-reset-$([Guid]::NewGuid().ToString('N')).js"
  $containerResetScriptPath = "/tmp/$(Split-Path -Leaf $resetScriptPath)"
  Set-Content -LiteralPath $resetScriptPath -Value $js -Encoding UTF8
  try {
    & docker cp $resetScriptPath "flowplane-mongo:$containerResetScriptPath" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "docker cp to flowplane-mongo failed with exit code $LASTEXITCODE"
    }
    $mongoOutput = & docker exec flowplane-mongo mongosh --quiet flowplane_control_plane $containerResetScriptPath
    if ($LASTEXITCODE -ne 0) {
      throw "mongosh reset failed with exit code $LASTEXITCODE"
    }
  } finally {
    Remove-Item -LiteralPath $resetScriptPath -Force -ErrorAction SilentlyContinue
    try { docker exec flowplane-mongo rm -f $containerResetScriptPath | Out-Null } catch {}
  }
  $resetDetails = $mongoOutput | Select-Object -Last 1 | ConvertFrom-Json
  Write-Pass "Local control-plane operational collections cleared"
} catch {
  $failures += "Mapping reset failed: $($_.Exception.Message)"
  Write-Fail "Local control-plane operational collections cleared"
}

$demoTopics = Get-FlowplaneDemoKafkaTopics
try {
  $kafkaResetDetails = Reset-FlowplaneKafkaTopics -Topics $demoTopics
  Write-Pass "Source, downstream, and DLQ topics reset"
} catch {
  $failures += "Kafka topic reset failed: $($_.Exception.Message)"
  Write-Fail "Source, downstream, and DLQ topics reset"
}

try {
  $mappings = Invoke-FlowplaneApi -Method Get -Path "/api/v1/mappings?page=0&size=1000"
  $remainingMappings = @($mappings.items)
  if ($remainingMappings.Count -gt 0) {
    throw "Control plane still has $($remainingMappings.Count) mapping(s)."
  }
  $profiles = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtime-registrations?environment=PRODUCTION&page=0&size=100"
  $runtimeProfiles = @($profiles.items)
  if ($runtimeProfiles.Count -gt 0) {
    throw "Control plane still has $($runtimeProfiles.Count) runtime profile(s)."
  }
  Write-Pass "Runtime registry inspected"
} catch {
  $failures += "Runtime registry inspection failed: $($_.Exception.Message)"
  Write-Fail "Runtime registry inspected"
}

Remove-Item -LiteralPath $script:FLOWPLANE_DEMO_RAW -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $script:FLOWPLANE_DEMO_RAW | Out-Null
Write-Pass "Demo evidence directory initialized"

$state = [ordered]@{
  runId = $metadata.runId
  tenantId = $metadata.tenantId
  mappingName = "$($script:FLOWPLANE_DEMO_NAME)-$($metadata.runId)"
  topicPrefix = "flowplane.demo"
  rawTopic = "flowplane.demo.orders.raw"
  transformedTopic = "flowplane.demo.orders.flink.transformed"
  dlqTopic = "flowplane.demo.orders.flink.dlq"
  runtimeTargets = Get-FlowplaneDemoRuntimeTargets
}
Save-DemoState $state

$report = [ordered]@{
  metadata = $metadata
  status = if ($failures.Count -eq 0) { "PASS" } else { "FAIL" }
  localStackHardReset = $resetDetails
  kafkaTopicReset = $kafkaResetDetails
  stoppedRuntimeContainers = $stoppedRuntimeContainers
  cancelledFlinkJobs = $cancelledFlinkJobs
  flinkClusterReset = $flinkClusterReset
  revokedRuntimeIds = $revokedRuntimeIds
  removedConnectors = $removedConnectors
  remainingConnectors = $remainingConnectors
  mongoSinkReset = $mongoSinkReset
  existingDemoRuntimeProfiles = $runtimeProfiles
  caveats = @("The reset clears Flowplane operational Mongo collections while preserving teams, users, and authentication revocation state. Kafka, Schema Registry, and the base Flink/Connect infrastructure remain available.")
  failures = $failures
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "reset-state-report.json") -Value $report
Write-MarkdownSummary -Path (Join-Path $script:FLOWPLANE_DEMO_ROOT "reset-state-summary.md") -Title "Flowplane Demo Reset Summary" -Lines @(
  "- Status: $($report.status)",
  "- Reset mode: $($resetDetails.mode)",
  "- Deleted mappings: $($resetDetails.counts.mappings)",
  "- Deleted runtime profiles: $($resetDetails.counts.runtime_registration_profiles)",
  "- Preserved teams: $($resetDetails.preservedCounts.teams)",
  "- Preserved users: $($resetDetails.preservedCounts.users)",
  "- Preserved token/session security state: $($resetDetails.preservedCounts.revoked_tokens)/$($resetDetails.preservedCounts.session_revocations)",
  "- Remaining mappings: $(@($remainingMappings).Count)",
  "- Remaining runtime profiles: $(@($runtimeProfiles).Count)",
  "- Kafka topics reset: $(@($kafkaResetDetails).Count)",
  "- Runtime containers removed: $(@($stoppedRuntimeContainers).Count)",
  "- Previous Flink jobs cancelled: $(@($cancelledFlinkJobs).Count)",
  "- Flink cluster after restart: $($flinkClusterReset.visibleJobs) visible jobs, $($flinkClusterReset.taskManagers) TaskManager",
  "- Runtime identities revoked before reset: $(@($revokedRuntimeIds).Count)",
  "- Kafka Connect connectors removed: $(@($removedConnectors).Count)",
  "- Kafka Connect connectors remaining: $(@($remainingConnectors).Count)",
  "- Mongo sink collection: $($mongoSinkReset.database).$($mongoSinkReset.collection)",
  "- Evidence: raw/reset-state-report.json"
)

Write-Pass "Demo state reset"
Write-Pass "Demo evidence directory initialized"
if ($failures.Count -gt 0) { exit 1 }
exit 0
