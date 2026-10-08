# Project conventions

- Use explicit startup options for configuration; do not add environment-variable configuration.
- Keep EventKit and AppleScript access in the server process. Mutations must honor native authorization and editability; do not turn test restrictions into product allowlists.
- Live writes must stay within the user's authorized test scope. Use explicit IDs, modify only disposable test data, and delete it afterward with verified cleanup. Never use the default list implicitly in a test.
- Prefer existing dependencies. Do not add permanent unit/integration tests unless requested.

Build with `swift build` (or `swift build -c release`). The executable is `reminders-swift`.
