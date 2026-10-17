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
- [Scripting dictionary](Reminders.sdef) and [dictionary summary](reminders-dictionary.json):
  declarations used by the automation integration. These contain terminology,
  not personal reminder data. The XML references an external Cocoa Standard
  suite that is not expanded in the JSON summary.

Regenerate the dictionary on the target Mac with:

```sh
/usr/bin/sdef /System/Applications/Reminders.app > docs/Reminders.sdef
```

Update the JSON summary when changing the dictionary reference. Declarations
alone do not establish provider support or runtime behavior.
