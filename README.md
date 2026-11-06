# postgres

An async Postgres client for CeeSafe, speaking the wire protocol 3.0 directly. It is written fresh for CeeSafe,
not ported line by line, though its feature set follows CosmoSQLClient's Postgres client.

```ceesafe
import postgres.PgConfig;
import postgres.PgConnection;
import postgres.PgParams;
import postgres.PgPool;
import postgres.PgRows;

let config = PgConfig.parse("postgres://mail:secret@db.internal/mail?sslmode=verify-full")?;
var db = await PgConnection.connect(config)?;

var params = PgParams.create();
params.text("alice@example.org")?;
params.int64(10)?;
let rows = await db.query("SELECT uid, subject FROM messages WHERE owner = $1 ORDER BY uid DESC LIMIT $2", params)?;
for (r in 0..rows.rowCount()) {
    let uid = rows.int64(r, 0)!;
    let subject = rows.text(r, 1);          // null for SQL NULL
}

params.clear();
params.text("alice@example.org")?;
let deleted = await db.execute("DELETE FROM messages WHERE owner = $1 AND expunged", params)?;
await db.batch("BEGIN; UPDATE quota SET used = used - 1; COMMIT")?;
```

## What it does

- **Connecting.** `PgConfig.parse` reads URLs (`postgres://user:pass@host:port/db?sslmode=…&application_name=…`),
  libpq keyword strings (`host=… dbname=… password='a b'`), and ADO.NET strings (`Host=…;Username=…;SSL Mode=…`).
  `PgConfig.create(host, user, password, database)` builds one directly. `connect` tries every address a host
  name resolves to, in order. Build one `PgConfig` and share it: it holds the loaded TLS configuration, so
  connections do not reload the trust store.
- **TLS.** `sslmode` follows libpq:
  - `disable`, `prefer` (the default) and `require` don't check the server's certificate;
  - `verify-ca` checks the chain;
  - `verify-full` checks the chain and the host name.
  - `PgConfig.useTls(mode, tlsConfig)` takes a private CA (`trustPem`), a client certificate, or `minVersion`.
  - It is built on the `tls` package (OpenSSL 3). The SSLRequest answer is read as exactly one byte, so nothing a
    man in the middle sends before the handshake can be mistaken for protected data (CVE-2021-23222).
- **Authentication.** It supports SCRAM-SHA-256, md5 and cleartext.
  - SCRAM checks the server's final signature. A server that does not know the password cannot fake a successful
    login, and an `AuthenticationOk` before that check fails with `ServerNotAuthenticated`.
  - It caps the server-chosen PBKDF2 iteration count at 10 million.
  - It does not apply SASLprep to passwords, so passwords with unusual Unicode, such as non-ASCII spaces or
    compatibility characters, are an exception: use ASCII or ordinary UTF-8 passwords.
- **Queries.**
  - `query` and `queryInto` give rows; `execute` gives the affected-row count; `batch` runs a `;`-separated script
    with the simple protocol.
  - Values travel apart from the SQL (`$1`, `$2`, …), never spliced into it.
  - `PgParams` sends text untyped, so the server types it as it would a quoted literal. That covers dates,
    numerics, UUIDs and enums.
  - `int64`, `int32`, `float64`, `bool` and `bytes` go in binary, so they are exact and never formatted.
  - `textAs(value, OID_JSONB)` declares a type where the query doesn't fix one.
- **Results.**
  - A `PgRows` keeps every row's bytes in one buffer, with an offset per cell. Reading a result allocates per query,
    not per row or value.
  - Getters (`text`, `int64`, `int32`, `uint64`, `float64`, `bool`, `bytea`, `raw`) view or parse a cell where they
    are called.
  - `queryInto` with a reused `PgRows` reuses its memory.
- **Errors.**
  - `PgError.Server` means the server sent an ErrorResponse. `lastError()` gives its fields: `code()` (the SQLSTATE,
    such as `23505`), `message()`, `severity()`, and `field('n')` for the constraint, `'D'` detail, `'H'` hint, and
    so on.
  - After an error the connection is usable again. Inside a transaction, `transactionFailed()` tells you only
    `ROLLBACK` will be accepted.
- **Cancellation.** Every operation can be cancelled or put under `Async.timeout`. A cancelled exchange leaves the
  server's reply unread, so the connection then reports `PgError.Broken` (and `isReady()` is false): drop it and
  connect again. Waiting in `waitForNotification` is the exception, since no exchange is in progress.
- **Statement cache.**
  - Each distinct query, meaning its SQL and its parameter types, is parsed once as a named prepared statement.
    After that it is only bound and executed, so the server skips parsing and, after a few runs, planning.
  - A connection keeps the 128 most recently used statements, closing the oldest. Change the limit with
    `PgConfig.statementCache(n)`; `statementCache(0)` turns the cache off, which PgBouncer in transaction mode
    (before 1.21) needs.
  - A query whose Parse fails is not kept.
  - Two server errors make the cache forget every statement, so the query fails once and is prepared again on its
    next run: `0A000`, when an `ALTER TABLE` changed a cached query's columns, and `26000`, when `DISCARD ALL`
    dropped the statements.
- **LISTEN/NOTIFY.**
  - After `batch("LISTEN channel")`, `waitForNotification(mut n)` waits for the next notification, giving
    `n.channel`, `n.payload` and `n.pid`.
  - Notifications that arrive during other operations are queued; `takeNotification` drains the queue without
    waiting.

- **Pool.** `PgPool.create(config, max)` shares up to `max` connections between every task of a program, on any
  worker of `Async.runWorkers`.
  - `var lease = await pool.acquire()?;` then `lease.connection()`. The lease's drop returns the connection; a task
    waits while all `max` are leased. Connections open on demand.
  - A connection that cannot be reused safely is dropped instead: an operation failed partway or was cancelled, a
    transaction is still open, or it is older than `lifetime` (an hour by default). One idle longer than
    `idleLimit` (5 minutes) is replaced when next taken. `lease.discard()` drops it explicitly.
  - A failed or cancelled `acquire` gives its slot back. Session settings (`SET`, `LISTEN`, temporary tables) stay
    with a connection, so use `SET LOCAL` in a transaction, and a connection of your own for `LISTEN`.

## Not yet

- Binary result format (results are text, which every type supports).
- COPY, CancelRequest, multiple hosts, `.pgpass`, Kerberos/GSSAPI, SCRAM channel binding (`SCRAM-SHA-256-PLUS`).

## Tests

```sh
ceesafec test                                  # unit tests; the live tests pass without running
tests/setup-docker.sh                          # Postgres 17 in Docker on 127.0.0.1:55432, TLS on, one user per auth method
PG_TEST_PORT=55432 ceesafec test               # everything
PG_TEST_PORT=55432 ceesafec test --sweep cancel
```

What the live tests cover:

- **Logins:** every authentication method, and a wrong password for each.
- **TLS modes:** `prefer` and `require`; a user refused without TLS; `verify-full` with the system roots (refused)
  and with the test CA, by host name and by address.
- **Values:** the supported types each way, including SQL-injection-shaped text and a 5 MB value.
- **Rows:** a 200,000-row result over plain TCP and over TLS.
- **Statement outcomes:** affected-row counts, and server errors with their SQLSTATEs, including failed
  transactions and constraint names.
- **Notifications:** NOTIFY between two sessions.
- **Cancellation:** an abandoned query leaves the connection `Broken`.
- **Pool:** reuse, and dropping a connection left in a transaction or discarded; 12 tasks over 4 workers
  sharing 3 connections; an `acquire` cancelled while it connects.
- **Statement cache:** cache hits, a new statement for new parameter types, a failed Parse that is not kept, LRU
  eviction, and recovery after `ALTER TABLE` and `DISCARD ALL`.

`examples/bench` times a small parameterised query in a loop. Against Postgres in Docker Desktop on an M-series Mac it
does about 3,000 queries/s, the same as libpq's `pgbench` (3,050 to 3,185 tps) over the same path. Docker's port
forwarding, at about 0.33 ms per round trip, is the limit there, not either client.

`examples/query` runs one statement from the command line:
`./out/query "postgres://cee:cee_test_pw@127.0.0.1:55432/ceetest" "SELECT now()"`.

## License

PostgresClient is licensed under the GNU General Public License, version 2 only ([COPYING](COPYING)).
