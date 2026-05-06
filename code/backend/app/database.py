import os
from contextlib import contextmanager

from psycopg_pool import ConnectionPool

_pool: ConnectionPool | None = None


def get_db_dsn() -> str:
    return os.getenv(
        "DATABASE_URL",
        "postgresql://postgres:postgres@localhost:5432/aisys",
    )


def _build_conninfo() -> str:
    dsn = get_db_dsn()
    if "connect_timeout=" in dsn:
        return dsn

    connect_timeout = os.getenv("DB_CONNECT_TIMEOUT", "5")
    separator = "&" if "?" in dsn else "?"
    return f"{dsn}{separator}connect_timeout={connect_timeout}"


def get_pool() -> ConnectionPool:
    global _pool
    if _pool is None:
        min_size = int(os.getenv("DB_POOL_MIN_SIZE", "1"))
        max_size = int(os.getenv("DB_POOL_MAX_SIZE", "10"))
        max_idle = float(os.getenv("DB_POOL_MAX_IDLE", "30"))
        timeout = float(os.getenv("DB_POOL_TIMEOUT", "10"))
        _pool = ConnectionPool(
            conninfo=_build_conninfo(),
            min_size=min_size,
            max_size=max_size,
            max_idle=max_idle,
            timeout=timeout,
            open=True,
        )
    return _pool


def close_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


@contextmanager
def get_conn():
    with get_pool().connection() as conn:
        yield conn
