# GraphQL API

```sh
curl http://127.0.0.1:8171/graphql -H 'Content-Type: application/json' \
  --data '{"query":"{ lists(limit: 10) { totalCount items { id name } pageInfo { hasNextPage } } }"}'
```

The [schema](reminders.graphql) documents every type, field, argument, and
validation rule; live introspection is authoritative.

All fields in one request observe the same data, and a failed read fails every
field that needs it. Root mutations run serially, later fields observe earlier
writes, and a rejected mutation changes nothing.

## Errors and partial saves

Every error carries a code in `extensions.code`; [SERVER.md](SERVER.md#errors)
lists the codes.

`flagged`, `remindMeDate`, and `emblem` apply through Reminders automation after
the EventKit save, so a write can partly succeed:

| Outcome | Response | Client action |
| --- | --- | --- |
| Automation fails after the save | Null result, `WRITE_APPLIED` error naming the saved ID | Inspect that ID and apply only what is missing; never repeat a create automatically. |
| A response field fails after the save | Selected fields such as `id` remain; the failed field is null with an error | Always select `id` and keep it even when `errors` is present. |
| Navigation fails after showing | `SHOW_APPLIED`, or `SHOW_FAILED` if it may have changed the UI | Treat the UI as possibly changed. |
| Timeout or lost connection | No confirmed outcome | Check existing data before retrying a create. |

There is no transaction across EventKit and automation, no rollback, and no
idempotency key. Saved IDs appear only in error messages.
