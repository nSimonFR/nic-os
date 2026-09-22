# Mount the Papra archive into Nextcloud as a read-only Local external storage.
# Idempotent. Env: OCC, ARCHIVE_DIR, ARCHIVE_MOUNT, NC_USER.

find_mount() {
  "$OCC" files_external:list --output=json 2>/dev/null \
    | jq -r --arg mp "/$ARCHIVE_MOUNT" 'map(select(.mount_point == $mp)) | .[0].mount_id // empty'
}

"$OCC" app:enable files_external >/dev/null

mount_id=$(find_mount)
if [ -z "$mount_id" ]; then
  "$OCC" files_external:create "/$ARCHIVE_MOUNT" local null::null -c "datadir=$ARCHIVE_DIR" >/dev/null
  mount_id=$(find_mount)
fi
if [ -z "$mount_id" ]; then
  echo "could not create the /$ARCHIVE_MOUNT external mount" >&2
  exit 1
fi

# The real guarantee is POSIX (papra:papra 0755, php-fpm not in that group);
# readonly stops the UI offering edits it cannot perform.
"$OCC" files_external:applicable --add-user "$NC_USER" "$mount_id" >/dev/null
"$OCC" files_external:option "$mount_id" readonly true >/dev/null
echo "archive mounted at /$ARCHIVE_MOUNT (mount $mount_id), read-only, for $NC_USER"
