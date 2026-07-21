param(
  [Parameter(Mandatory)][string]$ProfileJson
)

. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$ErrorActionPreference = "Stop"
$secret = $env:FLOWPLANE_CONNECT_RUNTIME_CLIENT_SECRET
if ([string]::IsNullOrWhiteSpace($secret)) { throw "FLOWPLANE_CONNECT_RUNTIME_CLIENT_SECRET is required." }
if (-not (Test-Path -LiteralPath $ProfileJson)) { throw "UI-issued runtime profile was not found: $ProfileJson" }

$profile = Read-Json $ProfileJson
$target = Get-FlowplaneDemoRuntimeTargets | Where-Object { $_.startupKind -eq "kafka-connect" } | Select-Object -First 1
if (-not $target) { throw "Kafka Connect demo target is not configured." }
if ($profile.runtimeId -ne $target.runtimeId -or $profile.runtimeType -ne "KAFKA_CONNECT_SMT") {
  throw "The UI-issued profile does not match the expected Kafka Connect connector runtime."
}

Write-Host "[RUN] Applying the UI-issued profile to connector $($target.connectorName)"
Write-Host "[RUN] Target worker: flowplane-connect; source topic: $($target.inputTopic)"

$state = Read-DemoState
$rawTopic = if ($state.rawTopic) { $state.rawTopic } else { $target.inputTopic }
$config = [ordered]@{
  "connector.class" = "com.mongodb.kafka.connect.MongoSinkConnector"
  "tasks.max" = "2"
  "topics" = $rawTopic
  "connection.uri" = "mongodb://mongo:27017"
  "database" = $target.mongoDatabase
  "collection" = $target.mongoCollection
  "key.converter" = "org.apache.kafka.connect.storage.StringConverter"
  "value.converter" = "org.apache.kafka.connect.json.JsonConverter"
  "value.converter.schemas.enable" = "false"
  "errors.tolerance" = "all"
  "errors.log.enable" = "true"
  "errors.log.include.messages" = "true"
  "consumer.override.auto.offset.reset" = "earliest"
  "transforms.flowplane.flowplane.connect.output.mode" = "SCHEMALESS_MAP"
  "transforms.flowplane.flowplane.fail.on.error" = "false"
  "transforms.flowplane.flowplane.schema-check.enabled" = "false"
}

foreach ($property in $profile.generatedConfig.connectorConfig.psobject.Properties) {
  $value = [string]$property.Value
  if ($value -eq '${FLOWPLANE_RUNTIME_CLIENT_SECRET}') { $value = $secret }
  if ($value -like '${FLOWPLANE_*}') { continue }
  $config[$property.Name] = $value
}

$configured = Invoke-FlowplaneConnect -Method Put -Path "/connectors/$([uri]::EscapeDataString($target.connectorName))/config" -Body $config
Write-Pass "Kafka Connect accepted the connector configuration"
Write-Host "[WAIT] Waiting for connector, task, and Flowplane runtime health"
$deadline = (Get-Date).AddSeconds(90)
$connectorStatus = $null
$runtime = $null
$runtimeInstances = $null
do {
  try { $connectorStatus = Invoke-FlowplaneConnect -Method Get -Path "/connectors/$([uri]::EscapeDataString($target.connectorName))/status" } catch {}
  try { $runtime = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes/$($target.runtimeId)" } catch {}
  try { $runtimeInstances = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes/$($target.runtimeId)/instances?page=0&size=25" } catch {}
  $taskStates = @($connectorStatus.tasks | ForEach-Object { $_.state })
  $onlineConnectTasks = @($runtimeInstances.instances | Where-Object { $_.online -and $_.instanceKind -eq "CONNECT_TASK" })
  if ($connectorStatus.connector.state -eq "RUNNING" -and $taskStates.Count -eq 2 -and ($taskStates | Where-Object { $_ -ne "RUNNING" }).Count -eq 0 -and $runtime.health -eq "HEALTHY" -and $runtime.lifecycleState -eq "IDLE" -and $onlineConnectTasks.Count -eq 2) {
    break
  }
  Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)

if ($connectorStatus.connector.state -ne "RUNNING") { throw "Kafka Connect connector did not reach RUNNING state." }
if (@($connectorStatus.tasks).Count -ne 2 -or @($connectorStatus.tasks | Where-Object { $_.state -ne "RUNNING" }).Count -gt 0) {
  throw "Kafka Connect connector did not reach exactly two RUNNING tasks: $($connectorStatus | ConvertTo-Json -Depth 20 -Compress)"
}
if ($runtime.health -ne "HEALTHY" -or $runtime.lifecycleState -ne "IDLE" -or $runtime.activeArtifactId) {
  throw "Kafka Connect runtime did not reach healthy IDLE with zero assignments."
}
$onlineConnectTasks = @($runtimeInstances.instances | Where-Object { $_.online -and $_.instanceKind -eq "CONNECT_TASK" })
if ($onlineConnectTasks.Count -ne 2) {
  throw "Flowplane did not discover exactly two online CONNECT_TASK instances: $($runtimeInstances | ConvertTo-Json -Depth 20 -Compress)"
}

$runtimeIds = @($state.runtimeIds)
if ($runtimeIds -notcontains $target.runtimeId) { $runtimeIds += $target.runtimeId }
$state | Add-Member -NotePropertyName runtimeIds -NotePropertyValue $runtimeIds -Force
$state | Add-Member -NotePropertyName runtimeTargets -NotePropertyValue (Get-FlowplaneDemoRuntimeTargets) -Force
Save-DemoState $state

$redactedConfig = [ordered]@{}
foreach ($entry in $config.GetEnumerator()) {
  $redactedConfig[$entry.Key] = if ($entry.Key -match '(?i)secret|password|jaas|credential') { "***REDACTED***" } else { $entry.Value }
}
$configText = $redactedConfig | ConvertTo-Json -Depth 20 -Compress
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
  $configHash = ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($configText))) -replace '-', '').ToLowerInvariant()
} finally {
  $sha256.Dispose()
}
$report = [ordered]@{
  metadata = Get-DemoMetadata
  status = "PASS"
  source = "UI-issued runtime profile plus its one-time secret"
  runtimeId = $target.runtimeId
  connectorName = $target.connectorName
  expectedTaskCount = 2
  runningTaskCount = @($connectorStatus.tasks | Where-Object { $_.state -eq "RUNNING" }).Count
  connectorStatus = $connectorStatus
  runtime = $runtime
  runtimeInstances = $runtimeInstances
  generatedConnectorPropertyCount = @($profile.generatedConfig.connectorConfig.psobject.Properties).Count
  redactedConfigSha256 = $configHash
  downstream = "$($target.mongoDatabase).$($target.mongoCollection)"
  assignmentCount = 0
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "connect-ui-registration-report.json") -Value $report
Write-Pass "UI-issued Kafka Connect connector is registered, healthy, and IDLE"
exit 0
