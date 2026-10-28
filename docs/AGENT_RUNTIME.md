# Agent runtime acceptance

This branch carries the opt-in runtime policy described in
[OFFICE_KEEP_AWAKE.md](OFFICE_KEEP_AWAKE.md). It provides the host prerequisites
for a separately installed connector; it does not add a general Agent control
API, expose application data, or enable an Agent by itself.

## Responsibilities

- Macdora owns the selected Android environment, display, input focus and
  plugin process lifecycle. Keep-awake control appears only inside a plugin
  that explicitly declares `runtime.keep-awake`, never in global preferences.
  Its effect and recovery record belong to that canonical Android environment
  directory, and it remains off by default.
- A connector owns its application protocol, current account/session checks,
  operation permissions and business result verification. Application-specific
  connectors and their data remain outside this public source tree.
- The user's Agent owns task planning, summaries and proposed responses. A
  connector must not interpret received application content as authorization.

The existing `host_service` driver and local IPC should be reused. Its
`macdora.ping` handshake verifies a particular service instance. Business
availability must be verified by the connector and may fail even when the
service handshake succeeds. Opt-in Agent packages expose a read-only status,
prepare, grant and revoke path, persistent manual state and a generic MCP stdio
configuration export; see [AGENT_PLUGIN_HOST.md](AGENT_PLUGIN_HOST.md) and
[PLUGIN_HOST_SERVICE.md](PLUGIN_HOST_SERVICE.md).

## Acceptance order

1. Check runtime ownership, application session identity and the actual
   connector capability list without starting another environment.
2. Establish a small, explicitly bounded business operation while the window
   is visible. Check the business result and any required state invariants.
3. Repeat with the Mac window minimized, then hidden, and then with only the
   display closed. Record which window condition was actually observed.
4. Check network/session failure and operator handover. Do not return an empty
   successful result for a failed request, silently switch account or instance,
   or blindly replay an operation with an unknown outcome.
5. Check shutdown and expiry: reject new work, revoke undisclosed results,
   finish or explicitly fail verification of an in-flight operation, and
   release only owned resources. The operator must be able to resume manual
   work without an Agent immediately starting another task.

Window visibility, cached-process freezing, host App Nap, application network
availability and connector readiness are separate observations. A passing
isolated test or enabled keep-awake setting is not evidence that a minimized
business workflow succeeded. Mac sleep and an unavailable application session
remain reasons for a task to stop.

An application's internal page lifecycle is also separate from the Mac window.
A cached session or an available WebView target may outlive the page that owns
the request path. State any page prerequisite in the connector's instructions
and check it independently from minimization. Document visibility alone does
not establish server reachability.

UI fallback must bind input to the selected application window and its Android
display. The default Android display can belong to another surface. Verify the
application, display and unique navigation target before activation, then check
the resulting state. An issued window action is not evidence of minimization.
Keep transient UI content local and expose only the metadata needed for that
decision.

## Current delivery boundary

The keep-awake implementation is copied from the existing local development
branch; that branch and its uncommitted work are preserved. Local validation
does not install the host, activate a live environment, or publish a Release.
Installing or restarting the host and enabling a live runtime policy remain
separate from source and synthetic acceptance.
