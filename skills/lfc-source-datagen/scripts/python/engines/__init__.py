# engine name (and short name) -> Engine class; each module imports only its own driver, when it connects
import importlib


class _Lazy(dict):
    def __missing__(self, k):
        m = {"pg": "postgres", "cockroachdb": "postgres", "crdb": "postgres", "yugabytedb": "postgres", "yb": "postgres",
             "my": "mysql", "mariadb": "mysql", "maria": "mysql", "ms": "sqlserver", "mssql": "sqlserver", "ora": "oracle",
             "ifx": "informix"}.get(k, k)
        if m not in ("postgres", "mysql", "sqlserver", "oracle", "db2", "informix"): raise SystemExit(f"unknown engine {k}")
        return importlib.import_module(f"engines.{m}").Engine


ENGINES = _Lazy()
