#!/bin/bash
# =============================================================================
#  rman_19c.sh - Backups RMAN para Oracle Database 19c (CDB con PDBs o non-CDB)
#                Retencion de 1 dia y depuracion automatica de backups,
#                archivelogs y logs del script. Sin dependencias de red.
#
#  Uso:   rman_19c.sh <ORACLE_SID> <MODO>
#
#  Modos:
#    SETUP     Aplica la configuracion RMAN (ejecutar una vez, a mano) y revisa
#              que la FRA pueda depurarse sola. Muestra avisos si algo lo impide.
#    FULL      Backup nivel 0 comprimido de la base completa (en un CDB incluye
#              root, seed y todas las PDBs) + archivelogs + depuracion.
#    ARCH      Backup de archivelogs, los elimina del disco + depuracion.
#    CHECK     Vigila FRA y filesystem; si superan el umbral lanza ARCH.
#    VALIDATE  Comprueba que los backups se pueden restaurar (no restaura nada).
#    ESTADO    Muestra uso de la FRA, ultimos backups y obsoletos (manual).
#
#  Cron sugerido (usuario oracle). Repetir el bloque por cada base del servidor:
#    0 1 * * *     /home/oracle/scripts/rman_19c.sh ORCL FULL
#    0 */2 * * *   /home/oracle/scripts/rman_19c.sh ORCL ARCH
#    */15 * * * *  /home/oracle/scripts/rman_19c.sh ORCL CHECK
#    0 5 * * 0     /home/oracle/scripts/rman_19c.sh ORCL VALIDATE
#
#  Errores: <LOG_BASE>/<SID>/ERRORES.log y syslog local (tag "rman_19c").
#  Ejecutado a mano desde una terminal, tambien muestra todo en pantalla.
#
#  Notas:
#   - Pensado para instancia unica (no RAC).
#   - Detecta solo si la base es CDB o non-CDB. En un CDB siempre se conecta
#     al root (CDB$ROOT); nunca ejecutarlo contra una PDB.
#   - En un standby el script no hace nada (sale sin error), asi el mismo cron
#     sirve en ambos servidores tras un switchover.
#   - SETUP ejecuta "CONFIGURE CHANNEL DEVICE TYPE DISK CLEAR" para que los
#     backups vayan a la FRA. Si hoy usan un FORMAT a otra ruta, se elimina.
# =============================================================================

# =========================== PARAMETROS ======================================
LOG_BASE=/home/oracle/rman_logs   # logs del script (una carpeta por SID)
LOG_DIAS=7                        # dias que se conservan los logs del script

# Politica de retencion:
#   "RECOVERY WINDOW OF 1 DAYS" -> restaurar a cualquier punto de las ultimas
#                                  24 h. Ocupa ~2 fulls + ~48 h de archives.
#   "REDUNDANCY 1"              -> solo el ultimo full + archives desde ese
#                                  full. Minimo espacio; ventana de 0 a 24 h.
POLITICA="RECOVERY WINDOW OF 1 DAYS"

PARALELISMO=2        # canales RMAN (ajustar segun CPUs y discos)
SECTION_SIZE=32G     # backup multiseccion de datafiles grandes
UMBRAL_FRA=80        # % de uso de FRA que dispara backup de archives (CHECK)
UMBRAL_FS=90         # % de uso del filesystem de la FRA que dispara (CHECK)
ESPERA_LOCK=1800     # segundos que FULL espera si hay un ARCH en curso
# =============================================================================

ORACLE_SID=$1
MODO=$(echo "$2" | tr '[:lower:]' '[:upper:]')

case "$MODO" in
  SETUP|FULL|ARCH|CHECK|VALIDATE|ESTADO) ;;
  *) echo "Uso: $0 <ORACLE_SID> SETUP|FULL|ARCH|CHECK|VALIDATE|ESTADO"; exit 1 ;;
esac

LOG_DIR="$LOG_BASE/$ORACLE_SID"
mkdir -p "$LOG_DIR" || { echo "ERROR: no se pudo crear $LOG_DIR" >&2; exit 1; }
if [ "$MODO" = "CHECK" ]; then
  LOG="$LOG_DIR/check_fra.log"
else
  LOG="$LOG_DIR/rman_${MODO}_$(date +%Y%m%d_%H%M%S).log"
fi
ERRLOG="$LOG_DIR/ERRORES.log"

# --------------------------- Utilidades --------------------------------------
# Si se ejecuta a mano (terminal), todo se muestra tambien en pantalla.
INTERACTIVO=0
[ -t 1 ] && INTERACTIVO=1

log() {
  local l
  l="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$l" >> "$LOG"
  if [ "$INTERACTIVO" -eq 1 ]; then echo "$l"; fi
}

# Copia stdin al log (y a pantalla si es interactivo)
volcar() {
  if [ "$INTERACTIVO" -eq 1 ]; then tee -a "$LOG"; else cat >> "$LOG"; fi
}

error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$ORACLE_SID][$MODO] $1 -> $LOG" >> "$ERRLOG"
  logger -t rman_19c -p user.err "[$ORACLE_SID][$MODO] $1" 2>/dev/null
  log "ERROR: $1"
}

es_num() { [[ "$1" =~ ^-?[0-9]+$ ]]; }

# Ejecuta SQL (leido de stdin) como SYSDBA (en un CDB, en el root)
sql() {
  { echo "set heading off feedback off pagesize 0 verify off linesize 400 trimout on tab off"
    echo "whenever sqlerror exit 1"
    cat
    echo "exit"
  } | sqlplus -s -L / as sysdba
}

# Ejecuta comandos RMAN (leidos de stdin). Devuelve 1 si hubo errores.
run_rman() {
  local tmp rc
  tmp=$(mktemp "$LOG_DIR/.rman_XXXXXX")
  { echo "SET ECHO ON;"; cat; echo "EXIT;"; } | rman target / > "$tmp" 2>&1
  rc=${PIPESTATUS[1]}
  volcar < "$tmp"
  if [ "$rc" -ne 0 ] || grep -q "RMAN-00569" "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"; return 0
}

uso_fra() {
  sql <<'EOF' | tr -d '[:space:]'
select nvl(round((space_used - space_reclaimable) * 100 / nullif(space_limit,0)), -1)
from v$recovery_file_dest;
EOF
}

ruta_fra() {
  sql <<'EOF' | tr -d '[:space:]'
select value from v$parameter where name = 'db_recovery_file_dest';
EOF
}

uso_fs() {
  # % de uso del filesystem de la FRA (-1 si es ASM o no se puede medir)
  local ruta=$1
  if [ -z "$ruta" ] || [[ "$ruta" == +* ]]; then echo -1; return; fi
  df -P "$ruta" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}'
}

# --------------------------- Entorno 19c -------------------------------------
# 1) /etc/oratab  2) proceso pmon de la instancia en ejecucion
OH_ORATAB=""
if [ -r /etc/oratab ]; then
  OH_ORATAB=$(awk -F: -v sid="$ORACLE_SID" '$1==sid {print $2; exit}' /etc/oratab)
fi
ORACLE_HOME="$OH_ORATAB"
if [ -z "$ORACLE_HOME" ] || [ ! -x "$ORACLE_HOME/bin/rman" ]; then
  PMON_PID=$(pgrep -f "^ora_pmon_${ORACLE_SID}\$" | head -1)
  if [ -n "$PMON_PID" ]; then
    EXE=$(readlink "/proc/$PMON_PID/exe" 2>/dev/null)       # <ORACLE_HOME>/bin/oracle
    [ -n "$EXE" ] && ORACLE_HOME=$(dirname "$(dirname "$EXE")")
  fi
fi
if [ -z "$ORACLE_HOME" ] || [ ! -x "$ORACLE_HOME/bin/rman" ]; then
  SIDS_ORATAB=$(grep -Ev '^[[:space:]]*(#|$)' /etc/oratab 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
  SIDS_ACTIVOS=$(pgrep -a -f '^ora_pmon_' 2>/dev/null | sed 's/.*ora_pmon_//' | tr '\n' ' ')
  error "No se encontro un ORACLE_HOME valido para '$ORACLE_SID'. SIDs en /etc/oratab: [${SIDS_ORATAB:-ninguno}] | instancias en ejecucion: [${SIDS_ACTIVOS:-ninguna}]"
  exit 1
fi
if [ -z "$OH_ORATAB" ]; then
  log "AVISO: '$ORACLE_SID' no esta en /etc/oratab; ORACLE_HOME tomado de la instancia: $ORACLE_HOME"
fi
export ORACLE_SID ORACLE_HOME
ORACLE_BASE=$("$ORACLE_HOME/bin/orabase" 2>/dev/null)   # existe desde 18c
export ORACLE_BASE
export PATH="$ORACLE_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LD_LIBRARY_PATH="$ORACLE_HOME/lib"
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8      # mensajes en ingles para validar errores
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
unset ORACLE_PDB_SID TWO_TASK                  # en un CDB, forzar conexion al root
umask 027

# Bloqueos: 8 = backups de base (FULL/VALIDATE/SETUP), 9 = archivelogs.
# Separados para que los archives se puedan respaldar mientras corre un FULL.
exec 8>"$LOG_DIR/.lock_db"
exec 9>"$LOG_DIR/.lock_arch"

# --------------------------- Validaciones ------------------------------------
# 0 = OK | 1 = error | 2 = no es primario (no hacer nada)
precheck() {
  local out linea
  out=$(sql <<'EOF'
select d.cdb||'|'||d.open_mode||'|'||d.database_role||'|'||d.log_mode||'|'||
       sys_context('USERENV','CON_NAME')||'|'||i.version_full
from v$database d, v$instance i;
EOF
)
  linea=$(echo "$out" | grep -m1 '|')
  if [ -z "$linea" ]; then
    MOTIVO="La instancia no responde: $(echo "$out" | grep -m1 -E 'ORA-|SP2-')"
    return 1
  fi
  IFS='|' read -r DB_CDB DB_OPEN DB_ROLE DB_LOGMODE DB_CON DB_VERSION <<< "$linea"

  if [ "$DB_ROLE" != "PRIMARY" ]; then
    MOTIVO="Rol $DB_ROLE: los backups se ejecutan solo en el primario"; return 2
  fi
  # 19c admite CDB y non-CDB. En un CDB hay que estar en el root.
  if [ "$DB_CDB" = "YES" ] && [ "$DB_CON" != 'CDB$ROOT' ]; then
    MOTIVO="Conectado a $DB_CON; se requiere CDB\$ROOT"; return 1
  fi
  if [ "$DB_CDB" != "YES" ]; then DB_CON="NON-CDB"; fi
  if [ "$DB_LOGMODE" != "ARCHIVELOG" ]; then
    MOTIVO="La base no esta en modo ARCHIVELOG"; return 1
  fi
  if [ "$DB_OPEN" != "READ WRITE" ]; then
    MOTIVO="La base esta en $DB_OPEN; se requiere READ WRITE"; return 1
  fi
  if [ -z "$(ruta_fra)" ]; then
    MOTIVO="No hay FRA configurada (db_recovery_file_dest)"; return 1
  fi
  [[ "$DB_VERSION" == 19.* ]] || log "AVISO: version $DB_VERSION (script pensado para 19c)"
  return 0
}

# --------------------------- Operaciones -------------------------------------
backup_arch() {
  # $1 = segundos de espera por el lock (0 = no esperar). Devuelve 3 si se omite.
  local espera=$1 rc
  if [ "$espera" -eq 0 ]; then
    flock -n 9 || { log "Otro backup de archivelogs en curso; se omite."; return 3; }
  else
    flock -w "$espera" 9 || { log "No se obtuvo el lock de archivelogs en ${espera}s."; return 3; }
  fi
  run_rman <<EOF
CROSSCHECK ARCHIVELOG ALL;
DELETE NOPROMPT EXPIRED ARCHIVELOG ALL;
ALTER SYSTEM ARCHIVE LOG CURRENT;
BACKUP AS COMPRESSED BACKUPSET ARCHIVELOG ALL NOT BACKED UP 1 TIMES DELETE ALL INPUT TAG 'ARCH';
DELETE NOPROMPT OBSOLETE ${POLITICA};
EOF
  rc=$?
  flock -u 9
  return $rc
}

modo_full() {
  local rc=0
  flock -n 8 || { log "Ya hay un FULL/VALIDATE/SETUP en curso; se omite."; return 0; }

  # 1) Liberar archives antes del full
  backup_arch "$ESPERA_LOCK" || rc=1

  # 2) Full nivel 0 de la base completa (en un CDB incluye todas las PDBs)
  run_rman <<EOF || rc=1
CROSSCHECK BACKUP;
DELETE NOPROMPT EXPIRED BACKUP;
BACKUP AS COMPRESSED BACKUPSET INCREMENTAL LEVEL 0 SECTION SIZE ${SECTION_SIZE} DATABASE TAG 'FULL_DIARIO';
EOF

  # 3) Archives generados durante el full + depuracion de obsoletos
  backup_arch "$ESPERA_LOCK" || rc=1
  return $rc
}

modo_validate() {
  local arch_val=""
  flock -n 8 || { log "Ya hay un FULL/VALIDATE/SETUP en curso; se omite."; return 0; }
  # Con REDUNDANCY 1 no siempre existen archives de 24 h atras
  [[ "$POLITICA" == RECOVERY* ]] && arch_val="RESTORE ARCHIVELOG FROM TIME 'SYSDATE-1' VALIDATE;"
  run_rman <<EOF
RESTORE DATABASE VALIDATE CHECK LOGICAL;
RESTORE CONTROLFILE VALIDATE;
${arch_val}
EOF
}

modo_check() {
  local pct fs
  pct=$(uso_fra)
  fs=$(uso_fs "$(ruta_fra)")
  es_num "$pct" || pct=-1
  es_num "$fs"  || fs=-1
  if [ "$pct" -ge 95 ]; then
    error "FRA en nivel critico: ${pct}%"
  fi
  if [ "$pct" -ge "$UMBRAL_FRA" ] || [ "$fs" -ge "$UMBRAL_FS" ]; then
    log "FRA ${pct}% / filesystem ${fs}% -> se lanza backup de archivelogs"
    exec "$0" "$ORACLE_SID" ARCH
  fi
}

modo_setup() {
  local rc=0 n_std del_policy fra n lim used avail fb
  flock -n 8 || { log "Ya hay un FULL/VALIDATE en curso; reintente luego."; return 1; }

  # Data Guard: no borrar archives que el standby aun no aplico
  n_std=$(sql <<'EOF' | tr -d '[:space:]'
select count(*) from v$archive_dest where target = 'STANDBY' and status = 'VALID';
EOF
)
  if es_num "$n_std" && [ "$n_std" -gt 0 ]; then
    del_policy="APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DEVICE TYPE DISK"
    log "Data Guard detectado ($n_std destino/s standby)."
  else
    del_policy="BACKED UP 1 TIMES TO DEVICE TYPE DISK"
  fi

  run_rman <<EOF || rc=1
CONFIGURE RETENTION POLICY TO ${POLITICA};
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK CLEAR;
CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE DEFAULT DEVICE TYPE TO DISK;
CONFIGURE DEVICE TYPE DISK PARALLELISM ${PARALELISMO} BACKUP TYPE TO COMPRESSED BACKUPSET;
CONFIGURE COMPRESSION ALGORITHM 'BASIC';
CONFIGURE CHANNEL DEVICE TYPE DISK CLEAR;
CONFIGURE ARCHIVELOG DELETION POLICY TO ${del_policy};
SHOW ALL;
EOF

  # --- Revisiones que impiden la depuracion automatica ---
  n=$(sql <<'EOF' | tr -d '[:space:]'
select count(*) from v$archive_dest
where status = 'VALID' and target = 'PRIMARY'
  and destination <> 'USE_DB_RECOVERY_FILE_DEST';
EOF
)
  if es_num "$n" && [ "$n" -gt 0 ]; then
    log "AVISO: hay $n destino/s de archive fuera de la FRA; Oracle no los depura solo."
    log "       Use: ALTER SYSTEM SET log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST' SCOPE=BOTH;"
  fi

  n=$(sql <<'EOF' | tr -d '[:space:]'
select count(*) from v$restore_point where guarantee_flashback_database = 'YES';
EOF
)
  if es_num "$n" && [ "$n" -gt 0 ]; then
    log "AVISO: hay $n restore point/s garantizado/s; bloquean la depuracion de la FRA."
  fi

  fb=$(sql <<'EOF' | tr -d '[:space:]'
select d.flashback_on||'|'||p.value
from v$database d, v$parameter p where p.name = 'db_flashback_retention_target';
EOF
)
  if [[ "$fb" == YES\|* ]] && es_num "${fb#*|}" && [ "${fb#*|}" -gt 1440 ]; then
    log "AVISO: flashback retiene ${fb#*|} min. Para 1 dia: ALTER SYSTEM SET db_flashback_retention_target=1440;"
  fi

  # Tamano de la FRA vs espacio real del filesystem
  fra=$(ruta_fra)
  if [[ "$fra" != +* ]]; then
    read -r lim used <<< "$(sql <<'EOF'
select round(space_limit/1024)||' '||round(space_used/1024) from v$recovery_file_dest;
EOF
)"
    avail=$(df -Pk "$fra" 2>/dev/null | awk 'NR==2 {print $4}')
    if es_num "$lim" && es_num "$used" && es_num "$avail" && \
       [ "$lim" -gt $(( (used + avail) * 95 / 100 )) ]; then
      log "AVISO: db_recovery_file_dest_size ($((lim/1024/1024)) GB) es mayor que el espacio real"
      log "       disponible (~$(((used + avail)/1024/1024)) GB). El disco se llenaria antes que la FRA."
      log "       Reduzca db_recovery_file_dest_size para que Oracle depure a tiempo."
    fi
  fi
  return $rc
}

modo_estado() {
  sql <<'EOF' | volcar
set heading on pagesize 100 linesize 200
col name format a40
prompt
prompt === FRA ===
select name, round(space_limit/1073741824,1) limite_gb, round(space_used/1073741824,1) usado_gb,
       round(space_reclaimable/1073741824,1) liberable_gb
from v$recovery_file_dest;
select file_type, percent_space_used pct_usado, percent_space_reclaimable pct_liberable,
       number_of_files archivos
from v$recovery_area_usage where number_of_files > 0;
prompt
prompt === Backups ultimas 48 h ===
select to_char(start_time,'YYYY-MM-DD HH24:MI') inicio, input_type tipo, status estado,
       round(output_bytes/1073741824,2) gb, time_taken_display duracion
from v$rman_backup_job_details
where start_time > sysdate - 2 order by start_time;
EOF
  run_rman <<EOF
LIST BACKUP OF DATABASE SUMMARY;
REPORT OBSOLETE;
EOF
}

depurar_logs() {
  find "$LOG_DIR" -maxdepth 1 -name 'rman_*.log' -mtime +"$LOG_DIAS" -delete 2>/dev/null
  find "$LOG_DIR" -maxdepth 1 -name '.rman_*' -mtime +1 -delete 2>/dev/null
  local f
  for f in "$ERRLOG" "$LOG_DIR/check_fra.log"; do
    if [ -f "$f" ] && [ "$(wc -l < "$f")" -gt 1000 ]; then
      tail -n 1000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
  done
}

# =========================== PRINCIPAL =======================================
if [ "$MODO" = "CHECK" ]; then
  precheck || exit 0          # base caida o standby: no hacer nada
  modo_check
  exit 0
fi

log "===== Inicio $MODO ($ORACLE_SID) ====="
precheck; PR=$?
if [ $PR -eq 2 ]; then log "$MOTIVO. No se ejecuta nada."; exit 0; fi
if [ $PR -ne 0 ]; then error "$MOTIVO"; exit 1; fi
log "CDB=$DB_CDB contenedor=$DB_CON version=$DB_VERSION rol=$DB_ROLE"

RC=0
case "$MODO" in
  SETUP)    modo_setup    || RC=1 ;;
  FULL)     modo_full     || RC=1 ;;
  ARCH)     backup_arch 0; R=$?; [ $R -ne 0 ] && [ $R -ne 3 ] && RC=1 ;;
  VALIDATE) modo_validate || RC=1 ;;
  ESTADO)   modo_estado   || RC=1 ;;
esac

log "Uso de la FRA al terminar: $(uso_fra)%"
if grep -qE "RMAN-08137|RMAN-08120" "$LOG"; then
  log "AVISO: algunos archivelogs no se borraron (standby aun no los aplica o falta backup)."
fi
[ $RC -ne 0 ] && error "Termino con errores"
log "===== Fin $MODO RC=$RC ====="

depurar_logs
exit $RC
