# Agents

- Live writes must stay within the user's authorized test scope. Use explicit IDs, modify only disposable test data, and delete it afterward with verified cleanup. Never use the default list implicitly in a test.
- Prefer existing dependencies. Do not add permanent unit/integration tests unless requested.

Regenerate the GraphQL schema and MCP tool catalog after changing either:

```sh
swift run apple-reminders-server --dump-graphql-schema >docs/reminders.graphql
swift run apple-reminders-server --dump-mcp-tools >docs/mcp-tools.json
prettier --write docs/reminders.graphql docs/mcp-tools.json
```
