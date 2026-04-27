# Migration: filebrowser → Nextcloud (shared datadir on /mnt/data/cloud)

This PR replaces filebrowser with Nextcloud at the same tailnet port (`:8085`)
and points Nextcloud's `datadir` at `/mnt/data/cloud`. The user-visible files
move from a flat layout (`/mnt/data/cloud/{ADMINISTRATIVE,BACKUPS,DOCUMENTS}`)
to Nextcloud's required per-user layout
(`/mnt/data/cloud/nsimon/files/{ADMINISTRATIVE,BACKUPS,DOCUMENTS}`).

The data migration is a **one-time manual step** before the rebuild. Run on
rpi5 (you ARE on rpi5):

```sh
sudo bash rpi5/migrate-nextcloud-datadir.sh
```

The script:

1. Stops `filebrowser`, `nextcloud-cron.timer`, `paperless-scheduler`,
   `paperless-task-queue`, `paperless-consumer`, `paperless-web`.
2. Creates `/mnt/data/cloud/nsimon/files/` and moves
   `ADMINISTRATIVE/`, `BACKUPS/`, `DOCUMENTS/` into it.
3. `chown -R nextcloud:nextcloud /mnt/data/cloud/nsimon` (Nextcloud needs
   to own the datadir tree).
4. `chown -R paperless:paperless` on the `paperless-consume/` leaf
   (paperless writes to it).
5. Cleans the old empty Nextcloud datadir at `/var/lib/nextcloud/data` so
   the new datadir starts fresh.

Then, on the host:

```sh
sudo nixos-rebuild switch --flake /home/nsimon/nic-os#rpi5 --max-jobs 1 -j 1
```

The rebuild:
- Drops `services.filebrowser` and the `:8085` Tailscale Serve route to
  filebrowser; routes `:8085` to Nextcloud's nginx (`127.0.0.1:8091`).
- Sets `services.nextcloud.datadir = "/mnt/data/cloud"` so the new install
  uses the migrated tree.
- Re-enables file-related apps (`files_sharing`, `files_versions`,
  `files_trashbin`, `files_pdfviewer`, `text`, `systemtags`, `activity`).
- Updates `services.paperless.settings.consumeDir` to the new path.
- Updates `ts drive share cloud /mnt/data/cloud/nsimon/files`.

After the rebuild, scan the existing files into the Nextcloud index:

```sh
sudo nextcloud-occ files:scan nsimon
```

This walks the filesystem under `/mnt/data/cloud/nsimon/files/` and inserts
the metadata rows so the existing files show up in the Nextcloud Files UI.

## Verification

- `https://rpi5.gate-mintaka.ts.net:8085/` → Nextcloud login (was filebrowser)
- After login, Files app should list `ADMINISTRATIVE/`, `BACKUPS/`, `DOCUMENTS/`
- `ls /mnt/data/cloud/nsimon/files/` → same three dirs
- `systemctl status paperless-consumer` → active
- `systemctl status filebrowser` → not-found (service removed)

## Rollback

If the migration fails before the rebuild:

```sh
cd /mnt/data/cloud
sudo mv nsimon/files/ADMINISTRATIVE .
sudo mv nsimon/files/BACKUPS .
sudo mv nsimon/files/DOCUMENTS .
sudo rm -rf nsimon
sudo chown -R root:root ADMINISTRATIVE
sudo chown -R nsimon:users BACKUPS DOCUMENTS
sudo systemctl start filebrowser
```

Then revert this PR.
