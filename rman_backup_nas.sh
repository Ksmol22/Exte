#!/bin/bash
# =====================================================================
#  rman_backup_nas.sh
#  Respaldos RMAN directo a NAS, con ventana de recuperación de 2 días
#  y un punto de restauración (restore point) por cada respaldo diario.
#
#  Uso:
#    rman_backup_nas.sh full   -> nivel 0 comprimido + archivelogs
#                                 + punto de restauración + limpieza
#    rman_backup_nas.sh arch   -> solo archivelogs (cada pocas horas)
#
#  Crontab sugerido (usuario oracle):
#    15 1 * * *   /home/oracle/scripts/rman_backup_nas.sh full >/dev/null 2>&1
#    0 */2 * * *  /home/oracle/scripts/rman_backup_nas.sh arch >/dev/null 2>&1
#
#  Volver a un punto de restauración (ejemplo):
#    rman target /
#    SHUTDOWN IMMEDIATE;
#    STARTUP MOUNT;
#    RUN {
#      RESTORE DATABASE UNTIL RESTORE POINT RP_DIARIO_20261028_0115;
#      RECOVER DATABASE UNTIL RESTORE POINT RP_DIARIO_20261028_0115;
#    }
#    ALTER DATABASE OPEN RESETLOGS;
#
#  Ver los puntos disponibles:
#    SELECT name, time FROM v$restore_point ORDER BY time;
# =====================================================================

set -o pipefail

# ------------------- CONFIGURACIÓN (ajusta a tu entorno) -------------------
export ORACLE_SID=ORCL
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export PATH=$ORACLE_HOME/bin:$PATH
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'

NAS_MOUNT=/nas_backup                  # punto de montaje de la NAS
BACKUP_DIR=$NAS_MOUNT/rman/$ORACLE_SID # carpeta de respaldos en la NAS
LOG_DIR=/home/oracle/rman_logs         # logs en local (pesan muy poco)
DIAS_RETENCION=2                       # ventana de recuperación en días
CANALES=2                              # paralelismo; súbelo si red y NAS aguantan
RP_PREFIJO=RP_DIARIO                   # prefijo de los puntos de restauración
MIN_LIBRE_GB=50                        # aviso si la NAS baja de este espacio libre
MAIL_TO=""                             # ej. "dba@empresa.com" (requiere mailx); vacío = sin correo
DIAS_LOGS=15                           # días que se conservan los logs del script
# ---------------------------------------------------------------------------

MODO=${1:-}
FECHA=$(date +%Y%m%d_%H%M)
LOG=$LOG_DIR/rman_${MODO}_${ORACLE_SID}_${FECHA}.log
LOCK=/tmp/rman_backup_${ORACLE_SID}.lock
RP_NOMBRE=${RP_PREFIJO}_${FECHA}

case "$MODO" in
  full|arch) ;;
  *) echo "Uso: $0 {full|arch}"; exit 2 ;;
esac

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

notificar() {
  if [ -n "$MAIL_TO" ] && command -v mailx >/dev/null 2>&1; then
    tail -n 100 "$LOG" | mailx -s "$1" "$MAIL_TO"
  fi
}

fallar() {
  log "ERROR: $*"
  notificar "[RMAN][$ORACLE_SID] FALLO respaldo $MODO"
  exit 1
}

# --- Evitar dos ejecuciones al mismo tiempo ---
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Ya hay un respaldo de $ORACLE_SID en curso; no hago nada."
  exit 3
fi

log "Inicio respaldo modo=$MODO SID=$ORACLE_SID"

# --- Verificar la NAS ANTES de respaldar ---
# Si la NAS no está montada, la carpeta existiría en el disco local y
# RMAN lo llenaría. Por eso se aborta.
if ! mountpoint -q "$NAS_MOUNT"; then
  fallar "La NAS no está montada en $NAS_MOUNT. Se cancela para no llenar el disco local."
fi

mkdir -p "$BACKUP_DIR" || fallar "No se pudo crear $BACKUP_DIR"

PRUEBA=$BACKUP_DIR/.prueba_escritura_$$
if ! touch "$PRUEBA" 2>/dev/null; then
  fallar "Sin permiso de escritura en $BACKUP_DIR (revisa UID/GID de oracle en la NAS)"
fi
rm -f "$PRUEBA"

LIBRE_GB=$(df -P -BG "$NAS_MOUNT" | awk 'NR==2 {gsub("G","",$4); print $4}')
log "Espacio libre en NAS: ${LIBRE_GB} GB"
if [ -n "$LIBRE_GB" ] && [ "$LIBRE_GB" -lt "$MIN_LIBRE_GB" ]; then
  log "AVISO: queda poco espacio en la NAS (${LIBRE_GB} GB < ${MIN_LIBRE_GB} GB)"
  notificar "[RMAN][$ORACLE_SID] AVISO poco espacio en NAS: ${LIBRE_GB} GB"
fi

# --- Configuración persistente de RMAN (idempotente, se aplica en cada corrida) ---
CONFIG_RMAN="
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${DIAS_RETENCION} DAYS;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${BACKUP_DIR}/cf_%F';
CONFIGURE DEVICE TYPE DISK PARALLELISM ${CANALES} BACKUP TYPE TO COMPRESSED BACKUPSET;
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '${BACKUP_DIR}/%d_%T_%U';
CONFIGURE ARCHIVELOG DELETION POLICY TO BACKED UP 1 TIMES TO DISK;
"

# --- Comandos según el modo ---
if [ "$MODO" = "full" ]; then
  CMDS_RMAN="
${CONFIG_RMAN}
# 1) Vaciar los archivelogs pendientes del disco local hacia la NAS
SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
BACKUP TAG 'ARCH_PRE_${FECHA}' ARCHIVELOG ALL NOT BACKED UP 1 TIMES DELETE ALL INPUT;

# 2) Respaldo nivel 0 (completo, comprimido)
BACKUP INCREMENTAL LEVEL 0 TAG 'NIVEL0_${FECHA}' DATABASE;

# 3) Punto de restauración con nombre, justo al terminar el respaldo
SQL 'CREATE RESTORE POINT ${RP_NOMBRE}';

# 4) Archivelogs generados durante el respaldo (cubren hasta el punto de restauración)
SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
BACKUP TAG 'ARCH_POST_${FECHA}' ARCHIVELOG ALL NOT BACKED UP 1 TIMES DELETE ALL INPUT;

# 5) Spfile y control file
BACKUP TAG 'SPFILE_${FECHA}' SPFILE;
BACKUP TAG 'CTL_${FECHA}' CURRENT CONTROLFILE;

# 6) Limpieza: todo lo que quede fuera de la ventana de ${DIAS_RETENCION} días
CROSSCHECK BACKUP;
CROSSCHECK ARCHIVELOG ALL;
DELETE NOPROMPT OBSOLETE;
DELETE NOPROMPT EXPIRED BACKUP;
"
else
  CMDS_RMAN="
${CONFIG_RMAN}
SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
BACKUP TAG 'ARCH_${FECHA}' ARCHIVELOG ALL NOT BACKED UP 1 TIMES DELETE ALL INPUT;
"
fi

# --- Ejecutar RMAN ---
rman target / log="$LOG" append <<EOF
${CMDS_RMAN}
EXIT;
EOF
RC=$?

if [ $RC -ne 0 ] || grep -q "ERROR MESSAGE STACK FOLLOWS" "$LOG"; then
  fallar "RMAN terminó con errores (código $RC). Revisa $LOG"
fi

# --- Borrar puntos de restauración fuera de la ventana (solo modo full) ---
if [ "$MODO" = "full" ]; then
  log "Eliminando puntos de restauración con más de ${DIAS_RETENCION} días"
  sqlplus -s / as sysdba >> "$LOG" 2>&1 <<EOF
WHENEVER SQLERROR EXIT FAILURE
SET SERVEROUTPUT ON FEEDBACK OFF
BEGIN
  FOR r IN (SELECT name
              FROM v\$restore_point
             WHERE name LIKE '${RP_PREFIJO}%'
               AND guarantee_flashback_database = 'NO'
               AND time < SYSTIMESTAMP - INTERVAL '${DIAS_RETENCION}' DAY)
  LOOP
    EXECUTE IMMEDIATE 'DROP RESTORE POINT "' || r.name || '"';
    DBMS_OUTPUT.PUT_LINE('Eliminado: ' || r.name);
  END LOOP;
END;
/
EXIT
EOF
  [ $? -eq 0 ] || fallar "No se pudieron limpiar los puntos de restauración antiguos"
  log "Punto de restauración creado: ${RP_NOMBRE}"
fi

# --- Limpiar logs viejos del script ---
find "$LOG_DIR" -name 'rman_*.log' -mtime +"$DIAS_LOGS" -delete 2>/dev/null

log "Respaldo $MODO terminado correctamente"
exit 0
