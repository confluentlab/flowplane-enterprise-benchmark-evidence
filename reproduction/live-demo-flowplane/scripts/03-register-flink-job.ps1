. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$ErrorActionPreference = "Stop"
$state = Read-DemoState
$target = Get-FlowplaneDemoRuntimeTargets | Where-Object { $_.startupKind -eq "flink" } | Select-Object -First 1
if (-not $target) { throw "Flink demo target is not configured." }
$flinkJar = Join-Path $script:FLOWPLANE_ROOT "flowplane-java-sdk\flowplane-flink-runtime\target\flowplane-flink-runtime-job.jar"
if (-not (Test-Path -LiteralPath $flinkJar)) { throw "Flink runtime JAR is missing: $flinkJar" }
$jobName = "flowplane-flink-kafka-e2e"
$consumerGroup = "$($target.runtimeId)-consumer"
$instanceId = "$($target.runtimeId)/primary"

$jobsBeforeJson = (& docker exec flowplane-flink-jobmanager curl -fsS "http://localhost:8081/jobs/overview") -join ""
if ($LASTEXITCODE -ne 0) { throw "Flink JobManager was unavailable before submission." }
$jobsBefore = @((ConvertFrom-Json $jobsBeforeJson).jobs)
if ($jobsBefore.Count -ne 0) {
  throw "Flink registration requires a clean JobManager with zero visible jobs; found $($jobsBefore.Count). Run 01-reset-demo-state.ps1 first."
}

$issue = Invoke-FlowplaneApi -Method Post -Path "/api/v1/runtime-registrations" -Body @{
  runtimeId = $target.runtimeId
  name = $target.name
  type = "FLINK"
  environment = "PRODUCTION"
  ownerTeam = "Platform Streaming"
  projectId = "Flowplane-live-demo"
  deploymentTarget = "DOCKER"
  networkProfile = "local-quality-stack"
  controlPlaneUrl = "http://flowplane-backend:8080"
  kafkaBootstrapServers = "kafka:9092"
  schemaRegistryUrl = "http://schema-registry:8081"
  inputTopic = $target.inputTopic
  outputTopic = $target.outputTopic
  errorTopic = $target.dlqTopic
  dockerNetwork = "flowplane-quality-stack_default"
  serviceName = "flowplane-live-demo-flink-job"
  containerImage = "flink:1.20.2-scala_2.12-java17"
  outputShape = "FLAT_OBJECT"
  outputComplexTypes = "NATIVE_JSON"
  outputFieldNaming = "AS_IS"
  replayEnabled = $false
  assignmentPollIntervalMs = 2000
  heartbeatIntervalMs = 5000
  wrapperVersion = "1.0.0"
  coreEngineVersion = "1.0.0"
  supportedDslVersions = @("flowplane/v1")
  supportedFeatures = @("stateless", "error-policy/v1", "schema-check/kafka")
  labels = @{ demo = "connect-flink-live"; workload = "orders-enrichment" }
}
if ([string]::IsNullOrWhiteSpace([string]$issue.clientSecret)) { throw "Flink registration did not issue a one-time secret." }

$submitContainer = $target.containerName
$existing = @(& docker ps -a --filter "name=^/$submitContainer$" --format "{{.Names}}")
if ($existing -contains $submitContainer) { & docker rm -f $submitContainer | Out-Null }

$arguments = @(
  "run", "--rm",
  "--name", $submitContainer,
  "--network", "flowplane-quality-stack_default",
  "-v", "${flinkJar}:/opt/flowplane/flowplane-flink-runtime-job.jar:ro",
  "flink:1.20.2-scala_2.12-java17",
  "flink", "run", "-d",
  "-m", "flowplane-flink-jobmanager:8081",
  "-p", "1",
  "-c", "com.flowplane.flink.FlowPlaneKafkaFlinkJob",
  "/opt/flowplane/flowplane-flink-runtime-job.jar",
  "--bootstrap.servers=kafka:9092",
  "--input.topic=$($target.inputTopic)",
  "--output.topic=$($target.outputTopic)",
  "--error.topic=$($target.dlqTopic)",
  "--group.id=$consumerGroup",
  "--control-plane.url=http://flowplane-backend:8080",
  "--runtime.id=$($target.runtimeId)",
  "--runtime.deployment.id=$($target.runtimeId)",
  "--runtime.instance.id=$instanceId",
  "--runtime.name=$($target.name)",
  "--runtime.environment=PRODUCTION",
  "--runtime.owner.team=Platform Streaming",
  "--runtime.project.id=Flowplane-live-demo",
  "--tenant.id=$script:FLOWPLANE_TENANT_ID",
  "--runtime.client.secret=$($issue.clientSecret)",
  "--schema-registry.url=http://schema-registry:8081",
  "--schema-check.enabled=true",
  "--schema-check.poll.interval.ms=2000",
  "--assignment.poll.interval.ms=2000",
  "--fail.on.error=false",
  "--output.shape=FLAT_OBJECT",
  "--output.complex.types=NATIVE_JSON",
  "--output.field.naming=AS_IS",
  "--kafka.output.mode=JSON_STRING",
  "--auto.offset.reset=earliest"
)
$submitOutput = @(& docker @arguments)
if ($LASTEXITCODE -ne 0) { throw "Submitting the registered Flink job failed." }

$deadline = (Get-Date).AddSeconds(120)
$runtime = $null
do {
  try { $runtime = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes/$($target.runtimeId)" } catch {}
  if ($runtime.health -eq "HEALTHY" -and $runtime.lifecycleState -eq "IDLE" -and -not $runtime.activeArtifactId) { break }
  Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
if ($runtime.health -ne "HEALTHY" -or $runtime.lifecycleState -ne "IDLE" -or $runtime.activeArtifactId) {
  throw "Flink job did not reach healthy IDLE with zero assignments: $($runtime | ConvertTo-Json -Depth 20 -Compress)"
}

$jobsAfterJson = (& docker exec flowplane-flink-jobmanager curl -fsS "http://localhost:8081/jobs/overview") -join ""
if ($LASTEXITCODE -ne 0) { throw "Flink JobManager was unavailable after submission." }
$jobsAfter = @((ConvertFrom-Json $jobsAfterJson).jobs)
$activeJobs = @($jobsAfter | Where-Object { $_.name -eq $jobName -and $_.state -in @("CREATED", "RUNNING", "RESTARTING", "FAILING", "CANCELLING") })
if ($jobsAfter.Count -ne 1 -or $activeJobs.Count -ne 1 -or [int]$activeJobs[0].tasks.total -ne 1) {
  throw "Expected exactly one visible Flink job with one parallel task: $($jobsAfter | ConvertTo-Json -Depth 20 -Compress)"
}
$executionInstances = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes/$($target.runtimeId)/instances?page=0&size=25"
if ([int]$executionInstances.totalInstances -ne 1 -or [int]$executionInstances.onlineInstances -ne 1 -or $executionInstances.instances[0].instanceId -ne $instanceId) {
  throw "Expected exactly one online Flink execution instance: $($executionInstances | ConvertTo-Json -Depth 20 -Compress)"
}

$runtimeIds = @($state.runtimeIds)
if ($runtimeIds -notcontains $target.runtimeId) { $runtimeIds += $target.runtimeId }
$state | Add-Member -NotePropertyName runtimeIds -NotePropertyValue $runtimeIds -Force
$state | Add-Member -NotePropertyName runtimeTargets -NotePropertyValue (Get-FlowplaneDemoRuntimeTargets) -Force
Save-DemoState $state

$report = [ordered]@{
  metadata = Get-DemoMetadata
  status = "PASS"
  runtimeId = $target.runtimeId
  jobName = $target.name
  flinkJobName = $jobName
  visibleJobCount = $jobsAfter.Count
  activeJobCount = $activeJobs.Count
  parallelism = 1
  consumerGroup = $consumerGroup
  instanceId = $instanceId
  executionInstanceCount = $executionInstances.totalInstances
  onlineExecutionInstanceCount = $executionInstances.onlineInstances
  submitOutput = $submitOutput
  runtime = $runtime
  schemaCheckEnabled = $true
  schemaRegistryUrl = "http://schema-registry:8081"
  assignmentCount = 0
  credentialHandling = "One-time secret passed only to the Flink submission process and omitted from evidence."
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "flink-registration-report.json") -Value $report
Write-Pass "Flink job is registered, healthy, schema-check capable, and IDLE"
exit 0
