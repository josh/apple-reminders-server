# Documentation

- [Server](SERVER.md): launchd, sockets, configuration, and errors.
- [GraphQL](GRAPHQL.md) · [Schema](reminders.graphql)
- [MCP](MCP.md) · [Tool catalog](mcp-tools.json)
- [Metrics](METRICS.md) · [Example](metrics.prom)
- [EventKit](EVENTKIT.md): ownership, reads, dates, recurrence, and writes.
- [AppleScript](APPLESCRIPT.md): identity checks, verification, and retries.
- [Reminders scripting dictionary](Reminders.sdef)

The schema and catalog are exports; live introspection and MCP discovery describe
the running version. The scripting dictionary contains declarations, not personal
data or proof of runtime behavior or provider support. Its external Cocoa Standard suite is not expanded.

Refresh the scripting dictionary on the target Mac:

```sh
/usr/bin/sdef /System/Applications/Reminders.app >docs/Reminders.sdef
```
