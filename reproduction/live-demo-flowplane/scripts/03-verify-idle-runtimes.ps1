. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$ErrorActionPreference = "Stop"
$targets = @(Get-FlowplaneDemoRuntimeTargets)
if ($targets.Count -ne 2) { throw "The live demo must contain exactly the Kafka Connect connector and Flink job runtimes." }
$profiles = @()
$runtimeStates = @()
foreach ($target in $targets) {
  $profile = $null
  $runtime = $null
  $instances = $null
  $deadline = (Get-Date).AddSeconds(90)
  do {
    try {
      $profile = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtime-registrations/$($target.runtimeId)"
      $runtime = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes/$($target.runtimeId)"
      $instances = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes/$($target.runtimeId)/instances?page=0&size=25"
      $expectedKind = if ($target.startupKind -eq "kafka-connect") { "CONNECT_TASK" } else { "FLINK_SUBTASK" }
      $expectedOnline = if ($target.startupKind -eq "kafka-connect") { 2 } else { 1 }
      $onlineInstances = @($instances.instances | Where-Object { $_.online -and $_.instanceKind -eq $expectedKind })
      if ($runtime.health -eq "HEALTHY" -and
          $runtime.lifecycleState -eq "IDLE" -and
          -not $runtime.activeArtifactId -and
          -not $runtime.expectedArtifactId -and
          $onlineInstances.Count -eq $expectedOnline) {
        break
      }
    } catch {}
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  if ($runtime.health -ne "HEALTHY" -or $runtime.lifecycleState -ne "IDLE" -or $runtime.activeArtifactId -or $runtime.expectedArtifactId) {
    throw "$($target.name) is not healthy and IDLE with zero assignments."
  }
  if ($onlineInstances.Count -ne $expectedOnline) {
    throw "$($target.name) did not report exactly $expectedOnline online $expectedKind instance(s)."
  }
  $profiles += $profile
  $runtimeStates += $runtime
}

$state = Read-DemoState
$state | Add-Member -NotePropertyName runtimeIds -NotePropertyValue @($targets.runtimeId) -Force
$state | Add-Member -NotePropertyName runtimeTargets -NotePropertyValue $targets -Force
Save-DemoState $state

$report = [ordered]@{
  metadata = Get-DemoMetadata
  status = "PASS"
  runtimeCount = $targets.Count
  runtimeSemantics = @{
    KAFKA_CONNECT_SMT = "Individual Kafka Connect connector"
    FLINK = "Individual Flink job"
  }
  profiles = $profiles
  runtimes = $runtimeStates
  assignmentCount = 0
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "runtime-registration-report.json") -Value $report
Write-Pass "Exactly one Kafka Connect connector and one Flink job are registered and IDLE"
exit 0
