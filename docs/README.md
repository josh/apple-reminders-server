# Documentation

## Interfaces

- [Server](SERVER.md): startup options, permissions, HTTP behavior, and limits.
- [GraphQL API](GRAPHQL.md) and [schema](reminders.graphql): queries, mutations, validation, and partial-save errors.
- [MCP API](MCP.md) and [tool catalog](mcp-tools.json): current tool interface.
- [Metrics](METRICS.md) and [exposition example](metrics.prom): EventKit-only counts and background collection.

Live introspection and MCP discovery describe the running version.

## Platform references

- [EventKit](EVENTKIT.md): public framework behavior for reading and writing reminders.
- [Reminders automation](APPLESCRIPT.md): scripting-only properties and identifier matching.
- [Scripting dictionary](Reminders.sdef): Reminders' scripting declarations. It
  contains terminology, not personal reminder data, and references an external
  Cocoa Standard suite that is not expanded.

Regenerate the dictionary on the target Mac with:

```sh
/usr/bin/sdef /System/Applications/Reminders.app >docs/Reminders.sdef
```

Declarations alone do not establish provider support or runtime behavior.
