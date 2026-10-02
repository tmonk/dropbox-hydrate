# Eviction and undo

Eviction removes local content and leaves legacy Smart Sync placeholders.
Evict fully synced files only. The tool cannot verify that Dropbox has uploaded
the latest changes. **No content backups are made.**

This uses a reverse-engineered Dropbox format. Undo depends on Dropbox still
having the same content and recognizing the placeholders; recovery is not
guaranteed. Keep files unchanged while eviction runs. Concurrent writes or a
crash can leave a partially evicted file.

## Preview

Specify an existing folder with `--sandbox`. All targets must be inside it.
Eviction defaults to a preview:

```console
./build/bin/dbhydrate evict --sandbox ~/Dropbox/project ~/Dropbox/project/files
```

Files without Dropbox metadata and existing placeholders are skipped. Symlinks,
hard links and special files are refused.

## Evict

Add `--yes` to remove local content:

```console
./build/bin/dbhydrate evict --sandbox ~/Dropbox/project --yes \
  --manifest /tmp/new-eviction.jsonl ~/Dropbox/project/files
```

The metadata journal records paths, sizes, hashes and Dropbox attributes before
each file changes. Its destination must be new and outside the sandbox.

Without `--manifest`, the journal is saved under
`~/Library/Application Support/dbhydrate/evictions` and its path is printed.
Keep the journal until undo succeeds.

## Undo

Use the same sandbox and the journal from eviction:

```console
./build/bin/dbhydrate evict --sandbox ~/Dropbox/project \
  --undo /tmp/new-eviction.jsonl
```

Undo downloads placeholders through Dropbox and checks their size and SHA-256
hash. Matching local files pass without a download. Changed local files are
preserved and reported as failures. Missing files, incomplete downloads and
hash mismatches also fail. Keep the journal and retry when Dropbox is available.

Add `--dry-run` to preview undo without requesting downloads. Run
`./build/bin/dbhydrate --help` for time limits and other options.
