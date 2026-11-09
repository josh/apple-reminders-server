# GraphQL

`POST /graphql`. The [schema](reminders.graphql) documents types, fields, inputs,
and validation; introspection describes the running version. No subscriptions.

```sh
curl --unix-socket /path/to/server.sock http://localhost/graphql \
  -H 'Content-Type: application/json' \
  --data '{"query":"{ lists(limit: 10) { totalCount items { id name } pageInfo { hasNextPage } } }"}'
```

Send one object with `query`, optional `variables`, and optional `operationName`.
Null `variables`/`operationName` mean absent. Invalid envelopes return 400, other
methods 405. A read-only grant permits only the selected query operation; mutations,
including UI navigation, require write access. Execution errors normally use HTTP
200 with `errors`; clients must inspect the body.

## Reads and mutations

Repeated reads share results/failures within a request; unrelated fields may still
succeed. Root mutations run serially and refresh reads after attempted writes,
including failures. Later fields see earlier writes; separate requests can interleave.
See [access and sync limits](SERVER.md#limits).

Collections filter and sort before pagination. `limit` is 1–100 (default 50),
`offset` is nonnegative, and an offset beyond the end returns an empty page with
the full matching count. Pages across requests have no shared snapshot.

Nullable create/filter inputs generally treat null as absent. Top-level patch
values reject null; remove values with `clearFields`. Reject invalid changes before
saving. Later mutation failures do not undo earlier successful mutations.

An unknown flag returns null with an error and matches neither true nor false
filters. A failed flag read fails the filtered collection. Unselected optional
fields do not trigger their reads.

## Input aliases

Both APIs accept the aliases in the schema and return canonical IDs, numeric
priorities, and structured weekdays. Alias values reject null, even on creation;
supplying both forms fails even when one is null.

`listName` searches all accessible lists, including other accounts and read-only
lists, before checking editability. No match returns `NOT_FOUND`; multiple matches
return `INVALID_ARGUMENT`. A supplied name never falls back to the default list.

List names preserve whitespace; priority names are not trimmed. Weekday phrases
use full English names and ignore surrounding/repeated whitespace. Duplicates
are checked after normalization; structured recurrence constraints still apply.

## Errors

[Error codes](SERVER.md#errors) appear in `extensions.code`. Select `id` in
mutation responses and retain it even when other fields return errors.
A failed response field can be null after a successful save; `WRITE_APPLIED`
can instead return a null mutation result with the saved ID only in the error
message. Follow the [partial-save recovery guidance](SERVER.md#errors).
Clearing completed reminders returns a count only on success; a failed batch can
have persisted deletions. Refetch the explicit list before retrying.
