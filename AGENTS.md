# Project conventions

- launchd is the only supported launcher: it owns the sockets, and the plist's environment variables are the only configuration.
- Keep EventKit and AppleScript access in the server process. Writes must honor native authorization and editability.
- Live writes must stay within the user's authorized test scope. Use explicit IDs, modify only disposable test data, and delete it afterward with verified cleanup. Never use the default list implicitly in a test.
- Prefer existing dependencies. Do not add permanent unit/integration tests unless requested.

Build with `swift build` (or `swift build -c release`). The executable is `apple-reminders-server`.

Regenerate the GraphQL schema and MCP tool catalog after changing either:

```sh
swift run apple-reminders-server --dump-graphql-schema >docs/reminders.graphql
swift run apple-reminders-server --dump-mcp-tools >docs/mcp-tools.json
prettier --write docs/reminders.graphql docs/mcp-tools.json
```
