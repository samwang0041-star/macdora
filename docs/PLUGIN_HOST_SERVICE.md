# Host Service Plugins

`host_service` is an optional host-side plugin driver. It starts one signed
executable shipped inside the plugin package. The service owns its business
logic and, when needed, its own guest login/session checks; the Mac host does
not infer login state from the active Android package.

## Manifest

Schema version remains `1`. The host SDK is `0.2.0`; packages that declare an
older minimum host version remain compatible.

```json
{
  "schemaVersion": 1,
  "id": "dev.example.host-service",
  "name": "Example host service",
  "version": "1.0.0",
  "minHostVersion": "0.2.0",
  "capabilities": ["host.service"],
  "driverType": "host_service",
  "entrypoints": {
    "hostService": "bin/service"
  }
}
```

The complete manifest must still provide the fields required by the existing
plugin schema. `entrypoints.hostService` is optional for other drivers and is
included in signed package path validation. It is not a guest-shell hook.
The host launches the executable without extra arguments.

`host_service` requires:

- the `host.service` capability;
- `entrypoints.hostService`, relative to the plugin package;
- an executable owned by the current user with no group/other write bits;
- a valid code signature for that executable.

The executable is checked again before launch and before health acceptance.
Its package contents are never modified at runtime.

## Environment

The process receives only these plugin-specific variables:

- `MACDORA_PLUGIN_ID`
- `MACDORA_PLUGIN_BUNDLE_DIR`
- `MACDORA_PLUGIN_STATE_DIR`
- `MACDORA_PLUGIN_SOCKET_PATH`
- `MACDORA_PLUGIN_INSTANCE_ID`
- `MACDORA_HOST_PID`

Ambient credentials and the host process environment are not copied. When the
manifest also declares `guest.shell`, the host may add the controlled guest
access variables:

- `MACDORA_ADB_PATH`
- `MACDORA_ADB_SERIAL`
- `ANDROID_ADB_SERVER_PORT`
- `ADB_SERVER_SOCKET`

## Runtime files

State lives below the runtime root, never in the signed package:

```text
private/plugin-state/<plugin-id>/
private/run/macdora-<short-hash>.sock
```

The plugin state directory and its parents are owner-only directories. The
socket is `0600`. If the normal socket path would exceed the macOS Unix-socket
limit, the host uses `/tmp/macdora-<uid>/macdora-<short-hash>.sock` with the
same owner/mode checks.

The temporary parent is validated through its resolved filesystem location,
so on macOS the owner/mode checks apply to `/private/tmp/macdora-<uid>` while
the socket path remains stable at `/tmp/macdora-<uid>/...`.

The service writes `endpoint.json` atomically with mode `0600`:

```json
{
  "schemaVersion": 1,
  "pluginId": "dev.example.host-service",
  "instanceId": "UUID",
  "pid": 1234,
  "socketPath": "/path/to/macdora-....sock",
  "protocol": "json-rpc-2.0"
}
```

`pid` identifies the hosting Mac app process, not the service process.

## Health handshake

Within five seconds the host requires the launched process handle to still be
running, the endpoint to match this launch, and a secure Unix socket. It then
sends one JSON line:

```json
{"jsonrpc":"2.0","id":123,"method":"macdora.ping","params":{"instanceId":"UUID"}}
```

The service must reply with one JSON line (maximum 4 KiB):

```json
{"jsonrpc":"2.0","id":123,"result":{"pluginId":"dev.example.host-service","instanceId":"UUID","ready":true}}
```

Health I/O runs off the main thread with bounded timeouts. Process stdout and
stderr are drained, but are not included in health or diagnostic UI text.

## Service responsibilities

- Hold a `flock`-based single-instance lock in `MACDORA_PLUGIN_STATE_DIR`.
- Monitor `getppid()` and exit when the Mac host disappears.
- Listen only on `MACDORA_PLUGIN_SOCKET_PATH`.
- Write and remove only its own endpoint/socket files.
- Treat endpoint files and stale locks as ownership hints, never as authority
  to terminate an arbitrary PID or executable path.
- The host passes no shell commands, ambient paths, extra arguments, or
  credentials beyond the documented environment.

The host only terminates handles obtained from `ProcessRunner.launch` and
tracked by its in-process owner registry. A new process must wait until any
previous owned handle has stopped. Deleting or switching drivers removes only
that plugin's private state; a new instance's endpoint is never removed.
No owned handle plus a live or unverifiable socket is treated conservatively:
cleanup and driver switching wait for cooperative service exit rather than
deleting or reusing files that may belong to another live instance.

Stopping the Android runtime stops the owned service but preserves the
plugin's enabled intent. Disable, delete, retire, and update stop the owned
handle first. If termination cannot be confirmed, the operation is blocked
and ownership is retained for retry.
