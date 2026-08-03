---
summary: "JavaScriptCore provider-plugin prototype API, safety boundary, enablement, and limitations."
read_when:
  - Working on the JavaScript provider prototype
  - Converting a first-party provider to a bundled JavaScript resource
  - Reviewing the plugin sandbox or parity tests
---

# JavaScript provider-plugin prototype

This prototype proves that an existing first-party `UsageProvider` can define its manifest, HTTP requests, response
parsing, and generic `UsageSnapshot` projection in one bundled JavaScript file. It is deliberately not a user-plugin
system: IDs remain compile-time `UsageProvider` cases, scripts ship inside CodexBar, and the normal Swift path remains
the default.

## Enable and test

Set `CODEXBAR_JS_PROVIDERS=1` in CodexBar's environment. Synthetic, Venice, Crof, OpenAI, z.ai, OpenRouter, Poe, and
ClawRouter then prepend a script strategy to their existing API pipeline. A missing required secret leaves the script
strategy unavailable and permits the Swift strategy to run; a loaded script that fails does not fall back, so parity
defects stay visible. Without the variable, the resolver returns the original Swift strategy only and does not load
JavaScriptCore or a plugin resource.

Run the focused proof with:

```sh
swift test --filter ProviderPluginRuntimeTests
swift test --filter ProviderPluginParityTests
swift test --filter ProviderPluginDetailsParityTests
```

The parity suites send the same canned responses through an injected `ProviderHTTPTransport` to both implementations
and compare core windows, percentages, reset dates, cost, subscription dates, and identity fields. Details-provider
fixtures additionally characterize the complete declarative section output.

## Manifest

Every script calls `defineProvider` once:

```js
defineProvider({
  id: "example", // must be an existing UsageProvider raw value
  name: "Example",
  endpoints: ["https://api.example.com"], // HTTPS origins, not URL prefixes
  auth: {
    type: "bearer", // bearer | x-api-key | header
    header: "X-Custom-Key", // required only for type: "header"
    secret: "EXAMPLE_API_KEY", // key declared below
  },
  settings: [{
    key: "EXAMPLE_API_KEY",
    title: "API key",
    subtitle: "Where to obtain the key.",
    type: "secure", // secure | plain
  }],
  async fetchUsage(ctx) {
    const response = await ctx.http.getJSON("https://api.example.com/v1/usage");
    return { primary: { usedPercent: response.json.usedPercent } };
  },
});
```

`endpoints` accepts only normalized HTTPS origins. The broker rejects user info, non-HTTPS URLs, and any request whose
scheme, host, or effective port is not declared. `bearer` injects `Authorization: Bearer <secret>`, `x-api-key` injects
`X-API-Key`, and `header` injects the named header. A plugin cannot override its auth header in request options.

## `ctx` reference

`ctx` exists only as the argument to `fetchUsage`; it is not a global. JavaScriptCore supplies standard ECMAScript
built-ins, but no browser or Node host environment. Tests assert that `fetch`, `XMLHttpRequest`, `setTimeout`, and
`setInterval` are undefined.

- `await ctx.http.getJSON(url, opts?)` performs a GET and returns `{status, headers, json}`.
- `await ctx.http.get(url, opts?)` performs a GET and returns `{status, headers, bodyText}`.
- `opts.headers` may contain string header values. Requests have a 15-second timeout, responses are capped at 5 MiB,
  and transport uses `ProviderHTTPClient`, including its same-origin HTTPS redirect policy.
- `ctx.secrets.get(key)` returns a value only for a key declared in `settings`; undeclared access throws.
- `ctx.log(...values)` writes to the provider-derived `<provider>-plugin` category. Do not log credentials; known secret
  values are also substring-redacted from errors crossing back to Swift.
- `ctx.cache.get(key)` and `ctx.cache.set(key, value, ttlSeconds)` provide an in-memory, per-context cache. TTLs are
  positive and capped at 24 hours.
- `ctx.date.iso(text)`, `unixSeconds(number)`, and `unixMillis(number)` return JavaScript `Date` objects.
- `ctx.date.nextDailyReset(timeZoneIdentifier, hour)` returns the next wall-clock hour in an IANA time zone, including
  DST transitions. Crof uses `America/Chicago` at hour `0`.
- `ctx.jwt.decode(token)` decodes the JSON payload segment without verifying a signature.
- `ctx.pct(used, limit)` returns a finite percentage clamped to 0–100; a non-positive limit maps to 100.

## Snapshot result

`fetchUsage` resolves to an object containing at least one window or `cost`. `primary`, `secondary`, and `tertiary` are
optional `{usedPercent, resetsAt?, windowMinutes?, resetDescription?, nextRegenPercent?}` objects. `extraWindows` is an
optional array of `{id, title, window}`. Percentages must be finite numbers and are clamped to 0–100; window minutes must
be positive integers.

`cost` requires finite numeric `used` and a three-letter uppercase `currency`; `limit`, `period`, `resetsAt`,
`nextRegenAmount`, and `balance` are optional. A missing limit maps to zero. `identity` accepts bounded, trimmed `email`,
`organization`, `loginMethod`, and `accountID` strings; Swift always scopes it to the manifest provider ID.
`subscriptionRenewsAt` and `subscriptionExpiresAt` accept a JavaScript `Date` or ISO-8601 string. Missing optionals are
fine, while a present value of the wrong type fails the entire fetch with its property path.

### Declarative details

`details` is an optional array of sections rendered generically in the provider menu card. A snapshot may contain
details without a rate window or cost. Each section has optional `title`, required `rows`, and an optional simple chart:

```js
return {
  primary: { usedPercent: 25 },
  details: [{
    title: "Usage summary",
    rows: [
      { label: "Requests", value: "1,240", secondaryValue: "Last 30 days" },
      { label: "Top model", value: "gpt-5" },
    ],
    chart: {
      kind: "bars", // bars | line
      title: "Daily spend",
      unit: "USD",
      points: [
        { label: "2026-08-01", value: 4.25 },
        { label: "2026-08-02", value: 6.50 },
      ],
    },
  }],
};
```

The bridge rejects rather than truncates more than 8 sections, 24 rows per section, or 120 points per chart. Section,
row, chart, and point strings are trimmed and limited to 120 characters; required row/point strings must remain
non-empty. Point values must be finite numbers. A present value with the wrong type, an unknown chart kind, or any
bound violation fails the entire fetch with its property path.

## Concurrency and execution limit

Each runtime owns one `JSContext` confined to a dedicated serial dispatch queue; `JSContext` and every `JSValue` remain
on that executor. Promise `then`/rejection callbacks converge on a lock-protected checked continuation gate, so network,
timeout, and script completion can resume Swift exactly once. The exported `JSContextGroupSetExecutionTimeLimit` symbol
has no declaration in the public macOS JavaScriptCore headers, so the prototype does not bind that private SPI.

Instead, a 20-second wall-clock watchdog fails the refresh and discards the poisoned worker; the next refresh creates a
new context on a fresh executor, which the hung-script recovery test proves. This keeps refresh callers responsive but
cannot interrupt the abandoned JavaScriptCore thread, which may remain alive until process exit. A production plugin
runtime needs a public interrupt API or a killable helper-process boundary before accepting untrusted scripts.

## Current limitations

The runtime is macOS-only and compiled out when JavaScriptCore is unavailable. It supports bundled first-party IDs and
the generic snapshot and declarative details only: no runtime identities, user-installed files, install UI,
TypeScript/Sucrase, provider-specific Swift payloads, cookies, OAuth/refresh broker, local files or databases,
subprocesses, POST bodies, PTY, WebView,
binary/protobuf responses, localhost HTTP, or dynamic endpoint origins. See
[`plugin-conversion-matrix.md`](plugin-conversion-matrix.md) for the provider-by-provider impact.

## Future work

Migrating existing Swift providers' roughly 25 bespoke `UsageSnapshot` payload fields onto the details model is
intentionally not part of this prototype slice. Those fields and their current views remain intact for the flag-off
path and for providers not yet converted.
