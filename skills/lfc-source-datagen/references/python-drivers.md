# Run the planners from Python (no database CLI)

**Status: design, not built yet.** Today the planners are SQL files run with each engine's own client (`psql`, `mysql`, `sqlcmd`, `sqlplus`), and `fill.sh` sends their output back through the same client. That works where we run the database ourselves (a container in Lima or on a cloud VM). It doesn't work where there's no client to run:

- **Managed services:** RDS, Aurora, Azure SQL Database, Azure Database for PostgreSQL and MySQL, and Cloud SQL give no shell on the database host. A client can still run elsewhere, but not on the host, and not always on the machine the skill runs on.
- **Databricks serverless:** a notebook or job has Python and pip, not `psql`, `sqlcmd`, `sqlplus`, `db2` or `dbaccess`.

So the planner moves to Python, and the SQL goes through a driver.

## What stays the same

- **The rows are still generated inside the database.** Python sends one `INSERT ... SELECT` per table, from the same row generators (`generate_series`, `GENERATE_SERIES`, `CONNECT BY LEVEL`, a seed table); only SQL text crosses the network.
- **Each statement still checks its own keys.** It reads the table's current max key and the parent's key range when it runs, so a rerun never duplicates rows and Python holds no state about the database.
- **The tags still describe the shape** (`lfc:rows`, `lfc:v`, `lfc:n`, ...), in comments or in the side table, as written by **lfc-source-statschema**.

## What changes

| | SQL planner per engine (now) | Python planner |
|---|---|---|
| Shared logic (levels, foreign-key ranges, scramble, top-up) | Once per engine, in its own dialect | Once |
| Per engine | A whole planner (210 to 308 lines) | A catalog query, a type-to-expression map, the row generator, quoting, how to connect |
| Running the SQL | The engine's CLI, with its limits (sqlcmd splits lines at 4,096 bytes, SQL*Plus line limits and `DEFINE`, dbaccess writes to stderr) | A driver: `cursor.execute()`, `rowcount`, the database's error code |
| Testing | Needs each database running | The generated SQL can be compared to a saved copy without a database |
| Where it runs | Next to the database's CLI | Anywhere Python reaches the database's port, including Databricks serverless |

It's also the way to add Db2 and Informix, which would otherwise each need a planner in SQL PL or SPL.

## Two ways to connect

### 1. pip-installable drivers (the default)

Every engine has a driver that installs with `pip` alone, with no OS packages and no JVM. These are the versions [forgedb2](https://github.com/rsleedbx/forgedb2) uses (`pyproject.toml`; the connect calls are in `src/forgedb/sqlcli.py`, and `src/forgedb/dbkit/` is a small connection layer modeled on SQLAlchemy, a reference but not needed here):

| Engine | Package (forgedb2's version) | What's inside | Connect |
|---|---|---|---|
| PostgreSQL, and Postgres-protocol engines (CockroachDB, YugabyteDB) | `psycopg2-binary` 2.9.12 | libpq, built into the wheel | `psycopg2.connect(host=, port=, user=, password=, dbname=)` |
| MySQL, MariaDB | `pymysql` 1.2.0 | Pure Python | `pymysql.connect(host=, port=, user=, password=, database=, charset="utf8mb4")` |
| SQL Server, Azure SQL | `mssql-python` 1.11.0 | Microsoft's ODBC driver and driver manager, inside the wheel (no separate ODBC install) | `mssql_python.connect(server=, port=, user=, password=, database=)` |
| Oracle | `oracledb` 4.0.2 | Thin mode is pure Python (no Instant Client; Oracle 12.1 and later) | `oracledb.connect(user=, password=, dsn="host:port/service")` |
| Db2 | `ibm-db` 3.2.9 | IBM's C client (`clidriver`), downloaded by `pip install` (an arm64 build installs on Apple Silicon) | `ibm_db_dbi.connect("DATABASE=;HOSTNAME=;PORT=;PROTOCOL=TCPIP;UID=;PWD=;", "", "")` |
| Informix | `informix-driver` 2026.5.8.1 | Pure Python: speaks Informix's SQLI protocol over a socket, no client SDK | `informix_db.connect(host=, port=, user=, password=, database=, server=)`; `server` is the `onsoctcp` name in the container's `sqlhosts` |

`informix-driver` is young (a 2026 release); forgedb2's probe (`src/forgedb/dbkit/tests/test_informix_driver.py`) is the only test of it so far.

### 2. JDBC through JPype

The same JDBC drivers Lakeflow Connect itself uses, called from Python: JPype starts a JVM inside the Python process with the driver jars on its classpath, and `jpype.dbapi2` wraps a JDBC connection as a PEP 249 one. Use it when the pip driver lacks something, or to connect exactly the way the connector does (TLS settings such as `trustServerCertificate`, authentication options).

```python
import jpype, jpype.dbapi2
jpype.startJVM(classpath=[str(p) for p in jars])      # once per process, with every jar it will need
conn = jpype.dbapi2.connect("jdbc:postgresql://<host>:5432/<db>",
                            driver_args={"user": user, "password": password})
conn.autocommit = True
```

| Engine | Jar (Maven Central `group:artifact`) | URL |
|---|---|---|
| PostgreSQL | `org.postgresql:postgresql` | `jdbc:postgresql://<host>:<port>/<db>` |
| MySQL | `com.mysql:mysql-connector-j` | `jdbc:mysql://<host>:<port>/<db>?sslMode=PREFERRED&allowPublicKeyRetrieval=true` |
| MariaDB | `org.mariadb.jdbc:mariadb-java-client` | `jdbc:mariadb://<host>:<port>/<db>` |
| SQL Server | `com.microsoft.sqlserver:mssql-jdbc` | `jdbc:sqlserver://<host>:<port>;database=<db>` |
| Oracle | `com.oracle.database.jdbc:ojdbc8` (or `ojdbc11`) | `jdbc:oracle:thin:@//<host>:<port>/<service>` |
| Db2 | `com.ibm.db2:jcc` | `jdbc:db2://<host>:<port>/<db>` |
| Informix | `com.ibm.informix:jdbc` | `jdbc:informix-sqli://<host>:<port>/<db>:INFORMIXSERVER=<server>` |

Gotchas:

- **One JVM per process, and it can't be restarted.** JPype can't start a second JVM after `shutdownJVM()`, so start it once with every jar the run needs.
- **Pass the password in `driver_args`, never in the URL**, which ends up in logs and in `getMetaData().getURL()`.
- **Oracle and a long OS user name.** The Oracle driver sends the JVM's `user.name` as `v$session.osuser`, and fails when it's longer than 30 characters (it is on Spark, where it's the application name). Set it first: `jpype.JClass("java.lang.System").setProperty("user.name", "lfc-datagen")`.
- **Oracle takes the service from the URL**, not from `driver_args`; the other drivers take `user` and `password` there, and any JDBC property the connection needs.
- **It needs a Java runtime** (`JAVA_HOME`, or `jpype.getDefaultJVMPath()` finding one) and the jars on disk: download them once per machine (e.g. into a UC volume on Databricks).

## Which to use

| Where the skill runs | Database | Use |
|---|---|---|
| Laptop or VM, database in a container we run | Any | The current CLI planners work; the Python planner also works |
| Laptop or VM | Managed service (RDS, Aurora, Azure SQL, Cloud SQL) | Python, pip drivers |
| Databricks serverless | Any reachable from serverless | Python, pip drivers in the job's environment (`dependencies`), JDBC if a pip driver falls short |

On Databricks serverless, the database must accept connections from serverless egress, as a Lakeflow Connect connection does (**lfc-source-firewall**). `ibm-db` downloads its C client from IBM during `pip install`, so that install also needs outbound access to IBM. **Not tested yet on serverless:** the six pip drivers (in particular `mssql-python`'s bundled ODBC and `ibm-db` on Linux), and whether a Java runtime is available to JPype there.

## Things to handle in the Python planner

- **Autocommit:** the defaults differ by driver; set it explicitly, or commit after each statement, so a killed run loses at most one statement (as with `fill.sh` today).
- **Parameter styles** differ (`%s`, `:name`, `?`). The generated statements need almost no parameters, since each one probes its own key range, so send them as plain SQL text.
- **Passwords** come from a file (`umask 077`) or a secret scope, never from the command line or the code.
- **Statement size:** a driver has no CLI line limit, but the database still has its own (SQL Server's 8632 expression limit, Oracle's 4,000-byte `VARCHAR2` literals in SQL); the planner's existing workarounds stay.
