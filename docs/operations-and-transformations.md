# Operations and transformations

This catalog describes the stateless mapping operations supported by the current Flowplane transformation runtime. Each row contains a minimal YAML example and the result for the stated input. The examples are intentionally small so they can be copied into a larger mapping.

The catalog was checked against the current compiler and runtime contract suite on 2026-07-22. The verification ran 25 focused contract tests covering the full sample mapping, operation boundaries, encryption round trips, output shapes, and equivalent execution strategies, plus one exact starter-fixture comparison; all 26 passed. See the [verification record](../examples/operations/verification.json).

## Minimal mapping

```yaml
output: FLAT_OBJECT
fields:
  order_id: $.order.id
```

Input `{"order":{"id":"A-1"}}` produces `{"order_id":"A-1"}`. A field may use the short path form above or the expanded `path: $.order.id` form.

## Value sources and composition

| Operation | Minimal field recipe | Example result |
|---|---|---|
| JSONPath selection | `id: $.order.id` | `A-1` |
| Path aliases | `id: { direct: $.order.id }` or `id: { source: $.order.id }` | `A-1` |
| Fallback paths | `region: { path: $.missing, fallback: [$.tenant.region] }` | `us-west` |
| Constant | `env: { constant: production }` | `production` |
| Literal value | `env: { value: production }` | `production` |
| Context metadata | `request_id: { metadata: requestId }` | the runtime request ID |
| Message header | `trace_id: { header: x-trace-id }` | the `x-trace-id` value |
| Generated UUID | `id: { generate: uuid }` | a new UUID string |
| Generated timestamp | `created_at: { generate: now }` | the current ISO-8601 instant |
| Coalesce | `email: { valueExpr: { coalesce: { mode: FIRST_NON_EMPTY, candidates: [{path: $.primary}, {path: $.backup}, {const: unknown}] } } }` | first non-empty candidate |
| Conditional case | `route: { valueExpr: { case: { branches: [{when: {path: $.risk, operator: EQ, value: HIGH}, then: {const: page}}], else: {const: observe} } } }` | `page` when `risk` is `HIGH` |
| Lookup | `action: { path: $.status, lookup: { dictionary: statusCodes } }` | dictionary value for `status` |
| Function | `label: { valueExpr: { function: { name: concat, args: [{path: $.type}, {const: "-"}, {path: $.id}] } } }` | `gateway-42` |

Coalesce modes are `FIRST_NON_MISSING`, `FIRST_NON_NULL`, `FIRST_NON_EMPTY`, and `FIRST_VALID`. Function keys `function`, `func`, and `fn` are accepted aliases.

### Predicates

Case branches support `all`/`and` and `any`/`or` composition. The available predicate operators are:

| Operator | Example condition | Matches when |
|---|---|---|
| `EXISTS` | `{ path: $.email, operator: EXISTS }` | the path exists |
| `MISSING` | `{ path: $.email, operator: MISSING }` | the path is absent |
| `IS_NULL` | `{ path: $.email, operator: IS_NULL }` | the value is null |
| `NOT_NULL` | `{ path: $.email, operator: NOT_NULL }` | the value is not null |
| `IS_EMPTY` | `{ path: $.email, operator: IS_EMPTY }` | the value is blank or empty |
| `NOT_EMPTY` | `{ path: $.email, operator: NOT_EMPTY }` | the value is not empty |
| `EQ`, `NE` | `{ path: $.status, operator: EQ, value: OK }` | equality or inequality holds |
| `GT`, `GTE`, `LT`, `LTE` | `{ path: $.score, operator: GTE, value: 80 }` | numeric comparison holds |
| `IN` | `{ path: $.status, operator: IN, value: [OK, WARN] }` | the value is in the list |
| `REGEX_MATCH` | `{ path: $.code, operator: REGEX_MATCH, value: "^A-" }` | the regex matches |
| `STARTS_WITH` | `{ path: $.code, operator: STARTS_WITH, value: A- }` | the string starts with `A-` |
| `ENDS_WITH` | `{ path: $.file, operator: ENDS_WITH, value: .json }` | the string ends with `.json` |
| `CONTAINS` | `{ path: $.message, operator: CONTAINS, value: error }` | the string contains `error` |

## Functions

The value-expression function form supports these operations:

| Function | Minimal invocation | Example result |
|---|---|---|
| `concat` | `name: concat; args: [{const: Ada}, {const: " "}, {const: Lovelace}]` | `Ada Lovelace` |
| `template` | `name: template; args: [{const: "id="}, {path: $.id}]` | `id=42` |
| `upper` | `name: upper; args: [{const: stream}]` | `STREAM` |
| `lower` | `name: lower; args: [{const: STREAM}]` | `stream` |
| `trim` | `name: trim; args: [{const: "  ready  "}]` | `ready` |
| `substring` | `name: substring; args: [{const: stream}, {const: 1}, {const: 5}]` | `trea` |
| `split` | `name: split; args: [{const: "a,b,c"}, {const: ","}]` | `["a","b","c"]` |
| `round` | `name: round; args: [{const: 12.345}, {const: 2}]` | `12.35` |
| `now` | `name: now` | the current ISO-8601 instant |
| `uuid` | `name: uuid` | a new UUID string |
| `hash` | `name: hash; args: [{const: abc}]` | SHA-256 digest of `abc` |

## String and regex transforms

| Operation | Minimal field recipe | Example result |
|---|---|---|
| Uppercase | `status: { path: $.status, case_convert: upper }` | `OK` from `ok` |
| Lowercase | `status: { path: $.status, case_convert: lower }` | `ok` from `OK` |
| Normalize whitespace | `message: { path: $.message, normalize_string: true }` | `Fan speed unstable` |
| Template current value | `label: { path: $.status, template: "status-${value}" }` | `status-OK` |
| Substring | `prefix: { path: $.serial, substring: { start: 0, end: 2 } }` | `GW` |
| Split | `parts: { path: $.labels, split: { by: "|" } }` | `["a","b"]` |
| Regex match | `valid: { path: $.status, regex_match: "^(OK|FAIL)$" }` | `true` |
| Regex extract | `family: { path: $.serial, regex_extract: "^(GW)-.*" }` | `GW` |
| Regex replace | `version: { path: $.firmware, regex_replace: "^fw-", replacement: "" }` | `v2.7.1` |

## Expressions and numeric transforms

| Operation | Minimal field recipe | Example result |
|---|---|---|
| Arithmetic expression | `total: { expression: "$.price * $.quantity" }` | `30` from `10 × 3` |
| Comparison expression | `adult: { expression: "$.age >= 18" }` | `true` for `21` |
| Arithmetic alias | `adjusted: { arithmetic: "$.load + 10" }` | `75` for `65` |
| Round | `amount: { path: $.amount, round: { scale: 2 } }` | `12.35` from `12.345` |

Simple expressions support `+`, `-`, `*`, `/`, `>`, `>=`, `<`, `<=`, `==`, and `!=`. Arithmetic is evaluated from left to right; use separate fields when conventional operator precedence is required.

## Type conversion

Use `cast` or `type` with any of the following types.

| Type | Example | Result |
|---|---|---|
| `STRING` | `value: { path: $.id, cast: string }` | string value |
| `INT` / `INTEGER` | `value: { path: $.count, cast: int }` | 32-bit integer |
| `LONG` | `value: { path: $.count, cast: long }` | 64-bit integer |
| `DOUBLE` | `value: { path: $.amount, cast: double }` | double-precision number |
| `DECIMAL` | `value: { path: $.amount, cast: decimal, decimalScale: 2, decimalScalePolicy: ROUND }` | fixed-scale decimal |
| `BOOLEAN` | `value: { path: $.enabled, cast: boolean }` | boolean |
| `TIMESTAMP` | `value: { path: $.time, cast: timestamp }` | epoch milliseconds |
| `DATE` | `value: { path: $.day, cast: date, date_format: MM/dd/yyyy }` | ISO date |
| `TIME` | `value: { path: $.clock, cast: time, date_format: HH:mm:ss }` | ISO time |
| `JSON` | `value: { path: $.raw, cast: json }` | parsed JSON value |
| `OBJECT` | `value: { path: $.raw, cast: object }` | object/map |
| `ARRAY` | `value: { path: $.items, cast: array }` | array/list |

Decimal scale policies are `FAIL`, `ROUND`, and `TRUNCATE`. Numeric overflow can use `ERROR`, `CLAMP`, or `DEFAULT`.

## Array transforms

For input `items: [{name: cpu, value: 82}, {name: mem, value: 67}, {name: disk, value: 91}]`:

| Operation | Minimal field recipe | Result |
|---|---|---|
| `FIRST` | `value: { path: $.items[*].name, array_mode: FIRST }` | `cpu` |
| `LAST` | `value: { path: $.items[*].name, array_mode: LAST }` | `disk` |
| `INDEX` | `value: { path: $.items[*].name, array_mode: INDEX, array_index: 1 }` | `mem` |
| `ONLY` | `value: { path: $.single[*].name, array_mode: ONLY }` | the only element; errors for any other cardinality |
| `FILTER_FIRST` | `value: { path: "$.items[?(@.value >= 80)].name", array_mode: FILTER_FIRST }` | `cpu` |
| `FILTER_ALL` | `value: { path: "$.items[?(@.value >= 80)].name", array_mode: FILTER_ALL }` | `["cpu","disk"]` |
| `COUNT` | `value: { path: $.items[*], array_mode: COUNT }` | `3` |
| `COLLECT` | `value: { path: $.items[*].name, array_mode: COLLECT }` | `["cpu","mem","disk"]` |
| `JOIN` | `value: { path: $.items[*].name, array_mode: JOIN, delimiter: "|" }` | `cpu|mem|disk` |
| Filter | `value: { path: $.items[*], filter: "item.value >= 80" }` | the `cpu` and `disk` objects |
| Map | `value: { path: $.items[*], map: { metric: item.name, reading: item.value } }` | renamed object fields |
| Flatten | `value: { path: $.groups, flatten: true }` | one-level flattened list |
| Distinct | `value: { path: $.tags[*], distinct: true }` | duplicates removed |
| Aggregate count | `value: { path: $.items[*].value, aggregate: count }` | `3` |
| Aggregate sum | `value: { path: $.items[*].value, aggregate: sum }` | `240` |
| Aggregate min | `value: { path: $.items[*].value, aggregate: min }` | `67` |
| Aggregate max | `value: { path: $.items[*].value, aggregate: max }` | `91` |

## Object transforms

| Operation | Minimal field recipe | Example result |
|---|---|---|
| Construct object | `customer: { object: { id: $.customer.id, email: $.customer.email } }` | a new object with `id` and `email` |
| Merge objects | `profile: { merge: [$.profile.base, $.profile.preferences] }` | one object containing both sets of fields |
| Nested output | `customer.id: { path: $.customerId }` | `{ "customer": { "id": "C-1" } }` in object output |

## Lookup behavior

```yaml
lookups:
  statusCodes:
    OK: observe
    FAIL: dispatch
fields:
  action:
    path: $.status
    lookup:
      dictionary: statusCodes
      onMiss: DEFAULT
      defaultValue: unknown
      caseInsensitive: true
      trimInput: true
```

Lookup miss actions are `KEEP_ORIGINAL`, `DEFAULT`, `NULL`, `SKIP_FIELD`, and `ERROR`. `resultField` selects a property from an object-valued dictionary entry. A lookup may also be expressed inside `valueExpr` and may declare its key with `path` or `key`.

## Validation and field policies

| Capability | Minimal example | Behavior |
|---|---|---|
| Required field | `id: { path: $.id, required: true }` | reports a missing-required-field error |
| Regex validation | `id: { path: $.id, validate: "^evt-" }` | accepts matching strings |
| Validation map | `age: { path: $.age, validate: { required: true, min: 0, max: 120, one_of: [18, 21, 65] } }` | applies declared constraints; `pattern` is also available |
| Field error: skip | `age: { path: $.age, cast: int, on_error: { action: SKIP_FIELD } }` | omits the failed field |
| Field error: null | `age: { path: $.age, cast: int, on_error: { action: SET_NULL } }` | emits null |
| Field error: default | `age: { path: $.age, cast: int, on_error: { action: SET_DEFAULT, value: 0 } }` | emits the configured value |

Policy options are:

| Input condition | Supported actions |
|---|---|
| Missing value (`onMissing`) | `NULL`, `SKIP_FIELD`, `ERROR` |
| Null value (`onNull`) | `ALLOW`, `DEFAULT`, `ERROR` |
| Array where scalar expected (`onArray`) | `USE_PICK`, `JSON_STRING`, `ERROR` |
| Object where scalar expected (`onObject`) | `NATIVE`, `JSON_STRING`, `ERROR` |
| Type mismatch (`onTypeMismatch`) | `COERCE`, `STRINGIFY`, `DEFAULT`, `ERROR` |
| Numeric overflow (`onOverflow`) | `ERROR`, `CLAMP`, `DEFAULT` |

`default`/`defaultValue` supplies the default used by the relevant policies. `strict: true` enables strict field handling.

## Data protection

| Operation | Minimal field recipe | Result |
|---|---|---|
| Mask | `token: { path: $.token, mask: last4 }` | masks all but the final four characters |
| Sensitive | `token: { path: $.token, sensitive: true }` | applies the same protected display behavior |
| Hash | `digest: { path: $.id, hash: sha256 }` | hexadecimal digest |
| Redact | `secret: { path: $.secret, redact: true }` | redacted value |
| Encrypt | `secret: { path: $.secret, encrypt: { key_ref: payments } }` | AES-GCM ciphertext |
| Decrypt | `secret: { path: $.ciphertext, decrypt: { key_ref: payments } }` | original plaintext |

Encryption keys are resolved by key reference from runtime configuration. Encryption output includes a fresh initialization vector, so ciphertext is intentionally nondeterministic. Do not place real keys or secrets in mappings or public fixtures.

## Output controls

Mapping output shapes are `OBJECT`, `FLAT_OBJECT`, `JSON_STRING`, `PRIMITIVE`, and `BYTES`.

```yaml
output:
  shape: FLAT_OBJECT
```

Host output materialization options include complex-value modes `NATIVE_JSON`, `JSON_STRING`, and `ERROR`, plus field naming policies `AS_IS`, `SNAKE_CASE`, and `CAMEL_CASE`. A host runtime may apply these options or override the output shape while preserving the same compiled transformation semantics.

## Mapping-level error behavior

```yaml
errorPolicy:
  onTransformationError: ROUTE_TO_DLQ
  onValidationFailure: SKIP_RECORD
  onTypeMismatch: REDACT_AND_PROCEED
  dlqTopicTemplate: "${inputTopic}.flowplane.dlq"
  includeOriginalPayload: false
  includeErrorMetadata: true

errorOutput:
  action: EMIT_TO_TOPIC
  format: CLOUD_EVENTS
  topicTemplate: "errors.${inputTopic}"
```

Mapping-level error actions are `FAIL_PIPELINE`, `SKIP_RECORD`, `ROUTE_TO_DLQ`, and `REDACT_AND_PROCEED`. Error-output actions are `ROUTE_TO_DLQ`, `EMIT_TO_TOPIC`, `FAIL_PIPELINE`, `DROP`, and `RETRY`; formats are `ENVELOPE`, `FIELD_ERRORS`, `COMPACT`, `CLOUD_EVENTS`, and `CUSTOM`. These directives travel with the compiled mapping; the host integration performs transport actions such as topic emission, retry, and record acknowledgement.

## Intentional boundary

This mapping language is stateless. Broker transport, joins, windows, sessions, state stores, timers, watermarks, retries, acknowledgements, ordering, checkpoints, and backpressure remain host-runtime responsibilities. Stateful DSL keys are rejected rather than silently accepted.

For a runnable, deterministic starter fixture, see the [operations example](../examples/operations/README.md).
