# Nextcloud Backup via WebDAV (multi-user)

Bash script to back up Nextcloud users’ files via WebDAV using `rclone`, reading credentials from a CSV, saving to a mounted USB disk, and sending a single end-of-run status notification via CallMeBot (WhatsApp). It keeps local state with the timestamp of the last success for more informative reporting.

## Overview
- Per-user backup using WebDAV (`rclone`) from `NC_URL`.
- Reads users and app passwords from `backup_nextcloud_user_webdav.csv` (simple CSV).
- Target is a USB disk (requires the mount point to be present). If not mounted, skips execution and only notifies.
- Per-user rotation keeping only the most recent `RETENTION` snapshots.
- Optional compression (`COMPRESS=true`) and `SHA256` generation.
- Single end-of-run notification via CallMeBot (total success, no valid users, or failures) with duration and free space on target.
- Stores `.state/last_success_epoch.txt` to compute how many days since the last success.

## Requirements
- bash, coreutils (`df`, `du`, `sha256sum`), `tar` (if compression enabled)
- `rclone` (with WebDAV support)
- `curl` (for CallMeBot notification)
- System providing `mountpoint` (e.g., util-linux)

## Main Files
- `backup_nextcloud_user_webdav.sh`: backup script.
- `backup_nextcloud_user_webdav.env.example`: environment configuration template.
- `backup_nextcloud_user_webdav.csv`: list of users and app passwords (one per line).
- `.state/`: directory created by the script to record the last success.

## Configuration
1) Prepare the users CSV `backup_nextcloud_user_webdav.csv`:
   - Format: `username,app_password`
   - Lines starting with `#` are ignored
   - Example:
     ```
     # username,app_password
     user1,ABCD-1234-...
     ```
2) Create your environment file from the template:
   ```bash
   cp backup_nextcloud_user_webdav.env.example backup_nextcloud_user_webdav.env
   ```
   Edit `backup_nextcloud_user_webdav.env` for your environment. Key variables:
   - `NC_URL`: base Nextcloud URL (e.g., `https://your-host`)
   - `USB_MOUNT_POINT`: target disk mount point
   - `BACKUP_BASE`: backup destination directory (must be inside `USB_MOUNT_POINT`)
   - `USERS_FILE`: path to the users CSV
   - `RETENTION`: number of snapshots to keep per user (default: 1)
   - `COMPRESS`: `true|false` to produce `tar.gz` per snapshot
   - `GENERATE_SHA256`: `true|false` to generate `.sha256`
   - `TLS_SKIP_VERIFY`: `true|false` to skip certificate verification (not recommended; prefer `false` in production)
   - `EXCLUDES`: one per line, same syntax as `rclone --exclude`
   - `CALLMEBOT_PHONE`, `CALLMEBOT_APIKEY`, `CALLMEBOT_ADMIN_NAME`: notification parameters (optional)

## How to Run
The script automatically loads environment variables from `backup_nextcloud_user_webdav.env` located next to the script. Simply run:
```bash
bash ./backup_nextcloud_user_webdav.sh
```

## Manual Run
1) Prepare the environment file:
   ```bash
   cp backup_nextcloud_user_webdav.env.example backup_nextcloud_user_webdav.env
   ```
   Edit `backup_nextcloud_user_webdav.env` and set at least:
   - `NC_URL`
   - `USERS_FILE=./backup_nextcloud_user_webdav.csv`
   - `USB_MOUNT_POINT`
   - `BACKUP_BASE`
   Optional: to disable notifications, set `CURL_BIN=/bin/false`.

2) Create the users CSV (or use your own):
   ```bash
   cp backup_nextcloud_user_webdav.csv.example backup_nextcloud_user_webdav.csv
   ```
   Replace placeholders with real `username,app_password` values.

3) Check dependencies are available:
   ```bash
   rclone version && curl --version && mountpoint --version
   ```

4) Ensure the USB target is mounted:
   ```bash
   mountpoint -q "$USB_MOUNT_POINT" || echo "USB not mounted: $USB_MOUNT_POINT"
   ```

5) Run the backup:
   ```bash
   bash ./backup_nextcloud_user_webdav.sh
   # or
   chmod +x backup_nextcloud_user_webdav.sh && ./backup_nextcloud_user_webdav.sh
   ```

6) Verify results:
   - Backups under `BACKUP_BASE/<user>/<timestamp>/` (or `.tar.gz` if `COMPRESS=true`).
   - `.state/last_success_epoch.txt` updated on total success.

Output and logs:
- The script prints a summary to stdout and sends a single notification (if `curl` configured and CallMeBot variables set).
- If pre-checks fail (e.g., USB not mounted), it skips the backup and reports the reason.

## Output Structure
There are two modes controlled by `MODE` in the env file:

- snapshot (default):
  - When `COMPRESS=false` (default): `BACKUP_BASE/<user>/<YYYYMMDDThhmmss>/` directory with files copied via WebDAV (local time).
  - When `COMPRESS=true`: `BACKUP_BASE/<user>/<YYYYMMDDThhmmss>.tar.gz` and optional `.sha256` if `GENERATE_SHA256=true` (local time).
  - Rotation: keeps only the most recent `RETENTION` snapshots per user; removes older ones (and respective `.sha256`).

- incremental:
  - Syncs to `BACKUP_BASE/<user>/current`.
  - Changed/removed files are moved to `BACKUP_BASE/<user>/_versions/<YYYYMMDDThhmmss>/` (local time) via `rclone --backup-dir`.
  - Rotation: keeps only the most recent `RETENTION` version directories under `_versions/` per user.
  - Note: `COMPRESS=true` is ignored in incremental mode.

### Incremental Example (one user)
```
<BACKUP_BASE>/
  alice/
    current/
      Documents/
        report.docx
      Photos/
        2024/
          img001.jpg
    _versions/
      20240905T094215/
        Documents/
          old-report.docx      # replaced in current
        Photos/
          2023/
            img099.jpg         # deleted from current
```

## Exclusions
Set `EXCLUDES` in the env file, one pattern per line (same syntax as `rclone --exclude`). Example:
```bash
EXCLUDES="*/Temp/**
*/node_modules/**"
```

## Notifications (CallMeBot)
- Sends a single message at the end (total success, no valid users, or failures).
- Variables: `CALLMEBOT_PHONE`, `CALLMEBOT_APIKEY`, `CALLMEBOT_ADMIN_NAME`.
- To disable, leave variables empty and/or set `CURL_BIN=/bin/false` in the env file.

## TLS Security
- `TLS_SKIP_VERIFY=true` adds `--no-check-certificate` to `rclone` (skips TLS verification). Not recommended in production.
- Prefer `TLS_SKIP_VERIFY=false` with valid certificates on your `NC_URL`.

## Scheduling (cron)
Example crontab entry (daily at 02:30):
```cron
30 2 * * * cd /path/to/project && /bin/bash -lc 'bash ./backup_nextcloud_user_webdav.sh' >> backup.log 2>&1
```
Notes:
- Ensure the USB is mounted at `USB_MOUNT_POINT` before the scheduled time.
- Verify read permissions on the source (Nextcloud via WebDAV) and write permissions on the destination.

## Tips and Troubleshooting
- Check dependencies: `rclone`, `curl`, `tar`, `sha256sum`, and `mountpoint` must be available in PATH.
- Test with a single user in the CSV to validate connectivity and credentials.
- Use `RETENTION=1` to keep only the latest snapshot (default) and save space.
- Inspect `.state/last_success_epoch.txt` to understand “last success X day(s) ago” messages.

## Warning
This project handles sensitive credentials (app passwords). Protect `backup_nextcloud_user_webdav.csv` and the project directory, and avoid saving logs with credentials.
