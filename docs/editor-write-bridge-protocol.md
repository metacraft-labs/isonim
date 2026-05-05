# IsoNim Editor Write Bridge Protocol

M48 defines the local write bridge as a versioned contract between the generic
IsoNim editor client and a consumer-owned bridge service.

IsoNim owns the client state model, source-edit transaction semantics, release
gate evidence, and protocol documentation. Consumer projects own concrete
workspace roots, allowlists, local trust policy, process launch, logging, and
project-specific patch adapters.

## Version

Current protocol version: `isonim.write-bridge.v1`.

Every JSON response includes:

- `protocolVersion`: protocol identifier.
- `revision`: monotonically increasing consumer workspace revision.
- `ok`: request success.
- `diagnostics`: structured diagnostics for rejected or degraded requests.

## Capabilities

The bridge advertises capabilities from `/__isonim-dev-bridge/status` and
`/__isonim-dev-bridge/health`:

- `status`
- `read`
- `dry-run`
- `apply`
- `save`
- `revert`
- `conflict-detection`
- `atomic-write`
- `rollback`
- `path-allowlist`
- `symlink-denial`
- `structured-logs`

The IsoNim client treats unknown or missing capabilities as degraded. It does
not infer consumer paths or policies.

## Endpoints

`GET /__isonim-dev-bridge/health`

Returns bridge health, mode, version, revision, and capability list.

`POST /__isonim-dev-bridge/status`

Returns version, mode, configured write status, owned file allowlist, revision,
maximum file size, transaction-in-flight flag, and capabilities.

`POST /__isonim-dev-bridge/read`

Request:

```json
{ "file": "consumer/owned/file.nim" }
```

Response includes `content`, `hash`, and `revision`.

`POST /__isonim-dev-bridge/transaction`

Request:

```json
{
  "mode": "dry-run",
  "baseRevision": 12,
  "files": [
    {
      "file": "consumer/owned/file.nim",
      "beforeText": "old",
      "afterText": "new",
      "baseHash": "optional sha256"
    }
  ]
}
```

`mode` is one of `dry-run`, `apply`, `save`, or `revert`. `baseRevision` is
optional but recommended. If it is stale, the bridge returns a conflict instead
of overwriting the file.

## Failure Semantics

The bridge must reject malformed JSON, unsupported modes, unknown files,
absolute paths, `..` traversal, symlink-owned files, files outside the real
workspace root, oversized reads/writes, stale revisions, concurrent
transactions, and external hash conflicts.

File writes must be atomic per file. Multi-file transactions must roll back
earlier writes when a later write fails. Conflict responses include
`choices: ["preserve", "reload", "revert"]` so the UI can present recovery
actions without overwriting external changes.

## Client States

IsoNim models bridge availability as:

- `offline`
- `connecting`
- `degraded`
- `read-only`
- `staged`
- `writable`
- `saving`
- `conflict`
- `failed`
- `recovered`

These are generic framework states. Concrete health checks, allowlists, logs,
and workspace paths remain consumer-owned.

## Non-Goals

M48 does not implement remote multi-user collaboration, network authentication,
cloud storage synchronization, or consumer-agnostic project path discovery.
Those require separate product and security designs.
