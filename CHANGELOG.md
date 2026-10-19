# Changelog

## 1.0.0 — 2026-10-19

- Syncthing 2.1.6 in Container Manager, running as the package's own user, on
  the NAS's own network so local discovery works (or Docker's network, from
  the Site address tab).
- The install wizard suggests free web and sync ports, warns when local
  discovery's port is taken, and asks whether Syncthing may reach the
  internet or stays on your network.
- **Devices:** this Synology's ID with a QR code and Copy; devices asking to
  connect (accept with a name, or ignore); paired devices with connection,
  address, rates and how far they're in sync; add by ID, pause, rename,
  remove.
- **Folders:** sync shared folders (each mounted at its own path, never
  created), with a write test as the package's user and the exact steps when
  it lacks permission; type, devices, versioning and ignore patterns (DSM's
  pre-filled); rescan, pause, override, revert, stop syncing; folders offered
  by other devices accepted into a shared folder or declined.
- **Conflicts:** every conflicting copy, by file, with keep this version or
  keep the original.
- **Activity:** recent file changes, here or on which device.
- **Privacy & network:** local network only or anywhere, bandwidth limits,
  the sync port, listener and discovery status, Show password and New
  password for Syncthing's web interface.
- DSM notifications for a device asking to pair, a folder out of sync for
  over 30 minutes, and new conflicts.
- Backups keep this Synology's device identity; updates back up first and
  remove only the old Syncthing image.
