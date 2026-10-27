# Agent Plugin Host

Macdora can host a public, read-only Agent entry from a signed plugin. Agent
support is opt-in: a `host_service` package becomes an Agent package only when
its manifest contains both `host.service` and `agent.readonly`.

## Manifest

Schema version remains `1`; older manifests without Agent fields continue to
load unchanged.

```json
{
  "schemaVersion": 1,
  "id": "dev.example.readonly-agent",
  "name": "Read-only Agent example",
  "subtitle": "Neutral example",
  "version": "1.0.0",
  "author": "Example publisher",
  "category": "Example",
  "iconSymbol": "person.crop.circle.badge.checkmark",
  "accentHex": 7965290,
  "minHostVersion": "0.2.0",
  "capabilities": ["host.service", "agent.readonly"],
  "driverType": "host_service",
  "entrypoints": {
    "hostService": "bin/service",
    "agentMCP": "bin/agent-mcp"
  }
}
```

`agentMCP` is a package-relative executable MCP stdio entry. It is covered by
the same package signature and executable-code validation as `hostService`.
Absolute paths, traversal, hidden path components and symlinks are rejected.
An `agentMCP` without `agent.readonly`, or `agent.readonly` without a valid
`agentMCP`, is rejected.

Agent packages can also declare two optional, signed manifest fields:

```json
{
  "agentSummary": "Read-only checks; no business writes",
  "agentInstructions": "Configure the accompanying MCP entry. Discover tools, verify status, then follow this plugin's workflow."
}
```

`agentSummary` supplies the compact permission/capability text in the workspace;
`agentInstructions` supplies the provider's Agent onboarding and usage knowledge.
They require `host_service` and `agent.readonly`, are nonempty, reject control
characters other than whitespace, and are limited to 240 and 16,384 UTF-8 bytes
respectively. The package signature covers both fields. Older manifests omit
them and keep generic read-only text and MCP discovery guidance.

Provider commands, preparation policy, error recovery and business examples
belong in the plugin. Macdora does not interpret that knowledge, install a
second backend, or implement provider-specific Agent workflows.

## User-controlled state

The persistent handoff state is stored outside the signed package:

```text
private/agent-control/<plugin-id>.json
```

The control directory and file are owner-only (`0700` / `0600`). Reads and
writes use a locked control file, reject symlinks, hard links, wrong owners
and wrong modes, and replace the JSON atomically. A malformed or empty file at
a safe path may be repaired only by an explicit manual withdrawal (or initial
manual default); grant never proceeds from a malformed record. The JSON schema
is:

```json
{
  "schemaVersion": 1,
  "pluginId": "dev.example.readonly-agent",
  "generation": "lowercase UUID",
  "manual": true
}
```

`manual` defaults to `true` and means effective manual control: if there is no
live in-memory grant, the value is `true`, including after restart or a failed
cancelled grant. Every explicit grant or revoke writes a new lowercase
generation before the control RPC is attempted. A grant that is not confirmed
is compensated by a generation-CAS write back to `manual=true`; the CAS
preserves the pending generation and never overwrites a newer explicit action.
Internal compensation does not create a generation. A revoke writes
`manual=true` before the RPC and remains effective offline; an unavailable
service does not undo it. The host never writes Agent control files through
symlinks and never grants Agent control merely because a status reply says
`ready`.

Only packages with `agent.readonly` receive
`MACDORA_AGENT_CONTROL_PATH` in the service environment.

## Control RPC

The host rechecks its owned process, exact `endpoint.json`, socket owner/mode
and signed service/Agent entry before each request. The executable snapshots
are also revalidated when health is accepted, when configuration is exported
and immediately before a grant is persisted. Requests run off the main thread
with bounded time and a bounded response size. The Unix socket is configured
with `SO_NOSIGPIPE`; a peer disconnect returns a fixed failure and must not
terminate the Mac host.

Every request uses `params.instanceId`. `instanceId` keeps the host/endpoint
UUID casing. `generation` and the opaque `consumerId` are lowercase UUID
strings on the wire, matching Python `str(uuid.UUID(...))`; an uppercase
consumer ID is rejected rather than normalized. The supported methods are:

- `macdora.agent.status`
- `macdora.agent.prepare` (user-initiated read-only directory self-check)
- `macdora.agent.grant` with `generation` and the opaque `consumerId` from status
- `macdora.agent.revoke` with `generation`

`status` is a zero-business read. `prepare` is an explicit, bounded read-only
self-check whose business meaning belongs to the plugin; it does not retry
business work. The worker must verify that the Unix-socket peer
PID equals the host PID; clients do not carry a shared secret.

A first launch of a freshly packaged Python Agent can take much longer than a
warm launch; the measured delay has not been causally attributed. For a package
that explicitly declares both `agent.readonly` and a valid `agentMCP`, the host
allows a bounded 35-second startup-health window (the non-Agent window remains
5 seconds). This waits only for the fixed `macdora.ping` health response; it
does not retry business operations, restart the process, or infer readiness
from a signature alone. Disable/cancellation aborts the wait immediately, and
a late probe success cannot resurrect a cancelled instance.

The successful result shape is:

```json
{
  "schemaVersion": 1,
  "pluginId": "dev.example.readonly-agent",
  "instanceId": "host UUID",
  "state": "ready",
  "agentConnected": true,
  "businessReady": true,
  "taskRunning": false,
  "manual": true,
  "consumerId": "lowercase UUID",
  "errorCode": "businessNotReady",
  "lastSuccessAt": "2026-10-27T10:00:00.000000+00:00"
}
```

`state` is one of `waitingForAgent`, `waitingForApproval`,
`waitingForLogin`, `ready`, `running`, `recovering`, `needsAttention`, or
`manual`. `consumerId`, `errorCode` and `lastSuccessAt` are optional.
`errorCode` must be a fixed value from the host control contract; raw error text
must not be exposed to the UI. Fixed server errors use JSON-RPC
`code=-32000` with `data.errorCode`; the fixed `busy` value is classified
separately. The host does not treat every JSON-RPC error as an invalid
response.

Providers map their internal failures to the host's fixed categories:
`agentNotConnected`, `consumerUnavailable`, `businessNotReady`,
`approvalRequired`, `loginRequired`, `recoveryRequired`, `manualMode`,
`invalidRequest`, `permissionDenied`, or `internalFailure`. Error replies may
also use `busy`. Provider-specific diagnostic fields do not drive host UI.

Strict type, schema, plugin, instance and unknown-state checks apply. A late
response from an older page load, generation or another plugin instance cannot
replace the current page state. Refresh reuses one Agent view only for the same
host plugin instance; a hot-reloaded same-ID package gets a new plugin/view
identity and cannot keep rendering the retired instance.

## Grant and revoke

The workspace exposes one short primary action driven by real state, error,
connection and permission data:

- **交给 Agent** requires a status response with `consumerId`,
  `businessReady == true`, a successful business self-check, and the explicit
  user action. It first saves `manual=false`, then sends `grant`. If grant is
  not confirmed, generation-CAS restores `manual=true` without replacing a
  newer explicit action.
- **我来操作** saves `manual=true` before attempting `revoke`, so an offline
  revoke remains effective when the service returns. It remains available in
  loading/failed/preparing states. Switching pages does not silently revoke an
  already confirmed grant, and explicit in-flight grant/revoke is host-owned:
  late responses are gated by action token, instance and control generation.

The control file is the authority for the user's persistent intent. A service
may report effective `manual=true` after losing an in-memory grant; that pause
does not rewrite the saved intent or remove the offline withdrawal action.
Grant reserves its action before asynchronous validation and atomically checks
the previous control record before saving a new generation. Withdrawal can
supersede an in-flight grant; neither an old status response nor its rollback
can overwrite the newer generation.

The page states the actual scope in one short line: read-only counts, no
business body returned, no business writes. The onboarding sequence is:
copy the configuration, enable it in an MCP-compatible client, test the
read-only connection, then hand off. `status` readiness does not by itself
claim that login, recovery or business permission is ready; those states show
their own next action.

Status RPC success is not evidence that the connector's protected application
session or business operation is ready. This public host code does not open
external network connections, invoke a model, log in, start another runtime,
change keep-awake policy or request input permissions.

## Configuration export

The page can copy a standard `mcpServers` document only after revalidating the
current instance, service and valid signed Agent snapshot. It contains only
the plugin's stable `agentMCP` command and the current instance's
`endpoint.json` argument. It does not contain runtime credentials, tokens,
cookies, process IDs, hashes or environment dumps. A tampered or retired
snapshot cannot produce executable configuration.

```json
{
  "mcpServers": {
    "dev.example.readonly-agent": {
      "command": "/path/to/plugin/bin/agent-mcp",
      "args": [
        "--endpoint",
        "/path/to/private/plugin-state/dev.example.readonly-agent/endpoint.json"
      ]
    }
  }
}
```

The default workspace action is **复制给 Agent**. It copies a self-contained
handoff containing the plugin's instructions and this structured JSON. The
Agent uses its client's supported configuration mechanism, preserves existing
servers, discovers tools and reports configuration, connection, business and
authorization states separately. Programs and arguments remain JSON fields;
the host does not turn package text or paths into a shell command.

The copy action retains the same current-instance and executable-snapshot
checks as raw configuration export. It never grants authorization. Macdora
does not modify another application's configuration, and this repository does
not claim interoperability with an untested client. Provider-specific setup
commands and Skill material can ship inside the signed plugin without adding
provider logic to the host.

## Validation boundary

The focused Swift tests use neutral fixture packages and synthetic endpoints.
They cover opt-in registration, legacy compatibility, unsafe Agent paths,
persistent manual state, offline/failed revoke, malformed-control repair,
hardlink/symlink/mode rejection, lowercase cross-language wire fixtures,
generation CAS and late actions, instance/type mismatch, real Unix peer close,
tamper fail-closed export/grant, hot-reload identity, 35-second Agent startup
cancel/no-resurrection, secret-free configuration export and bounded response
gates. Set `MACDORA_AGENT_QA_SNAPSHOTS` to export neutral native AppKit state
screenshots (waitingForAgent, managed ready, manual, needsLogin,
failed-revocable, wide/narrow) and exercise button accessibility/keyboard
activation. The test captures only its own `NSView`/test `NSWindow`; it never
captures the desktop or office content. This round did not install or start
Macdora, enable a real plugin, use ADB or a private connector, or verify a
production business flow.

For a locally built development bundle, set
`MACDORA_AGENT_DEVELOPMENT_BUNDLE=/path/to/bundle` and run
`swift test --filter AgentHostServiceTests`. The optional artifact test calls
the actual package verifier with the existing local developer trust policy;
it checks the complete file ledger, executable signatures, host compatibility
and package limits without importing, enabling or running the plugin. A local
integrity seal does not establish a publisher identity or authorize publishing.
