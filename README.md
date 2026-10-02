# dropbox-hydrate (beta)

Download online-only files from legacy Dropbox Smart Sync on macOS without
opening windows.

Requires macOS 13+ and the Xcode command line tools. No third-party dependencies.
Dropbox File Provider installations and files excluded by Selective Sync are
unsupported.

## Build and use

```console
./scripts/build.sh
./build/bin/dbhydrate --dry-run ~/Dropbox/some-project
./build/bin/dbhydrate ~/Dropbox/some-project
```

Pass one or more files or folders. Folders are scanned recursively; `--dry-run`
counts files needing download without requesting them.

| Option | Description |
| --- | --- |
| `-c, --concurrency N` | Active files, 1–64; default 8 |
| `-t, --ceiling SEC` | Total wait per file across retries; default 60 seconds |
| `--stall-grace SEC` | Stop after no observed download progress; default 30 seconds |
| `--stats PATH` | Create a new JSON report; refuses an existing file |
| `-v, --verbose` | Show each file's result |

Run `./build/bin/dbhydrate --help` for all options.

The default Dropbox folder is `~/Dropbox`. Set `DBHYDRATE_DROPBOX_ROOT` for a
different location. Symlinks and paths outside that folder are refused.

Download speed depends on Dropbox and the network. Slow downloads may need
longer time limits. Downloads already requested may continue after a timeout or
Ctrl-C.

## Eviction and undo

`evict` removes local content, leaving Smart Sync placeholders. Evict fully
synced files only: the tool cannot verify upload completion.
**No content backups are made.** Undo downloads from Dropbox and verifies the
result; recovery is not guaranteed.

Eviction defaults to a preview. Deleting content requires `--yes` and an explicit
`--sandbox` folder. Keep the metadata journal until undo succeeds. See the
[eviction and undo guide](docs/eviction.md) for commands and limits.

MIT licensed. See [LICENSE](LICENSE).
