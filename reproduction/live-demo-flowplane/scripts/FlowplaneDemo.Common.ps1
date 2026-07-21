$ErrorActionPreference = "Stop"

function Get-FlowplaneRoot {
  if (-not [string]::IsNullOrWhiteSpace($env:FLOWPLANE_ROOT)) {
    return (Resolve-Path -LiteralPath $env:FLOWPLANE_ROOT).Path
  }
  return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$script:FLOWPLANE_ROOT = Get-FlowplaneRoot
$script:FLOWPLANE_API_BASE = if ($env:FLOWPLANE_API_BASE) { $env:FLOWPLANE_API_BASE } else { "http://127.0.0.1:8081" }
$script:FLOWPLANE_TENANT_ID = if ($env:FLOWPLANE_TENANT_ID) { $env:FLOWPLANE_TENANT_ID } else { "acme-corp" }
$script:FLOWPLANE_DEMO_NAME = "flowplane-live-demo-orders"
$script:FLOWPLANE_DEMO_PREFIX = "flowplane-live-demo"
$script:FLOWPLANE_DEMO_ROOT = Join-Path $script:FLOWPLANE_ROOT "evidence\demo\live-demo"
$script:FLOWPLANE_DEMO_RAW = Join-Path $script:FLOWPLANE_DEMO_ROOT "raw"
$script:FLOWPLANE_DEMO_RUN_ID = if ($env:FLOWPLANE_DEMO_RUN_ID) { $env:FLOWPLANE_DEMO_RUN_ID } else { "flowplane-live-demo-" + (Get-Date -Format "yyyyMMddHHmmss") }

New-Item -ItemType Directory -Force -Path $script:FLOWPLANE_DEMO_RAW | Out-Null

function Write-Pass([string]$Message) {
  Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Fail([string]$Message) {
  Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Write-Warn([string]$Message) {
  Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
  return [Convert]::ToBase64String($Bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function New-FlowplaneAccessToken {
  if ($env:FLOWPLANE_DEMO_ACCESS_TOKEN) {
    return $env:FLOWPLANE_DEMO_ACCESS_TOKEN
  }

  $secret = if ($env:FLOWPLANE_JWT_SECRET) { $env:FLOWPLANE_JWT_SECRET } else { "local-quality-stack-secret-change-before-prod" }
  $subject = if ($env:FLOWPLANE_DEMO_USER) { $env:FLOWPLANE_DEMO_USER } else { "admin@flowplane.local" }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((@{ alg = "HS256"; typ = "JWT" } | ConvertTo-Json -Compress)))
  $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes(([ordered]@{
    iss = "flowplane-control-plane"
    aud = "flowplane-control-plane-api"
    sub = $subject
    name = $subject
    tenantId = $script:FLOWPLANE_TENANT_ID
    roles = @("ADMIN", "MAPPER", "REVIEWER", "QA_TESTER", "OPERATOR", "VIEWER")
    jti = [Guid]::NewGuid().ToString()
    iat = $now
    exp = $now + (8 * 60 * 60)
  } | ConvertTo-Json -Compress)))
  $unsigned = "$header.$payload"
  $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($secret))
  $signature = ConvertTo-Base64Url ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($unsigned)))
  return "$unsigned.$signature"
}

function Invoke-FlowplaneApi {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    $Body = $null,
    [string]$Token = "",
    [hashtable]$ExtraHeaders = @{}
  )

  $headers = @{
    tenantId = $script:FLOWPLANE_TENANT_ID
  }
  if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = New-FlowplaneAccessToken
  }
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $headers.Authorization = "Bearer $Token"
  }
  foreach ($key in $ExtraHeaders.Keys) {
    $headers[$key] = $ExtraHeaders[$key]
  }

  $params = @{
    Method = $Method
    Uri = "$script:FLOWPLANE_API_BASE$Path"
    Headers = $headers
    ContentType = "application/json"
  }
  if ($null -ne $Body) {
    $params.Body = $Body | ConvertTo-Json -Depth 100 -Compress
  }
  try {
    return Invoke-RestMethod @params
  } catch {
    $responseBody = $_.ErrorDetails.Message
    if ([string]::IsNullOrWhiteSpace($responseBody) -and $null -ne $_.Exception.Response) {
      try {
        $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        $responseBody = $reader.ReadToEnd()
        $reader.Dispose()
      } catch {
        $responseBody = $null
      }
    }
    if ([string]::IsNullOrWhiteSpace($responseBody)) { throw }
    throw "Flowplane API $Method $Path failed: $responseBody"
  }
}

function Invoke-FlowplaneRuntimeToken {
  param(
    [Parameter(Mandatory)][string]$RuntimeId,
    [Parameter(Mandatory)][string]$ClientSecret
  )
  $body = @{
    tenantId = $script:FLOWPLANE_TENANT_ID
    runtimeId = $RuntimeId
    clientSecret = $ClientSecret
  }
  return Invoke-RestMethod -Method Post -Uri "$script:FLOWPLANE_API_BASE/runtime/v1/auth/token" -ContentType "application/json" -Body ($body | ConvertTo-Json -Compress)
}

function Save-Json {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-Json {
  param([Parameter(Mandatory)][string]$Path)
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-MarkdownSummary {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Title, [string[]]$Lines)
  $content = @("# $Title", "") + $Lines
  $content | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Assert-FlowplaneKafkaTopicName {
  param([Parameter(Mandatory)][string]$Topic)
  if ($Topic -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Unsafe Kafka topic name: $Topic"
  }
}

function Invoke-FlowplaneKafkaShell {
  param([Parameter(Mandatory)][string]$Command)
  $output = & docker exec flowplane-kafka sh -lc $Command 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Kafka command failed with exit code $LASTEXITCODE`: $($output -join [Environment]::NewLine)"
  }
  return $output
}

function Reset-FlowplaneKafkaTopics {
  param([Parameter(Mandatory)][string[]]$Topics)
  $results = @()
  foreach ($topic in $Topics) {
    Assert-FlowplaneKafkaTopicName -Topic $topic
    Invoke-FlowplaneKafkaShell "kafka-topics --bootstrap-server kafka:9092 --delete --if-exists --topic '$topic' >/dev/null 2>&1 || true" | Out-Null
  }
  Start-Sleep -Seconds 2
  foreach ($topic in $Topics) {
    Invoke-FlowplaneKafkaShell "kafka-topics --bootstrap-server kafka:9092 --create --if-not-exists --partitions 2 --replication-factor 1 --topic '$topic'" | Out-Null
    $results += @{ topic = $topic; status = "READY"; partitions = 2 }
  }
  return $results
}

function Write-FlowplaneKafkaRecords {
  param(
    [Parameter(Mandatory)][string]$Topic,
    [Parameter(Mandatory)][string[]]$Records
  )
  Assert-FlowplaneKafkaTopicName -Topic $Topic
  $temp = Join-Path ([IO.Path]::GetTempPath()) "flowplane-kafka-records-$([Guid]::NewGuid().ToString('N')).jsonl"
  $containerPath = "/tmp/$(Split-Path -Leaf $temp)"
  try {
    [System.IO.File]::WriteAllText($temp, ($Records -join [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    & docker cp $temp "flowplane-kafka:$containerPath" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker cp to flowplane-kafka failed with exit code $LASTEXITCODE" }
    Invoke-FlowplaneKafkaShell "cat '$containerPath' | kafka-console-producer --bootstrap-server kafka:9092 --topic '$Topic'" | Out-Null
    return @{ topic = $Topic; produced = $Records.Count; containerPath = $containerPath }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    try { Invoke-FlowplaneKafkaShell "rm -f '$containerPath'" | Out-Null } catch {}
  }
}

function Read-FlowplaneKafkaRecords {
  param(
    [Parameter(Mandatory)][string]$Topic,
    [int]$MaxMessages = 10
  )
  Assert-FlowplaneKafkaTopicName -Topic $Topic
  $command = "kafka-console-consumer --bootstrap-server kafka:9092 --topic '$Topic' --from-beginning --timeout-ms 5000 --max-messages $MaxMessages 2>/dev/null || true"
  $records = Invoke-FlowplaneKafkaShell $command
  return @($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Read-FlowplaneKafkaRecordAtOffset {
  param(
    [Parameter(Mandatory)][string]$Topic,
    [Parameter(Mandatory)][int]$Partition,
    [Parameter(Mandatory)][long]$Offset
  )
  Assert-FlowplaneKafkaTopicName -Topic $Topic
  if ($Partition -lt 0 -or $Offset -lt 0) {
    throw "Kafka source coordinates must be non-negative: $Topic partition=$Partition offset=$Offset."
  }
  $command = "kafka-console-consumer --bootstrap-server kafka:9092 --topic '$Topic' --partition $Partition --offset $Offset --timeout-ms 5000 --max-messages 1 2>/dev/null || true"
  $records = @(Invoke-FlowplaneKafkaShell $command | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($records.Count -ne 1) {
    throw "Expected exactly one Kafka record at $Topic partition=$Partition offset=$Offset, found $($records.Count)."
  }
  return ConvertFrom-FlowplaneKafkaJsonRecord -Record $records[0]
}

function Wait-FlowplaneKafkaRecords {
  param(
    [Parameter(Mandatory)][string]$Topic,
    [int]$ExpectedCount = 1,
    [int]$MaxMessages = 10,
    [int]$TimeoutSeconds = 90
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $records = @(Read-FlowplaneKafkaRecords -Topic $Topic -MaxMessages $MaxMessages)
    if ($records.Count -ge $ExpectedCount) {
      return $records
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "Timed out waiting for $ExpectedCount runtime-produced Kafka record(s) on $Topic."
}

function ConvertFrom-FlowplaneKafkaJsonRecord {
  param([Parameter(Mandatory)][string]$Record)
  $clean = $Record.TrimStart([char]0xFEFF)
  try {
    return $clean | ConvertFrom-Json
  } catch {
    throw "Runtime-produced Kafka record was not valid JSON: $clean"
  }
}

function Select-FlowplaneRuntimeDlqRecord {
  param(
    [Parameter(Mandatory)][string[]]$Records,
    [Parameter(Mandatory)][string]$Topic,
    [Parameter(Mandatory)][string]$RuntimeId,
    [string]$ArtifactHash = "",
    [string]$ArtifactVersion = "",
    [string]$RunId = ""
  )
  for ($i = $Records.Count - 1; $i -ge 0; $i--) {
    try {
      $record = ConvertFrom-FlowplaneKafkaJsonRecord -Record $Records[$i]
      if ($record.schemaVersion -eq "flowplane.runtime.error.v1" -and $record.type -eq "com.flowplane.runtime.error") {
        $artifact = $record.artifact
        if (-not $artifact -or [string]::IsNullOrWhiteSpace($artifact.mappingId) -or [string]::IsNullOrWhiteSpace($artifact.mappingName) -or [string]::IsNullOrWhiteSpace($artifact.artifactVersion)) {
          throw "Flowplane runtime DLQ envelope on $Topic for $RuntimeId is missing mapping metadata."
        }
        if ($record.runtime.id -ne $RuntimeId) { continue }
        if (-not [string]::IsNullOrWhiteSpace($ArtifactHash) -and $artifact.artifactHash -ne $ArtifactHash) { continue }
        if (-not [string]::IsNullOrWhiteSpace($ArtifactVersion) -and $artifact.artifactVersion -ne $ArtifactVersion) { continue }
        if (-not [string]::IsNullOrWhiteSpace($RunId)) {
          if (-not $record.source) { continue }
          try {
            $sourceRecord = Read-FlowplaneKafkaRecordAtOffset `
              -Topic ([string]$record.source.topic) `
              -Partition ([int]$record.source.partition) `
              -Offset ([long]$record.source.offset)
            if ($sourceRecord.run.id -ne $RunId) { continue }
          } catch {
            continue
          }
        }
        return @{ raw = $Records[$i]; parsed = $record }
      }
    } catch {
      # Keep scanning older records, then fail with the full topic/runtime context below.
    }
  }
  throw "No structured Flowplane runtime DLQ envelope with mapping metadata was found on $Topic for $RuntimeId."
}

function Confirm-FlowplaneDlqSourceProvenance {
  param(
    [Parameter(Mandatory)]$DlqRecord,
    [Parameter(Mandatory)][string]$ExpectedTopic,
    [Parameter(Mandatory)][string]$ExpectedRunId
  )
  if (-not $DlqRecord.source) { throw "Runtime DLQ envelope is missing source coordinates." }
  if ($DlqRecord.source.topic -ne $ExpectedTopic) {
    throw "Runtime DLQ source topic '$($DlqRecord.source.topic)' did not match '$ExpectedTopic'."
  }
  $sourceRecord = Read-FlowplaneKafkaRecordAtOffset `
    -Topic $ExpectedTopic `
    -Partition ([int]$DlqRecord.source.partition) `
    -Offset ([long]$DlqRecord.source.offset)
  if ($sourceRecord.run.id -ne $ExpectedRunId) {
    throw "Runtime DLQ source record did not belong to run $ExpectedRunId."
  }
  return [ordered]@{
    topic = $ExpectedTopic
    partition = [int]$DlqRecord.source.partition
    offset = [long]$DlqRecord.source.offset
    runId = [string]$sourceRecord.run.id
    schemaVersion = [string]$sourceRecord.run.schemaVersion
    verification = "exact Kafka source partition and offset"
  }
}

function Get-GitInfo {
  $branch = "unknown"
  $commit = "unknown"
  try { $branch = (git -C $script:FLOWPLANE_ROOT rev-parse --abbrev-ref HEAD).Trim() } catch {}
  try { $commit = (git -C $script:FLOWPLANE_ROOT rev-parse HEAD).Trim() } catch {}
  return @{ branch = $branch; commit = $commit }
}

function Get-DemoMetadata {
  param([switch]$IgnoreExistingState)
  $git = Get-GitInfo
  $statePath = Join-Path $script:FLOWPLANE_DEMO_RAW "demo-state.json"
  $runId = $script:FLOWPLANE_DEMO_RUN_ID
  if (-not $IgnoreExistingState -and (Test-Path -LiteralPath $statePath)) {
    try {
      $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
      if (-not [string]::IsNullOrWhiteSpace($state.runId)) {
        $runId = $state.runId
      }
    } catch {}
  }
  return @{
    runId = $runId
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    tenantId = $script:FLOWPLANE_TENANT_ID
    apiBase = $script:FLOWPLANE_API_BASE
    gitBranch = $git.branch
    gitCommit = $git.commit
  }
}

function Get-DemoTeam {
  $teams = Invoke-FlowplaneApi -Method Get -Path "/api/v1/teams?activeOnly=true&page=0&size=100"
  if ($teams.items -and $teams.items.Count -gt 0) {
    return $teams.items[0]
  }
  return Invoke-FlowplaneApi -Method Post -Path "/api/v1/teams" -Body @{
    key = "platform-streaming"
    name = "Platform Streaming"
    description = "Flowplane live demo owner team"
    ownerEmail = "platform-streaming@Flowplane.local"
  }
}

function New-FlowplaneDemoPayload {
  param([switch]$Invalid, [string]$SchemaVersion = "v1.0.0")
  $runId = (Get-DemoMetadata).runId
  $wide = [ordered]@{}
  for ($i = 1; $i -le 1000; $i++) {
    $wide["field{0:D4}" -f $i] = "value-{0:D4}" -f $i
  }
  $padding = @()
  for ($i = 1; $i -le 420; $i++) {
    $padding += ("payload-padding-segment-{0:D4}-abcdefghijklmnopqrstuvwxyz0123456789" -f $i)
  }
  $versionTag = if ($SchemaVersion -eq "v1.0.0") { "v1" } else { "v2" }
  $eventId = if ($Invalid) { "" } else { "evt-live-$versionTag-1001" }
  return ([ordered]@{
    run = [ordered]@{
      id = $runId
      schemaVersion = $SchemaVersion
    }
    event = [ordered]@{
      id = $eventId
      type = "ORDER_CREATED"
      ts = "2026-07-05T12:00:00Z"
      trace = "trace-Flowplane-live-demo"
    }
    tenant = [ordered]@{
      id = $script:FLOWPLANE_TENANT_ID
      env = "production"
      region = "us-west"
    }
    order = [ordered]@{
      id = "ORD-1001"
      status = "submitted"
      amount = "128.45"
      currency = "USD"
    }
    customer = [ordered]@{
      id = "CUST-1001"
      tier = "GOLD"
      email = "buyer@example.com"
      ssn = "123-45-6789"
      risk = "LOW"
    }
    metrics = [ordered]@{
      load = "65"
      tempC = 21.89
      risk = "LOW"
      online = $true
      badInt = "not-a-number"
      huge = "999999999999"
    }
    signals = @(
      @{ name = "cpu"; value = 82; category = "compute" },
      @{ name = "mem"; value = 67; category = "memory" },
      @{ name = "disk"; value = 91; category = "storage" }
    )
    packet = @{
      labels = "alpha|beta|gamma"
      message = "  Flowplane   live   demo  "
    }
    wide = $wide
    demo = @{
      mappingSchemaVersion = $SchemaVersion
      padding = $padding
    }
  } | ConvertTo-Json -Depth 30 -Compress)
}

function New-FlowplaneDemoMappingDsl {
  param([string]$SchemaVersion = "v1.0.0", [string]$MappingName = "Flowplane-live-demo-orders")
  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add("version: 1")
  $lines.Add("name: $MappingName")
  $lines.Add("error_policy:")
  $lines.Add("  on_transformation_error: ROUTE_TO_DLQ")
  $lines.Add("  on_validation_failure: ROUTE_TO_DLQ")
  $lines.Add("  on_type_mismatch: ROUTE_TO_DLQ")
  $lines.Add("output:")
  $lines.Add("  shape: FLAT_OBJECT")
  $lines.Add("  complexTypes: NATIVE_JSON")
  $lines.Add("  fieldNaming: AS_IS")
  $lines.Add("lookups:")
  $lines.Add("  statusCode:")
  $lines.Add("    submitted: ACCEPTED")
  $lines.Add("    cancelled: CANCELLED")
  $lines.Add("  riskBand:")
  $lines.Add("    LOW: LOW")
  $lines.Add("    MEDIUM: MEDIUM")
  $lines.Add("    HIGH: HIGH")
  $lines.Add("fields:")
  $lines.Add("  demoRunId:")
  $lines.Add("    path: $.run.id")
  $lines.Add("    required: true")
  $lines.Add("  eventId:")
  $lines.Add("    path: $.event.id")
  $lines.Add("    required: true")
  $lines.Add("    validate:")
  $lines.Add("      required: true")
  $lines.Add("      pattern: `"^evt-`"")
  if ($SchemaVersion -ne "v1.0.0") {
    $lines.Add("  customerRiskBand:")
    $lines.Add("    path: $.customer.risk")
    $lines.Add("    lookup:")
    $lines.Add("      dictionary: riskBand")
  }
  $lines.Add("  orderId:")
  $lines.Add("    path: $.order.id")
  $lines.Add("    required: true")
  $lines.Add("  customerTier:")
  $lines.Add("    path: $.customer.tier")
  $lines.Add("    case_convert: upper")
  $lines.Add("  normalizedStatus:")
  $lines.Add("    path: $.order.status")
  $lines.Add("    lookup:")
  $lines.Add("      dictionary: statusCode")
  $lines.Add("  orderAmountDouble:")
  $lines.Add("    path: $.order.amount")
  $lines.Add("    cast: double")
  $lines.Add("  amountRounded:")
  $lines.Add("    path: $.order.amount")
  $lines.Add("    cast: decimal")
  $lines.Add("    decimalScale: 2")
  $lines.Add("    decimalScalePolicy: ROUND")
  $lines.Add("  eventTypeUpper:")
  $lines.Add("    path: $.event.type")
  $lines.Add("    case_convert: upper")
  $lines.Add("  eventTypeLower:")
  $lines.Add("    path: $.event.type")
  $lines.Add("    case_convert: lower")
  $lines.Add("  receivedAt:")
  $lines.Add("    path: $.event.ts")
  $lines.Add("    cast: timestamp")
  $lines.Add("  region:")
  $lines.Add("    path: $.tenant.missingRegion")
  $lines.Add("    fallback:")
  $lines.Add("      - $.tenant.region")
  $lines.Add("  runtimeConstant:")
  $lines.Add("    constant: Flowplane-live-demo")
  $lines.Add("  customerLabel:")
  $lines.Add("    valueExpr:")
  $lines.Add("      function:")
  $lines.Add("        name: concat")
  $lines.Add("        args:")
  $lines.Add("          - path: $.customer.id")
  $lines.Add("          - const: `"-`"")
  $lines.Add("          - path: $.customer.tier")
  $lines.Add("  statusRoute:")
  $lines.Add("    valueExpr:")
  $lines.Add("      case:")
  $lines.Add("        branches:")
  $lines.Add("          - when:")
  $lines.Add("              path: $.metrics.risk")
  $lines.Add("              operator: eq")
  $lines.Add("              value: HIGH")
  $lines.Add("            then:")
  $lines.Add("              const: page-oncall")
  $lines.Add("        else:")
  $lines.Add("          const: observe")
  $lines.Add("  labelParts:")
  $lines.Add("    path: $.packet.labels")
  $lines.Add("    split:")
  $lines.Add("      by: `"|`"")
  $lines.Add("  normalizedMessage:")
  $lines.Add("    path: $.packet.message")
  $lines.Add("    normalize_string: true")
  $lines.Add("  loadPlusTen:")
  $lines.Add("    arithmetic: `"$.metrics.load + 10`"")
  $lines.Add("  hugeIntClamped:")
  $lines.Add("    path: $.metrics.huge")
  $lines.Add("    cast: int")
  $lines.Add("    onOverflow: CLAMP")
  $lines.Add("  badIntDefault:")
  $lines.Add("    path: $.metrics.badInt")
  $lines.Add("    cast: int")
  $lines.Add("    onTypeMismatch: DEFAULT")
  $lines.Add("    default: -1")
  $lines.Add("  customerEmailMasked:")
  $lines.Add("    path: $.customer.email")
  $lines.Add("    mask: last4")
  $lines.Add("  customerSsnHashed:")
  $lines.Add("    path: $.customer.ssn")
  $lines.Add("    hash: sha256")
  $lines.Add("  traceHash:")
  $lines.Add("    path: $.event.trace")
  $lines.Add("    hash: sha256")
  $lines.Add("  mappingSchemaVersion:")
  $lines.Add("    path: $.demo.mappingSchemaVersion")
  if ($SchemaVersion -ne "v1.0.0") {
    $lines.Add("  runtimeMetadataField:")
    $lines.Add("    constant: v2-runtime-visible")
  }
  for ($i = 1; $i -le 970; $i++) {
    $name = "wideField{0:D4}" -f $i
    $path = "field{0:D4}" -f $i
    $lines.Add("  ${name}:")
    $lines.Add("    path: `$.wide.$path")
  }
  return ($lines -join [Environment]::NewLine)
}

function Get-LatestArtifact {
  param([Parameter(Mandatory)][string]$MappingId)
  $artifacts = Invoke-FlowplaneApi -Method Get -Path "/api/v1/mappings/$MappingId/artifacts"
  if ($artifacts -is [array]) {
    return $artifacts | Select-Object -First 1
  }
  if ($artifacts.items) {
    return $artifacts.items | Select-Object -First 1
  }
  return $artifacts
}

function Get-ApprovalForMapping {
  param([Parameter(Mandatory)][string]$MappingId)
  $approvals = Invoke-FlowplaneApi -Method Get -Path "/api/v1/approvals?environment=PRODUCTION&page=0&size=100"
  return @($approvals.items) | Where-Object { $_.mappingId -eq $MappingId } | Select-Object -First 1
}

function Read-DemoState {
  $path = Join-Path $script:FLOWPLANE_DEMO_RAW "demo-state.json"
  if (-not (Test-Path -LiteralPath $path)) {
    return [ordered]@{}
  }
  return Read-Json $path
}

function Save-DemoState {
  param([Parameter(Mandatory)]$State)
  Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "demo-state.json") -Value $State
}

function Get-FlowplaneDemoRuntimeTargets {
  $rawTopic = "flowplane.demo.orders.raw"
  return @(
    [ordered]@{
      runtimeId = "$($script:FLOWPLANE_DEMO_PREFIX)-flink"
      name = "Orders enrichment Flink job"
      type = "FLINK"
      transport = "FLINK"
      inputTopic = $rawTopic
      outputTopic = "flowplane.demo.orders.flink.transformed"
      dlqTopic = "flowplane.demo.orders.flink.dlq"
      downstreamKind = "kafka"
      containerName = "flowplane-live-demo-flink-submit"
      taskManagerContainerName = "flowplane-live-demo-flink-taskmanager"
      startupKind = "flink"
    },
    [ordered]@{
      runtimeId = "$($script:FLOWPLANE_DEMO_PREFIX)-kafka-connect"
      name = "Orders Mongo sink connector"
      type = "KAFKA_CONNECT_SMT"
      transport = "KAFKA_CONNECT"
      inputTopic = $rawTopic
      outputTopic = "mongodb://flowplane_sink.flowplane_demo_orders_connect"
      dlqTopic = "flowplane.demo.orders.connect.dlq"
      downstreamKind = "mongo"
      connectorName = "flowplane-live-demo-mongo-sink"
      mongoDatabase = "flowplane_sink"
      mongoCollection = "flowplane_demo_orders_connect"
      startupKind = "kafka-connect"
    }
  )
}

function Get-FlowplaneDemoKafkaTopics {
  $topics = [System.Collections.Generic.List[string]]::new()
  $topics.Add("flowplane.demo.orders.raw")
  foreach ($target in Get-FlowplaneDemoRuntimeTargets) {
    if (-not [string]::IsNullOrWhiteSpace($target.outputTopic) -and $target.outputTopic -notlike "mongodb://*") {
      $topics.Add($target.outputTopic)
    }
    if (-not [string]::IsNullOrWhiteSpace($target.dlqTopic)) {
      $topics.Add($target.dlqTopic)
    }
  }
  return @($topics | Select-Object -Unique)
}

function Get-FlowplaneDemoRuntimeSecretsById {
  $path = Join-Path $script:FLOWPLANE_DEMO_RAW "runtime-secrets.local.json"
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Runtime secrets not found at $path. Run 03-register-runtimes.ps1 first."
  }
  $secrets = Read-Json $path
  $byId = @{}
  foreach ($secret in @($secrets.runtimes)) {
    $byId[$secret.runtimeId] = $secret.clientSecret
  }
  return $byId
}

function Remove-FlowplaneDemoRuntimeContainers {
  $removed = @()
  $names = [System.Collections.Generic.List[string]]::new()
  $names.Add("flowplane-live-demo-redpanda-console")
  foreach ($target in Get-FlowplaneDemoRuntimeTargets) {
    foreach ($property in @("containerName", "taskManagerContainerName", "sidecarContainerName", "processorContainerName")) {
      if ($target.Contains($property) -and -not [string]::IsNullOrWhiteSpace($target[$property])) {
        $names.Add($target[$property])
      }
    }
  }
  foreach ($containerName in @($names | Select-Object -Unique)) {
    $existing = docker ps -a --filter "name=^/$containerName$" --format "{{.Names}}"
    if ($existing -contains $containerName) {
      docker rm -f $containerName | Out-Null
      $removed += $containerName
    }
  }
  return $removed
}

function Reset-FlowplaneDemoMongoSink {
  $target = Get-FlowplaneDemoRuntimeTargets | Where-Object { $_.startupKind -eq "kafka-connect" } | Select-Object -First 1
  if (-not $target) { return $null }
  $database = $target.mongoDatabase
  $collection = $target.mongoCollection
  $js = "db.getCollection('$collection').drop(); db.createCollection('$collection'); print(JSON.stringify({ database: '$database', collection: '$collection', count: db.getCollection('$collection').countDocuments() }));"
  $output = & docker exec flowplane-mongo mongosh --quiet $database --eval $js
  if ($LASTEXITCODE -ne 0) {
    throw "Mongo sink reset failed for $database.$collection."
  }
  return ($output | Select-Object -Last 1 | ConvertFrom-Json)
}

function Invoke-FlowplaneConnect {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    $Body = $null
  )
  $params = @{
    Method = $Method
    Uri = "http://127.0.0.1:8084$Path"
    ContentType = "application/json"
  }
  if ($null -ne $Body) {
    $params.Body = $Body | ConvertTo-Json -Depth 100 -Compress
  }
  return Invoke-RestMethod @params
}

function Remove-FlowplaneDemoConnectors {
  $removed = @()
  try {
    $connectors = @(Invoke-FlowplaneConnect -Method Get -Path "/connectors")
    foreach ($name in $connectors) {
      if ([string]$name -like "flowplane-live-demo-*") {
        Invoke-FlowplaneConnect -Method Delete -Path "/connectors/$([uri]::EscapeDataString([string]$name))" | Out-Null
        $removed += [string]$name
      }
    }
  } catch {
    throw "Kafka Connect cleanup failed: $($_.Exception.Message)"
  }
  return $removed
}

function Wait-FlowplaneMongoDocuments {
  param(
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$Collection,
    [int]$ExpectedCount = 1,
    [int]$TimeoutSeconds = 120,
    [int]$Limit = 10
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $js = "const docs = db.getCollection('$Collection').find({}).limit($Limit).toArray(); print(EJSON.stringify({ count: db.getCollection('$Collection').countDocuments(), docs }));"
    $output = & docker exec flowplane-mongo mongosh --quiet $Database --eval $js
    if ($LASTEXITCODE -ne 0) {
      throw "Mongo read failed for $Database.$Collection."
    }
    $result = $output | Select-Object -Last 1 | ConvertFrom-Json
    if ([int]$result.count -ge $ExpectedCount) {
      return $result
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "Timed out waiting for $ExpectedCount runtime-written Mongo document(s) in $Database.$Collection."
}

function Wait-FlowplaneRuntimeAssignments {
  param(
    [Parameter(Mandatory)][string]$ExpectedVersion,
    [int]$TimeoutSeconds = 90
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastStates = @()
  do {
    $lastStates = @()
    $allReady = $true
    foreach ($target in Get-FlowplaneDemoRuntimeTargets) {
      try {
        $runtime = Invoke-FlowplaneApi -Method Get -Path "/api/v1/runtimes/$($target.runtimeId)"
        $lastStates += [ordered]@{
          runtimeId = $target.runtimeId
          activeVersion = $runtime.activeVersion
          expectedVersion = $runtime.expectedVersion
          lifecycleState = $runtime.lifecycleState
          health = $runtime.health
        }
        $versionReady = ($runtime.activeVersion -eq $ExpectedVersion) -or ($runtime.expectedVersion -eq $ExpectedVersion)
        $stateReady = @("RUNNING", "ROLLOUT_PENDING") -contains $runtime.lifecycleState
        if (-not $versionReady -or -not $stateReady) {
          $allReady = $false
        }
      } catch {
        $lastStates += [ordered]@{ runtimeId = $target.runtimeId; error = $_.Exception.Message }
        $allReady = $false
      }
    }
    if ($allReady) {
      return $lastStates
    }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  throw "Timed out waiting for all live runtimes to run $ExpectedVersion. Last states: $($lastStates | ConvertTo-Json -Compress -Depth 20)"
}

function ConvertTo-FlowplaneSafeName {
  param([Parameter(Mandatory)][string]$Value)
  return ($Value -replace '[^A-Za-z0-9._-]', '-')
}

function Wait-FlowplaneDemoRuntimeOutputs {
  param(
    [Parameter(Mandatory)][string]$VersionLabel,
    [int]$TimeoutSeconds = 180,
    [string[]]$RuntimeIds = @()
  )
  $evidence = @()
  $state = Read-DemoState
  $schemaMarker = if ($VersionLabel -eq "v1") { "v1.0.0" } else { "v1.1.0" }
  $expectedArtifactHash = if ($VersionLabel -eq "v1") { [string]$state.v1ArtifactHash } else { [string]$state.v2ArtifactHash }
  $expectedDlqCount = if ($VersionLabel -eq "v1") { 1 } else { 2 }
  $targets = @(Get-FlowplaneDemoRuntimeTargets)
  if ($RuntimeIds.Count -gt 0) {
    $targets = @($targets | Where-Object { $RuntimeIds -contains $_.runtimeId })
  }
  foreach ($target in $targets) {
    $safeRuntime = ConvertTo-FlowplaneSafeName $target.runtimeId
    if ($target.downstreamKind -eq "mongo") {
      $mongo = Wait-FlowplaneMongoDocuments -Database $target.mongoDatabase -Collection $target.mongoCollection -ExpectedCount 1 -TimeoutSeconds $TimeoutSeconds -Limit 50
      $matchingDocs = @($mongo.docs | Where-Object { $_.mappingSchemaVersion -eq $schemaMarker -and $_.demoRunId -eq $state.runId })
      if ($matchingDocs.Count -eq 0) {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
          $mongo = Wait-FlowplaneMongoDocuments -Database $target.mongoDatabase -Collection $target.mongoCollection -ExpectedCount 1 -TimeoutSeconds 5 -Limit 50
          $matchingDocs = @($mongo.docs | Where-Object { $_.mappingSchemaVersion -eq $schemaMarker -and $_.demoRunId -eq $state.runId })
          if ($matchingDocs.Count -gt 0) { break }
          Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)
      }
      if ($matchingDocs.Count -eq 0) {
        throw "Timed out waiting for Mongo document from run $($state.runId) with mappingSchemaVersion=$schemaMarker in $($target.mongoDatabase).$($target.mongoCollection)."
      }
      $dlqRecords = Wait-FlowplaneKafkaRecords -Topic $target.dlqTopic -ExpectedCount $expectedDlqCount -MaxMessages 50 -TimeoutSeconds $TimeoutSeconds
      $selectedDlq = Select-FlowplaneRuntimeDlqRecord -Records $dlqRecords -Topic $target.dlqTopic -RuntimeId $target.runtimeId -ArtifactHash $expectedArtifactHash -ArtifactVersion $schemaMarker -RunId $state.runId
      $selectedDlqRecords = @($selectedDlq.raw)
      $dlqOutput = $selectedDlq.parsed
      $sourceProvenance = Confirm-FlowplaneDlqSourceProvenance -DlqRecord $dlqOutput -ExpectedTopic $target.inputTopic -ExpectedRunId $state.runId
      Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "$VersionLabel-$safeRuntime-mongo-output.json") -Value $mongo
      Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "$VersionLabel-$safeRuntime-dlq-output.json") -Value $dlqOutput
      $evidence += [ordered]@{
        runtimeId = $target.runtimeId
        name = $target.name
        downstreamKind = "mongo"
        mongoDatabase = $target.mongoDatabase
        mongoCollection = $target.mongoCollection
        mongoDocumentCount = @($matchingDocs).Count
        dlqTopic = $target.dlqTopic
        dlqRecordCount = $selectedDlqRecords.Count
        dlqTopicRecordCount = @($dlqRecords).Count
        dlqRecords = $selectedDlqRecords
        sourceRecordRunId = $sourceProvenance.runId
        sourceProvenance = $sourceProvenance
        outputSource = "runtime-written Mongo document through Kafka Connect SMT"
        dlqSource = "runtime-written Kafka DLQ record through Kafka Connect SMT"
      }
    } else {
      $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
      $outputRecords = @()
      $matchingOutputRecords = @()
      do {
        $outputRecords = @(Read-FlowplaneKafkaRecords -Topic $target.outputTopic -MaxMessages 50)
        $matchingOutputRecords = @($outputRecords | ForEach-Object {
          try {
            $candidate = ConvertFrom-FlowplaneKafkaJsonRecord -Record $_
            if ($candidate.mappingSchemaVersion -eq $schemaMarker -and $candidate.demoRunId -eq $state.runId) {
              $_
            }
          } catch {
            # Ignore unrelated or malformed records while waiting for the current run.
          }
        })
        if ($matchingOutputRecords.Count -gt 0) { break }
        Start-Sleep -Seconds 2
      } while ((Get-Date) -lt $deadline)
      if ($matchingOutputRecords.Count -eq 0) {
        throw "Timed out waiting for runtime-produced Kafka record containing $schemaMarker on $($target.outputTopic)."
      }
      $dlqRecords = @()
      $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
      do {
        $dlqRecords = @(Read-FlowplaneKafkaRecords -Topic $target.dlqTopic -MaxMessages 50)
        if ($dlqRecords.Count -ge $expectedDlqCount) { break }
        Start-Sleep -Seconds 2
      } while ((Get-Date) -lt $deadline)
      if ($dlqRecords.Count -lt $expectedDlqCount) {
        throw "Timed out waiting for $expectedDlqCount runtime-produced DLQ record(s) on $($target.dlqTopic)."
      }
      $selectedDlq = Select-FlowplaneRuntimeDlqRecord -Records $dlqRecords -Topic $target.dlqTopic -RuntimeId $target.runtimeId -ArtifactHash $expectedArtifactHash -ArtifactVersion $schemaMarker -RunId $state.runId
      $selectedDlqRecords = @($selectedDlq.raw)
      $output = ConvertFrom-FlowplaneKafkaJsonRecord -Record (@($matchingOutputRecords)[0])
      if ($output.demoRunId -ne $state.runId) {
        throw "Runtime output on $($target.outputTopic) did not belong to run $($state.runId)."
      }
      $dlqOutput = $selectedDlq.parsed
      $sourceProvenance = Confirm-FlowplaneDlqSourceProvenance -DlqRecord $dlqOutput -ExpectedTopic $target.inputTopic -ExpectedRunId $state.runId
      Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "$VersionLabel-$safeRuntime-transformed-output.json") -Value $output
      Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "$VersionLabel-$safeRuntime-dlq-output.json") -Value $dlqOutput
      if ($target.runtimeId -eq "$($script:FLOWPLANE_DEMO_PREFIX)-flink") {
        Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "$VersionLabel-transformed-output.json") -Value $output
        Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "$VersionLabel-dlq-output.json") -Value $dlqOutput
      }
      $evidence += [ordered]@{
        runtimeId = $target.runtimeId
        name = $target.name
        downstreamKind = "kafka"
        outputTopic = $target.outputTopic
        dlqTopic = $target.dlqTopic
        outputRecordCount = @($matchingOutputRecords).Count
        dlqRecordCount = $selectedDlqRecords.Count
        dlqTopicRecordCount = @($dlqRecords).Count
        outputRecords = $matchingOutputRecords
        dlqRecords = $selectedDlqRecords
        sourceRecordRunId = $sourceProvenance.runId
        sourceProvenance = $sourceProvenance
        outputSource = "runtime-written Kafka downstream record"
        dlqSource = "runtime-written Kafka DLQ record"
      }
    }
  }
  Save-Json -Path (Join-Path $script:FLOWPLANE_DEMO_RAW "$VersionLabel-runtime-downstream-evidence.json") -Value $evidence
  return $evidence
}
