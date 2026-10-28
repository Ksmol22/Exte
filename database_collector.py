"""
Colector DB — soporta PostgreSQL, MySQL, SQL Server y Oracle.

Sin agentes: conexión JDBC/DBAPI directa (thin mode / native drivers).
Todas las consultas son READ-ONLY sobre vistas de sistema en memoria
→ impacto mínimo en I/O y red, sin instalar nada en el servidor.

Métricas recopiladas (6 categorías):
  1. Estado del servicio  (db_status, db_version, db_role)
  2. Conexiones activas   (total / active / idle / max / pct)
  3. Usuarios bloqueados  (blocked_sessions + detalle blocking_chain)
  4. Tablespace / filegroups (por espacio, usado/libre, pct)
  5. Tamaño de logs       (redo logs Oracle, WAL Postgres, transaction log MSSQL)
  6. Extras               (cache hit ratio, waits top-5, slow queries, replication lag)
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Dict, List, Optional

from app.services.collectors.base_collector import BaseCollector, CollectionResult
from app.core.config import settings
from app.core.security import decrypt
from app.services.collectors.db_checks import mssql as mssql_checks
from app.services.collectors.db_checks import oracle as oracle_checks
from app.services.collectors.db_checks import postgres as postgres_checks
from app.services.collectors.db_checks.common import counts as checklist_counts

logger = logging.getLogger(__name__)

LIMITED_ORACLE_WARNING = (
    "Conectado, pero el usuario no puede leer las vistas V$/DBA_: "
    "pida al DBA GRANT SELECT_CATALOG_ROLE para ver sesiones y tablespaces."
)

# Fragmentos de error de cada driver → (estado, explicación para el operador).
_DB_ERROR_HINTS: tuple[tuple[tuple[str, ...], str, str], ...] = (
    (("ORA-01017", "password authentication failed", "Login failed", "Access denied", "28000"),
     "unknown", "Usuario o contraseña rechazados por el motor"),
    (("ORA-12514", "ORA-12505", "DPY-6001", "does not exist", "Cannot open database", "Unknown database"),
     "unknown", "La base o el servicio indicado no existe en ese servidor"),
    (("DPY-3010", "ORA-28040", "not supported by python-oracledb in Thin mode"),
     "unknown", "Versión de Oracle anterior a 12.1: no la soporta el modo thin del driver"),
    (("IM002", "Data source name not found", "no default driver"),
     "unknown", "Falta instalar el ODBC Driver for SQL Server en el equipo de Sentinel"),
    (("DPY-6005", "ORA-12170", "ORA-12541", "ORA-12543", "timed out", "timeout", "Connection refused",
      "WinError 10060", "WinError 10061", "Can't connect", "08001", "HYT00", "Login timeout"),
     "offline", "Sin conexión al puerto del motor (red, firewall o servicio caído)"),
)


# Cada consulta del checklist se corta a los N s para no agotar el sondeo.
CHECK_STATEMENT_TIMEOUT_SEC = 15


def _with_checklist(metrics: dict, checklist: list[dict]) -> dict:
    """Agrega el checklist DBA a las métricas (y a extra, que se guarda en la base)."""
    metrics["db_checklist"] = checklist
    metrics["db_checks"] = checklist_counts(checklist)
    metrics["extra"] = {**(metrics.get("extra") or {}), "checklist": checklist}
    return metrics


def explain_db_error(error: str) -> tuple[str, str]:
    """Traduce el error del driver a un estado y un mensaje que diga qué revisar."""
    for needles, status, hint in _DB_ERROR_HINTS:
        if any(n.lower() in error.lower() for n in needles):
            return status, f"{hint}. Detalle: {error}"
    return "unknown", error


def _odbc_value(value: str) -> str:
    """Valor de cadena ODBC entre llaves: así ';', '=', '{' o espacios en una clave no rompen la conexión."""
    return "{" + value.replace("}", "}}") + "}"


def _odbc_driver() -> str:
    """El ODBC Driver for SQL Server más nuevo instalado (17 si no se puede consultar)."""
    import pyodbc  # type: ignore

    try:
        installed = [d for d in pyodbc.drivers() if "SQL Server" in d and "ODBC Driver" in d]
    except Exception:
        installed = []
    return max(installed, key=lambda d: int("".join(ch for ch in d if ch.isdigit()) or 0),
               default="ODBC Driver 17 for SQL Server")


def _safe_float(val, default=0.0) -> float:
    try:
        return round(float(val), 3) if val is not None else default
    except (TypeError, ValueError):
        return default


def _safe_int(val, default=0) -> int:
    try:
        return int(val) if val is not None else default
    except (TypeError, ValueError):
        return default


class DatabaseCollector(BaseCollector):

    async def run(self) -> CollectionResult:
        if not self.credential or not self.credential.username:
            return CollectionResult(
                target_id=self.target_id, status="unknown",
                error="Sin usuario de base de datos: defina DB_USER_<AMBIENTE>_<MOTOR> y DB_PASSWORD_... "
                      "en backend/.env y vuelva a importar, o edite la credencial del servidor.",
            )
        result = await super().run()
        if result.error:
            result.status, result.error = explain_db_error(result.error)
        elif result.metrics.get("db_warning"):
            result.error = result.metrics["db_warning"]   # online, pero con aviso visible
        return result

    @property
    def _db_type(self) -> str:
        return (self.credential.db_type or self.extra_config.get("db_type", "postgres")).lower()

    @property
    def _db_port(self) -> int:
        return self.credential.db_port or self.port

    @property
    def _db_name(self) -> str:
        return self.credential.db_name or self.extra_config.get("db_name", "")

    async def collect_metrics(self) -> Dict[str, Any]:
        db = self._db_type
        if db in ("postgres", "postgresql"):
            return await self._collect_postgres()
        elif db in ("mysql", "mariadb"):
            return await self._collect_mysql()
        elif db in ("mssql", "sqlserver", "sql_server"):
            return await self._collect_mssql()
        elif db == "oracle":
            return await self._collect_oracle()
        else:
            raise RuntimeError(f"Unsupported DB type: {db}")

    # ── PostgreSQL ──────────────────────────────────────────────────────────

    async def _collect_postgres(self) -> dict:
        import asyncpg  # type: ignore

        password = decrypt(self.credential.password_enc) if self.credential.password_enc else ""
        conn = await asyncpg.connect(
            host=self.host,
            port=self._db_port,
            user=self.credential.username,
            password=password,
            database=self._db_name or "postgres",
            timeout=settings.SSH_CONNECT_TIMEOUT,
        )
        try:
            await conn.execute(f"SET statement_timeout = '{CHECK_STATEMENT_TIMEOUT_SEC}s'")
            # ── 1. Estado del servicio ────────────────────────────────────────
            ver_row = await conn.fetchrow(
                "SELECT version() AS ver, pg_is_in_recovery() AS is_replica"
            )
            db_status = "replica" if ver_row["is_replica"] else "primary"
            db_version = ver_row["ver"].split(" ")[1] if ver_row else ""

            # ── 2. Conexiones activas ─────────────────────────────────────────
            conns = await conn.fetchrow(
                """
                SELECT
                  count(*)                                              AS total,
                  count(*) FILTER (WHERE state = 'active'
                                   AND pid <> pg_backend_pid())        AS active,
                  count(*) FILTER (WHERE state = 'idle')               AS idle,
                  count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_tx,
                  count(*) FILTER (WHERE wait_event_type = 'Lock')     AS waiting,
                  count(*) FILTER (
                    WHERE state = 'active'
                    AND query_start IS NOT NULL
                    AND EXTRACT(EPOCH FROM (now() - query_start)) > 30
                    AND pid <> pg_backend_pid()
                  )                                                     AS long_running
                FROM pg_stat_activity
                """
            )
            max_conns_row = await conn.fetchrow(
                "SELECT setting::int AS max_conn FROM pg_settings WHERE name = 'max_connections'"
            )
            max_conns = _safe_int(max_conns_row["max_conn"], 100)
            conn_pct = round(_safe_int(conns["total"]) / max_conns * 100, 1)

            # ── 3. Usuarios bloqueados ────────────────────────────────────────
            blocked_rows = await conn.fetch(
                """
                SELECT
                  a.pid, a.usename, a.application_name, a.client_addr::text,
                  a.state, a.wait_event_type, a.wait_event,
                  ROUND(EXTRACT(EPOCH FROM (now() - a.state_change))::numeric, 1) AS wait_sec,
                  LEFT(a.query, 120) AS query_snippet
                FROM pg_stat_activity a
                WHERE a.wait_event_type = 'Lock'
                  AND a.pid <> pg_backend_pid()
                LIMIT 20
                """
            )
            blocking_chain = [dict(r) for r in blocked_rows]

            # ── 4. Tablespaces (tamaño de cada base de datos del cluster) ─────
            db_sizes = await conn.fetch(
                """
                SELECT datname AS name,
                       pg_database_size(datname) AS size_bytes,
                       pg_size_pretty(pg_database_size(datname)) AS size_pretty,
                       datallowconn
                FROM pg_database
                WHERE datistemplate = false
                ORDER BY size_bytes DESC
                """
            )
            tablespaces = [
                {
                    "name": r["name"],
                    "used_gb": round(r["size_bytes"] / 1024**3, 3),
                    "total_gb": round(r["size_bytes"] / 1024**3, 3),
                    "used_pct": 100.0,
                    "status": "ONLINE" if r["datallowconn"] else "RESTRICTED",
                    "size_pretty": r["size_pretty"],
                }
                for r in db_sizes
            ]

            # ── 5. WAL / log ──────────────────────────────────────────────────
            log_size_mb = 0.0
            try:
                wal_row = await conn.fetchrow(
                    """
                    SELECT COALESCE(SUM(size) / 1048576.0, 0) AS wal_mb
                    FROM pg_ls_waldir()
                    WHERE name ~ '^[0-9A-F]{24}$'
                    """
                )
                log_size_mb = _safe_float(wal_row["wal_mb"])
            except Exception:
                # pg_ls_waldir requiere superuser; si no hay permisos, calculamos LSN diff
                try:
                    wal_row2 = await conn.fetchrow(
                        "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0') / 1048576.0 AS wal_mb"
                    )
                    log_size_mb = _safe_float(wal_row2["wal_mb"])
                except Exception:
                    pass

            # ── 6. Extras ─────────────────────────────────────────────────────
            tx = await conn.fetchrow(
                """
                SELECT xact_commit, xact_rollback, blks_hit, blks_read
                FROM pg_stat_database
                WHERE datname = current_database()
                """
            )
            cache_hit = round(
                _safe_int(tx["blks_hit"])
                / max(_safe_int(tx["blks_hit"]) + _safe_int(tx["blks_read"]), 1)
                * 100,
                2,
            )

            slow = 0
            try:
                s = await conn.fetchrow(
                    "SELECT count(*) AS n FROM pg_stat_statements WHERE mean_exec_time > 1000"
                )
                slow = _safe_int(s["n"])
            except Exception:
                pass

            repl_lag = None
            try:
                r = await conn.fetchrow(
                    "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag"
                )
                repl_lag = _safe_float(r["lag"]) if r and r["lag"] is not None else None
            except Exception:
                pass

            locks = await conn.fetchrow("SELECT count(*) AS n FROM pg_locks WHERE NOT granted")

            # Longest active query
            long_q = await conn.fetchrow(
                """
                SELECT ROUND(EXTRACT(EPOCH FROM (now() - query_start))::numeric, 1) AS secs,
                       LEFT(query, 80) AS q
                FROM pg_stat_activity
                WHERE state = 'active'
                  AND query_start IS NOT NULL
                  AND pid <> pg_backend_pid()
                ORDER BY secs DESC
                LIMIT 1
                """
            )
            longest_query_sec = _safe_float(long_q["secs"]) if long_q else 0.0

            result = {
                # 1
                "db_status": db_status,
                "db_version": db_version,
                "db_role": db_status,
                # 2
                "db_connections": _safe_int(conns["total"]),
                "db_connections_active": _safe_int(conns["active"]),
                "db_connections_idle": _safe_int(conns["idle"]),
                "db_connections_idle_in_tx": _safe_int(conns["idle_in_tx"]),
                "db_connections_waiting": _safe_int(conns["waiting"]),
                "db_connections_long_running": _safe_int(conns["long_running"]),
                "db_connections_max": max_conns,
                "db_connections_pct": conn_pct,
                # 3
                "db_blocked_sessions": len(blocking_chain),
                "db_blocking_chain": blocking_chain,
                "db_locks": _safe_int(locks["n"]),
                # 4
                "db_tablespaces": tablespaces,
                "db_size_gb": round(sum(t["used_gb"] for t in tablespaces), 3),
                # 5
                "db_log_size_mb": round(log_size_mb, 2),
                "db_log_used_pct": None,
                # 6
                "db_slow_queries": slow,
                "db_longest_query_sec": longest_query_sec,
                "db_cache_hit_ratio": cache_hit,
                "db_replication_lag_sec": repl_lag,
                "db_deadlocks": _safe_int(tx["xact_rollback"]),
                "extra": {
                    "xact_commit": _safe_int(tx["xact_commit"]),
                    "xact_rollback": _safe_int(tx["xact_rollback"]),
                    "cache_hit_ratio": cache_hit,
                },
            }
            return _with_checklist(result, await postgres_checks.run(conn))
        finally:
            await conn.close()

    # ── MySQL / MariaDB ─────────────────────────────────────────────────────

    async def _collect_mysql(self) -> dict:
        import aiomysql  # type: ignore

        password = decrypt(self.credential.password_enc) if self.credential.password_enc else ""
        conn = await aiomysql.connect(
            host=self.host,
            port=self._db_port,
            user=self.credential.username,
            password=password,
            db=self._db_name or "information_schema",
            connect_timeout=settings.SSH_CONNECT_TIMEOUT,
        )
        try:
            async with conn.cursor() as cur:
                await cur.execute("SHOW GLOBAL STATUS LIKE 'Threads_connected'")
                r = await cur.fetchone()
                connections = _safe_int(r[1] if r else 0)

                await cur.execute("SHOW GLOBAL STATUS LIKE 'Slow_queries'")
                r = await cur.fetchone()
                slow = _safe_int(r[1] if r else 0)

                await cur.execute(
                    "SELECT SUM(data_length + index_length) FROM information_schema.tables"
                )
                r = await cur.fetchone()
                size_bytes = _safe_int(r[0] if r else 0)

                await cur.execute("SHOW GLOBAL STATUS LIKE 'Innodb_row_lock_waits'")
                r = await cur.fetchone()
                locks = _safe_int(r[1] if r else 0)

                await cur.execute("SHOW GLOBAL VARIABLES LIKE 'max_connections'")
                r = await cur.fetchone()
                max_conns = _safe_int(r[1] if r else 100)

                size_gb = round(size_bytes / 1024**3, 3)
                return {
                    "db_status": "online",
                    "db_version": "",
                    "db_connections": connections,
                    "db_connections_max": max_conns,
                    "db_connections_pct": round(connections / max(max_conns, 1) * 100, 1),
                    "db_slow_queries": slow,
                    "db_size_gb": size_gb,
                    "db_locks": locks,
                    "db_blocked_sessions": 0,
                    "db_blocking_chain": [],
                    "db_tablespaces": [{"name": "default", "used_gb": size_gb, "used_pct": 0, "status": "ONLINE"}],
                    "db_log_size_mb": 0.0,
                    "db_cache_hit_ratio": 0.0,
                    "db_replication_lag_sec": None,
                    "extra": {},
                }
        finally:
            conn.close()

    # ── SQL Server ──────────────────────────────────────────────────────────

    async def _collect_mssql(self) -> dict:
        import pyodbc  # type: ignore

        password = decrypt(self.credential.password_enc) if self.credential.password_enc else ""
        driver = _odbc_driver()
        conn_str = (
            f"DRIVER={{{driver}}};"
            f"SERVER={self.host},{self._db_port};"
            f"DATABASE={_odbc_value(self._db_name or 'master')};"
            f"UID={_odbc_value(self.credential.username or '')};"
            f"PWD={_odbc_value(password)};TrustServerCertificate=yes;"
            # El Driver 18 cifra por defecto; se mantiene el comportamiento del 17.
            + ("Encrypt=optional;" if "18" in driver else "")
        )

        loop = asyncio.get_running_loop()

        def _sync() -> dict:
            with pyodbc.connect(conn_str, timeout=settings.SSH_CONNECT_TIMEOUT) as c:
                c.timeout = 15
                cur = c.cursor()

                # ── 1. Estado del servicio ────────────────────────────────────
                cur.execute(
                    "SELECT @@VERSION AS ver, "
                    "  SERVERPROPERTY('Edition') AS edition, "
                    "  SERVERPROPERTY('ProductVersion') AS product_ver"
                )
                r = cur.fetchone()
                db_version = str(r.product_ver) if r else ""

                cur.execute(
                    "SELECT state_desc FROM sys.databases WHERE name = DB_NAME()"
                )
                r = cur.fetchone()
                db_status = (r[0] or "UNKNOWN").upper() if r else "UNKNOWN"

                # ── 2. Conexiones activas ─────────────────────────────────────
                cur.execute(
                    "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1"
                )
                connections = cur.fetchone()[0]

                cur.execute(
                    "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE status = 'running'"
                )
                active = cur.fetchone()[0]

                max_conns = 0
                try:
                    cur.execute(
                        "SELECT value_in_use FROM sys.configurations "
                        "WHERE name = 'max connections'"
                    )
                    r = cur.fetchone()
                    max_conns = _safe_int(r[0]) if r else 0
                except Exception:
                    pass
                if max_conns == 0:
                    max_conns = 32767  # SQL Server default unlimited → use theoretical max
                conn_pct = round(connections / max_conns * 100, 1)

                # ── 3. Usuarios bloqueados ────────────────────────────────────
                cur.execute(
                    "SELECT COUNT(*) FROM sys.dm_exec_requests "
                    "WHERE blocking_session_id <> 0"
                )
                blocked_count = cur.fetchone()[0]

                blocking_chain: list = []
                try:
                    cur.execute(
                        """
                        SELECT TOP 20
                          r.session_id,
                          r.blocking_session_id,
                          r.wait_type,
                          ROUND(r.wait_time / 1000.0, 1) AS wait_sec,
                          s.login_name,
                          s.host_name,
                          s.program_name,
                          LEFT(qt.text, 120) AS query_snippet
                        FROM sys.dm_exec_requests r
                        JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
                        CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) qt
                        WHERE r.blocking_session_id <> 0
                        """
                    )
                    cols = [c[0] for c in cur.description]
                    blocking_chain = [dict(zip(cols, row)) for row in cur.fetchall()]
                except Exception:
                    pass

                deadlocks = 0
                try:
                    cur.execute(
                        "SELECT cntr_value FROM sys.dm_os_performance_counters "
                        "WHERE counter_name = 'Number of Deadlocks/sec' "
                        "  AND instance_name = '_Total'"
                    )
                    r = cur.fetchone()
                    deadlocks = _safe_int(r[0]) if r else 0
                except Exception:
                    pass

                # ── 4. Bases de datos / filegroups ────────────────────────────
                tablespaces: list = []
                try:
                    cur.execute(
                        """
                        SELECT
                          DB_NAME(mf.database_id) AS db_name,
                          mf.type_desc,
                          SUM(mf.size) * 8.0 / 1024 AS size_mb,
                          SUM(mf.size) * 8.0 / 1024 / 1024 AS size_gb,
                          d.state_desc AS status
                        FROM sys.master_files mf
                        JOIN sys.databases d ON d.database_id = mf.database_id
                        WHERE mf.type = 0  -- data files only
                        GROUP BY mf.database_id, mf.type_desc, d.state_desc
                        ORDER BY size_mb DESC
                        """
                    )
                    cols = [c[0] for c in cur.description]
                    rows = cur.fetchall()
                    for row in rows:
                        rd = dict(zip(cols, row))
                        tablespaces.append(
                            {
                                "name": rd["db_name"],
                                "used_gb": round(float(rd["size_gb"] or 0), 3),
                                "total_gb": round(float(rd["size_gb"] or 0), 3),
                                "used_pct": 100.0,
                                "status": rd["status"],
                            }
                        )
                except Exception:
                    pass

                size_gb = round(sum(t["used_gb"] for t in tablespaces), 3)

                # ── 5. Transaction log size ───────────────────────────────────
                log_size_mb = 0.0
                log_used_pct = 0.0
                db_logs: list = []
                try:
                    cur.execute(
                        """
                        SELECT
                          DB_NAME(mf.database_id)     AS db_name,
                          mf.size * 8.0 / 1024        AS log_size_mb,
                          pc.cntr_value * 1.0 / 1024  AS log_used_mb,
                          d.state_desc
                        FROM sys.master_files mf
                        JOIN sys.databases d ON d.database_id = mf.database_id
                        LEFT JOIN sys.dm_os_performance_counters pc
                          ON pc.instance_name = d.name
                         AND pc.counter_name = 'Log File(s) Used Size (KB)'
                        WHERE mf.type = 1  -- log files
                        ORDER BY mf.size DESC
                        """
                    )
                    cols = [c[0] for c in cur.description]
                    for row in cur.fetchall():
                        rd = dict(zip(cols, row))
                        sz = _safe_float(rd["log_size_mb"])
                        # El contador de rendimiento puede superar el tamaño del archivo: se acota.
                        used = min(_safe_float(rd.get("log_used_mb", 0)), sz)
                        db_logs.append(
                            {
                                "name": rd["db_name"],
                                "size_mb": round(sz, 2),
                                "used_mb": round(used, 2),
                                "used_pct": round(used / max(sz, 0.001) * 100, 1),
                            }
                        )
                    log_size_mb = sum(l["size_mb"] for l in db_logs)
                    if log_size_mb > 0:
                        log_used_pct = round(
                            sum(l["used_mb"] for l in db_logs) / log_size_mb * 100, 1
                        )
                except Exception:
                    pass

                # ── 6. Extras ─────────────────────────────────────────────────
                slow = 0
                try:
                    cur.execute(
                        "SELECT count(*) FROM sys.dm_exec_requests "
                        "WHERE total_elapsed_time > 5000 AND status = 'running'"
                    )
                    slow = cur.fetchone()[0]
                except Exception:
                    pass

                longest_sec = 0.0
                try:
                    cur.execute(
                        "SELECT TOP 1 ROUND(total_elapsed_time / 1000.0, 1) "
                        "FROM sys.dm_exec_requests "
                        "WHERE status = 'running' "
                        "ORDER BY total_elapsed_time DESC"
                    )
                    r = cur.fetchone()
                    longest_sec = _safe_float(r[0]) if r else 0.0
                except Exception:
                    pass

                cache_hit = 0.0
                try:
                    cur.execute(
                        "SELECT TOP 1 cntr_value FROM sys.dm_os_performance_counters "
                        "WHERE object_name LIKE '%Buffer Manager%' "
                        "  AND counter_name = 'Buffer cache hit ratio'"
                    )
                    r = cur.fetchone()
                    cache_hit = _safe_float(r[0]) if r else 0.0
                except Exception:
                    pass

                waits: list = []
                try:
                    cur.execute(
                        """
                        SELECT TOP 5 wait_type,
                               waiting_tasks_count,
                               ROUND(wait_time_ms / 1000.0, 1) AS wait_time_sec
                        FROM sys.dm_os_wait_stats
                        WHERE wait_type NOT IN (
                          'SLEEP_TASK','BROKER_TO_FLUSH','LAZYWRITER_SLEEP',
                          'SQLTRACE_BUFFER_FLUSH','CLR_AUTO_EVENT',
                          'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
                          'HADR_WORK_QUEUE','ONDEMAND_TASK_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH',
                          'RESOURCE_QUEUE','SERVER_IDLE_CHECK','SLEEP_DBSTARTUP',
                          'SLEEP_DCOMSTARTUP','SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY',
                          'SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK',
                          'SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP',
                          'WAITFOR','XE_DISPATCHER_WAIT','XE_TIMER_EVENT'
                        )
                        ORDER BY wait_time_ms DESC
                        """
                    )
                    cols = [c[0] for c in cur.description]
                    waits = [dict(zip(cols, row)) for row in cur.fetchall()]
                except Exception:
                    pass

                result = {
                    # 1
                    "db_status": db_status,
                    "db_version": db_version,
                    "db_role": "primary",
                    # 2
                    "db_connections": connections,
                    "db_connections_active": active,
                    "db_connections_idle": connections - active,
                    "db_connections_max": max_conns,
                    "db_connections_pct": conn_pct,
                    # 3
                    "db_blocked_sessions": blocked_count,
                    "db_blocking_chain": blocking_chain,
                    "db_locks": blocked_count,
                    "db_deadlocks": deadlocks,
                    # 4
                    "db_tablespaces": tablespaces,
                    "db_size_gb": size_gb,
                    # 5
                    "db_log_size_mb": round(log_size_mb, 2),
                    "db_log_used_pct": log_used_pct,
                    "db_logs": db_logs,
                    # 6
                    "db_slow_queries": slow,
                    "db_longest_query_sec": longest_sec,
                    "db_cache_hit_ratio": cache_hit,
                    "db_replication_lag_sec": None,
                    "db_waits_top5": waits,
                    "extra": {"waits": waits},
                }
                return _with_checklist(result, mssql_checks.run(cur))

        return await loop.run_in_executor(None, _sync)

    # ── Oracle ──────────────────────────────────────────────────────────────

    async def _collect_oracle(self) -> dict:
        import oracledb  # type: ignore

        password = decrypt(self.credential.password_enc) if self.credential.password_enc else ""
        service = self.credential.db_service or self._db_name
        dsn = f"{self.host}:{self._db_port}/{service}"

        loop = asyncio.get_running_loop()

        def _sync() -> dict:
            with oracledb.connect(
                user=self.credential.username,
                password=password,
                dsn=dsn,
                tcp_connect_timeout=settings.SSH_CONNECT_TIMEOUT,
            ) as c:
                cur = c.cursor()
                cur.execute("SELECT 1 FROM DUAL")   # la conexión ya prueba que la instancia está abierta
                cur.fetchone()

                # ── 1. Estado del servicio ────────────────────────────────────
                # Las vistas V$ y DBA_ exigen SELECT_CATALOG_ROLE; sin ellas se
                # reporta igual la disponibilidad y la versión (viene del protocolo).
                db_status, db_version, db_role, uptime_sec = "OPEN", str(c.version or ""), "PRIMARY", 0
                limited = False
                try:
                    cur.execute(
                        "SELECT i.STATUS, i.VERSION, d.DATABASE_ROLE, d.OPEN_MODE, "
                        "       ROUND((SYSDATE - i.STARTUP_TIME) * 86400) AS uptime_sec "
                        "FROM V$INSTANCE i, V$DATABASE d"
                    )
                    r = cur.fetchone()
                    if r:
                        db_status = (r[0] or "UNKNOWN").upper()
                        db_version = str(r[1])
                        db_role = str(r[2])
                        uptime_sec = _safe_int(r[4])
                except oracledb.DatabaseError:
                    limited = True

                # ── 2. Conexiones activas ─────────────────────────────────────
                total_conns = active_conns = 0
                try:
                    cur.execute(
                        """
                        SELECT
                          COUNT(*)                                              AS total,
                          COUNT(CASE WHEN STATUS = 'ACTIVE' THEN 1 END)        AS active
                        FROM V$SESSION
                        WHERE TYPE = 'USER'
                        """
                    )
                    conns = cur.fetchone()
                    total_conns = _safe_int(conns[0]) if conns else 0
                    active_conns = _safe_int(conns[1]) if conns else 0
                except oracledb.DatabaseError:
                    limited = True

                max_conns = 0
                try:
                    cur.execute(
                        "SELECT TO_NUMBER(VALUE) FROM V$PARAMETER WHERE NAME = 'sessions'"
                    )
                    r = cur.fetchone()
                    max_conns = _safe_int(r[0]) if r else 0
                except Exception:
                    pass
                if max_conns == 0:
                    max_conns = 1
                conn_pct = round(total_conns / max_conns * 100, 1)

                # ── 3. Usuarios bloqueados ────────────────────────────────────
                blocked_count = 0
                try:
                    cur.execute(
                        """
                        SELECT COUNT(*) FROM V$SESSION
                        WHERE BLOCKING_SESSION IS NOT NULL
                          AND TYPE = 'USER'
                        """
                    )
                    blocked_count = _safe_int(cur.fetchone()[0])
                except oracledb.DatabaseError:
                    limited = True

                blocking_chain: list = []
                try:
                    cur.execute(
                        """
                        SELECT s.SID, s.SERIAL#, s.USERNAME, s.MACHINE,
                               s.STATUS, s.BLOCKING_SESSION,
                               s.SECONDS_IN_WAIT,
                               s.EVENT,
                               SUBSTR(q.SQL_TEXT, 1, 120) AS query_snippet
                        FROM V$SESSION s
                        LEFT JOIN V$SQL q ON q.SQL_ID = s.SQL_ID
                        WHERE s.BLOCKING_SESSION IS NOT NULL
                          AND s.TYPE = 'USER'
                          AND ROWNUM <= 20
                        """
                    )
                    cols = [c[0].lower() for c in cur.description]
                    blocking_chain = [dict(zip(cols, row)) for row in cur.fetchall()]
                except Exception:
                    pass

                deadlocks = 0
                try:
                    cur.execute(
                        "SELECT VALUE FROM V$SYSSTAT WHERE NAME = 'enqueue deadlocks'"
                    )
                    r = cur.fetchone()
                    deadlocks = _safe_int(r[0]) if r else 0
                except Exception:
                    pass

                # ── 4. Tablespaces ────────────────────────────────────────────
                tablespaces: list = []
                size_gb = 0.0
                try:
                    cur.execute(
                        """
                        SELECT
                          df.TABLESPACE_NAME,
                          df.total_bytes / 1073741824                       AS total_gb,
                          GREATEST(df.total_bytes - NVL(fs.free_bytes, 0), 0)
                            / 1073741824                                     AS used_gb,
                          ROUND(
                            GREATEST(df.total_bytes - NVL(fs.free_bytes, 0), 0)
                            / df.total_bytes * 100, 2
                          )                                                  AS used_pct,
                          dt.STATUS
                        FROM (
                          SELECT TABLESPACE_NAME, SUM(BYTES) AS total_bytes
                          FROM DBA_DATA_FILES
                          GROUP BY TABLESPACE_NAME
                        ) df
                        LEFT JOIN (
                          SELECT TABLESPACE_NAME, SUM(BYTES) AS free_bytes
                          FROM DBA_FREE_SPACE
                          GROUP BY TABLESPACE_NAME
                        ) fs ON fs.TABLESPACE_NAME = df.TABLESPACE_NAME
                        JOIN DBA_TABLESPACES dt ON dt.TABLESPACE_NAME = df.TABLESPACE_NAME
                        ORDER BY used_pct DESC NULLS LAST
                        """
                    )
                    cols = [c[0].lower() for c in cur.description]
                    for row in cur.fetchall():
                        rd = dict(zip(cols, row))
                        tablespaces.append(
                            {
                                "name": rd["tablespace_name"],
                                "total_gb": round(_safe_float(rd["total_gb"]), 3),
                                "used_gb": round(_safe_float(rd["used_gb"]), 3),
                                "free_gb": round(
                                    _safe_float(rd["total_gb"])
                                    - _safe_float(rd["used_gb"]),
                                    3,
                                ),
                                "used_pct": round(_safe_float(rd["used_pct"]), 2),
                                "status": str(rd["status"]),
                            }
                        )
                    size_gb = round(sum(t["used_gb"] for t in tablespaces), 3)
                except oracledb.DatabaseError:
                    limited = True

                # ── 5. Redo logs ──────────────────────────────────────────────
                log_size_mb = 0.0
                db_logs: list = []
                try:
                    cur.execute(
                        """
                        SELECT l.GROUP#, l.STATUS, l.ARCHIVED,
                               l.BYTES / 1048576 AS size_mb,
                               f.MEMBER
                        FROM V$LOG l
                        JOIN V$LOGFILE f ON l.GROUP# = f.GROUP#
                        WHERE f.TYPE = 'ONLINE'
                        ORDER BY l.GROUP#
                        """
                    )
                    cols = [c[0].lower() for c in cur.description]
                    for row in cur.fetchall():
                        rd = dict(zip(cols, row))
                        db_logs.append(
                            {
                                "name": f"GROUP#{rd['group#']} {rd['status']}",
                                "size_mb": round(_safe_float(rd["size_mb"]), 2),
                                "archived": str(rd["archived"]) == "YES",
                                "member": str(rd["member"]),
                            }
                        )
                    log_size_mb = sum(l["size_mb"] for l in db_logs)
                except Exception:
                    pass

                # Archive log usage
                archive_mb = 0.0
                try:
                    cur.execute(
                        "SELECT NVL(SUM(BLOCKS * BLOCK_SIZE) / 1048576, 0) "
                        "FROM V$ARCHIVED_LOG "
                        "WHERE STANDBY_DEST = 'NO' AND DELETED = 'NO'"
                    )
                    r = cur.fetchone()
                    archive_mb = _safe_float(r[0]) if r else 0.0
                except Exception:
                    pass

                # ── 6. Extras ─────────────────────────────────────────────────
                # Top waits (non-idle)
                waits: list = []
                try:
                    cur.execute(
                        """
                        SELECT EVENT, TOTAL_WAITS,
                               ROUND(TIME_WAITED / 100, 2) AS wait_time_sec
                        FROM V$SYSTEM_EVENT
                        WHERE WAIT_CLASS != 'Idle'
                        ORDER BY TIME_WAITED DESC
                        FETCH FIRST 5 ROWS ONLY
                        """
                    )
                    cols = [c[0].lower() for c in cur.description]
                    waits = [dict(zip(cols, row)) for row in cur.fetchall()]
                except Exception:
                    pass

                # Buffer cache hit ratio
                cache_hit = 0.0
                try:
                    cur.execute(
                        """
                        SELECT ROUND(
                          (1 - phyrds / GREATEST(dbget + cnstget, 1)) * 100, 2
                        ) AS ratio
                        FROM (
                          SELECT SUM(VALUE) AS phyrds
                          FROM V$SYSSTAT WHERE NAME = 'physical reads'
                        ), (
                          SELECT SUM(VALUE) AS dbget
                          FROM V$SYSSTAT WHERE NAME = 'db block gets'
                        ), (
                          SELECT SUM(VALUE) AS cnstget
                          FROM V$SYSSTAT WHERE NAME = 'consistent gets'
                        )
                        """
                    )
                    r = cur.fetchone()
                    cache_hit = _safe_float(r[0]) if r else 0.0
                except Exception:
                    pass

                # Longest running SQL
                longest_sec = 0.0
                try:
                    cur.execute(
                        """
                        SELECT ROUND(ELAPSED_TIME / 1000000, 2) AS elapsed_sec
                        FROM V$SQL
                        ORDER BY ELAPSED_TIME DESC
                        FETCH FIRST 1 ROWS ONLY
                        """
                    )
                    r = cur.fetchone()
                    longest_sec = _safe_float(r[0]) if r else 0.0
                except Exception:
                    pass

                result = {
                    # 1
                    "db_status": db_status,
                    "db_version": db_version,
                    "db_role": db_role,
                    "db_uptime_sec": uptime_sec,
                    # 2
                    "db_connections": total_conns,
                    "db_connections_active": active_conns,
                    "db_connections_idle": total_conns - active_conns,
                    "db_connections_max": max_conns,
                    "db_connections_pct": conn_pct,
                    # 3
                    "db_blocked_sessions": blocked_count,
                    "db_blocking_chain": blocking_chain,
                    "db_locks": blocked_count,
                    "db_deadlocks": deadlocks,
                    # 4
                    "db_tablespaces": tablespaces,
                    "db_size_gb": size_gb,
                    # 5
                    "db_log_size_mb": round(log_size_mb, 2),
                    "db_archive_log_mb": round(archive_mb, 2),
                    "db_logs": db_logs,
                    "db_log_used_pct": None,
                    # 6
                    "db_slow_queries": 0,
                    "db_longest_query_sec": longest_sec,
                    "db_cache_hit_ratio": cache_hit,
                    "db_replication_lag_sec": None,
                    "db_waits_top5": waits,
                    "db_privileges": "limited" if limited else "full",
                    "db_warning": LIMITED_ORACLE_WARNING if limited else None,
                    "extra": {"waits": waits, "archive_log_mb": archive_mb,
                              "privileges": "limited" if limited else "full"},
                }
                c.call_timeout = CHECK_STATEMENT_TIMEOUT_SEC * 1000
                return _with_checklist(result, oracle_checks.run(cur))

        return await loop.run_in_executor(None, _sync)
