# Bounded 48-hour soak

The soak combines a dedicated Transmission daemon with real Harbor models,
SwiftUI main-window layout, native menu rebuilding and polling. It does not
exercise search providers or replace manual UI interaction. It is a separate
Swift test-helper process, not a deployment of the normal Harbor app.

## Prepare without starting

Requires macOS, Python 3.9+, Xcode and a standalone engine build. Build the Swift
test bundle with `swift build --build-tests --build-system native --disable-sandbox`.
Use private local storage outside a cloud-synced folder for the run.

```sh
python3 scripts/soak.py prepare \
  --root "$HARBOR_SOAK_ROOT" \
  --engine-app "$HARBOR_ENGINE_APP" \
  --test-bundle "$HARBOR_TEST_BUNDLE" \
  --helper "$(xcrun --find swiftpm-testing-helper)" \
  --torrent /absolute/path/to/selected.torrent
python3 scripts/soak.py verify --root "$HARBOR_SOAK_ROOT"
```

If Xcode does not expose the test helper through `xcrun`, supply its full path
under the selected toolchain's `usr/libexec/swift/pm/` directory.
Preparation parses metadata, rejects unsafe paths, checks the total payload
size and copies/hashes the engine, libraries, test bundle, runner and metadata.
It creates **no daemon, transfer, credentials, schedule or background service**.
`plan.json` remains `prepared-not-started` until a separate start action.

## Start and stop

Only after the operator explicitly approves starting:

```sh
python3 "$HARBOR_SOAK_ROOT/soak.py" run --root "$HARBOR_SOAK_ROOT" --confirm-start
```

Keep the runner session alive. There is no login job or automatic restart.
To inspect state or request a graceful stop from another terminal:

```sh
python3 "$HARBOR_SOAK_ROOT/soak.py" status --root "$HARBOR_SOAK_ROOT"
python3 "$HARBOR_SOAK_ROOT/soak.py" stop --root "$HARBOR_SOAK_ROOT"
```

The helper receives a random per-run local login only through a private stdin
pipe. No production Keychain item is used. Disk settings contain only the native
salted verifier. The test owns its child processes; cleanup stops only those
processes. Downloaded files are retained after the run.

## Resource limits

- Fixed selection: 1–4 complete torrents, at most 8 GiB total declared payload;
  no repeated deletion/redownload loop. Unexpected added transfers stop the run.
- One download slot; global limits of 1,000 kB/s down and 64 kB/s up.
- At 12 GiB downloaded or 4 GiB uploaded, pause test transfers and continue idle
  observation. These are daemon payload counters, not a hard network quota;
  protocol overhead is not included, and the watchdog can overshoot between checks.
- Require a 100 GiB free-space reserve plus selected payload before starting.
  Stop the test below the reserve or above 3 GiB combined test-process RSS.
  These guards are sampled every 10 seconds, not OS-enforced quotas.
- Process/RPC samples every 30 seconds, bounded to 32 MiB. Each child log retains
  at most three 8-MiB segments. Swift UI summaries overwrite a small atomic report.
- Harbor cycles every 300 seconds; normal download polling remains every two
  seconds. No sleep, reboot, network toggling or changes to other services.

## Profiling alongside another test

No Instruments or `leaks` recording starts automatically. For manually approved
short captures, `soak.py profile COMMAND ...` holds an exclusive nonblocking flock
on `~/Library/Application Support/Codex Test Coordination/instruments.lock`.
Keep capture and export inside the same wrapper command. Never unlink/replace
the lock file while recording. Other tools must opt into the same lock; the lock
does not serialize independently launched Xcode/Instruments sessions.

## Results and limits

Inspect `state.json`, `samples.jsonl`, `ui-report.json` and rotating logs. A safety
stop, early child exit or failed graceful cleanup is not a successful 48-hour run.
The UI report includes owner-release checks after teardown. Soak measurements
are not a proof that no leaks exist. Store reports privately; they can contain
transfer names and machine-specific information.
