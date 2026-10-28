# Manual setup

Harbor currently supports migrating an existing local Transmission session. Fresh-install setup is not automated yet.

1. Install `transmission-cli` with Homebrew and build Harbor as described in the README.
2. In the Transmission Mac app, enable authenticated RPC on port 9091. Restrict access to localhost and choose your own username and password.
3. With Transmission running, capture the session:

   ```sh
   python3 scripts/migrate-transmission.py snapshot
   ```

   The script prompts for the local RPC credentials. It saves a pending configuration with a salted password verifier.

4. Open Harbor. If it reports that the Transmission app is running, dismiss that message. In **Downloads → Connection Settings…**, save the same credentials. This tests the running local session and stores the login in Keychain.
5. Quit Harbor, then quit the Transmission Mac app completely.
6. Complete the migration while both apps are stopped:

   ```sh
   python3 scripts/migrate-transmission.py finish
   ```

7. Open Harbor again. It starts the daemon using the migrated settings.

The migration copies torrent and resume state and backs up the original configuration. Downloaded files are not moved. It refuses to overwrite an existing daemon configuration.

## Troubleshooting

- **Port 9091 already in use:** stop the other Transmission instance or service before opening Harbor.
- **Keychain prompt after rebuilding:** approve access for the locally rebuilt app through macOS.
- **Incoming peer connections fail:** check the configured peer port, firewall and any router forwarding rule. The peer port is separate from RPC port 9091.
- **Shutdown takes time:** Harbor waits for the daemon to save its state. If it cannot confirm exit, it stays open and reports the problem.

## Returning to the Mac app

Quit Harbor and confirm its daemon has stopped before opening Transmission. The original app retains its previous session. Transfers added after migration need to be moved back deliberately; they are not synchronized between the two configurations.
