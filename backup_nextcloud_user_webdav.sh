#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# backup_nextcloud_user_webdav.sh
# - Multi-user backup via WebDAV (Nextcloud) using rclone
# - Writes to a USB disk; if not mounted, it will skip
# - Sends a single final notification (CallMeBot) with a concise summary
# - Keeps local state of the "last success" under .state
# ============================================================

# -------- CONFIG (loaded from backup_nextcloud_user_webdav.env) --------
# ONLY accepted config file: backup_nextcloud_user_webdav.env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup_nextcloud_user_webdav.env"
if [[ -f "${CONFIG_FILE}" ]]; then
  set -a; source "${CONFIG_FILE}"; set +a
fi

NC_URL="${NC_URL:-}"
USERS_FILE="${USERS_FILE:-}"

USB_MOUNT_POINT="${USB_MOUNT_POINT:-}"
BACKUP_BASE="${BACKUP_BASE:-}"
MODE="${MODE:-snapshot}"

# Default retention = 1 (as requested)
RETENTION="${RETENTION:-1}"
COMPRESS="${COMPRESS:-false}"
GENERATE_SHA256="${GENERATE_SHA256:-true}"
TLS_SKIP_VERIFY="${TLS_SKIP_VERIFY:-true}"

# Exclusions (rclone patterns) as multi-line string; leave empty if unused
# EXCLUDES='*/Temp/**
# */node_modules/**'
EXCLUDES="${EXCLUDES:-}"

RCLONE_BIN="${RCLONE_BIN:-rclone}"
CURL_BIN="${CURL_BIN:-curl}"

# CallMeBot (WhatsApp)
CALLMEBOT_PHONE="${CALLMEBOT_PHONE:-}"
CALLMEBOT_APIKEY="${CALLMEBOT_APIKEY:-}"
CALLMEBOT_ADMIN_NAME="${CALLMEBOT_ADMIN_NAME:-}"
# ---------------------------------------------------------------

# -------- Local state (independent from USB) --------
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-${BASE_DIR}/.state}"
LAST_SUCCESS_FILE="${LAST_SUCCESS_FILE:-${STATE_DIR}/last_success_epoch.txt}"
mkdir -p "$STATE_DIR"

die_soft(){ echo "ERROR: $*" >&2; ERROR_REASON="$*"; RETURN_CODE=1; }

notify() {
  local msg="[$CALLMEBOT_ADMIN_NAME] $*"
  "$CURL_BIN" -sfS -G \
    --data-urlencode "phone=${CALLMEBOT_PHONE}" \
    --data-urlencode "apikey=${CALLMEBOT_APIKEY}" \
    --data-urlencode "text=${msg}" \
    https://api.callmebot.com/whatsapp.php >/dev/null || true
}

# -------- Helper functions --------
format_duration() {
  # $1 = seconds
  local s=$1 h m
  h=$(( s/3600 ))
  m=$(( (s%3600)/60 ))
  s=$(( s%60 ))
  printf "%02dh%02dm%02ds" "$h" "$m" "$s"
}

days_since_last_success() {
  if [[ -f "$LAST_SUCCESS_FILE" ]]; then
    local last_epoch now_epoch diff
    last_epoch="$(cat "$LAST_SUCCESS_FILE" 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    if [[ "$last_epoch" =~ ^[0-9]+$ ]] && (( last_epoch>0 )); then
      diff=$(( (now_epoch - last_epoch) / 86400 ))
      echo "$diff"
      return 0
    fi
  fi
  echo "unknown"
  return 1
}

record_success_now() {
  date +%s > "$LAST_SUCCESS_FILE" 2>/dev/null || true
}

# -------- Pre-checks without skipping final reporting --------
RETURN_CODE=0
ERROR_REASON=""

if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
  die_soft "curl not found"
fi
if ! command -v "$RCLONE_BIN" >/dev/null 2>&1; then
  die_soft "rclone not found"
fi
if [[ ! -f "$USERS_FILE" ]]; then
  die_soft "USERS_FILE not found: $USERS_FILE"
fi

# -------- Start time measurement --------
START_HUMAN="$(date +'%Y-%m-%dT%H:%M:%S %Z')"
START_EPOCH="$(date +%s)"

# If a critical error occurred during pre-checks, skip execution and notify at the end
if [[ "$RETURN_CODE" -ne 0 ]]; then
  # Skipped due to pre-check error
  DAYS="$(days_since_last_success)"
  notify "Backup NOT EXECUTED due to pre-check error: ${ERROR_REASON}. Last success: ${DAYS} day(s) ago."
  echo "NOK: ${ERROR_REASON}. Last success: ${DAYS} day(s) ago."
  exit 0
fi

# -------- USB disk check --------
if ! mountpoint -q "$USB_MOUNT_POINT"; then
  DAYS="$(days_since_last_success)"
  notify "Backup NOT EXECUTED: target disk not mounted at ${USB_MOUNT_POINT}. Last success: ${DAYS} day(s) ago."
  echo "ABORT: USB not mounted. Last success: ${DAYS} day(s) ago."
  exit 0
fi

case "$BACKUP_BASE" in
  "${USB_MOUNT_POINT}"/*) : ;;
  *) ERROR_REASON="BACKUP_BASE (${BACKUP_BASE}) must be inside ${USB_MOUNT_POINT}";;
esac

if [[ -n "${ERROR_REASON}" ]]; then
  DAYS="$(days_since_last_success)"
  notify "Backup NOT EXECUTED: ${ERROR_REASON}. Last success: ${DAYS} day(s) ago."
  echo "NOK: ${ERROR_REASON}. Last success: ${DAYS} day(s) ago."
  exit 0
fi

mkdir -p "$BACKUP_BASE"

# Build exclusion args (one --exclude per line in EXCLUDES)
RCLONE_EXCLUDES_ARGS=""
if [[ -n "$EXCLUDES" ]]; then
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    RCLONE_EXCLUDES_ARGS="$RCLONE_EXCLUDES_ARGS --exclude $pat"
  done <<EOF
$EXCLUDES
EOF
fi

RCLONE_TLS_ARGS=""
if [[ "$TLS_SKIP_VERIFY" == "true" ]]; then
  RCLONE_TLS_ARGS="--no-check-certificate"
fi

# -------- Execution (no arrays; uses temp files) --------
SUMMARY_FILE="$(mktemp -t nc_bkp_summary_XXXX.txt)"
FAILED_FILE="$(mktemp -t nc_bkp_failed_XXXX.txt)"
trap 'rm -f "$SUMMARY_FILE" "$FAILED_FILE"' EXIT

ok_count=0
fail_count=0

backup_user() {
  # $1=user  $2=app_pass
  local user="$1"
  local app_pass="$2"

  if [[ -z "$user" || -z "$app_pass" ]]; then
    echo -e "$user\t-\tFAIL(empty credentials)" >>"$SUMMARY_FILE"
    echo "$user" >>"$FAILED_FILE"
    return 2
  fi

  local remote_url="${NC_URL%/}/remote.php/dav/files/${user}/"
  local now; now="$(date +'%Y%m%dT%H%M%S')"

  local parent snap_dir target_dir versions_dir
  parent="${BACKUP_BASE%/}/${user}"
  snap_dir="${parent}/${now}"
  target_dir="${parent}/current"
  versions_dir="${parent}/_versions/${now}"

  mkdir -p "$parent"

  # temporary rclone.conf
  local tmpconf; tmpconf="$(mktemp -t rclone-nextcloud_XXXX.conf)"

  # obscure as positional argument
  local obscured; obscured="$("$RCLONE_BIN" obscure "$app_pass")"

  cat >"$tmpconf" <<EOF
[nextcloud]
type = webdav
url = ${remote_url}
vendor = nextcloud
user = ${user}
pass = ${obscured}
EOF

  if [[ "$MODE" == "incremental" ]]; then
    mkdir -p "$target_dir" "$versions_dir"
    echo "-> [$user] incremental sync via WebDAV -> $target_dir (versions: ${versions_dir})"
    # If COMPRESS=true in incremental mode, it's ignored; warn once per user
    if [[ "$COMPRESS" == "true" ]]; then
      echo "WARN: COMPRESS=true is ignored in incremental mode" >&2
    fi
    # shellcheck disable=SC2086
    if ! $RCLONE_BIN sync "nextcloud:" "$target_dir" \
          --config "$tmpconf" \
          --create-empty-src-dirs \
          --backup-dir "$versions_dir" \
          --transfers 8 --checkers 16 --tpslimit 8 \
          --retries 3 --low-level-retries 5 \
          --timeout 1h --stats 30s \
          $RCLONE_EXCLUDES_ARGS $RCLONE_TLS_ARGS; then
      echo -e "$user\t-\tFAIL(rclone sync)" >>"$SUMMARY_FILE"
      echo "$user" >>"$FAILED_FILE"
      rm -f "$tmpconf"
      return 3
    fi
  else
    mkdir -p "$snap_dir"
    echo "-> [$user] copying via WebDAV -> $snap_dir"
    # shellcheck disable=SC2086
    if ! $RCLONE_BIN copy "nextcloud:" "$snap_dir" \
          --config "$tmpconf" \
          --create-empty-src-dirs \
          --transfers 8 --checkers 16 --tpslimit 8 \
          --retries 3 --low-level-retries 5 \
          --timeout 1h --stats 30s \
          $RCLONE_EXCLUDES_ARGS $RCLONE_TLS_ARGS; then
      echo -e "$user\t-\tFAIL(rclone copy)" >>"$SUMMARY_FILE"
      echo "$user" >>"$FAILED_FILE"
      rm -f "$tmpconf"
      return 3
    fi
  fi

  # Optional compression
  local size_str="unknown"
  if [[ "$MODE" == "incremental" ]]; then
    if [[ -d "$target_dir" ]]; then
      size_str="$(du -sh "$target_dir" | awk '{print $1}')"
    fi
  elif [[ "$COMPRESS" == "true" ]]; then
    local tarfile="${snap_dir}.tar.gz"
    tar -C "$parent" -czf "$tarfile" "$(basename "$snap_dir")"
    if [[ "$GENERATE_SHA256" == "true" ]]; then
      sha256sum "$tarfile" > "${tarfile}.sha256"
    fi
    rm -rf "$snap_dir"
    if [[ -f "$tarfile" ]]; then
      size_str="$(du -h "$tarfile" | awk '{print $1}')"
    fi
  else
    if [[ -d "$snap_dir" ]]; then
      size_str="$(du -sh "$snap_dir" | awk '{print $1}')"
    fi
  fi

  # Rotation (keep only newest RETENTION)
  if [[ -d "$parent" ]]; then
    if [[ "$MODE" == "incremental" ]]; then
      # keep only newest RETENTION version folders under _versions
      if [[ -d "${parent}/_versions" ]]; then
        existing="$(ls -1t -d "${parent}/_versions/"[0-9T]* 2>/dev/null || true)"
        count=0
        echo "$existing" | while IFS= read -r item; do
          [[ -z "$item" ]] && continue
          count=$((count+1))
          if [[ "$count" -gt "$RETENTION" ]]; then
            rm -rf "$item" 2>/dev/null || true
          fi
        done
      fi
    else
      if [[ "$COMPRESS" == "true" ]]; then
        existing="$(ls -1t "${parent}/"[0-9T]*.tar.gz 2>/dev/null || true)"
      else
        existing="$(ls -1t -d "${parent}/"[0-9T]* 2>/dev/null || true)"
      fi
      count=0
      echo "$existing" | while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        count=$((count+1))
        if [[ "$count" -gt "$RETENTION" ]]; then
          rm -rf "$item" "${item}.sha256" 2>/dev/null || true
        fi
      done
    fi
  fi

  echo -e "$user\t${size_str}\tOK" >>"$SUMMARY_FILE"
  rm -f "$tmpconf"
  return 0
}

# Process CSV (user,app_password)
# Be robust to files without a trailing newline (process last line too)
while IFS=, read -r csv_user csv_pass _rest || [[ -n "$csv_user" || -n "$csv_pass" ]]; do
  csv_user="$(printf "%s" "$csv_user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  csv_pass="$(printf "%s" "$csv_pass" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$csv_user" ]] && continue
  case "$csv_user" in \#*) continue ;; esac

  if backup_user "$csv_user" "$csv_pass"; then
    ok_count=$((ok_count+1))
  else
    fail_count=$((fail_count+1))
  fi
done < "$USERS_FILE"

END_HUMAN="$(date +'%Y-%m-%dT%H:%M:%S %Z')"
END_EPOCH="$(date +%s)"
DURATION_SEC=$((END_EPOCH - START_EPOCH))
DURATION_FMT="$(format_duration "$DURATION_SEC")"

# -------- Single end-of-run notification --------
if [[ "$ok_count" -gt 0 && "$fail_count" -eq 0 ]]; then
  # Total success: report free space, start/end and duration
  # Free space on target
  DISK_FREE="$(df -h --output=avail,target "$USB_MOUNT_POINT" | tail -1 | awk '{print $1}')"
  SUMMARY_LINES_TABLE="$(awk -F'\t' 'BEGIN{printf("User\tSize\tStatus\n")} {printf("%s\t%s\t%s\n",$1,$2,$3)}' "$SUMMARY_FILE" | column -t -s$'\t')"
  notify "Backup COMPLETED SUCCESSFULLY.
Start: ${START_HUMAN}
End:   ${END_HUMAN}
Duration: ${DURATION_FMT}
Free space at ${USB_MOUNT_POINT}: ${DISK_FREE}
Users processed: ${ok_count}
Details:
$(echo "$SUMMARY_LINES_TABLE" | sed 's/^/ - /')"
  echo "OK: total success. Duration ${DURATION_FMT}. Free ${DISK_FREE}."
  # record \"last success\"
  record_success_now
elif [[ "$ok_count" -eq 0 && "$fail_count" -eq 0 ]]; then
  # No users in CSV (or all ignored)
  DAYS="$(days_since_last_success)"
  notify "Backup NOT EXECUTED: no valid user in CSV. Last success: ${DAYS} day(s) ago."
  echo "NOK: no valid user. Last success: ${DAYS} day(s) ago."
else
  # Partial/total failures: report reason and time since last success
  FAILED_LIST="$(tr '\n' ' ' < "$FAILED_FILE" | sed 's/[[:space:]]\{1,\}$//')"
  DAYS="$(days_since_last_success)"
  [[ -z "$FAILED_LIST" ]] && FAILED_LIST="unknown"
  SUMMARY_LINES_TABLE="$(awk -F'\t' 'BEGIN{printf("User\tSize\tStatus\n")} {printf("%s\t%s\t%s\n",$1,$2,$3)}' "$SUMMARY_FILE" | column -t -s$'\t')"
  notify "Backup NOT SUCCESSFUL for all users.
Start: ${START_HUMAN}
End:   ${END_HUMAN}
Users failed: ${FAILED_LIST}
Last success: ${DAYS} day(s) ago
Details:
$(echo "$SUMMARY_LINES_TABLE" | sed 's/^/ - /')"
  echo "NOK: failures detected. Last success: ${DAYS} day(s) ago."
fi
