#!/bin/bash

# ==============================================================================
# CONFIGURATION VARIABLES
# ==============================================================================
LIST_DB_FILE="/home/postgres/script/test_email/replication_mail/list_db_test_mp_2" # DB List file: HOSTNAME,IP,PORT,DBNAME,DISPLAY_NAME,MP
DB_USER="pemuser" # PostgreSQL user for target DBs
DB_PASSWORD="pemuser"

# PEM Database Connection
PEM_HOST="localhost"
PEM_PORT="5433"
PEM_USER="pemuser"
PEM_DB="pem"

# Thresholds (New Logic Implemented)
DEAD_TUPLES_WARN_THRESHOLD=200000     # Dead Tuples threshold for WARNING (200k)
DEAD_TUPLES_ALERT_THRESHOLD=1000000   # Dead Tuples threshold for ALERT (1M)

XID_AGE_WARN_THRESHOLD=250000000      # XID Age threshold for WARNING (250M)
XID_AGE_ALERT_THRESHOLD=1000000000    # XID Age threshold for ALERT (1B)

CONN_WARN_PERCENT=80                  # Connection usage percentage for WARNING (80%)
CONN_ALERT_PERCENT=90                 # Connection usage percentage for ALERT (90%)

MOUNTPOINT_WARN_THRESHOLD=70        # Mountpoint usage percentage for WARNING (70%)
MOUNTPOINT_CRIT_THRESHOLD=80        # Mountpoint usage percentage for CRITICAL (80%)

REPLICATION_LAG_DELAY_BYTES=10485760  # 10MB replication lag for DELAY status

# Email Subject Line (Used for HTML title/header and Email subject)
SUBJECT="[Daily Report] PostgreSQL Database Healthcheck Report"

# Generate output file with date and time
DATE=$(date +"%Y-%m-%d")
TIME=$(date +"%H:%M:%S")
DATETIME=$(date +"%Y-%m-%d %H:%M:%S")
OUTPUT_HTML="/home/postgres/script/test_email/replication_mail/report/daily_health_check_report_${DATETIME}.html"

# ==============================================================================
# HELPER FUNCTIONS (Rewritten to use BASH and AWK instead of BC)
# ==============================================================================

# Function to convert bytes to human-readable format (Pure Bash Integer Math)
human_readable_bytes() {
    local bytes=$1
    if (( bytes < 1024 )); then
        echo "${bytes} B"
    elif (( bytes < 1048576 )); then
        # Calculate KB using integer math
        echo "$(( bytes / 1024 )) KB"
    elif (( bytes < 1073741824 )); then
        # Calculate MB using integer math
        echo "$(( bytes / 1048576 )) MB"
    else
        # Calculate GB using integer math
        echo "$(( bytes / 1073741824 )) GB"
    fi
}

# Function to format large numbers (e.g., 1234567890 -> 1.23B) (Uses AWK for floating point)
format_large_number() {
    local num=$1
    # Check if num is defined and greater than 0
    if [[ -z "$num" || "$num" -eq 0 ]]; then
        echo "0"
        return
    fi

    if (( num >= 1000000000 )); then
        # Use Awk for precise floating point division (Billion)
        awk -v n="$num" "BEGIN {printf \"%.2fB\", n / 1000000000}"
    elif (( num >= 1000000 )); then
        # Use Awk for precise floating point division (Million)
        awk -v n="$num" "BEGIN {printf \"%.1fM\", n / 1000000}"
    else
        echo "$num"
    fi
}

# Function to run psql command and handle connection failure
run_psql_query() {
    local host=$1
    local port=$2
    local dbname=$3
    local query=$4
    # Connect using the appropriate user for the target DB
    # Note: This assumes .pgpass is set up for $DB_USER (for targets)
    psql -h "$host" -p "$port" -U "$DB_USER" -d "$dbname" -t -A -F"," -c "$query" 2>/dev/null
    return $?
}

# Function to run psql query on the PEM database
run_psql_query_pem() {
    local query=$1
    # Connect using the specific PEM user and DB configuration
    # Note: This assumes .pgpass is set up for $PEM_USER
    # We leave 2>/dev/null OFF for debugging the "N/A" mountpoint issue
    psql -h "$PEM_HOST" -p "$PEM_PORT" -U "$PEM_USER" -d "$PEM_DB" -t -A -F"," -c "$query"
    return $?
}

# ==============================================================================
# INITIAL CHECKS AND HTML SETUP
# ==============================================================================

# Check if list_db file exists
if [[ ! -f "$LIST_DB_FILE" ]]; then
    echo "Error: File '$LIST_DB_FILE' not found!"
    exit 1
fi

# ==============================================================================
# HTML HEADER WITH POSTGRESQL V6 THEME
# ==============================================================================
cat <<'HTMLHEADER' > "$OUTPUT_HTML"
<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>PostgreSQL Healthcheck Report</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root { --pg-blue: #336791; --pg-blue-light: #5a9fd4; --pg-blue-dark: #264653; --transition: 0.3s ease; }
[data-theme="light"] { --bg: #f5f7fa; --bg-alt: #ffffff; --surface: #ffffff; --border: #e1e5eb; --text: #1a202c; --text-muted: #718096; --card-shadow: 0 2px 8px rgba(51, 103, 145, 0.08); --hover-shadow: 0 8px 24px rgba(51, 103, 145, 0.12); }
[data-theme="dark"] { --bg: #0d1117; --bg-alt: #161b22; --surface: #1c2128; --border: #30363d; --text: #e6edf3; --text-muted: #8b949e; --card-shadow: 0 2px 8px rgba(0, 0, 0, 0.3); --hover-shadow: 0 8px 24px rgba(51, 103, 145, 0.2); }
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: var(--bg); color: var(--text); font-family: 'Inter', -apple-system, sans-serif; line-height: 1.4; padding: 20px; transition: background var(--transition), color var(--transition); min-height: 100vh; position: relative; overflow-x: hidden; }
.bg-animation { position: fixed; top: 0; left: 0; right: 0; bottom: 0; z-index: -1; overflow: hidden; }
.bg-orb { position: absolute; border-radius: 50%; filter: blur(80px); opacity: 0.12; animation: orb-float 25s ease-in-out infinite; }
.bg-orb-1 { width: 400px; height: 400px; background: var(--pg-blue); top: -100px; right: -100px; }
.bg-orb-2 { width: 300px; height: 300px; background: var(--pg-blue-light); bottom: -80px; left: -80px; animation-delay: -12s; }
@keyframes orb-float { 0%, 100% { transform: translate(0, 0) scale(1); } 33% { transform: translate(20px, -20px) scale(1.1); } 66% { transform: translate(-15px, 15px) scale(0.95); } }
.container { max-width: 100%; margin: 0 auto; position: relative; z-index: 1; }
.card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; box-shadow: var(--card-shadow); transition: all var(--transition); }
.card:hover { box-shadow: var(--hover-shadow); }
.header { padding: 16px 20px; margin-bottom: 16px; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 12px; }
.header-left h1 { font-size: 1.2rem; font-weight: 700; display: flex; align-items: center; gap: 10px; }
.pg-logo { width: 28px; height: 28px; background: linear-gradient(135deg, var(--pg-blue), var(--pg-blue-dark)); border-radius: 6px; display: flex; align-items: center; justify-content: center; font-weight: 800; color: white; font-size: 10px; }
.header-left p { color: var(--text-muted); font-size: 0.75rem; margin-top: 2px; }
.header-right { display: flex; align-items: center; gap: 12px; }
.header-badge { background: linear-gradient(135deg, var(--pg-blue), var(--pg-blue-light)); color: white; padding: 6px 12px; border-radius: 6px; font-size: 0.7rem; font-weight: 600; }
.theme-toggle { display: flex; align-items: center; background: var(--bg-alt); border: 1px solid var(--border); border-radius: 6px; padding: 3px; }
.theme-btn { padding: 4px 10px; border-radius: 4px; font-size: 0.65rem; font-weight: 600; color: var(--text-muted); background: transparent; border: none; cursor: pointer; transition: all var(--transition); }
.theme-btn.active { background: var(--pg-blue); color: white; }
.stats-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin-bottom: 16px; }
.stat-card { padding: 12px; text-align: center; transition: transform var(--transition); }
.stat-card:hover { transform: translateY(-2px); }
.stat-label { font-size: 0.6rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600; }
.stat-value { font-size: 1.2rem; font-weight: 700; color: var(--pg-blue); margin-top: 2px; }
.section-title { font-size: 1rem; font-weight: 700; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }
.section-title::before { content: ''; width: 3px; height: 20px; background: linear-gradient(180deg, var(--pg-blue), var(--pg-blue-light)); border-radius: 2px; }
.table-card { margin-bottom: 16px; overflow: hidden; }
.table-wrapper { overflow-x: visible; }
table { width: 100%; border-collapse: collapse; font-size: 0.72rem; table-layout: fixed; }
th, td { padding: 8px 6px; text-align: center; vertical-align: middle; word-wrap: break-word; overflow-wrap: break-word; }
th { background: var(--bg-alt); color: var(--text-muted); font-weight: 600; font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.3px; position: sticky; top: 0; border-bottom: 2px solid var(--pg-blue); }
th:nth-child(1) { width: 12%; } /* Instance */
th:nth-child(2) { width: 14%; } /* Hostname */
th:nth-child(3) { width: 5%; } /* Port */
th:nth-child(4) { width: 7%; } /* Role */
th:nth-child(5) { width: 10%; } /* Replication */
th:nth-child(6) { width: 12%; } /* Connections */
th:nth-child(7) { width: 10%; } /* Dead Tuples */
th:nth-child(8) { width: 8%; } /* XID Age */
th:nth-child(9) { width: 7%; } /* Blocked */
th:nth-child(10) { width: 15%; } /* Mountpoint */
tr { border-bottom: 1px solid var(--border); transition: background var(--transition); }
tbody tr:hover { background: var(--bg-alt); }
td { font-weight: 500; }
.badge { padding: 3px 6px; border-radius: 4px; font-size: 0.6rem; font-weight: 600; text-transform: uppercase; display: inline-block; transition: transform 0.2s; }
.badge:hover { transform: scale(1.05); }
.badge.ok, .badge.sync { background: rgba(46, 160, 67, 0.15); color: #2ea043; }
.badge.warning, .badge.delay { background: rgba(210, 153, 34, 0.15); color: #d29922; }
.badge.critical, .badge.unsync { background: rgba(248, 81, 73, 0.15); color: #f85149; animation: pulse-red 2s infinite; }
.badge.primary { background: rgba(51, 103, 145, 0.2); color: var(--pg-blue-light); }
.badge.replica { background: rgba(46, 160, 67, 0.15); color: #2ea043; }
.badge.na { background: rgba(139, 148, 158, 0.15); color: var(--text-muted); }
.role-badge { padding: 3px 6px; border-radius: 4px; font-size: 0.6rem; font-weight: 600; display: inline-block; transition: transform 0.2s; }
.role-badge:hover { transform: scale(1.05); }
.role-badge.master { background: linear-gradient(135deg, var(--pg-blue), var(--pg-blue-dark)); color: white; }
.role-badge.slave { background: linear-gradient(135deg, #2ea043, #238636); color: white; }
.role-badge.unknown { background: rgba(139, 148, 158, 0.3); color: var(--text-muted); }
.value-cell { display: flex; flex-direction: column; align-items: center; gap: 1px; }
.value-main { font-weight: 600; font-size: 0.7rem; }
.value-sub { font-size: 0.55rem; color: var(--text-muted); word-break: break-all; }
code { background: var(--bg-alt); padding: 1px 4px; border-radius: 3px; font-size: 0.6rem; color: var(--pg-blue-light); word-break: break-all; }
.progress-bar { width: 50px; height: 4px; background: var(--border); border-radius: 2px; overflow: hidden; margin: 4px auto 0; }
.progress-fill { height: 100%; border-radius: 2px; position: relative; }
.progress-fill::after { content: ''; position: absolute; inset: 0; background: linear-gradient(90deg, transparent, rgba(255,255,255,0.3), transparent); animation: shimmer 2s infinite; }
@keyframes pulse-red { 0% { box-shadow: 0 0 0 0 rgba(248, 81, 73, 0.4); } 70% { box-shadow: 0 0 0 4px rgba(248, 81, 73, 0); } 100% { box-shadow: 0 0 0 0 rgba(248, 81, 73, 0); } }
@keyframes shimmer { 0% { transform: translateX(-100%); } 100% { transform: translateX(100%); } }
.progress-fill.ok { background: linear-gradient(90deg, #238636, #2ea043); }
.progress-fill.warning { background: linear-gradient(90deg, #9e6a03, #d29922); }
.progress-fill.critical { background: linear-gradient(90deg, #da3633, #f85149); }
.footer { text-align: center; padding: 20px; color: var(--text-muted); font-size: 0.75rem; margin-top: 12px; }
.footer a { color: var(--pg-blue); text-decoration: none; font-weight: 600; }
@media (max-width: 1024px) { body { padding: 16px; } th, td { padding: 10px 12px; font-size: 0.8rem; } }
@media (max-width: 768px) { .header { flex-direction: column; text-align: center; } .stats-grid { grid-template-columns: repeat(2, 1fr); } }
</style>
</head>
<body>
<div class="bg-animation"><div class="bg-orb bg-orb-1"></div><div class="bg-orb bg-orb-2"></div></div>
<div class="container">
HTMLHEADER

# Write header section with dynamic data
cat <<EOF >> "$OUTPUT_HTML"
<div class="header card">
  <div class="header-left">
    <h1><div class="pg-logo">PG</div> PostgreSQL Healthcheck Report</h1>
    <p>Daily Database Infrastructure Monitoring</p>
  </div>
  <div class="header-right">
    <div class="theme-toggle">
      <button class="theme-btn" data-theme="light" onclick="setTheme('light')">Light</button>
      <button class="theme-btn active" data-theme="dark" onclick="setTheme('dark')">Dark</button>
    </div>
    <div class="header-badge">${DATE}</div>
  </div>
</div>
EOF

# Count instances for stats
INSTANCE_COUNT=$(grep -v '^#' "$LIST_DB_FILE" | grep -v '^$' | wc -l)

# Write stats grid
cat <<EOF >> "$OUTPUT_HTML"
<div class="stats-grid">
  <div class="stat-card card"><div class="stat-label">Report Date</div><div class="stat-value">${DATE}</div></div>
  <div class="stat-card card"><div class="stat-label">Instances</div><div class="stat-value">${INSTANCE_COUNT}</div></div>
  <div class="stat-card card"><div class="stat-label">Generated</div><div class="stat-value">${TIME}</div></div>
  <div class="stat-card card"><div class="stat-label">Status</div><div class="stat-value">Active</div></div>
</div>

<h2 class="section-title">Instance Health Summary</h2>
<div class="table-card card">
<div class="table-wrapper">
<table>
<thead>
<tr>
  <th>Instance Name</th>
  <th>Hostname</th>
  <th>Port</th>
  <th>Role</th>
  <th>Replication</th>
  <th>Connections</th>
  <th>Dead Tuples</th>
  <th>XID Age</th>
  <th>Blocked Locks</th>
  <th>Mountpoint</th>
</tr>
</thead>
<tbody>
EOF

# ==============================================================================
# MAIN PROCESSING LOOP
# ==============================================================================

# Process each database entry in the list
while IFS=',' read -r HOSTNAME IP PORT DBNAME DISPLAY_NAME MP; do
    # Skip empty lines or comments
    if [[ -z "$HOSTNAME" || "$HOSTNAME" == \#* ]]; then
        continue
    fi

    echo "Checking $DISPLAY_NAME ($DBNAME) at $IP:$PORT..."

    # Initialize variables for current instance
    ROLE_STATUS=""
    REPL_DETAIL=""
    MASTER_STATUS="N/A"
    CONN_PERCENT="N/A"
    DEAD_TUPLES="N/A"
    XID_AGE="N/A"
    BLOCKING_COUNT="N/A"
    MOUNTPOINT_USAGE="N/A"

    CONN_STATUS_CLASS="na"
    DEAD_TUPLES_CLASS="na"
    XID_AGE_CLASS="na"
    BLOCKING_CLASS="na"
    MOUNTPOINT_CLASS="na"
    ROLE_CLASS="unknown"
    REPL_CLASS="na"

    # ----------------------------------------------------
    # 1. Connection Check & Max Connections
    # ----------------------------------------------------
    CONN_QUERY="
        SELECT setting::integer AS max_conn,
               (SELECT count(*)::float FROM pg_stat_activity) AS current_conn
        FROM pg_settings WHERE name = 'max_connections';
    "
    export PGPASSWORD="${DB_PASSWORD}"
    CONN_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$CONN_QUERY")
    PSQL_EXIT_CODE=$?
    unset PGPASSWORD

    if [[ $PSQL_EXIT_CODE -ne 0 ]]; then
        # Handle connection failure
        echo "Error: Failed to connect to $DISPLAY_NAME (Code $PSQL_EXIT_CODE). Check DB name ($DBNAME) or connection settings."

        # Output row with connection failure
        echo "<tr>
            <td><strong>$DISPLAY_NAME</strong></td>
            <td><code>$HOSTNAME</code></td>
            <td>$PORT</td>
            <td><span class='badge critical'>FAILED</span></td>
            <td><span class='badge critical'>FAILED</span></td>
            <td><span class='badge critical'>N/A</span></td>
            <td><span class='badge critical'>N/A</span></td>
            <td><span class='badge critical'>N/A</span></td>
            <td><span class='badge critical'>N/A</span></td>
            <td><span class='badge critical'>N/A</span></td>
          </tr>" >> "$OUTPUT_HTML"
        continue
    fi

    # If connection is OK, parse Connection result
    IFS=',' read -r MAX_CONN CURRENT_CONN <<< "$CONN_RESULT"

    if [[ -n "$MAX_CONN" && "$MAX_CONN" -ne 0 ]]; then
        # Calculate usage percentage using AWK (allows floating point division)
        CONN_RAW_PERCENT=$(awk "BEGIN {printf \"%.0f\", ($CURRENT_CONN * 100) / $MAX_CONN}")

        # Bash integer comparison
        if (( CONN_RAW_PERCENT >= CONN_ALERT_PERCENT )); then
            CONN_STATUS_CLASS="critical"
        elif (( CONN_RAW_PERCENT >= CONN_WARN_PERCENT )); then
            CONN_STATUS_CLASS="warning"
        else
            CONN_STATUS_CLASS="ok"
        fi
        CONN_DISPLAY="${CURRENT_CONN}/${MAX_CONN}"
        CONN_PERCENT_VALUE="${CONN_RAW_PERCENT}"
    else
        CONN_DISPLAY="N/A"
        CONN_PERCENT_VALUE="0"
    fi

    # ----------------------------------------------------
    # 2. Get Replication Role and Lag (Efficient)
    # ----------------------------------------------------

    # First, a single, fast query to determine the role
    ROLE_CHECK_QUERY="SELECT pg_is_in_recovery();"
    export PGPASSWORD="${DB_PASSWORD}"
    IS_REPLICA=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$ROLE_CHECK_QUERY" | xargs)
    unset PGPASSWORD

    if [[ "$IS_REPLICA" == "f" ]]; then
        # === PRIMARY (MASTER) ROLE LOGIC ===
        MASTER_STATUS="Master"
        ROLE_CLASS="master"

        MASTER_STATS_QUERY="
            SELECT
                count(*) FILTER (WHERE application_name <> 'pg_basebackup') AS replica_count,
                count(*) FILTER (WHERE state = 'streaming' AND application_name <> 'pg_basebackup') AS streaming_count,
                count(*) FILTER (WHERE application_name = 'pg_basebackup') AS backup_count,
                COALESCE(
                    max(
                        COALESCE(pg_wal_lsn_diff(sent_lsn, replay_lsn), 0)
                    ) FILTER (WHERE application_name <> 'pg_basebackup'),
                    0
                ) AS max_lag_bytes
            FROM pg_stat_replication;
        "

        export PGPASSWORD="${DB_PASSWORD}"
        MASTER_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$MASTER_STATS_QUERY")
        IFS=',' read -r REPLICA_COUNT STREAMING_COUNT BACKUP_COUNT MAX_LAG_BYTES <<< "$MASTER_RESULT"
        unset PGPASSWORD

        if [[ "$REPLICA_COUNT" -eq 0 && "$BACKUP_COUNT" -eq 0 ]]; then
            ROLE_STATUS="UNSYNC"
            REPL_CLASS="unsync"
            REPL_DETAIL="No Replicas"
        elif [[ "$STREAMING_COUNT" -eq 0 ]]; then
            ROLE_STATUS="UNSYNC"
            REPL_CLASS="unsync"
            if [[ "$BACKUP_COUNT" -gt 0 ]]; then
                REPL_DETAIL="Backup Running"
            else
                REPL_DETAIL="Not Streaming"
            fi
        elif [[ "$MAX_LAG_BYTES" -gt "$REPLICATION_LAG_DELAY_BYTES" ]]; then
            HUMAN_LAG=$(human_readable_bytes "$MAX_LAG_BYTES")
            REPL_DETAIL="Lag: $HUMAN_LAG"
            ROLE_STATUS="DELAY"
            REPL_CLASS="delay"
        else
            ROLE_STATUS="SYNC"
            REPL_CLASS="sync"
            if [[ "$BACKUP_COUNT" -gt 0 ]]; then
                REPL_DETAIL="OK, Backup Running"
            else
                REPL_DETAIL="Streaming OK"
            fi
        fi

    elif [[ "$IS_REPLICA" == "t" ]]; then
        # === REPLICA (SLAVE) ROLE LOGIC ===
        MASTER_STATUS="Slave"
        ROLE_CLASS="slave"

        WAL_RECEIVER_QUERY="SELECT count(*) FROM pg_stat_wal_receiver;"
        export PGPASSWORD="${DB_PASSWORD}"
        WAL_RECEIVER_COUNT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$WAL_RECEIVER_QUERY" | xargs)
        unset PGPASSWORD

        if [[ "$WAL_RECEIVER_COUNT" -gt 0 ]]; then
            ROLE_STATUS="SYNC"
            REPL_CLASS="sync"
            REPL_DETAIL="Replica OK"
        else
            ROLE_STATUS="UNSYNC"
            REPL_CLASS="unsync"
            REPL_DETAIL="Receiver Down"
        fi

    else
        MASTER_STATUS="Unknown"
        ROLE_CLASS="unknown"
        ROLE_STATUS="UNKNOWN"
        REPL_CLASS="na"
        REPL_DETAIL="Role Check Failed"
    fi

    # ----------------------------------------------------
    # 3. Dead Tuples Check (Max across all tables)
    # ----------------------------------------------------
    DEAD_TUPLES_QUERY="
        SELECT schemaname, relname, n_dead_tup
        FROM pg_stat_user_tables
        ORDER BY n_dead_tup DESC
        LIMIT 1;
    "

    export PGPASSWORD="${DB_PASSWORD}"
    DEAD_TUPLES_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$DEAD_TUPLES_QUERY")
    IFS=',' read -r SCHEMANAME RELNAME DEAD_TUPLES_RAW <<< "$DEAD_TUPLES_RESULT"
    unset PGPASSWORD

    DEAD_TUPLES_COMPARE=${DEAD_TUPLES_RAW:-0}

    if (( DEAD_TUPLES_COMPARE >= DEAD_TUPLES_ALERT_THRESHOLD )); then
        DEAD_TUPLES_CLASS="critical"
    elif (( DEAD_TUPLES_COMPARE >= DEAD_TUPLES_WARN_THRESHOLD )); then
        DEAD_TUPLES_CLASS="warning"
    else
        DEAD_TUPLES_CLASS="ok"
    fi

    if [[ -n "$DEAD_TUPLES_RAW" && "$DEAD_TUPLES_RAW" -gt 0 ]]; then
        FORMATTED_COUNT=$(format_large_number "$DEAD_TUPLES_RAW")
        DEAD_TUPLES="<div class='value-cell'><span class='value-main'>${FORMATTED_COUNT}</span><span class='value-sub'>${SCHEMANAME}.${RELNAME}</span></div>"
    else
        DEAD_TUPLES="0"
    fi

    # ----------------------------------------------------
    # 4. XID Age Check
    # ----------------------------------------------------
    XID_QUERY="
        SELECT COALESCE(MAX(age(datfrozenxid)), 0) FROM pg_database;
    "
    export PGPASSWORD="${DB_PASSWORD}"
    XID_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$XID_QUERY")
    XID_AGE_RAW=$(echo "$XID_RESULT" | xargs)
    unset PGPASSWORD

    if (( XID_AGE_RAW >= XID_AGE_ALERT_THRESHOLD )); then
        XID_AGE_CLASS="critical"
    elif (( XID_AGE_RAW >= XID_AGE_WARN_THRESHOLD )); then
        XID_AGE_CLASS="warning"
    else
        XID_AGE_CLASS="ok"
    fi

    XID_AGE=$(format_large_number "$XID_AGE_RAW")

    # ----------------------------------------------------
    # 5. Blocking Queries Count
    # ----------------------------------------------------
    BLOCKING_QUERY="
        SELECT COUNT(*) AS not_granted_lock_count
        FROM pg_locks
        WHERE NOT granted;
    "
    export PGPASSWORD="${DB_PASSWORD}"
    BLOCKING_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$BLOCKING_QUERY")
    BLOCKING_COUNT=$(echo "$BLOCKING_RESULT" | xargs)
    unset PGPASSWORD

    if (( BLOCKING_COUNT >= 11 )); then
        BLOCKING_CLASS="critical"
    elif (( BLOCKING_COUNT >= 1 )); then
        BLOCKING_CLASS="warning"
    else
        BLOCKING_CLASS="ok"
    fi

    # ----------------------------------------------------
    # 6. Mountpoint Usage Check (from PEM database)
    # ----------------------------------------------------
    MOUNTPOINT_QUERY="
      SELECT ROUND((d.space_used_mb::numeric / d.size_mb) * 100, 2) AS usage_percent
      FROM pemdata.disk_space d
      JOIN pem.agent a ON d.agent_id = a.id
      WHERE d.mount_point LIKE '%${MP}'
        AND a.description LIKE '%${HOSTNAME}%'
        AND d.size_mb > 0 -- Avoid division by zero
      ORDER BY d.recorded_time DESC
      LIMIT 1;
    "

    export PGPASSWORD="${DB_PASSWORD}"
    MOUNTPOINT_RESULT=$(run_psql_query_pem "$MOUNTPOINT_QUERY")
    PEM_QUERY_EXIT_CODE=$?
    unset PGPASSWORD

    if [[ $PEM_QUERY_EXIT_CODE -eq 0 && -n "$MOUNTPOINT_RESULT" ]]; then
        MOUNTPOINT_PERCENT_STRING=$(echo "$MOUNTPOINT_RESULT" | xargs)
        # We use the raw float string for display to show exactly what is in DB
        
        # Logic: 
        # > 80.0 -> Critical
        # >= 70.0 -> Warning
        # Else -> OK
        
        MOUNTPOINT_CLASS=$(awk -v usage="$MOUNTPOINT_PERCENT_STRING" -v warn="$MOUNTPOINT_WARN_THRESHOLD" -v crit="$MOUNTPOINT_CRIT_THRESHOLD" 'BEGIN {
            if (usage > crit) print "critical";
            else if (usage >= warn) print "warning";
            else print "ok";
        }')
        
        # Use integer for progress bar width (CSS)
        MOUNTPOINT_BAR_WIDTH=$(echo "$MOUNTPOINT_PERCENT_STRING" | awk '{printf "%.0f", $1}')

        MOUNTPOINT_USAGE="<div class='value-cell'><span class='value-main'>${MOUNTPOINT_PERCENT_STRING}%</span><span class='value-sub'><code>${MP}</code></span></div><div class='progress-bar'><div class='progress-fill ${MOUNTPOINT_CLASS}' style='width:${MOUNTPOINT_BAR_WIDTH}%'></div></div>"
    else
        MOUNTPOINT_CLASS="na"
        MOUNTPOINT_USAGE="<span class='badge na'>N/A</span>"
    fi

    # ----------------------------------------------------
    # FINAL HTML ROW OUTPUT
    # ----------------------------------------------------
    echo "<tr>
        <td><strong>$DISPLAY_NAME</strong></td>
        <td><code>$HOSTNAME</code></td>
        <td>$PORT</td>
        <td><span class='role-badge ${ROLE_CLASS}'>${MASTER_STATUS}</span></td>
        <td><div class='value-cell'><span class='badge ${REPL_CLASS}'>${ROLE_STATUS}</span><span class='value-sub'>${REPL_DETAIL}</span></div></td>
        <td><div class='value-cell'><span class='value-main'>${CONN_PERCENT_VALUE}% Usage</span><code>(${CONN_DISPLAY})</code></div><div class='progress-bar'><div class='progress-fill ${CONN_STATUS_CLASS}' style='width:${CONN_PERCENT_VALUE}%'></div></div></td>
        <td><span class='badge ${DEAD_TUPLES_CLASS}'>${DEAD_TUPLES}</span></td>
        <td><span class='badge ${XID_AGE_CLASS}'>${XID_AGE}</span></td>
        <td><span class='badge ${BLOCKING_CLASS}'>${BLOCKING_COUNT}</span></td>
        <td>${MOUNTPOINT_USAGE}</td>
      </tr>" >> "$OUTPUT_HTML"

done < "$LIST_DB_FILE"

# ==============================================================================
# HTML FOOTER AND JAVASCRIPT
# ==============================================================================

cat <<'HTMLFOOTER' >> "$OUTPUT_HTML"
</tbody>
</table>
</div>
</div>

<div class="footer">
  <a href="#">PostgreSQL</a> Healthcheck Report v6.0 | Generated by Telkomsigma DBA Team
</div>
</div>

<script>
function setTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  localStorage.setItem('theme', theme);
  document.querySelectorAll('.theme-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.theme === theme);
  });
}
const savedTheme = localStorage.getItem('theme') || 'dark';
setTheme(savedTheme);
</script>
</body>
</html>
HTMLFOOTER

echo "Health check report generated: $OUTPUT_HTML"

# ==============================================================================
# EMAIL SENDING
# ==============================================================================
TO_EMAIL="xxx@telkomsel.co.id"
FROM_EMAIL="yyy@telkomsel.co.id"

(
echo "Dear Team,"
echo ""
echo "Attached is the latest PostgreSQL Database Healthcheck Report for your review. Please examine the findings carefully. If any metrics or indicators fall outside the expected operational thresholds or best practices, kindly initiate the appropriate remediation procedures as soon as possible to ensure continued system stability and performance."
echo ""
echo "Best regards,"
echo "MODB Team"
) | mailx -s "$SUBJECT" -a "$OUTPUT_HTML" -r "$FROM_EMAIL" "$TO_EMAIL"

echo "Health check report sent to $TO_EMAIL."