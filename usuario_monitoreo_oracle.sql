-- ============================================================================
-- Sentinel · Usuario de monitoreo para Oracle (12c, 18c, 19c, 21c, 23ai)
-- ----------------------------------------------------------------------------
-- Solo lectura sobre el diccionario: el usuario no puede ver ni modificar datos
-- de negocio. Cubre los 10 puntos del checklist DBA de Sentinel:
--   instancia y listener (V$INSTANCE, V$ACTIVE_SERVICES), tablespaces
--   (DBA_TABLESPACE_USAGE_METRICS), FRA y ArchiveLogs (V$RECOVERY_FILE_DEST,
--   V$ARCHIVED_LOG), ASM (V$ASM_DISKGROUP), usuarios (DBA_USERS), sesiones
--   (V$SESSION, V$PROCESS), Alert Log (V$DIAG_ALERT_EXT), RMAN
--   (V$RMAN_BACKUP_JOB_DETAILS), objetos inválidos (DBA_OBJECTS, DBA_INDEXES)
--   y Data Guard (V$DATAGUARD_STATS, V$ARCHIVE_DEST).
--
-- Ejecutar como SYS o un DBA con ADMIN OPTION sobre SELECT_CATALOG_ROLE.
-- Antes de ejecutar: reemplazar <CLAVE_SEGURA> por una contraseña robusta.
--
-- Multitenant (CDB/PDB): elija UNA de las dos opciones de la sección 1.
--   A) Usuario local en cada PDB a monitorear (lo más común): conectarse a la PDB.
--   B) Usuario común C##SENTINEL_MON desde CDB$ROOT, que ve todas las PDB.
-- En Sentinel, el servicio (db_name/db_service del servidores.ini) debe ser
-- el de la PDB (opción A) o el del CDB (opción B).
-- ============================================================================

-- ── 0. Perfil: que la contraseña del monitor no expire ni se bloquee sola ──
--    (si un sondeo cada 5 min falla, no debe bloquear la cuenta)
--    En multitenant con opción B use: CREATE PROFILE C##SENTINEL_MON_PROFILE ... CONTAINER=ALL;
CREATE PROFILE SENTINEL_MON_PROFILE LIMIT
  PASSWORD_LIFE_TIME   UNLIMITED
  FAILED_LOGIN_ATTEMPTS 10
  PASSWORD_LOCK_TIME   1/24          -- 1 hora
  SESSIONS_PER_USER    5             -- Sentinel abre 1 por sondeo
  IDLE_TIME            15;

-- ── 1A. Usuario local (ejecutar dentro de la PDB, o en una base no-CDB) ──
--    ALTER SESSION SET CONTAINER = <NOMBRE_PDB>;   -- si está en CDB$ROOT
CREATE USER SENTINEL_MON IDENTIFIED BY "<CLAVE_SEGURA>"
  PROFILE SENTINEL_MON_PROFILE;

-- Sin CREATE TABLE ni cuota: no puede crear objetos en ningún tablespace.
GRANT CREATE SESSION TO SENTINEL_MON;
-- V$ y DBA_ en solo lectura (en SQL*Plus no debe haber comentarios tras el ";")
GRANT SELECT_CATALOG_ROLE TO SENTINEL_MON;
-- El Alert Log no está en SELECT_CATALOG_ROLE: se otorga aparte (ejecutar como SYS)
GRANT SELECT ON SYS.V_$DIAG_ALERT_EXT TO SENTINEL_MON;
ALTER USER SENTINEL_MON DEFAULT ROLE ALL;

-- ── 1B. (Alternativa) Usuario común en CDB$ROOT que ve todas las PDB ──
-- CREATE USER C##SENTINEL_MON IDENTIFIED BY "<CLAVE_SEGURA>" PROFILE C##SENTINEL_MON_PROFILE CONTAINER=ALL;
-- GRANT CREATE SESSION      TO C##SENTINEL_MON CONTAINER=ALL;
-- GRANT SELECT_CATALOG_ROLE TO C##SENTINEL_MON CONTAINER=ALL;
-- GRANT SELECT ON SYS.V_$DIAG_ALERT_EXT TO C##SENTINEL_MON CONTAINER=ALL;
-- ALTER USER C##SENTINEL_MON SET CONTAINER_DATA=ALL CONTAINER=CURRENT;   -- ver datos de todas las PDB
-- ALTER USER C##SENTINEL_MON DEFAULT ROLE ALL;

-- ── 2. Si su política no permite SELECT_CATALOG_ROLE, alternativa mínima ──
--    (otorgar solo las vistas que usa Sentinel; ejecutar como SYS)
-- GRANT SELECT ON SYS.V_$INSTANCE                 TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$DATABASE                 TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$ACTIVE_SERVICES          TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$SESSION                  TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$PROCESS                  TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$PARAMETER                TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$SQL                      TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$SYSSTAT                  TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$SYSTEM_EVENT             TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$LOG                      TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$LOGFILE                  TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$ARCHIVED_LOG             TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$ARCHIVE_DEST             TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$RECOVERY_FILE_DEST       TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$ASM_DISKGROUP            TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$DIAG_ALERT_EXT           TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$RMAN_BACKUP_JOB_DETAILS  TO SENTINEL_MON;
-- GRANT SELECT ON SYS.V_$DATAGUARD_STATS          TO SENTINEL_MON;
-- GRANT SELECT ON SYS.DBA_TABLESPACE_USAGE_METRICS TO SENTINEL_MON;
-- GRANT SELECT ON SYS.DBA_TABLESPACES             TO SENTINEL_MON;
-- GRANT SELECT ON SYS.DBA_DATA_FILES              TO SENTINEL_MON;
-- GRANT SELECT ON SYS.DBA_FREE_SPACE              TO SENTINEL_MON;
-- GRANT SELECT ON SYS.DBA_USERS                   TO SENTINEL_MON;
-- GRANT SELECT ON SYS.DBA_OBJECTS                 TO SENTINEL_MON;
-- GRANT SELECT ON SYS.DBA_INDEXES                 TO SENTINEL_MON;
-- GRANT SELECT ON SYS.DBA_IND_PARTITIONS          TO SENTINEL_MON;

-- ── 3. Verificación (conectado como SENTINEL_MON) ──
-- SELECT instance_name, status FROM v$instance;
-- SELECT COUNT(*) FROM dba_tablespace_usage_metrics;
-- SELECT COUNT(*) FROM v$diag_alert_ext WHERE originating_timestamp > SYSTIMESTAMP - INTERVAL '1' HOUR;

-- ── Para revertir ──
-- DROP USER SENTINEL_MON;
-- DROP PROFILE SENTINEL_MON_PROFILE;
