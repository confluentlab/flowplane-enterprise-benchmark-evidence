. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$ErrorActionPreference = "Stop"
$metadata = Get-DemoMetadata
$requiredContainers = @(
  "flowplane-backend",
  "flowplane-ui",
  "flowplane-kafka",
  "flowplane-schema-registry",
  "flowplane-mongo",
  "flowplane-connect",
  "flowplane-control-center",
  "flowplane-flink-jobmanager",
  "flowplane-flink-taskmanager"
)

foreach ($container in $requiredContainers) {
  $running = (& docker inspect -f "{{.State.Running}}" $container 2>$null | Select-Object -Last 1)
  if ($running -ne "true") { throw "Required demo container is not running: $container" }
}
Write-Pass "Kafka, Schema Registry, MongoDB, Connect, Flink, backend, and UI are ready"

$currentPolicy = Invoke-FlowplaneApi -Method Get -Path "/api/v1/approvals/policies"
$governancePolicy = Invoke-FlowplaneApi -Method Post -Path "/api/v1/approvals/policies" -Body @{
  piiScanLock = [bool]$currentPolicy.piiScanLock
  schemaDriftLock = [string]$currentPolicy.schemaDriftLock
  heapLimitAlert = [bool]$currentPolicy.heapLimitAlert
  environmentApprovalProdOnly = [bool]$currentPolicy.environmentApprovalProdOnly
  qaRequiredForProduction = [bool]$currentPolicy.qaRequiredForProduction
  autoRollbackPolicyApproved = [bool]$currentPolicy.autoRollbackPolicyApproved
  simulationRequiredForProduction = [bool]$currentPolicy.simulationRequiredForProduction
  replayRequiredForProduction = $false
  fieldProtectionRules = @($currentPolicy.fieldProtectionRules)
  maxConcurrentActiveArtifactVersions = [int]$currentPolicy.maxConcurrentActiveArtifactVersions
  versionConvergenceWindowSeconds = [int]$currentPolicy.versionConvergenceWindowSeconds
  lifecycleDecisionReasonsRequired = [bool]$currentPolicy.lifecycleDecisionReasonsRequired
}
if ($governancePolicy.replayRequiredForProduction -ne $false) {
  throw "The demo governance policy did not accept the single-runtime replay model."
}
Write-Pass "Governance policy configured for one explicit Connect replay plus the Flink schema gate"

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:FLOWPLANE_ROOT "docker\quality-stack\prepare-connect-plugin.ps1")
if ($LASTEXITCODE -ne 0) { throw "Fresh Kafka Connect SMT and Flink runtime build failed." }

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:FLOWPLANE_ROOT "scripts\dev\deploy-connect-smt.ps1")
if ($LASTEXITCODE -ne 0) { throw "Deploying the freshly built Kafka Connect SMT failed." }
Write-Pass "Fresh Kafka Connect SMT deployed to the running Connect worker"

$connectorsResponse = Invoke-FlowplaneConnect -Method Get -Path "/connectors"
$connectorsBeforeRegistration = if ($connectorsResponse.Count -eq 0) { @() } else { @($connectorsResponse) }
if ($connectorsBeforeRegistration.Count -ne 0) {
  throw "Kafka Connect must contain zero connectors before the live UI registration, found: $($connectorsBeforeRegistration -join ', ')"
}
Write-Pass "Kafka Connect worker has zero connectors before recording"

$flinkJar = Join-Path $script:FLOWPLANE_ROOT "flowplane-java-sdk\flowplane-flink-runtime\target\flowplane-flink-runtime-job.jar"
if (-not (Test-Path -LiteralPath $flinkJar)) { throw "Fresh Flink runtime JAR was not produced: $flinkJar" }

$subject = "flowplane.demo.orders.flink.transformed-value"
$schema = [ordered]@{
  '$schema' = "https://json-schema.org/draft/2020-12/schema"
  title = "Flowplane Flink Orders Output"
  type = "object"
  required = @("demoRunId", "eventId", "orderId", "mappingSchemaVersion")
  properties = [ordered]@{
    demoRunId = @{ type = "string"; minLength = 1 }
    eventId = @{ type = "string"; pattern = "^evt-" }
    orderId = @{ type = "string" }
    mappingSchemaVersion = @{ type = "string"; enum = @("v1.0.0", "v1.1.0") }
    customerRiskBand = @{ type = @("string", "null") }
    runtimeMetadataField = @{ type = @("string", "null") }
  }
  additionalProperties = $true
} | ConvertTo-Json -Depth 20 -Compress
$registrationBody = @{ schemaType = "JSON"; schema = $schema } | ConvertTo-Json -Depth 20 -Compress
$registered = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8082/subjects/$subject/versions" -ContentType "application/vnd.schemaregistry.v1+json" -Body $registrationBody
$latest = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:8082/subjects/$subject/versions/latest"
if ($latest.subject -ne $subject -or $latest.schemaType -ne "JSON") {
  throw "Downstream Flink schema registration could not be verified."
}
Write-Pass "Flink downstream schema is registered before recording"

$pluginFiles = @(Get-ChildItem (Join-Path $script:FLOWPLANE_ROOT "flowplane-java-sdk\flowplane-kafka-connect-smt\target\connect-plugin") -File)
if ($pluginFiles.Count -eq 0) { throw "Kafka Connect plugin directory is empty after the build." }
$pluginHashes = @($pluginFiles | Sort-Object Name | ForEach-Object {
  [ordered]@{ name = $_.Name; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant(); bytes = $_.Length }
})
$flinkHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $flinkJar).Hash.ToLowerInvariant()
$report = [ordered]@{
  metadata = $metadata
  status = "PASS"
  requiredContainers = $requiredContainers
  connectWorkerBaseline = [ordered]@{ total = 0; connectors = $connectorsBeforeRegistration }
  governancePolicy = [ordered]@{
    replayRequiredForProduction = $governancePolicy.replayRequiredForProduction
    demoPromotionGates = @("Kafka Connect candidate replay", "Flink downstream schema check")
  }
  schema = [ordered]@{ subject = $latest.subject; version = $latest.version; id = $latest.id; schemaType = $latest.schemaType }
  binaries = [ordered]@{
    flink = [ordered]@{ path = $flinkJar; sha256 = $flinkHash; bytes = (Get-Item -LiteralPath $flinkJar).Length }
    connectPlugin = $pluginHashes
  }
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "preflight-build-report.json") -Value $report
Write-Pass "Preflight binaries and schema are bound to run $($metadata.runId)"
exit 0
