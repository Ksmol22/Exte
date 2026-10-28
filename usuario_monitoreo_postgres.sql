-- ============================================================================
-- Sentinel · Usuario de monitoreo para PostgreSQL (10 a 17)
-- ----------------------------------------------------------------------------
-- Usa el rol predefinido pg_monitor (PostgreSQL 10+): lectura de estadísticas
-- y configuración, sin acceso a los datos de las tablas. Cubre los 10 puntos
-- del checklist DBA de Sentinel: servicio y modo, tamaños, conexiones, bloqueos
-- y consultas largas, autovacuum/XID, archivado de WAL y replication slots,
-- replicación, roles, índices y cache hit/checkpoints.
--
-- Ejecutar con psql como superusuario (postgres) o un rol con CREATEROLE.
-- Antes de ejecutar: reemplazar <CLAVE_SEGURA> por una contraseña robusta.
-- ============================================================================

-- ── 1. Rol de monitoreo ──
CREATE ROLE sentinel_mon WITH
  LOGIN
  PASSWORD '<CLAVE_SEGURA>'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  INHERIT                            -- hereda los permisos de pg_monitor sin SET ROLE
  CONNECTION LIMIT 5                 -- Sentinel abre 1 por sondeo
  VALID UNTIL 'infinity';            -- que no expire

GRANT pg_monitor TO sentinel_mon;

-- Solo lectura incluso si alguien le otorga algo por error
ALTER ROLE sentinel_mon SET default_transaction_read_only = on;
ALTER ROLE sentinel_mon SET statement_timeout = '15s';

-- ── 2. Permitir la conexión a la base que se monitorea ──
--    Sentinel se conecta a la base indicada en db_name del servidores.ini
--    (por defecto "postgres"). Repita por cada base que use como destino.
GRANT CONNECT ON DATABASE postgres TO sentinel_mon;
-- GRANT CONNECT ON DATABASE <OTRA_BASE> TO sentinel_mon;

-- ── 3. pg_hba.conf (lo edita el DBA; después: SELECT pg_reload_conf();) ──
--    Agregar ANTES de las reglas generales, con la IP del equipo de Sentinel:
--
--    # TYPE  DATABASE  USER          ADDRESS           METHOD
--    host    postgres  sentinel_mon  <IP_SENTINEL>/32  scram-sha-256
--
--    Use scram-sha-256 (o md5 en versiones < 10). Si la instancia exige SSL,
--    use "hostssl" en lugar de "host".

-- ── 4. Opcional: consultas lentas (pg_stat_statements) ──
--    Si la extensión está instalada en la base destino, pg_monitor ya puede leerla.
--    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;   -- requiere shared_preload_libraries

-- ── 5. Verificación (conectado como sentinel_mon) ──
-- SELECT pg_is_in_recovery(), current_setting('max_connections');
-- SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend';
-- SELECT * FROM pg_stat_archiver;
-- SELECT pg_size_pretty(pg_database_size(current_database()));

-- ── Para revertir ──
-- REVOKE CONNECT ON DATABASE postgres FROM sentinel_mon;
-- REVOKE pg_monitor FROM sentinel_mon;
-- DROP ROLE sentinel_mon;
