param([switch]$PostRun)

. "$PSScriptRoot\FlowplaneDemo.Common.ps1"

$ErrorActionPreference = "Stop"
$metadata = Get-DemoMetadata
$state = Read-DemoState
$failures = [Collections.Generic.List[string]]::new()
$producerCalls = [Collections.Generic.List[object]]::new()

$operationScripts = @(
  "02-create-approve-publish-mapping-v1.ps1",
  "03-apply-connect-ui-registration.ps1",
  "03-register-flink-job.ps1",
  "03-verify-idle-runtimes.ps1",
  "04-deploy-v1-to-runtimes.ps1",
  "05-produce-and-verify-v1.ps1",
  "06-create-approve-publish-mapping-v2.ps1",
  "07-deploy-v2-to-runtimes.ps1",
  "08-produce-and-verify-v2.ps1",
  "09-generate-demo-evidence-report.ps1",
  "record-connect-flink-live-demo.mjs"
)

$forbiddenDownstreamWritePatterns = @(
  '(?i)\binsertOne\s*\(',
  '(?i)\binsertMany\s*\(',
  '(?i)\bbulkWrite\s*\(',
  '(?i)\bmongoimport\b',
  '(?i)kafka-console-producer'
)

foreach ($name in $operationScripts) {
  $path = Join-Path $PSScriptRoot $name
  if (-not (Test-Path -LiteralPath $path)) {
    $failures.Add("Missing recording operation script: $name")
    continue
  }
  $content = Get-Content -LiteralPath $path -Raw
  foreach ($pattern in $forbiddenDownstreamWritePatterns) {
    if ($content -match $pattern) {
      $failures.Add("Forbidden direct downstream write primitive found in ${name}: $pattern")
    }
  }
  foreach ($match in [regex]::Matches($content, 'Write-FlowplaneKafkaRecords\s+-Topic\s+(?<topic>[^\s]+)')) {
    $topicExpression = $match.Groups['topic'].Value
    $allowed = ($name -eq '05-produce-and-verify-v1.ps1' -and $topicExpression -eq '$rawTopic') -or
      ($name -eq '08-produce-and-verify-v2.ps1' -and $topicExpression -eq '$state.rawTopic')
    $producerCalls.Add([ordered]@{ script = $name; topicExpression = $topicExpression; allowed = $allowed })
    if (-not $allowed) {
      $failures.Add("Kafka producer call in $name is not the approved raw-topic producer: $topicExpression")
    }
  }
}

if ($producerCalls.Count -ne 2) {
  $failures.Add("Expected exactly two raw producer call sites, found $($producerCalls.Count).")
}

$postRunChecks = [ordered]@{ requested = [bool]$PostRun; completed = $false }
if ($PostRun) {
  foreach ($version in @('v1', 'v2')) {
    $reportPath = Join-Path $script:FLOWPLANE_DEMO_RAW "$version-output-report.json"
    if (-not (Test-Path -LiteralPath $reportPath)) {
      $failures.Add("Missing $version runtime output report.")
      continue
    }
    $report = Read-Json $reportPath
    $boundary = @($report.kafkaTopicEvidence.producerWriteBoundary)
    if ($boundary.Count -ne 1 -or $boundary[0] -ne $state.rawTopic) {
      $failures.Add("$version producer boundary is not exactly the raw topic.")
    }
    $flink = @($report.runtimeDownstreams | Where-Object downstreamKind -eq 'kafka' | Select-Object -First 1)
    $connect = @($report.runtimeDownstreams | Where-Object downstreamKind -eq 'mongo' | Select-Object -First 1)
    if ($flink.Count -ne 1 -or $flink[0].outputSource -notmatch 'runtime-written') {
      $failures.Add("$version Flink output is not identified as runtime-written.")
    }
    if ($connect.Count -ne 1 -or $connect[0].outputSource -notmatch 'runtime-written') {
      $failures.Add("$version Mongo output is not identified as runtime-written.")
    }
    if ([int]$flink[0].outputRecordCount -ne 1 -or [int]$flink[0].dlqRecordCount -ne 1) {
      $failures.Add("$version Flink runtime evidence is not exactly one output and one DLQ record.")
    }
    if ([int]$connect[0].mongoDocumentCount -ne 1 -or [int]$connect[0].dlqRecordCount -ne 1) {
      $failures.Add("$version Connect runtime evidence is not exactly one Mongo document and one DLQ record.")
    }
  }
  $postRunChecks.completed = $true
}

$report = [ordered]@{
  metadata = $metadata
  status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
  policy = 'Demo scripts may write raw Kafka input only. Flink and Connect own transformed, DLQ, and Mongo writes.'
  rawTopic = $state.rawTopic
  producerCalls = $producerCalls
  forbiddenPrimitives = $forbiddenDownstreamWritePatterns
  postRunChecks = $postRunChecks
  failures = $failures
}
Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW 'runtime-write-boundary-report.json') -Value $report

if ($failures.Count -gt 0) {
  throw "Runtime write-boundary guard failed: $($failures -join '; ')"
}
Write-Pass "Runtime write boundary verified: raw producer only; no scripted downstream or Mongo inserts"
