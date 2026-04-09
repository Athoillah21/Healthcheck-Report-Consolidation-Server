#!/bin/bash

# ==============================================================================
# ENHANCED HEALTHCHECK REPORT - hc-report.sh (v2 - Minimalistic)
# Generates a premium minimalistic HTML report with dark/light toggle,
# hostname grouping, vertical bar charts, and alert detail lists.
# ==============================================================================

# ==============================================================================
# CONFIGURATION VARIABLES
# ==============================================================================
LIST_DB_FILE="/replication_mail/list_db_test_mp_2"
DB_USER="p"
DB_PASSWORD="p"

PEM_HOST="localhost"
PEM_PORT="5433"
PEM_USER="p"
PEM_DB="p"

DEAD_TUPLES_WARN_THRESHOLD=200000
DEAD_TUPLES_ALERT_THRESHOLD=1000000
XID_AGE_WARN_THRESHOLD=250000000
XID_AGE_ALERT_THRESHOLD=1000000000
CONN_WARN_PERCENT=80
CONN_ALERT_PERCENT=90
MOUNTPOINT_ALERT_THRESHOLD=80
REPLICATION_LAG_DELAY_BYTES=10485760

SUBJECT="[Testing Report] PostgreSQL Database Healthcheck Report"

DATE=$(date +"%Y-%m-%d")
TIME=$(date +"%H:%M:%S")
DATETIME=$(date +"%Y-%m-%d_%H:%M:%S")
OUTPUT_HTML="/report/daily_health_check_report_${DATETIME}_enhanced.html"

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

human_readable_bytes() {
    local bytes=$1
    if (( bytes < 1024 )); then echo "${bytes} B"
    elif (( bytes < 1048576 )); then echo "$(( bytes / 1024 )) KB"
    elif (( bytes < 1073741824 )); then echo "$(( bytes / 1048576 )) MB"
    else echo "$(( bytes / 1073741824 )) GB"; fi
}

format_large_number() {
    local num=$1
    if [[ -z "$num" || "$num" -eq 0 ]]; then echo "0"; return; fi
    if (( num >= 1000000000 )); then awk -v n="$num" "BEGIN {printf \"%.2fB\", n / 1000000000}"
    elif (( num >= 1000000 )); then awk -v n="$num" "BEGIN {printf \"%.1fM\", n / 1000000}"
    else echo "$num"; fi
}

run_psql_query() {
    local host=$1 port=$2 dbname=$3 query=$4
    psql -h "$host" -p "$port" -U "$DB_USER" -d "$dbname" -t -A -F"," -c "$query" 2>/dev/null
    return $?
}

run_psql_query_pem() {
    local query=$1
    psql -h "$PEM_HOST" -p "$PEM_PORT" -U "$PEM_USER" -d "$PEM_DB" -t -A -F"," -c "$query"
    return $?
}

json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/}"
    echo "$str"
}

# ==============================================================================
# INITIAL CHECKS
# ==============================================================================
if [[ ! -f "$LIST_DB_FILE" ]]; then
    echo "Error: File '$LIST_DB_FILE' not found!"
    exit 1
fi

# ==============================================================================
# MAIN PROCESSING LOOP
# ==============================================================================
JSON_INSTANCES=""
INSTANCE_INDEX=0
CURRENT_ALERTS_FILE="/tmp/hc_current_alerts.txt"
> "$CURRENT_ALERTS_FILE"

while IFS=',' read -r HOSTNAME IP PORT DBNAME DISPLAY_NAME MP; do
    if [[ -z "$HOSTNAME" || "$HOSTNAME" == \#* ]]; then continue; fi

    echo "Checking $DISPLAY_NAME ($DBNAME) at $IP:$PORT..."

    ROLE_STATUS_HTML=""
    ROLE_STATUS_CLASS="ok"
    MASTER_STATUS="N/A"
    CONN_PERCENT="N/A"; CONN_STATUS_CLASS="na"
    DEAD_TUPLES="N/A"; DEAD_TUPLES_CLASS="na"
    XID_AGE="N/A"; XID_AGE_CLASS="na"
    BLOCKING_COUNT="N/A"; BLOCKING_CLASS="na"
    MOUNTPOINT_USAGE="N/A"; MOUNTPOINT_CLASS="na"

    # 1. Connection Check
    CONN_QUERY="SELECT setting::integer AS max_conn, (SELECT count(*)::float FROM pg_stat_activity) AS current_conn FROM pg_settings WHERE name = 'max_connections';"
    export PGPASSWORD="${DB_PASSWORD}"
    CONN_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$CONN_QUERY")
    PSQL_EXIT_CODE=$?
    unset PGPASSWORD

    if [[ $PSQL_EXIT_CODE -ne 0 ]]; then
        echo "Error: Failed to connect to $DISPLAY_NAME"
        [[ $INSTANCE_INDEX -gt 0 ]] && JSON_INSTANCES+=","
        JSON_INSTANCES+="{\"name\":\"$(json_escape "$DISPLAY_NAME")\",\"hostname\":\"$(json_escape "$HOSTNAME")\",\"port\":\"$PORT\","
        JSON_INSTANCES+="\"masterStatus\":\"FAILED\","
        JSON_INSTANCES+="\"replication\":{\"html\":\"<span class='p p-alert'>FAILED</span>\",\"status\":\"alert\"},"
        JSON_INSTANCES+="\"connection\":{\"html\":\"N/A\",\"status\":\"alert\"},"
        JSON_INSTANCES+="\"deadTuples\":{\"html\":\"N/A\",\"status\":\"alert\"},"
        JSON_INSTANCES+="\"xidAge\":{\"html\":\"N/A\",\"status\":\"alert\"},"
        JSON_INSTANCES+="\"blocking\":{\"html\":\"N/A\",\"status\":\"alert\"},"
        JSON_INSTANCES+="\"mountpoint\":{\"html\":\"N/A\",\"status\":\"alert\"}}"
        INSTANCE_INDEX=$((INSTANCE_INDEX + 1))
        continue
    fi

    IFS=',' read -r MAX_CONN CURRENT_CONN <<< "$CONN_RESULT"
    if [[ -n "$MAX_CONN" && "$MAX_CONN" -ne 0 ]]; then
        CONN_RAW_PERCENT=$(awk "BEGIN {printf \"%.0f\", ($CURRENT_CONN * 100) / $MAX_CONN}")
        if (( CONN_RAW_PERCENT >= CONN_ALERT_PERCENT )); then CONN_STATUS_CLASS="alert"
        elif (( CONN_RAW_PERCENT >= CONN_WARN_PERCENT )); then CONN_STATUS_CLASS="warn"
        else CONN_STATUS_CLASS="ok"; fi
        CONN_PERCENT="${CURRENT_CONN}/${MAX_CONN} (${CONN_RAW_PERCENT}%)"
    fi

    # 2. Replication
    ROLE_CHECK_QUERY="SELECT pg_is_in_recovery();"
    export PGPASSWORD="${DB_PASSWORD}"
    IS_REPLICA=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$ROLE_CHECK_QUERY" | xargs)
    unset PGPASSWORD

    if [[ "$IS_REPLICA" == "f" ]]; then
        MASTER_STATUS="Master"
        MASTER_STATS_QUERY="SELECT count(*) FILTER (WHERE application_name <> 'pg_basebackup') AS replica_count, count(*) FILTER (WHERE state = 'streaming' AND application_name <> 'pg_basebackup') AS streaming_count, count(*) FILTER (WHERE application_name = 'pg_basebackup') AS backup_count, COALESCE(max(COALESCE(pg_wal_lsn_diff(sent_lsn, replay_lsn), 0)) FILTER (WHERE application_name <> 'pg_basebackup'), 0) AS max_lag_bytes FROM pg_stat_replication;"
        export PGPASSWORD="${DB_PASSWORD}"
        MASTER_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$MASTER_STATS_QUERY")
        IFS=',' read -r REPLICA_COUNT STREAMING_COUNT BACKUP_COUNT MAX_LAG_BYTES <<< "$MASTER_RESULT"
        unset PGPASSWORD

        if [[ "$REPLICA_COUNT" -eq 0 && "$BACKUP_COUNT" -eq 0 ]]; then
            ROLE_STATUS_HTML="<span class='p p-unsync'>UNSYNC</span> <br><small>(No Replicas)</small>"
            ROLE_STATUS_CLASS="alert"
        elif [[ "$STREAMING_COUNT" -eq 0 ]]; then
            ROLE_STATUS_CLASS="alert"
            if [[ "$BACKUP_COUNT" -gt 0 ]]; then
                ROLE_STATUS_HTML="<span class='p p-unsync'>UNSYNC</span> <br><small>(Backup Running)</small>"
            else
                STATE_QUERY="SELECT state FROM pg_stat_replication WHERE application_name <> 'pg_basebackup' AND state <> 'streaming' LIMIT 1;"
                export PGPASSWORD="${DB_PASSWORD}"
                OTHER_STATE=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$STATE_QUERY" | xargs)
                unset PGPASSWORD
                if [[ -n "$OTHER_STATE" ]]; then
                    ROLE_STATUS_HTML="<span class='p p-unsync'>UNSYNC</span> <br><small>(${OTHER_STATE^})</small>"
                else
                    ROLE_STATUS_HTML="<span class='p p-unsync'>UNSYNC</span> <br><small>(Not Streaming)</small>"
                fi
            fi
        elif [[ "$MAX_LAG_BYTES" -gt "$REPLICATION_LAG_DELAY_BYTES" ]]; then
            HUMAN_LAG=$(human_readable_bytes "$MAX_LAG_BYTES")
            ROLE_STATUS_HTML="<span class='p p-unsync'>DELAY</span> <br><small>(Lag: $HUMAN_LAG)</small>"
            ROLE_STATUS_CLASS="alert"
            [[ "$BACKUP_COUNT" -gt 0 ]] && ROLE_STATUS_HTML="$ROLE_STATUS_HTML, Backup Running"
        else
            ROLE_STATUS_HTML="<span class='p p-sync'>SYNC</span>"
            ROLE_STATUS_CLASS="ok"
            [[ "$BACKUP_COUNT" -gt 0 ]] && ROLE_STATUS_HTML="$ROLE_STATUS_HTML , Backup Running"
        fi
    elif [[ "$IS_REPLICA" == "t" ]]; then
        MASTER_STATUS="Slave"
        WAL_RECEIVER_QUERY="SELECT count(*) FROM pg_stat_wal_receiver;"
        export PGPASSWORD="${DB_PASSWORD}"
        WAL_RECEIVER_COUNT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$WAL_RECEIVER_QUERY" | xargs)
        unset PGPASSWORD
        if [[ "$WAL_RECEIVER_COUNT" -gt 0 ]]; then
            ROLE_STATUS_HTML="<span class='p p-replica'>SYNC</span> <br><small>(Replica)</small>"
            ROLE_STATUS_CLASS="ok"
        else
            ROLE_STATUS_HTML="<span class='p p-unsync'>UNSYNC</span> <br><small>(Receiver Down)</small>"
            ROLE_STATUS_CLASS="alert"
        fi
    else
        MASTER_STATUS="Unknown"
        ROLE_STATUS_HTML="<span class='p p-unsync'>UNKNOWN</span>"
        ROLE_STATUS_CLASS="alert"
    fi

    # (Si) = Single Instance: replication UNSYNC is expected, not critical
    if [[ "$DISPLAY_NAME" == *"(Si)"* && "$ROLE_STATUS_CLASS" == "alert" ]]; then
        ROLE_STATUS_CLASS="ok"
    fi

    # 3. Dead Tuples
    DEAD_TUPLES_QUERY="SELECT schemaname, relname, n_dead_tup FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 1;"
    export PGPASSWORD="${DB_PASSWORD}"
    DEAD_TUPLES_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$DEAD_TUPLES_QUERY")
    IFS=',' read -r SCHEMANAME RELNAME DEAD_TUPLES_RAW <<< "$DEAD_TUPLES_RESULT"
    unset PGPASSWORD
    DEAD_TUPLES_COMPARE=${DEAD_TUPLES_RAW:-0}
    if (( DEAD_TUPLES_COMPARE >= DEAD_TUPLES_ALERT_THRESHOLD )); then DEAD_TUPLES_CLASS="alert"
    elif (( DEAD_TUPLES_COMPARE >= DEAD_TUPLES_WARN_THRESHOLD )); then DEAD_TUPLES_CLASS="warn"
    else DEAD_TUPLES_CLASS="ok"; fi
    if [[ -n "$DEAD_TUPLES_RAW" && "$DEAD_TUPLES_RAW" -gt 0 ]]; then
        FORMATTED_COUNT=$(format_large_number "$DEAD_TUPLES_RAW")
        DEAD_TUPLES="${FORMATTED_COUNT}<br><small>(${SCHEMANAME}.${RELNAME})</small>"
    else DEAD_TUPLES="0"; fi

    # 4. XID Age
    XID_QUERY="SELECT COALESCE(MAX(age(datfrozenxid)), 0) FROM pg_database;"
    export PGPASSWORD="${DB_PASSWORD}"
    XID_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$XID_QUERY")
    XID_AGE=$(echo "$XID_RESULT" | xargs)
    unset PGPASSWORD
    if (( XID_AGE >= XID_AGE_ALERT_THRESHOLD )); then XID_AGE_CLASS="alert"
    elif (( XID_AGE >= XID_AGE_WARN_THRESHOLD )); then XID_AGE_CLASS="warn"
    else XID_AGE_CLASS="ok"; fi
    XID_AGE=$(format_large_number "$XID_AGE")

    # 5. Blocking
    BLOCKING_QUERY="SELECT COUNT(*) AS not_granted_lock_count FROM pg_locks WHERE NOT granted;"
    export PGPASSWORD="${DB_PASSWORD}"
    BLOCKING_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$BLOCKING_QUERY")
    BLOCKING_COUNT=$(echo "$BLOCKING_RESULT" | xargs)
    unset PGPASSWORD
    if (( BLOCKING_COUNT >= 11 )); then BLOCKING_CLASS="alert"
    elif (( BLOCKING_COUNT >= 1 )); then BLOCKING_CLASS="warn"
    else BLOCKING_CLASS="ok"; fi

    # 6. Mountpoint
    MOUNTPOINT_QUERY="SELECT ROUND((d.space_used_mb::numeric / d.size_mb) * 100, 2) AS usage_percent FROM pemdata.disk_space d JOIN pem.agent a ON d.agent_id = a.id WHERE d.mount_point LIKE '%${MP}' AND a.description LIKE '%${HOSTNAME}%' AND d.size_mb > 0 ORDER BY d.recorded_time DESC LIMIT 1;"
    export PGPASSWORD="${DB_PASSWORD}"
    MOUNTPOINT_RESULT=$(run_psql_query_pem "$MOUNTPOINT_QUERY")
    PEM_QUERY_EXIT_CODE=$?
    unset PGPASSWORD
    if [[ $PEM_QUERY_EXIT_CODE -eq 0 && -n "$MOUNTPOINT_RESULT" ]]; then
        MOUNTPOINT_PERCENT_STRING=$(echo "$MOUNTPOINT_RESULT" | xargs)
        MOUNTPOINT_RAW_PERCENT=$(echo "$MOUNTPOINT_PERCENT_STRING" | awk '{printf "%.0f", $1}')
        if (( MOUNTPOINT_RAW_PERCENT >= MOUNTPOINT_ALERT_THRESHOLD )); then MOUNTPOINT_CLASS="alert"
        else MOUNTPOINT_CLASS="safe"; fi
        MOUNTPOINT_USAGE="${MP}<br><small>(${MOUNTPOINT_PERCENT_STRING}%)</small>"
    else MOUNTPOINT_CLASS="na"; MOUNTPOINT_USAGE="N/A"; fi

    # Build JSON
    [[ $INSTANCE_INDEX -gt 0 ]] && JSON_INSTANCES+=","
    JSON_INSTANCES+="{\"name\":\"$(json_escape "$DISPLAY_NAME")\",\"hostname\":\"$(json_escape "$HOSTNAME")\",\"port\":\"$PORT\","
    JSON_INSTANCES+="\"masterStatus\":\"$MASTER_STATUS\","
    JSON_INSTANCES+="\"replication\":{\"html\":\"$(json_escape "$ROLE_STATUS_HTML")\",\"status\":\"$ROLE_STATUS_CLASS\"},"
    JSON_INSTANCES+="\"connection\":{\"html\":\"$(json_escape "$CONN_PERCENT")\",\"status\":\"$CONN_STATUS_CLASS\"},"
    JSON_INSTANCES+="\"deadTuples\":{\"html\":\"$(json_escape "$DEAD_TUPLES")\",\"status\":\"$DEAD_TUPLES_CLASS\"},"
    JSON_INSTANCES+="\"xidAge\":{\"html\":\"$(json_escape "$XID_AGE")\",\"status\":\"$XID_AGE_CLASS\"},"
    JSON_INSTANCES+="\"blocking\":{\"html\":\"$(json_escape "$BLOCKING_COUNT")\",\"status\":\"$BLOCKING_CLASS\"},"
    JSON_INSTANCES+="\"mountpoint\":{\"html\":\"$(json_escape "$MOUNTPOINT_USAGE")\",\"status\":\"$MOUNTPOINT_CLASS\"}}"
    INSTANCE_INDEX=$((INSTANCE_INDEX + 1))

    # Collect alerts for resolution tracking (format: instance|metric|type|hostname)
    IS_SI=false
    [[ "$DISPLAY_NAME" == *"(Si)"* ]] && IS_SI=true
    [[ "$IS_SI" == false && ("$ROLE_STATUS_CLASS" == "alert") ]] && echo "${DISPLAY_NAME}|replication|critical|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$IS_SI" == false && ("$ROLE_STATUS_CLASS" == "warn") ]] && echo "${DISPLAY_NAME}|replication|warning|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$CONN_STATUS_CLASS" == "alert" ]] && echo "${DISPLAY_NAME}|connection|critical|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$CONN_STATUS_CLASS" == "warn" ]] && echo "${DISPLAY_NAME}|connection|warning|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$DEAD_TUPLES_CLASS" == "alert" ]] && echo "${DISPLAY_NAME}|deadTuples|critical|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$DEAD_TUPLES_CLASS" == "warn" ]] && echo "${DISPLAY_NAME}|deadTuples|warning|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$XID_AGE_CLASS" == "alert" ]] && echo "${DISPLAY_NAME}|xidAge|critical|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$XID_AGE_CLASS" == "warn" ]] && echo "${DISPLAY_NAME}|xidAge|warning|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$BLOCKING_CLASS" == "alert" ]] && echo "${DISPLAY_NAME}|blocking|critical|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$BLOCKING_CLASS" == "warn" ]] && echo "${DISPLAY_NAME}|blocking|warning|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$MOUNTPOINT_CLASS" == "alert" ]] && echo "${DISPLAY_NAME}|mountpoint|critical|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"
    [[ "$MOUNTPOINT_CLASS" == "warn" ]] && echo "${DISPLAY_NAME}|mountpoint|warning|${HOSTNAME}" >> "$CURRENT_ALERTS_FILE"

done < "$LIST_DB_FILE"

# ==============================================================================
# ALERT RESOLUTION TRACKING (pure bash, no python required)
# ==============================================================================
SCRIPT_DIR_ALERTS="$(cd "$(dirname "$0")" && pwd)"
PREVIOUS_ALERTS_FILE="${SCRIPT_DIR_ALERTS}/previous_alerts.txt"

# Compare with previous alerts to find resolved ones
RESOLVED_JSON="[]"
if [[ -f "$PREVIOUS_ALERTS_FILE" ]]; then
    RESOLVED_ITEMS=""
    while IFS='|' read -r prev_instance prev_metric prev_type prev_hostname; do
        [[ -z "$prev_instance" ]] && continue
        # Check if this alert still exists in current
        if ! grep -qF "${prev_instance}|${prev_metric}|" "$CURRENT_ALERTS_FILE" 2>/dev/null; then
            # This alert is resolved
            [[ -n "$RESOLVED_ITEMS" ]] && RESOLVED_ITEMS+=","
            RESOLVED_ITEMS+="{\"instance\":\"$(json_escape "$prev_instance")\",\"metric\":\"$prev_metric\",\"type\":\"$prev_type\",\"hostname\":\"$(json_escape "$prev_hostname")\"}"
        fi
    done < "$PREVIOUS_ALERTS_FILE"
    [[ -n "$RESOLVED_ITEMS" ]] && RESOLVED_JSON="[$RESOLVED_ITEMS]"
fi

# Save current alerts for next run
cp "$CURRENT_ALERTS_FILE" "$PREVIOUS_ALERTS_FILE"

echo "Alert resolution tracking: state saved to $PREVIOUS_ALERTS_FILE"


# ==============================================================================
# GENERATE HTML
# ==============================================================================

cat <<'HTMLEOF' > "$OUTPUT_HTML"
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
HTMLEOF

echo "  <title>$SUBJECT - $DATE</title>" >> "$OUTPUT_HTML"

cat <<'HTMLEOF' >> "$OUTPUT_HTML"
  <!-- Chart.js embedded inline for portability (no external files needed) -->
  <script>
HTMLEOF

# Embed Chart.js inline so the HTML is fully self-contained
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHARTJS_FILE="${SCRIPT_DIR}/chart.umd.min.js"
if [[ -f "$CHARTJS_FILE" ]]; then
    cat "$CHARTJS_FILE" >> "$OUTPUT_HTML"
else
    echo "Warning: chart.umd.min.js not found at $CHARTJS_FILE"
fi

cat <<'HTMLEOF' >> "$OUTPUT_HTML"
  </script>
  <style>
    :root { --transition-speed: 0.3s; }
    [data-theme="dark"] {
      --bg-body:#0b0f19;--bg-surface:#111827;--bg-card:#1a2236;--bg-card-alt:#151d2e;--bg-hover:#1f2b42;
      --text-primary:#e8edf5;--text-secondary:#8896b0;--text-muted:#5a6a85;--border:rgba(136,150,176,0.12);
      --border-hover:rgba(136,150,176,0.22);--accent:#6366f1;--accent-soft:rgba(99,102,241,0.12);
      --critical:#f43f5e;--critical-bg:rgba(244,63,94,0.1);--critical-border:rgba(244,63,94,0.2);
      --warning:#f59e0b;--warning-bg:rgba(245,158,11,0.1);--warning-border:rgba(245,158,11,0.2);
      --safe:#10b981;--safe-bg:rgba(16,185,129,0.1);--safe-border:rgba(16,185,129,0.2);
      --shadow:0 1px 3px rgba(0,0,0,0.3);--shadow-lg:0 4px 20px rgba(0,0,0,0.25);
      --chart-grid:rgba(136,150,176,0.06);--toggle-bg:#1a2236;--toggle-knob:#e8edf5;
    }
    [data-theme="light"] {
      --bg-body:#f5f7fa;--bg-surface:#ffffff;--bg-card:#ffffff;--bg-card-alt:#f8fafc;--bg-hover:#f1f5f9;
      --text-primary:#0f172a;--text-secondary:#64748b;--text-muted:#94a3b8;--border:rgba(15,23,42,0.08);
      --border-hover:rgba(15,23,42,0.15);--accent:#6366f1;--accent-soft:rgba(99,102,241,0.08);
      --critical:#e11d48;--critical-bg:rgba(225,29,72,0.06);--critical-border:rgba(225,29,72,0.15);
      --warning:#d97706;--warning-bg:rgba(217,119,6,0.06);--warning-border:rgba(217,119,6,0.15);
      --safe:#059669;--safe-bg:rgba(5,150,105,0.06);--safe-border:rgba(5,150,105,0.15);
      --shadow:0 1px 3px rgba(0,0,0,0.06);--shadow-lg:0 4px 20px rgba(0,0,0,0.06);
      --chart-grid:rgba(15,23,42,0.05);--toggle-bg:#e2e8f0;--toggle-knob:#0f172a;
    }
    *{margin:0;padding:0;box-sizing:border-box;}
    body{font-family:'Inter',-apple-system,sans-serif;background:var(--bg-body);color:var(--text-primary);min-height:100vh;line-height:1.6;transition:background var(--transition-speed),color var(--transition-speed);}
    .header{background:var(--bg-surface);border-bottom:1px solid var(--border);padding:24px 0;transition:background var(--transition-speed);}
    .header-inner{max-width:1320px;margin:0 auto;padding:0 28px;display:flex;align-items:center;justify-content:space-between;}
    .header-left h1{font-size:1.35rem;font-weight:700;color:var(--text-primary);letter-spacing:-0.02em;}
    .header-left .meta{font-size:0.78rem;color:var(--text-muted);margin-top:3px;}
    .theme-toggle{display:flex;align-items:center;gap:10px;cursor:pointer;user-select:none;}
    .theme-toggle .label{font-size:0.75rem;font-weight:500;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em;}
    .toggle-track{width:44px;height:24px;border-radius:12px;background:var(--toggle-bg);border:1px solid var(--border);position:relative;transition:background var(--transition-speed);}
    .toggle-knob{width:18px;height:18px;border-radius:50%;background:var(--toggle-knob);position:absolute;top:2px;left:2px;transition:transform var(--transition-speed),background var(--transition-speed);}
    [data-theme="light"] .toggle-knob{transform:translateX(20px);}
    .container{max-width:1320px;margin:0 auto;padding:28px;}
    .summary-row{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:32px;}
    .stat-card{background:var(--bg-card);border:1px solid var(--border);border-radius:12px;padding:20px 22px;transition:all var(--transition-speed);box-shadow:var(--shadow);}
    .stat-card:hover{box-shadow:var(--shadow-lg);border-color:var(--border-hover);}
    .stat-card .stat-label{font-size:0.7rem;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.06em;margin-bottom:6px;}
    .stat-card .stat-value{font-size:1.8rem;font-weight:800;letter-spacing:-0.03em;}
    .stat-card.total .stat-value{color:var(--accent);} .stat-card.critical .stat-value{color:var(--critical);}
    .stat-card.warning .stat-value{color:var(--warning);} .stat-card.safe .stat-value{color:var(--safe);}
    .stat-card .stat-sub{font-size:0.72rem;color:var(--text-muted);margin-top:2px;}
    .group{background:var(--bg-card);border:1px solid var(--border);border-radius:12px;margin-bottom:12px;overflow:hidden;box-shadow:var(--shadow);transition:all var(--transition-speed);}
    .group:hover{border-color:var(--border-hover);}
    .group-head{padding:16px 22px;display:flex;align-items:center;justify-content:space-between;cursor:pointer;user-select:none;transition:background 0.15s;gap:16px;}
    .group-head:hover{background:var(--bg-hover);}
    .group-head-left{display:flex;align-items:center;gap:14px;flex:1;min-width:0;}
    .group-host-icon{width:36px;height:36px;border-radius:8px;background:var(--accent-soft);display:flex;align-items:center;justify-content:center;font-size:1rem;flex-shrink:0;color:var(--accent);font-weight:700;}
    .group-host-name{font-size:0.92rem;font-weight:600;color:var(--text-primary);}
    .group-host-count{font-size:0.72rem;color:var(--text-muted);}
    .group-badges{display:flex;gap:6px;flex-shrink:0;}
    .badge{display:inline-flex;align-items:center;gap:5px;padding:3px 10px;border-radius:6px;font-size:0.7rem;font-weight:600;}
    .badge-dot{width:6px;height:6px;border-radius:50%;}
    .badge.critical{background:var(--critical-bg);color:var(--critical);border:1px solid var(--critical-border);} .badge.critical .badge-dot{background:var(--critical);}
    .badge.warning{background:var(--warning-bg);color:var(--warning);border:1px solid var(--warning-border);} .badge.warning .badge-dot{background:var(--warning);}
    .badge.safe{background:var(--safe-bg);color:var(--safe);border:1px solid var(--safe-border);} .badge.safe .badge-dot{background:var(--safe);}
    .group-chevron{width:28px;height:28px;display:flex;align-items:center;justify-content:center;border-radius:6px;flex-shrink:0;transition:all 0.25s;}
    .group-chevron svg{width:14px;height:14px;fill:var(--text-muted);transition:transform 0.25s ease;}
    .group.open .group-chevron svg{transform:rotate(180deg);fill:var(--accent);}
    .group-body{display:grid;grid-template-rows:0fr;transition:grid-template-rows 0.35s cubic-bezier(0.4,0,0.2,1);overflow:hidden;}
    .group.open .group-body{grid-template-rows:1fr;}
    .group-body-inner{min-height:0;padding:0 22px;transition:padding-bottom 0.35s cubic-bezier(0.4,0,0.2,1);}
    .group.open .group-body-inner{padding-bottom:22px;}
    .overview-row{display:grid;grid-template-columns:280px 1fr;gap:16px;margin-bottom:16px;}
    .chart-panel{background:var(--bg-card-alt);border:1px solid var(--border);border-radius:10px;padding:18px;}
    .chart-panel .panel-title,.alerts-panel .panel-title{font-size:0.7rem;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:12px;}
    .chart-box{height:160px;}
    .alerts-panel{background:var(--bg-card-alt);border:1px solid var(--border);border-radius:10px;padding:18px;overflow:auto;}
    .alert-list{list-style:none;}
    .alert-item{display:flex;align-items:flex-start;gap:10px;padding:10px 12px;border-radius:8px;margin-bottom:6px;font-size:0.8rem;transition:background 0.15s;}
    .alert-item:hover{background:var(--bg-hover);}
    .alert-item .alert-icon{flex-shrink:0;width:22px;height:22px;border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:0.7rem;font-weight:700;margin-top:1px;}
    .alert-item.critical-item .alert-icon{background:var(--critical-bg);color:var(--critical);border:1px solid var(--critical-border);}
    .alert-item.warning-item .alert-icon{background:var(--warning-bg);color:var(--warning);border:1px solid var(--warning-border);}
    .alert-item .alert-body{flex:1;min-width:0;}
    .alert-item .alert-title{font-weight:600;color:var(--text-primary);font-size:0.8rem;}
    .alert-item .alert-detail{color:var(--text-secondary);font-size:0.72rem;margin-top:1px;}
    .alert-item .alert-badge{flex-shrink:0;font-size:0.65rem;font-weight:700;padding:2px 8px;border-radius:4px;text-transform:uppercase;letter-spacing:0.04em;margin-top:2px;}
    .alert-item.critical-item .alert-badge{background:var(--critical-bg);color:var(--critical);border:1px solid var(--critical-border);}
    .alert-item.warning-item .alert-badge{background:var(--warning-bg);color:var(--warning);border:1px solid var(--warning-border);}
    .no-alerts{color:var(--text-muted);font-size:0.78rem;font-style:italic;text-align:center;padding:20px 0;}
    .tbl{width:100%;border-collapse:separate;border-spacing:0;border-radius:10px;overflow:hidden;border:1px solid var(--border);font-size:0.8rem;}
    .tbl thead th{background:var(--bg-card-alt);color:var(--text-muted);font-size:0.68rem;font-weight:600;text-transform:uppercase;letter-spacing:0.06em;padding:10px 12px;text-align:center;border-bottom:1px solid var(--border);white-space:nowrap;}
    .tbl tbody td{padding:10px 12px;text-align:center;color:var(--text-primary);border-bottom:1px solid var(--border);background:var(--bg-card);vertical-align:middle;transition:background 0.15s;}
    .tbl tbody tr:hover td{background:var(--bg-hover);} .tbl tbody tr:last-child td{border-bottom:none;}
    .tbl tbody td small{display:block;color:var(--text-muted);font-size:0.68rem;margin-top:1px;}
    .p{display:inline-block;padding:2px 8px;border-radius:5px;font-size:0.72rem;font-weight:600;white-space:nowrap;}
    .p-ok,.p-safe{background:var(--safe-bg);color:var(--safe);border:1px solid var(--safe-border);}
    .p-warn{background:var(--warning-bg);color:var(--warning);border:1px solid var(--warning-border);}
    .p-alert{background:var(--critical-bg);color:var(--critical);border:1px solid var(--critical-border);}
    .p-na{background:var(--bg-card-alt);color:var(--text-muted);border:1px solid var(--border);}
    .p-sync{background:var(--accent-soft);color:var(--accent);border:1px solid rgba(99,102,241,0.2);}
    .p-replica{background:var(--safe-bg);color:var(--safe);border:1px solid var(--safe-border);}
    .p-unsync{background:var(--critical-bg);color:var(--critical);border:1px solid var(--critical-border);}
    .badge.resolved{background:rgba(59,130,246,0.08);color:#3b82f6;border:1px solid rgba(59,130,246,0.15);} .badge.resolved .badge-dot{background:#3b82f6;}
    .stat-card.resolved .stat-value{color:#3b82f6;}
    .alert-item.resolved-item .alert-icon{background:rgba(59,130,246,0.08);color:#3b82f6;border:1px solid rgba(59,130,246,0.15);}
    .alert-item.resolved-item .alert-badge{background:rgba(59,130,246,0.08);color:#3b82f6;border:1px solid rgba(59,130,246,0.15);}
    .alert-item.resolved-item{opacity:0.75;}
    .footer{text-align:center;padding:24px 28px;color:var(--text-muted);font-size:0.72rem;border-top:1px solid var(--border);margin-top:16px;}
    @media(max-width:1000px){.overview-row{grid-template-columns:1fr;}.summary-row{grid-template-columns:repeat(2,1fr);}}
    @media(max-width:600px){.summary-row{grid-template-columns:1fr;}.header-inner{flex-direction:column;gap:12px;align-items:flex-start;}}
    /* Beehive */
    .beehive-overlay{display:none;margin-bottom:28px;}.beehive-overlay.open{display:block;animation:bhIn .35s ease;}@keyframes bhIn{from{opacity:0;transform:translateY(-12px)}to{opacity:1;transform:translateY(0)}}
    .beehive-card{background:var(--bg-card);border:1px solid var(--border);border-radius:14px;padding:28px;box-shadow:var(--shadow);transition:all var(--transition-speed);}
    .beehive-header{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px;}
    .beehive-header-left{display:flex;align-items:center;gap:10px;}
    .beehive-header-left span{font-size:1rem;font-weight:700;color:var(--text-primary);}
    .beehive-close{width:30px;height:30px;display:flex;align-items:center;justify-content:center;border-radius:8px;background:var(--bg-card-alt);border:1px solid var(--border);cursor:pointer;font-size:1.1rem;color:var(--text-muted);transition:all .2s;}.beehive-close:hover{background:var(--critical-bg);color:var(--critical);border-color:var(--critical-border);}
    .hex-flexi{--s:100px;--g:10px;display:flex;gap:var(--g);flex-wrap:wrap;padding-bottom:calc(var(--s)/(4*cos(30deg)));margin:0 auto;}
    .hf-cell{width:var(--s);aspect-ratio:cos(30deg);border-radius:50%/25%;corner-shape:bevel;margin-bottom:calc(var(--s)/(-4*cos(30deg)));border:8px solid;box-sizing:border-box;display:grid;place-content:center;cursor:pointer;position:relative;transition:transform .2s cubic-bezier(.4,0,.2,1);z-index:1;overflow:visible;font-size:.6rem;font-weight:700;color:var(--text-primary);text-shadow:none;}
    .hf-cell:hover{transform:scale(1.15);z-index:3;}
    .hf-cell.healthy{background:var(--bg-card);border-color:var(--safe);}
    .hf-cell.warning{background:var(--bg-card);border-color:var(--warning);}
    .hf-cell.critical{background:var(--bg-card);border-color:var(--critical);}
    .hex-tooltip{position:absolute;bottom:calc(100% + 8px);left:50%;transform:translateX(-50%);background:rgba(15,23,42,.95);color:#fff;padding:8px 14px;border-radius:8px;font-size:.66rem;font-weight:500;white-space:nowrap;pointer-events:none;opacity:0;transition:opacity .2s;z-index:10;backdrop-filter:blur(10px);line-height:1.5;text-shadow:none;}
    .hex-tooltip::after{content:'';position:absolute;top:100%;left:50%;transform:translateX(-50%);border:5px solid transparent;border-top-color:rgba(15,23,42,.95);}.hf-cell:hover .hex-tooltip{opacity:1;}
    .hex-tooltip .tt-name{font-weight:700;font-size:.72rem;margin-bottom:2px;}
    .hex-tooltip .tt-host{opacity:.55;font-size:.6rem;margin-bottom:4px;}
    .hex-tooltip .tt-alert{display:flex;align-items:center;gap:4px;padding:1px 0;}
    .hex-tooltip .tt-dot{width:5px;height:5px;border-radius:50%;flex-shrink:0;}
    .hex-tooltip .tt-dot.c{background:#fb7185;}.hex-tooltip .tt-dot.w{background:#fbbf24;}.hex-tooltip .tt-dot.h{background:#10b981;}
    .beehive-legend{display:flex;align-items:center;justify-content:center;gap:16px;margin-top:20px;padding-top:16px;border-top:1px solid var(--border);flex-wrap:wrap;}
    .beehive-legend-item{display:flex;align-items:center;gap:6px;font-size:.7rem;font-weight:600;color:var(--text-secondary);}
    .beehive-legend-dot{width:10px;height:10px;border-radius:3px;}
    .beehive-legend-dot.l-critical{background:linear-gradient(135deg,#fb7185,#e11d48);}
    .beehive-legend-dot.l-warning{background:linear-gradient(135deg,#fbbf24,#d97706);}
    .beehive-legend-dot.l-healthy{background:linear-gradient(135deg,#10b981,#059669);}
    .beehive-count{font-size:.82rem;font-weight:800;margin-left:auto;}
    .beehive-count .bc-alert{color:var(--critical);}
    .beehive-count .bc-sep{color:var(--text-muted);margin:0 1px;}
    .beehive-count .bc-total{color:var(--text-secondary);}
    .stat-card.total{cursor:pointer;position:relative;overflow:hidden;}.stat-card.total::after{content:'Click to explore';position:absolute;bottom:8px;right:12px;font-size:.6rem;color:var(--text-muted);opacity:0;transition:opacity .2s;}.stat-card.total:hover::after{opacity:1;}.stat-card.total:hover{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent),var(--shadow-lg);}
    .stat-card.critical{cursor:pointer;position:relative;overflow:hidden;}.stat-card.critical::after{content:'Click for chart';position:absolute;bottom:8px;right:12px;font-size:.6rem;color:var(--text-muted);opacity:0;transition:opacity .2s;}.stat-card.critical:hover::after{opacity:1;}.stat-card.critical:hover{border-color:var(--critical);box-shadow:0 0 0 1px var(--critical),var(--shadow-lg);}
    .groups-toolbar{display:flex;align-items:center;justify-content:flex-end;margin-bottom:12px;}
    .btn-expand{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:8px;background:var(--bg-card);border:1px solid var(--border);cursor:pointer;font-size:.72rem;font-weight:600;color:var(--text-secondary);transition:all .2s;}.btn-expand:hover{background:var(--bg-hover);border-color:var(--border-hover);color:var(--text-primary);}
    .summary-chart-overlay{display:none;margin-bottom:28px;}.summary-chart-overlay.open{display:block;animation:bhIn .35s ease;}
    .summary-chart-card{background:var(--bg-card);border:1px solid var(--border);border-radius:14px;padding:28px;box-shadow:var(--shadow);}
    .summary-chart-header{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px;}
    .summary-chart-header span{font-size:1rem;font-weight:700;color:var(--text-primary);}
    .summary-chart-box{height:260px;max-width:600px;margin:0 auto;}
  </style>
</head>
<body>
  <div class="header">
    <div class="header-inner">
      <div class="header-left">
HTMLEOF

echo "        <h1>$SUBJECT</h1>" >> "$OUTPUT_HTML"
echo "        <div class=\"meta\">Daily Report &middot; Generated $DATE $TIME WIB</div>" >> "$OUTPUT_HTML"

cat <<'HTMLEOF' >> "$OUTPUT_HTML"
      </div>
      <div class="theme-toggle" onclick="toggleTheme()">
        <span id="themeIcon">🌙</span>
        <div class="toggle-track"><div class="toggle-knob"></div></div>
        <span id="themeIcon2">☀️</span>
      </div>
    </div>
  </div>
  <div class="container">
    <div class="summary-row" id="summaryRow"></div>
    <div class="beehive-overlay" id="beehiveOverlay"><div id="beehiveContainer"></div></div>
    <div class="summary-chart-overlay" id="summaryChartOverlay"><div class="summary-chart-card"><div class="summary-chart-header"><span>Alert Overview</span><div class="beehive-close" onclick="toggleSummaryChart()">&times;</div></div><div class="summary-chart-box"><canvas id="summaryChartCanvas"></canvas></div></div></div>
    <div class="groups-toolbar"><button class="btn-expand" id="btnExpandAll" onclick="toggleAllGroups()">&#9660; Expand All</button></div>
    <div id="groups"></div>
  </div>
  <div class="footer">Generated by PostgreSQL Healthcheck Report Script — Telkomsigma</div>
  <script>
HTMLEOF

echo "    const instances = [$JSON_INSTANCES];" >> "$OUTPUT_HTML"
echo "    const resolvedAlerts = $RESOLVED_JSON;" >> "$OUTPUT_HTML"

cat <<'HTMLEOF' >> "$OUTPUT_HTML"

    const metricLabels={replication:'Replication',connection:'Connection Usage',deadTuples:'Dead Tuples',xidAge:'XID Age',blocking:'Blocking Queries',mountpoint:'Mountpoint Usage'};
    function isSi(i){return i.name.includes('(Si)');}
    function getOverall(i){const si=isSi(i);const m=[si?'ok':i.replication.status,i.connection.status,i.deadTuples.status,i.xidAge.status,i.blocking.status,i.mountpoint.status];if(m.includes('alert'))return'critical';if(m.includes('warn'))return'warning';return'healthy';}
    function pillClass(s){return{ok:'p-ok',safe:'p-safe',healthy:'p-safe',warn:'p-warn',alert:'p-alert',na:'p-na'}[s]||'p-na';}
    function stripHtml(h){const t=document.createElement('div');t.innerHTML=h;return t.textContent||'';}
    function getAlerts(insts){const a=[];['replication','connection','deadTuples','xidAge','blocking','mountpoint'].forEach(m=>{insts.forEach(i=>{if(m==='replication'&&isSi(i))return;if(i[m].status==='alert')a.push({type:'critical',instance:i.name,metric:metricLabels[m],value:stripHtml(i[m].html)});else if(i[m].status==='warn')a.push({type:'warning',instance:i.name,metric:metricLabels[m],value:stripHtml(i[m].html)});});});return a;}
    function getResolvedForHost(hostname){return resolvedAlerts.filter(a=>a.hostname===hostname);}

    const groups={};instances.forEach(i=>{if(!groups[i.hostname])groups[i.hostname]=[];groups[i.hostname].push(i);});
    const allAlerts=getAlerts(instances);const tC=allAlerts.filter(a=>a.type==='critical').length,tW=allAlerts.filter(a=>a.type==='warning').length,tS=instances.filter(i=>getOverall(i)==='healthy').length;

    document.getElementById('summaryRow').innerHTML=`
      <div class="stat-card total" onclick="toggleBeehive()"><div class="stat-label">Total Instances</div><div class="stat-value">${instances.length}</div><div class="stat-sub">${Object.keys(groups).length} hosts</div></div>
      <div class="stat-card critical" onclick="toggleSummaryChart()"><div class="stat-label">Critical</div><div class="stat-value">${tC}</div><div class="stat-sub">Requires attention</div></div>
      <div class="stat-card warning"><div class="stat-label">Warning</div><div class="stat-value">${tW}</div><div class="stat-sub">Monitor closely</div></div>
      <div class="stat-card safe"><div class="stat-label">Healthy</div><div class="stat-value">${tS}</div><div class="stat-sub">Operating normally</div></div>`;

    const gc=document.getElementById('groups');
    function getThemeColors(){const cs=getComputedStyle(document.documentElement);return{critical:cs.getPropertyValue('--critical').trim(),warning:cs.getPropertyValue('--warning').trim(),safe:cs.getPropertyValue('--safe').trim(),grid:cs.getPropertyValue('--chart-grid').trim(),muted:cs.getPropertyValue('--text-muted').trim(),secondary:cs.getPropertyValue('--text-secondary').trim()};}
    const chartRefs=[];

    Object.keys(groups).forEach((host,idx)=>{
      const insts=groups[host];
      const alerts=getAlerts(insts);const resolved=getResolvedForHost(host);const gId=`g${idx}`,cId=`c${idx}`;
      const gC=alerts.filter(a=>a.type==='critical').length,gW=alerts.filter(a=>a.type==='warning').length,gS=insts.filter(i=>getOverall(i)==='healthy').length;
      let alertsHtml='';
      if(alerts.length===0&&resolved.length===0){alertsHtml='<div class="no-alerts">No alerts — all metrics are healthy</div>';}
      else{
        alertsHtml='<ul class="alert-list">';
        alertsHtml+=alerts.map(a=>{const cls=a.type==='critical'?'critical-item':'warning-item';const icon=a.type==='critical'?'!':'⚠';const label=a.type==='critical'?'Critical':'Warning';return`<li class="alert-item ${cls}"><div class="alert-icon">${icon}</div><div class="alert-body"><div class="alert-title">${a.instance}</div><div class="alert-detail">${a.metric}: ${a.value}</div></div><div class="alert-badge">${label}</div></li>`;}).join('');
        if(resolved.length>0){
          alertsHtml+=resolved.map(a=>{return`<li class="alert-item resolved-item"><div class="alert-icon">✓</div><div class="alert-body"><div class="alert-title">${a.instance}</div><div class="alert-detail">${metricLabels[a.metric]||a.metric}: Previously ${a.type}</div></div><div class="alert-badge">Resolved</div></li>`;}).join('');
        }
        alertsHtml+='</ul>';
      }
      const totalAlertCount=alerts.length+(resolved.length>0?' · '+resolved.length+' resolved':'');

      let rows='';insts.forEach(i=>{rows+=`<tr><td style="font-weight:600;text-align:left">${i.name}</td><td>${i.port}</td><td>${i.masterStatus}</td><td>${i.replication.html}</td><td><span class="p ${pillClass(i.connection.status)}">${i.connection.html}</span></td><td><span class="p ${pillClass(i.deadTuples.status)}">${i.deadTuples.html}</span></td><td><span class="p ${pillClass(i.xidAge.status)}">${i.xidAge.html}</span></td><td><span class="p ${pillClass(i.blocking.status)}">${i.blocking.html}</span></td><td><span class="p ${pillClass(i.mountpoint.status)}">${i.mountpoint.html}</span></td></tr>`;});

      gc.insertAdjacentHTML('beforeend',`<div class="group" id="${gId}"><div class="group-head" onclick="toggle('${gId}')"><div class="group-head-left"><div class="group-host-icon">⬡</div><div><div class="group-host-name">${host}</div><div class="group-host-count">${insts.length} instance${insts.length>1?'s':''}</div></div></div><div class="group-badges">${gC>0?`<div class="badge critical"><span class="badge-dot"></span>${gC} Critical</div>`:''}${gW>0?`<div class="badge warning"><span class="badge-dot"></span>${gW} Warning</div>`:''}${gS>0?`<div class="badge safe"><span class="badge-dot"></span>${gS} Healthy</div>`:''}${resolved.length>0?`<div class="badge resolved"><span class="badge-dot"></span>${resolved.length} Resolved</div>`:''}</div><div class="group-chevron"><svg viewBox="0 0 24 24"><path d="M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6z"/></svg></div></div><div class="group-body"><div class="group-body-inner"><div class="overview-row"><div class="chart-panel"><div class="panel-title">Alert Status</div><div class="chart-box"><canvas id="${cId}"></canvas></div></div><div class="alerts-panel"><div class="panel-title">Alert Details (${alerts.length}${resolved.length>0?' · '+resolved.length+' resolved':''})</div>${alertsHtml}</div></div><table class="tbl"><thead><tr><th style="text-align:left">Name</th><th>Port</th><th>Role</th><th>Replication</th><th>Connection</th><th>Dead Tuples</th><th>XID Age</th><th>Blocking</th><th>Mountpoint</th></tr></thead><tbody>${rows}</tbody></table></div></div></div>`);

      const tc=getThemeColors();const ctx=document.getElementById(cId).getContext('2d');
      const chart=new Chart(ctx,{type:'bar',data:{labels:['Critical','Warning','Healthy'],datasets:[{data:[gC,gW,gS],backgroundColor:[tc.critical,tc.warning,tc.safe],borderWidth:0,borderRadius:4,barPercentage:0.55,categoryPercentage:0.65}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false},tooltip:{backgroundColor:'rgba(0,0,0,0.8)',cornerRadius:6,padding:8,titleFont:{family:'Inter',size:11},bodyFont:{family:'Inter',size:11},callbacks:{label:function(c){return c.dataIndex<2?c.raw+' alert'+(c.raw!==1?'s':''):c.raw+' instance'+(c.raw!==1?'s':'');}}}},scales:{y:{beginAtZero:true,ticks:{stepSize:1,color:tc.muted,font:{family:'Inter',size:10}},grid:{color:tc.grid}},x:{ticks:{color:tc.secondary,font:{family:'Inter',size:11,weight:'500'}},grid:{display:false}}}}});
      chartRefs.push(chart);
    });

    function toggle(id){document.getElementById(id).classList.toggle('open');}
    function toggleAllGroups(){var gs=document.querySelectorAll('.group');var btn=document.getElementById('btnExpandAll');var anyOpen=document.querySelector('.group.open');if(anyOpen){gs.forEach(function(g){g.classList.remove('open');});btn.innerHTML='&#9660; Expand All';}else{gs.forEach(function(g){g.classList.add('open');});btn.innerHTML='&#9650; Collapse All';}}
    function toggleTheme(){const h=document.documentElement;const n=h.getAttribute('data-theme')==='dark'?'light':'dark';h.setAttribute('data-theme',n);localStorage.setItem('hc-theme',n);updateChartColors();}
    const saved=localStorage.getItem('hc-theme');if(saved)document.documentElement.setAttribute('data-theme',saved);
    function updateChartColors(){const tc=getThemeColors();chartRefs.forEach(c=>{c.options.scales.y.ticks.color=tc.muted;c.options.scales.y.grid.color=tc.grid;c.options.scales.x.ticks.color=tc.secondary;c.data.datasets[0].backgroundColor=[tc.critical,tc.warning,tc.safe];c.update('none');});}
    function toggleBeehive(){const o=document.getElementById('beehiveOverlay');o.classList.toggle('open');if(o.classList.contains('open')&&!o.dataset.rendered){renderBeehive();o.dataset.rendered='1';}}
    function renderBeehive(){
      var container=document.getElementById('beehiveContainer');
      var allInsts=[];var hostKeys=Object.keys(groups);
      hostKeys.forEach(function(host){groups[host].forEach(function(inst){allInsts.push({inst:inst,host:host});});});
      var HW=100,GAP=10;
      var card=document.createElement('div');card.className='beehive-card';
      card.innerHTML='<div class="beehive-header"><div class="beehive-header-left"><span>Hosts</span></div><div class="beehive-close" onclick="toggleBeehive()">&times;</div></div>';
      var grid=document.createElement('div');grid.className='hex-flexi';
      var cCnt=0,wCnt=0,hCnt=0;
      function getInstAlerts(inst){
        var alerts=[];var si=isSi(inst);
        var checks=[['replication','Replication'],['connection','Connection'],['deadTuples','Dead Tuples'],['xidAge','XID Age'],['blocking','Blocking'],['mountpoint','Mountpoint']];
        checks.forEach(function(c){
          var m=c[0],label=c[1];
          if(m==='replication'&&si)return;
          if(inst[m].status==='alert')alerts.push({type:'c',label:label,val:stripHtml(inst[m].html)});
          else if(inst[m].status==='warn')alerts.push({type:'w',label:label,val:stripHtml(inst[m].html)});
        });
        return alerts;
      }
      allInsts.forEach(function(item,i){
        var inst=item.inst,host=item.host;
        var status=getOverall(inst);
        if(status==='critical')cCnt++;else if(status==='warning')wCnt++;else hCnt++;
        var cell=document.createElement('div');cell.className='hf-cell '+status;
        var alerts=getInstAlerts(inst);
        var ttAlerts='';
        if(alerts.length>0){
          alerts.forEach(function(a){ttAlerts+='<div class="tt-alert"><span class="tt-dot '+a.type+'"></span>'+a.label+': '+a.val+'</div>';});
        }else{ttAlerts='<div class="tt-alert"><span class="tt-dot h"></span>All metrics healthy</div>';}
        cell.innerHTML='<div class="hex-tooltip"><div class="tt-name">'+inst.name+'</div><div class="tt-host">'+host+'</div>'+ttAlerts+'</div>';
        cell.addEventListener('click',function(){var gIdx=hostKeys.indexOf(host);var gId='g'+gIdx;var el=document.getElementById(gId);if(el){el.classList.add('open');el.scrollIntoView({behavior:'smooth',block:'start'});}});
        grid.appendChild(cell);
      });
      card.appendChild(grid);
      container.appendChild(card);
      /* Apply row stagger via JS */
      requestAnimationFrame(function(){
        var cells=grid.querySelectorAll('.hf-cell');
        var gw=grid.offsetWidth;
        var colsPerRow=Math.floor((gw+GAP)/(HW+GAP));
        if(colsPerRow<2)colsPerRow=2;
        var idx=0,row=0;
        while(idx<cells.length){
          var isOdd=row%2===1;
          var rowCols=isOdd?colsPerRow-1:colsPerRow;
          if(rowCols<1)rowCols=1;
          if(isOdd&&idx<cells.length){
            cells[idx].style.marginLeft=(HW+GAP)/2+'px';
          }
          idx+=rowCols;
          row++;
        }
      });
      var alertTotal=cCnt+wCnt;
      var legend='<div class="beehive-legend">';
      legend+='<div class="beehive-legend-item"><div class="beehive-legend-dot l-critical"></div>Critical '+cCnt+'</div>';
      legend+='<div class="beehive-legend-item"><div class="beehive-legend-dot l-warning"></div>Warning '+wCnt+'</div>';
      legend+='<div class="beehive-legend-item"><div class="beehive-legend-dot l-healthy"></div>Healthy '+hCnt+'</div>';
      legend+='<div class="beehive-count"><span class="bc-alert">'+alertTotal+'</span><span class="bc-sep">/</span><span class="bc-total">'+allInsts.length+'</span></div>';
      legend+='</div>';
      card.insertAdjacentHTML('beforeend',legend);
    }
    var summaryChartRef=null;
    function toggleSummaryChart(){
      var o=document.getElementById('summaryChartOverlay');o.classList.toggle('open');
      if(o.classList.contains('open')&&!summaryChartRef){
        var tc=getThemeColors();var ctx=document.getElementById('summaryChartCanvas').getContext('2d');
        summaryChartRef=new Chart(ctx,{type:'bar',data:{labels:['Critical','Warning','Healthy'],datasets:[{label:'Instances',data:[tC,tW,tS],backgroundColor:[tc.critical,tc.warning,tc.safe],borderWidth:0,borderRadius:6,barPercentage:0.5,categoryPercentage:0.6}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false},tooltip:{backgroundColor:'rgba(0,0,0,0.85)',cornerRadius:8,padding:10,titleFont:{family:'Inter',size:12},bodyFont:{family:'Inter',size:12},callbacks:{label:function(c){return c.dataIndex<2?c.raw+' alert'+(c.raw!==1?'s':''):c.raw+' instance'+(c.raw!==1?'s':'');}}}},scales:{y:{beginAtZero:true,ticks:{stepSize:1,color:tc.muted,font:{family:'Inter',size:11}},grid:{color:tc.grid}},x:{ticks:{color:tc.secondary,font:{family:'Inter',size:12,weight:'600'}},grid:{display:false}}}}});
      }
    }
  </script>
</body>
</html>
HTMLEOF

echo "Enhanced health check report generated: $OUTPUT_HTML"

# Email
TO_EMAIL="support@gmail.co.id"
FROM_EMAIL="pr@gmail.co.id"
(
echo "Dear Team,"
echo ""
echo "Attached is the latest PostgreSQL Database Healthcheck Report for your review. Please examine the findings carefully. If any metrics or indicators fall outside the expected operational thresholds or best practices, kindly initiate the appropriate remediation procedures as soon as possible to ensure continued system stability and performance."
echo ""
echo "Best regards,"
echo "MODB Team"
) | mailx -s "$SUBJECT" -a "$OUTPUT_HTML" -r "$FROM_EMAIL" "$TO_EMAIL"

echo "Health check report sent to $TO_EMAIL."