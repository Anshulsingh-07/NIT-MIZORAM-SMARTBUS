

## Backend Source

This directory contains the canonical Express/PostgreSQL backend. From the repository root, use `npm start`, `npm test`, `npm run db:migrate:local`, and `npm run db:seed:local` as documented in the root [README](../README.md).

Local secrets belong in the ignored `.env.local` file. Do not use `.env` for local database commands; it may contain unrelated connection details. No caretaker password is stored in source code.

The deployment templates are preparation-only. No cloud URL, project, or service is configured here.
