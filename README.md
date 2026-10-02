# dropbox-hydrate (beta)

Download online-only files from legacy Dropbox Smart Sync on macOS without
opening windows.

Requires macOS 13+. No third-party dependencies.
Dropbox File Provider installations and files excluded by Selective Sync are
unsupported.

## Install

Grab the latest release, no build required:

```console
gh release download --repo tmonk/dropbox-hydrate --pattern dbhydrate
chmod +x dbhydrate
xattr -d com.apple.quarantine dbhydrate     # see "First launch" below
```

Then move `dbhydrate` anywhere on your `PATH`, such as `/usr/local/bin`, or
call it by path. Each release also ships a zipped `DBHydrate.app` bundle: unzip
it and open it from Finder, or install it in `/Applications`.

Releases are built per architecture (currently Apple silicon). Pick the asset
matching your Mac.

### First launch

These releases are ad-hoc signed, not notarized with an Apple Developer ID, so
macOS blocks the first launch of a downloaded file. Clear the quarantine
attribute once:

```console
xattr -d com.apple.quarantine dbhydrate
```

Or right-click the file (or `DBHydrate.app`) in Finder and choose **Open**.

Each release includes a `SHA256SUMS` file; check it if you want to verify the
download.

## Use

```console
dbhydrate --dry-run ~/Dropbox/some-project
dbhydrate ~/Dropbox/some-project
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

Run `dbhydrate --help` for all options.

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
