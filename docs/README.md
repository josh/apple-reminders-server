# Documentation

## Service

- [Server](SERVER.md): build, startup options, permissions, HTTP behavior, and limits.
- [GraphQL reads](READ_API.md) and [schema](reminders.graphql): current query surface.
- [MCP API](MCP.md) and [tool catalog](mcp-tools.json): current tool interface.
- [Writes](WRITES.md): reminder/list mutations, validation, and partial-save errors.
- [Metrics](METRICS.md) and [exposition example](metrics.prom): EventKit-only counts and background collection.

Live introspection and MCP discovery describe the running version. The reference
files retain field documentation; behavioral restrictions are in the API guides.

## Data-access references

- [Data access](DATA_ACCESS.md): in-process execution, records, and threading.
- [EventKit](EVENTKIT.md): public framework APIs relevant to reads and writes.
- [Reminders automation](APPLESCRIPT.md): flags, metadata, mutations, and identity matching.
- [Scripting dictionary](Reminders.sdef): declarations used by the automation
  integration. It contains terminology, not personal reminder data, and
  references an external Cocoa Standard suite that is not expanded.

Regenerate the dictionary on the target Mac with:

```sh
/usr/bin/sdef /System/Applications/Reminders.app >docs/Reminders.sdef
```

Declarations alone do not establish provider support or runtime behavior.

Regenerate the MCP tool catalog after changing a tool with:

```sh
swift run apple-reminders-server --dump-mcp-tools >docs/mcp-tools.json
prettier --write docs/mcp-tools.json
```
