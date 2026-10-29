# Setup

## New installation

1. Copy Harbor from the disk image to Applications and open it.
2. Choose a download folder, then select **Start Harbor**.

Harbor creates its own download profile, generates a local login and stores the credentials in macOS Keychain. There is no Transmission account to create or password to type. Choosing **Not Now** leaves the engine off; use **Set Up Downloads…** in the menu to return later.

Existing Harbor settings and transfers are kept. Other Transmission configurations are not imported or changed automatically.

## Optional migration from Transmission

The developer migration helper can copy a local Transmission Mac session. It is optional and requires Python; normal fresh setup does not.

With the Mac app running and authenticated localhost RPC configured, run:

```sh
python3 scripts/migrate-transmission.py snapshot
```

Open Harbor, choose **Not Now** in the first-run sheet, and save those credentials through **Connection Settings…**, then fully quit both apps and run:

```sh
python3 scripts/migrate-transmission.py finish
```

The helper refuses an existing Harbor engine configuration and backs up the GUI profile before copying torrent/resume state. Downloaded payloads are not moved. Restart Harbor to use the migrated profile. If Harbor is already configured, keep using it rather than rerunning migration over that profile.

## Troubleshooting

- **Port 9091 already in use:** stop the other Transmission instance or service before opening Harbor.
- **Keychain prompt after rebuilding:** approve access for the locally rebuilt app through macOS.
- **Incoming peer connections fail:** check the configured peer port, firewall and any router forwarding rule. The peer port is separate from RPC port 9091.
- **Shutdown takes time:** Harbor waits for the daemon to save its state. If it cannot confirm exit, it stays open and reports the problem.

## Returning to the Mac app

Quit Harbor and confirm its daemon has stopped before opening Transmission. The original app retains its previous session. Transfers added after migration are not synchronized between the two configurations.
