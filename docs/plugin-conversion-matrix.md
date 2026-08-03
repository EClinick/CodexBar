---
summary: "All-provider conversion matrix for the bundled JavaScriptCore prototype capability set."
read_when:
  - Choosing another provider to convert to JavaScript
  - Planning the next plugin host capability
---

# Provider plugin conversion matrix

This matrix evaluates all 67 providers in the 2026-08-02 capability audit against the prototype documented in
[`plugin-prototype.md`](plugin-prototype.md). The current checkout has 66 `UsageProvider` cases; Notion is retained here
because it is the 67th audited provider explicitly requested by this work order. Each provider has one primary blocker.

`convertible-now` means the canonical first-party flow is GET-only, uses a fixed HTTPS origin and header secret, and fits
the generic snapshot. Optional canonical-origin endpoint overrides do not change that bucket; providers whose identity
is inherently a user-chosen origin (LLM Proxy and LiteLLM) do not qualify. The convertible rows were checked against the
current Swift request methods and snapshot projections; Azure OpenAI, StepFun, and Warp were removed from the audit's
earlier “fully expressible” baseline because their current implementations issue POST requests.

`convertible-now (details)` means the bundled JavaScript conversion is present behind `CODEXBAR_JS_PROVIDERS=1` and its
provider-specific dashboard projection is expressed through declarative detail sections. `needs-plugin-host-extension`
marks providers uncovered during implementation whose canonical flow needs a runtime primitive beyond declared-origin
GET, declared settings/secrets, and details.

## Totals

| Status | Count |
|---|---:|
| `convertible-now` | 11 |
| `convertible-now (details)` | 5 |
| `needs-details-model` | 0 |
| `needs-plugin-host-extension` | 3 |
| `needs-cookie-import` | 23 |
| `needs-files/subprocess/oauth-broker` | 15 |
| `needs-pty/webview/native` | 10 |
| **Total** | **67** |

## Matrix

| Provider | Status | Reason |
|---|---|---|
| codex | `needs-pty/webview/native` | PTY CLI, OAuth files/refresh, browser cookies, WKWebView scraping, local logs, and reset-credit details exceed this host. |
| openai | `convertible-now (details)` | Converted: fixed-origin bearer GET pagination with daily spend, model, line-item, and token details. |
| azureopenai | `needs-pty/webview/native` | The current quota probe is a POST chat completion against a user-configured deployment origin. |
| claude | `needs-files/subprocess/oauth-broker` | Full parity needs credential files/Keychain, OAuth refresh, CLI/PTY, cookies, local logs, and admin details. |
| clinepass | `convertible-now` | Verified fixed-origin bearer GET; limits and identity map to generic windows. |
| cursor | `needs-cookie-import` | Browser cookies/app database provide auth, and integer request history also has bespoke detail. |
| opencode | `needs-cookie-import` | React server-function usage requires imported browser cookies and non-JSON text parsing. |
| opencodego | `needs-files/subprocess/oauth-broker` | Local auth/SQLite state and browser sessions are required, with an additional bespoke usage model. |
| alibaba | `needs-cookie-import` | The console path needs imported cookies, CSRF/sec-token discovery, redirects, and embedded response parsing. |
| alibabatokenplan | `needs-cookie-import` | Full parity depends on Aliyun console cookies, CSRF/sec-token acquisition, and several dependent calls. |
| qwencloud | `needs-cookie-import` | OneConsole usage needs imported cookies, CSRF, form POSTs, and redirect-aware routing. |
| factory | `needs-cookie-import` | WorkOS/browser cookies and local storage recover the session; the API-key-only path is merely partial. |
| gemini | `needs-files/subprocess/oauth-broker` | Gemini CLI credential/config files, Google OAuth refresh, and a curl fallback own the current flow. |
| antigravity | `needs-pty/webview/native` | Process/port discovery, localhost IDE RPC, OAuth files, and a persistent PTY make this a native integration. |
| copilot | `needs-cookie-import` | API-token usage fits, but billing budgets require GitHub cookies/nonces and the device flow needs POST. |
| devin | `needs-files/subprocess/oauth-broker` | Full auth discovery reads Chromium localStorage and organization state; manual bearer alone is partial. |
| zai | `convertible-now (details)` | Converted: both fixed regional origins, personal/team settings, quota lanes, model totals, and hourly/daily token charts. |
| minimax | `needs-cookie-import` | Browser cookies/storage and group discovery feed a large service/billing/history-specific payload. |
| manus | `needs-cookie-import` | Full session acquisition imports browser cookies; a manually supplied bearer covers only one path. |
| kimi | `needs-cookie-import` | Browser cookies plus Kimi credential/device files and regional identity headers exceed the current broker. |
| kilo | `needs-files/subprocess/oauth-broker` | The default source reads Kilo's local auth file and organization metadata. |
| kiro | `needs-pty/webview/native` | Usage exists only through bounded CLI pipe/PTY automation and a bespoke credit/overage model. |
| vertexai | `needs-files/subprocess/oauth-broker` | ADC/gcloud files, OAuth refresh, optional subprocess fallback, and local cost logs are required. |
| augment | `needs-files/subprocess/oauth-broker` | The preferred strategy spawns `auggie`; the alternative imports browser cookies and maintains sessions. |
| jetbrains | `needs-pty/webview/native` | There is no HTTP strategy; native IDE discovery and local XML parsing are the provider. |
| moonshot | `convertible-now` | Verified bearer GET against two fixed regional origins; balances project into generic windows. |
| amp | `needs-files/subprocess/oauth-broker` | CLI subprocess and browser-cookie strategies plus workspace credit details are outside this host. |
| t3chat | `needs-cookie-import` | Usage is authenticated by an imported browser session cookie. |
| ollama | `needs-cookie-import` | The full hosted flow imports cookies and scrapes HTML; the API-key model-count probe is only partial. |
| synthetic | `convertible-now` | Converted: fixed-origin bearer GET with generic windows, cost, dates, and identity. |
| warp | `needs-pty/webview/native` | Warp sends a POST GraphQL operation, which the GET-only HTTP broker cannot express. |
| openrouter | `convertible-now (details)` | Converted: bearer GET credits plus best-effort key budget, period spend, rate-limit rows, and a spend chart. |
| elevenlabs | `convertible-now` | Verified `xi-api-key` GET; heterogeneous character/minute quotas map to named generic windows. |
| windsurf | `needs-files/subprocess/oauth-broker` | Chromium localStorage, IDE databases, and binary protobuf decoding supply the current session. |
| zed | `needs-files/subprocess/oauth-broker` | Zed server settings and a named Keychain credential must be read locally. |
| perplexity | `needs-cookie-import` | The provider imports a browser session before mapping multiple credit buckets. |
| mimo | `needs-cookie-import` | Browser/Firefox session import and a local cache feed balance, plan, and token-specific details. |
| doubao | `needs-files/subprocess/oauth-broker` | Full parity needs a CLI subprocess or Volcengine HMAC signing and POST-based plan calls. |
| sakana | `needs-cookie-import` | The web flow needs a cookie session; PAYG balance/period data also needs a detail model. |
| abacus | `needs-cookie-import` | Required compute and optional billing calls are authenticated through imported browser cookies. |
| mistral | `needs-cookie-import` | Console cookies/CSRF gate wallet, credit-note, and model-history details. |
| deepseek | `needs-files/subprocess/oauth-broker` | Platform auth/profile selection reads Chromium localStorage, and the result has a bespoke history model. |
| deepinfra | `convertible-now` | Verified fixed-origin bearer GET pair; spend limit and balance project into generic cost/windows. |
| codebuff | `needs-files/subprocess/oauth-broker` | Full credential parity reads a local Manicode credential file; environment-key mode is partial. |
| crof | `convertible-now` | Converted: fixed-origin bearer GET with exact credit formatting and America/Chicago daily reset. |
| venice | `convertible-now` | Converted: fixed-origin bearer GET with DIEM/USD allocation projection. |
| commandcode | `needs-cookie-import` | Browser cookies authenticate both calls, and three live subscription/depletion flags need details. |
| qoder | `needs-cookie-import` | Global/China session selection imports cookies and sends a bespoke browser header. |
| stepfun | `needs-files/subprocess/oauth-broker` | Device registration, password login, refresh, quota, and plan operations are POST-based token-broker work. |
| bedrock | `needs-files/subprocess/oauth-broker` | AWS profiles/CLI credentials, SigV4 signing, pagination, and two services need host-owned credential/signing APIs. |
| grok | `needs-pty/webview/native` | Persistent stdio JSON-RPC, auth/session files, cookies, logs, and binary gRPC-web are strongly native. |
| groq | `needs-cookie-import` | The API-token Prometheus path is partial; console parity imports Stytch/browser sessions and history details. |
| llmproxy | `needs-pty/webview/native` | Its origin is user-selected and may be private HTTP, conflicting with the manifest's fixed HTTPS origins. |
| litellm | `needs-pty/webview/native` | Its required user-selected proxy origin and optional private HTTP cannot be declared by a bundled static manifest. |
| deepgram | `needs-plugin-host-extension` | Skipped: Deepgram requires `Authorization: Token <key>`; the prototype can inject bearer or a raw custom-header value but cannot prefix a custom auth scheme. |
| poe | `convertible-now (details)` | Converted: fixed-origin bearer GET balance/history pagination with daily points and model/type summaries. |
| chutes | `convertible-now` | Verified bearer GET fan-out on the canonical origin; dynamic quota lanes map to named windows. |
| neuralwatt | `convertible-now` | Verified canonical bearer GET; quota lanes and prepaid cost/energy project generically. |
| clawrouter | `convertible-now (details)` | Converted for the canonical origin: monthly budget, ledger, request/token totals, routed-provider rows, and cost chart. |
| longcat | `needs-cookie-import` | Account, token use, and pending fuel merge behind an imported browser/manual cookie session. |
| sub2api | `needs-plugin-host-extension` | Skipped: every instance requires a user-selected origin and may use loopback HTTP; bundled manifests allow only predeclared HTTPS origins. |
| wayfinder | `needs-pty/webview/native` | The local unauthenticated HTTP gateway, metrics text, and routing/savings model violate HTTPS-only generic scope. |
| zenmux | `convertible-now` | Verified fixed-origin bearer GET pair; subscription and optional PAYG balance map generically. |
| aiand | `convertible-now` | Verified fixed-origin bearer GET pagination; 30-day spend maps to generic cost. |
| zoommate | `needs-cookie-import` | Host-specific cookies are exchanged for a JWT, then paginated credit history requires details. |
| xai | `needs-plugin-host-extension` | Skipped: prepaid balance is GET, but canonical daily usage history is a POST request with a JSON body. |
| notion | `needs-cookie-import` | Workspace selection and AI allowance calls require imported Notion cookies and forwarded session headers. |
