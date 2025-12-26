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

MOUNTPOINT_ALERT_THRESHOLD=70         # Mountpoint usage percentage for ALERT (70%)

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

# Start HTML report
cat <<EOF > "$OUTPUT_HTML"
<!DOCTYPE html>
<html>
<head>
    <title>$SUBJECT - $DATE</title>
    <style>
        body { font-family: Arial, sans-serif; background-color: #f4f7f6; color: #333; padding: 20px; }
        h1, h2 { color: #007bff; border-bottom: 2px solid #eee; padding-bottom: 5px; }
        .generated-info { text-align: center; color: #666; margin-bottom: 30px; font-style: italic; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; background-color: #ffffff; box-shadow: 0 4px 8px rgba(0, 0, 0, 0.05); }
        th, td { border: 1px solid #ddd; text-align: center; padding: 12px; }
        th { background-color: #007bff; color: white; font-weight: bold; }
        td { font-weight: 500; }

        /* Status Indicators - Converted to inline-block for pill-style appearance */
        .status-ok { background-color: #d4edda; color: #155724; font-weight: bold; display: inline-block; padding: 3px 8px; border-radius: 4px; font-size: 0.85em; }
        .status-warn { background-color: #fff3cd; color: #856404; font-weight: bold; display: inline-block; padding: 3px 8px; border-radius: 4px; font-size: 0.85em; }
        .status-alert { background-color: #f8d7da; color: #721c24; font-weight: bold; display: inline-block; padding: 3px 8px; border-radius: 4px; font-size: 0.85em; }
        .status-na { background-color: #e9ecef; color: #495057; display: inline-block; padding: 3px 8px; border-radius: 4px; font-size: 0.85em; }
        .status-safe { background-color: #d4edda; color: #155724; font-weight: bold; display: inline-block; padding: 3px 8px; border-radius: 4px; font-size: 0.85em; }

        /* Replication Status */
        .repl-primary { background-color: #00509e; color: white; padding: 3px 8px; border-radius: 4px; font-size: 0.85em; display: inline-block; }
        .repl-replica { background-color: #28a745; color: white; padding: 3px 8px; border-radius: 4px; font-size: 0.85em; display: inline-block; }
        .repl-unsync { background-color: #dc3545; color: white; padding: 3px 8px; border-radius: 4px; font-size: 0.85em; display: inline-block; }
    </style>
</head>
<body>
    <h1>$SUBJECT</h1>
    <div class="generated-info">Generated on: $DATE $TIME WIB</div>

    <h2>Instance Health Summary</h2>
    <table>
        <tr>
            <th>Name</th>
            <th>Hostname</th>
            <th>Port</th>
            <th>Master Status</th> <th>Replication Status</th>
            <th>Connection Usage (%)</th>
            <th>Dead Tuples</th>
            <th>XID Age</th>
            <th>Blocking Queries</th>
            <th>Mountpoint Usage</th>
        </tr>
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
    MASTER_STATUS="N/A" # <-- INITIALIZE NEW VARIABLE
    CONN_PERCENT="N/A"
    DEAD_TUPLES="N/A"
    XID_AGE="N/A"
    BLOCKING_COUNT="N/A"
    MOUNTPOINT_USAGE="N/A"

    CONN_STATUS_CLASS="status-na"
    DEAD_TUPLES_CLASS="status-na"
    XID_AGE_CLASS="status-na"
    BLOCKING_CLASS="status-na"
    MOUNTPOINT_CLASS="status-na"

    # ----------------------------------------------------
    # 1. Connection Check & Max Connections
    # ----------------------------------------------------
    CONN_QUERY="
        SELECT setting::integer AS max_conn,
               (SELECT count(*)::float FROM pg_stat_activity) AS current_conn
        FROM pg_settings WHERE name = 'max_connections';
    "
    # Pass $DBNAME as the third argument (database name)
    export PGPASSWORD="${DB_PASSWORD}"
    CONN_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$CONN_QUERY")
    PSQL_EXIT_CODE=$?
    unset PGPASSWORD

    if [[ $PSQL_EXIT_CODE -ne 0 ]]; then
        # Handle connection failure
        echo "Error: Failed to connect to $DISPLAY_NAME (Code $PSQL_EXIT_CODE). Check DB name ($DBNAME) or connection settings."

        # Output row with all N/A and an Alert status
        echo "<tr>
            <td>$DISPLAY_NAME</td>
            <td>$HOSTNAME</td>
            <td>$PORT</td>
            <td class='status-alert'>CONNECTION FAILED</td> <td class='repl-unsync'>CONNECTION FAILED</td>
            <td class='status-alert'>N/A</td>
            <td class='status-alert'>N/A</td>
            <td class='status-alert'>N/A</td>
            <td class='status-alert'>N/A</td>
            <td class='status-alert'>N/A</td>
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
            CONN_STATUS_CLASS="status-alert"
        elif (( CONN_RAW_PERCENT >= CONN_WARN_PERCENT )); then
            CONN_STATUS_CLASS="status-warn"
        else
            CONN_STATUS_CLASS="status-ok"
        fi
        CONN_PERCENT="${CURRENT_CONN}/${MAX_CONN} (${CONN_RAW_PERCENT}%)"
    fi

    # ----------------------------------------------------
    # 2. Get Replication Role and Lag (Efficient)
    # ----------------------------------------------------

    # First, a single, fast query to determine the role
    ROLE_CHECK_QUERY="SELECT pg_is_in_recovery();"
    # Use 'xargs' to trim whitespace from the result
    export PGPASSWORD="${DB_PASSWORD}"
    IS_REPLICA=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$ROLE_CHECK_QUERY" | xargs)
    unset PGPASSWORD

    if [[ "$IS_REPLICA" == "f" ]]; then
        # === PRIMARY (MASTER) ROLE LOGIC ===
        MASTER_STATUS="Master"

        # Master-side stats:
        # - Exclude pg_basebackup from replica/streaming counts and lag
        # - Count how many pg_basebackup clients are connected
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

        # Now, all logic is in Bash
        if [[ "$REPLICA_COUNT" -eq 0 && "$BACKUP_COUNT" -eq 0 ]]; then
            # No replicas and no backup clients
            ROLE_STATUS="<div class='repl-unsync'>UNSYNC</div>"
            REPL_DETAIL="<br/>(No Replicas)"

        # Rule 1: No streaming replicas (excluding backup). Check if a backup is running.
        elif [[ "$STREAMING_COUNT" -eq 0 ]]; then
            ROLE_STATUS="<div class='repl-unsync'>UNSYNC</div>"

            if [[ "$BACKUP_COUNT" -gt 0 ]]; then
                # Only pg_basebackup is connected → it's a backup session, not a standby
                REPL_DETAIL="<br/>(Backup Running)"
            else
                # Find out the state of one of the non-streaming, non-backup replicas
                STATE_QUERY="
                    SELECT state
                    FROM pg_stat_replication
                    WHERE application_name <> 'pg_basebackup'
                    AND state <> 'streaming'
                    LIMIT 1;
                "
                export PGPASSWORD="${DB_PASSWORD}"
                OTHER_STATE_RAW=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$STATE_QUERY")
                OTHER_STATE=$(echo "$OTHER_STATE_RAW" | xargs) # Clean whitespace
                unset PGPASSWORD

                if [[ -n "$OTHER_STATE" ]]; then
                    # Capitalize first letter: e.g., "backup" -> "Backup"
                    OTHER_STATE_CAPPED=$(echo "${OTHER_STATE^}")
                    REPL_DETAIL="<br/>($OTHER_STATE_CAPPED)"
                else
                    REPL_DETAIL="<br/>(Not Streaming)"
                fi
            fi

        # Rule 2: Streaming replicas exist, but check lag (on standbys only, excluding backup clients)
        elif [[ "$MAX_LAG_BYTES" -gt "$REPLICATION_LAG_DELAY_BYTES" ]]; then
            HUMAN_LAG=$(human_readable_bytes "$MAX_LAG_BYTES")
            REPL_DETAIL="<br/>(Lag: $HUMAN_LAG)"
            ROLE_STATUS="<div class='repl-unsync'>DELAY</div>"

            # If a backup is also running, append a note
            if [[ "$BACKUP_COUNT" -gt 0 ]]; then
                REPL_DETAIL="$REPL_DETAIL, Backup Running"
            fi

        # Rule 3: Streaming replicas and low lag
        else
            ROLE_STATUS="<div class='repl-primary'>SYNC</div>"

            # Optionally show backup note if present
            if [[ "$BACKUP_COUNT" -gt 0 ]]; then
                REPL_DETAIL="$REPL_DETAIL, Backup Running"
            fi
        fi

    elif [[ "$IS_REPLICA" == "t" ]]; then
        # === REPLICA (SLAVE) ROLE LOGIC ===
        MASTER_STATUS="Slave"

        # Run ONE query to check the WAL receiver
        WAL_RECEIVER_QUERY="SELECT count(*) FROM pg_stat_wal_receiver;"
        export PGPASSWORD="${DB_PASSWORD}"
        WAL_RECEIVER_COUNT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$WAL_RECEIVER_QUERY" | xargs)
        unset PGPASSWORD

        if [[ "$WAL_RECEIVER_COUNT" -gt 0 ]]; then
            # Connected and streaming (sync)
            ROLE_STATUS="<div class='repl-replica'>SYNC</div>"
            REPL_DETAIL="<br/>(Replica)"
        else
            # Not connected or not streaming (unsync)
            ROLE_STATUS="<div class='repl-unsync'>UNSYNC</div>"
            REPL_DETAIL="<br/>(Receiver Down)"
        fi

    else
        MASTER_STATUS="Unknown"
        ROLE_STATUS="<div class='repl-unsync'>UNKNOWN</div>"
        REPL_DETAIL="<br/>(Role Check Failed)"
    fi

    # ----------------------------------------------------
    # 3. Dead Tuples Check (Max across all tables)
    # ----------------------------------------------------
    # Query returns schema, table name, and count
    DEAD_TUPLES_QUERY="
        SELECT schemaname, relname, n_dead_tup
        FROM pg_stat_user_tables
        ORDER BY n_dead_tup DESC
        LIMIT 1;
    "

    # Pass $DBNAME as the third argument (database name)
    export PGPASSWORD="${DB_PASSWORD}"
    DEAD_TUPLES_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$DEAD_TUPLES_QUERY")

    # Parse schema, table, and dead tuple count (comma-separated result)
    IFS=',' read -r SCHEMANAME RELNAME DEAD_TUPLES_RAW <<< "$DEAD_TUPLES_RESULT"
    unset PGPASSWORD

    # Use the raw number for comparison, default to 0 if result is empty
    DEAD_TUPLES_COMPARE=${DEAD_TUPLES_RAW:-0}

    # Apply NEW logic: >=1M ALERT, 200k-999k WARN
    if (( DEAD_TUPLES_COMPARE >= DEAD_TUPLES_ALERT_THRESHOLD )); then
        DEAD_TUPLES_CLASS="status-alert"
    elif (( DEAD_TUPLES_COMPARE >= DEAD_TUPLES_WARN_THRESHOLD )); then
        DEAD_TUPLES_CLASS="status-warn"
    else
        DEAD_TUPLES_CLASS="status-ok"
    fi

    # Format the number and combine with table name for display
    if [[ -n "$DEAD_TUPLES_RAW" && "$DEAD_TUPLES_RAW" -gt 0 ]]; then
        FORMATTED_COUNT=$(format_large_number "$DEAD_TUPLES_RAW")
        DEAD_TUPLES="${FORMATTED_COUNT}<br/><small>(${SCHEMANAME}.${RELNAME})</small>"
    else
        DEAD_TUPLES="0"
    fi

    # ----------------------------------------------------
    # 4. XID Age Check
    # ----------------------------------------------------
    XID_QUERY="
        SELECT COALESCE(MAX(age(datfrozenxid)), 0) FROM pg_database;
    "
    # Pass $DBNAME as the third argument (database name)
    export PGPASSWORD="${DB_PASSWORD}"
    XID_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$XID_QUERY")
    XID_AGE=$(echo "$XID_RESULT" | xargs)
    unset PGPASSWORD
    # Apply NEW logic: >=1B ALERT, 250M-999M WARN
    if (( XID_AGE >= XID_AGE_ALERT_THRESHOLD )); then
        XID_AGE_CLASS="status-alert"
    elif (( XID_AGE >= XID_AGE_WARN_THRESHOLD )); then
        XID_AGE_CLASS="status-warn"
    else
        XID_AGE_CLASS="status-ok"
    fi

    XID_AGE=$(format_large_number "$XID_AGE")

    # ----------------------------------------------------
    # 5. Blocking Queries Count (MODIFIED)
    # ----------------------------------------------------
    BLOCKING_QUERY="
        SELECT COUNT(*) AS not_granted_lock_count
        FROM pg_locks
        WHERE NOT granted;
    "
    # Pass $DBNAME as the third argument (database name)
    export PGPASSWORD="${DB_PASSWORD}"
    BLOCKING_RESULT=$(run_psql_query "$IP" "$PORT" "$DBNAME" "$BLOCKING_QUERY")
    BLOCKING_COUNT=$(echo "$BLOCKING_RESULT" | xargs)
    unset PGPASSWORD
    # Apply NEW logic: 1-10 WARN, >=11 ALERT
    if (( BLOCKING_COUNT >= 11 )); then
        BLOCKING_CLASS="status-alert"
    elif (( BLOCKING_COUNT >= 1 )); then
        BLOCKING_CLASS="status-warn"
    else
        BLOCKING_CLASS="status-ok"
    fi

    # ----------------------------------------------------
    # 6. Mountpoint Usage Check (from PEM database)
    # ----------------------------------------------------
    # This query uses $HOSTNAME (field 1) and $DISPLAY_NAME (field 5) from the list_db file
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

    # Run query against the PEM database
    export PGPASSWORD="${DB_PASSWORD}"
    MOUNTPOINT_RESULT=$(run_psql_query_pem "$MOUNTPOINT_QUERY")
    PEM_QUERY_EXIT_CODE=$?
    unset PGPASSWORD
    # Check if the query returned a result
    if [[ $PEM_QUERY_EXIT_CODE -eq 0 && -n "$MOUNTPOINT_RESULT" ]]; then
        # The $MOUNTPOINT_RESULT is the percentage string (e.g., "85.23")
        MOUNTPOINT_PERCENT_STRING=$(echo "$MOUNTPOINT_RESULT" | xargs) # Trim whitespace

        # Use AWK to convert the percentage string (e.g., "85.23") to an integer
        MOUNTPOINT_RAW_PERCENT=$(echo "$MOUNTPOINT_PERCENT_STRING" | awk '{printf "%.0f", $1}')

        # NEW 80% THRESHOLD LOGIC (SAFE/ALERT)
        if (( MOUNTPOINT_RAW_PERCENT >= MOUNTPOINT_ALERT_THRESHOLD )); then
            MOUNTPOINT_CLASS="status-alert"
            MOUNTPOINT_DISPLAY_TEXT="$MP"
        else
            MOUNTPOINT_CLASS="status-safe"
            MOUNTPOINT_DISPLAY_TEXT="$MP"
        fi

        # Format for display: e.g., "ALERT (85.23%)" or "SAFE (70.10%)"
        MOUNTPOINT_USAGE="${MOUNTPOINT_DISPLAY_TEXT}<br/><small>(${MOUNTPOINT_PERCENT_STRING}%)</small>"
    else
        # Query failed or returned no data
        MOUNTPOINT_CLASS="status-na"
        MOUNTPOINT_USAGE="N/A"
    fi

    # ----------------------------------------------------
    # FINAL HTML ROW OUTPUT
    # ----------------------------------------------------
    echo "<tr>
        <td>$DISPLAY_NAME</td>
        <td>$HOSTNAME</td>
        <td>$PORT</td>
        <td>$MASTER_STATUS</td> <td>$ROLE_STATUS $REPL_DETAIL</td>
        <td><div class='$CONN_STATUS_CLASS'>$CONN_PERCENT</div></td>
        <td><div class='$DEAD_TUPLES_CLASS'>$DEAD_TUPLES</div></td>
        <td><div class='$XID_AGE_CLASS'>$XID_AGE</div></td>
        <td><div class='$BLOCKING_CLASS'>$BLOCKING_COUNT</div></td>
        <td><div class='$MOUNTPOINT_CLASS'>$MOUNTPOINT_USAGE</div></td>
      </tr>" >> "$OUTPUT_HTML"

done < "$LIST_DB_FILE"

# ==============================================================================
# HTML FOOTER AND EMAIL SENDING
# ==============================================================================

# Finish HTML file
echo '<footer>
    <p>Generated by PostgreSQL Healthcheck Report Script - Telkomsigma</p></footer>
</body>
</html>' >> "$OUTPUT_HTML"


# --- Email Sending ---
# Define email recipients and sender.
# TO_EMAIL="dba@telkomsel.co.id"
TO_EMAIL="xxx@telkomsel.co.id"
FROM_EMAIL="yyy@telkomsel.co.id"
# SUBJECT is already defined in the CONFIG section

# Send the HTML report using mailx.
# The report content is piped to mailx, which sends it as an HTML email.
#echo "$BODY_TEXT" | mailx -s "$SUBJECT" -a "$OUTPUT_FILE" -r "$FROM_EMAIL" "$TO_EMAIL"
# Construct the body of the email with explicit newlines for proper formatting
(
echo "Dear Team,"
echo "" # Empty line for spacing
echo "Attached is the latest PostgreSQL Database Healthcheck Report for your review. Please examine the findings carefully. If any metrics or indicators fall outside the expected operational thresholds or best practices, kindly initiate the appropriate remediation procedures as soon as possible to ensure continued system stability and performance."
echo "" # Empty line for spacing
echo "Best regards,"
echo "MODB Team"
) | mailx -s "$SUBJECT" -a "$OUTPUT_HTML" -r "$FROM_EMAIL" "$TO_EMAIL"

echo "Health check report sent to $TO_EMAIL."