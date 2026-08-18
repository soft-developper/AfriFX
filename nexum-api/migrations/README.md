# Database migrations

Every schema change goes in this folder. Nothing gets pasted into the Turso
shell by hand any more.

## Commands

```bash
npm run migrate            # apply all pending migrations
npm run migrate:status     # what's applied, what's pending, what's been edited
npm run migrate:mark 0001  # record as applied WITHOUT running (see below)
```

## First run against the existing production database

Production already contains every table in `0001`–`0013`. Those migrations are
written to be safe to re-run (`IF NOT EXISTS`, and the runner skips
"duplicate column" errors), so you can simply run:

```bash
npm run migrate
```

If you'd rather not touch production schema at all, mark the baselines instead:

```bash
for v in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011 0012 0013; do
  npm run migrate:mark $v
done
```

Either way, from `0014` onward everything applies normally.

## What the baselines are

`0001`–`0003` did not exist as SQL anywhere before. The core tables came from
`drizzle-kit push`, and the admin and app tables were created by hand in the
Turso shell, which meant **a fresh database could not be built from this
repository at all**. They were reconstructed from the `INSERT` statements and
row normalizers in the route code.

`0004`–`0013` are the former loose `*-schema.sql` files from `nexum-api/`,
moved here unchanged and given an order.

## Writing a migration

1. Create `NNNN_snake_case.sql` with the next free number.
2. Write plain SQL. Multiple statements are fine — the runner splits on `;`
   and executes them one at a time, because libSQL aborts a multi-statement
   string at the first error and would leave you half-migrated.
3. Prefer `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`.
4. `ALTER TABLE ... ADD COLUMN` has no `IF NOT EXISTS` in SQLite. Write it
   plainly — the runner treats "duplicate column name" as already-applied.
5. Run `npm run migrate` locally, then commit the file.

## Rules

- **Append-only.** Never edit a migration that has already run. Write a new
  one. `migrate:status` flags edited files as `EDITED!` by checksum.
- **One concern per migration.** Easier to review, easier to reason about when
  something fails halfway.
- **No `drizzle-kit push`.** `src/db/schema.ts` describes only 5 of roughly 29
  real tables, so a push would offer to drop the other 24. The `db:push`
  script is deliberately disabled.

## Note on `src/db/schema.ts`

The drizzle schema is badly out of date and is **not** the source of truth for
this database — these migration files are. The schema file is only used for
typing on the handful of tables it does define. Don't run schema-sync tools
against it.
