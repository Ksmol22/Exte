-- ============================================================================
-- Sentinel · Login de monitoreo para SQL Server (2016, 2017, 2019, 2022)
-- ----------------------------------------------------------------------------
-- Solo lectura de DMVs, catálogo y msdb: no puede leer ni modificar datos de
-- las bases de usuario. Cubre los 10 puntos del checklist DBA de Sentinel:
--   estado de bases, discos y archivos (sys.dm_os_volume_stats, DBCC SQLPERF),
--   tempdb y log_reuse_wait, backups (msdb.dbo.backupset), jobs del Agent
--   (msdb.dbo.sysjobhistory), logins, bloqueos/PLE/CPU, páginas sospechosas
--   (msdb.dbo.suspect_pages), Always On / Mirroring y el Error Log.
--
-- Ejecutar en SSMS / sqlcmd como sysadmin, en cada instancia.
-- Antes de ejecutar: reemplazar <CLAVE_SEGURA> por una contraseña robusta.
-- Requiere autenticación mixta (SQL Server y Windows) en la instancia.
-- ============================================================================

USE [master];
GO

-- ── 1. Login ──
--    CHECK_POLICY=ON aplica la política de complejidad de Windows;
--    CHECK_EXPIRATION=OFF evita que expire y deje a Sentinel sin datos.
IF SUSER_ID(N'sentinel_mon') IS NULL
    CREATE LOGIN [sentinel_mon] WITH PASSWORD = N'<CLAVE_SEGURA>',
        DEFAULT_DATABASE = [master], CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
GO

-- ── 2. Permisos de servidor ──
--    VIEW SERVER STATE: DMVs de sesiones, bloqueos, esperas, discos, memoria,
--    Always On, DBCC SQLPERF y tempdb. En SQL Server 2022 equivale a
--    VIEW SERVER PERFORMANCE STATE + VIEW SERVER SECURITY STATE.
GRANT VIEW SERVER STATE TO [sentinel_mon];
--    VIEW ANY DEFINITION: sys.master_files y el estado de todos los logins.
GRANT VIEW ANY DEFINITION TO [sentinel_mon];
--    VIEW ANY DATABASE ya lo tiene public; se deja explícito.
GRANT VIEW ANY DATABASE TO [sentinel_mon];
GO

-- ── 3. Error Log (xp_readerrorlog) ──
IF USER_ID(N'sentinel_mon') IS NULL
    CREATE USER [sentinel_mon] FOR LOGIN [sentinel_mon];
GRANT EXECUTE ON sys.xp_readerrorlog TO [sentinel_mon];
GO

-- ── 4. msdb: backups, jobs del Agent y páginas sospechosas (solo SELECT) ──
USE [msdb];
GO
IF USER_ID(N'sentinel_mon') IS NULL
    CREATE USER [sentinel_mon] FOR LOGIN [sentinel_mon];
GRANT SELECT  ON dbo.backupset       TO [sentinel_mon];
GRANT SELECT  ON dbo.sysjobs         TO [sentinel_mon];
GRANT SELECT  ON dbo.sysjobhistory   TO [sentinel_mon];
GRANT SELECT  ON dbo.suspect_pages   TO [sentinel_mon];
GRANT EXECUTE ON dbo.agent_datetime  TO [sentinel_mon];
GO

-- ── 5. Base destino distinta de master (opcional) ──
--    Sentinel se conecta a la base indicada en db_name del servidores.ini
--    (por defecto master). Si es otra, el login necesita un usuario en ella:
-- USE [<BASE_DESTINO>];
-- CREATE USER [sentinel_mon] FOR LOGIN [sentinel_mon];
-- GO

-- ── 6. Verificación (conectado como sentinel_mon) ──
-- SELECT name, state_desc FROM sys.databases;
-- SELECT TOP 1 * FROM sys.dm_os_volume_stats(1, 1);
-- DBCC SQLPERF(LOGSPACE);
-- SELECT TOP 1 backup_finish_date FROM msdb.dbo.backupset ORDER BY backup_finish_date DESC;
-- EXEC sys.xp_readerrorlog 0, 1, N'Severity';

-- ── Para revertir ──
-- USE [msdb];   DROP USER [sentinel_mon];
-- USE [master]; DROP USER [sentinel_mon]; DROP LOGIN [sentinel_mon];
