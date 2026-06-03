# LFS Book Parser

Parses the [Linux From Scratch](https://www.linuxfromscratch.org/) book (13.0-systemd, March 2026), extracts install commands into staged bash scripts, and provides a Python driver to run them in book order on a Linux host.

## Contents

| Path | Description |
|------|-------------|
| `13.0/` | Extracted LFS 13.0-systemd HTML book |
| `lfs` | Driver: `prepare`, `download`, `build` |
| `prepare-host.sh` | Debian/Ubuntu host prep + version check |
| `version-check.sh` | LFS §2.2 host tool versions (from the book) |
| `download-sources.sh` | `lfs-packages-13.0.tar` via axel |
| `extract-commands.js` | Node extractor (MIT book commands → bash) |
| `lfs-command-filters.json` | Patterns and per-page rules to strip test suites and other non-automated steps |
| `lfs-script-skip-rules.json` | Pages/heuristics that must not become `.sh` scripts (see below) |
| `command-filters.js` | Filter engine used by the extractor |
| `script-skip-rules.js` | Skip-rule engine used by the extractor |
| `package-tarball-exceptions.json` | Manual tarball overrides when headings ≠ wget-list names |
| `lfs-scripts/` | Generated scripts + `manifest.json` + `runners/` (after `npm run extract`) |
| `build_lfs.py` | Interactive build orchestrator |

## Quick start

```bash
# Already done in this repo: book downloaded and extracted to 13.0/

npm install
npm run extract
chmod +x lfs prepare-host.sh download-sources.sh version-check.sh

# On Debian/Ubuntu (LFS Chapter 2 host requirements):
sudo ./lfs prepare    # apt packages, /bin/sh -> bash, version-check.sh
./lfs download        # lfs-packages-13.0.tar -> ~/sources (no LFS mount required)
sudo ./lfs build      # build orchestrator (root); syncs ~/sources -> \$LFS/sources when mounted
```

### Three-step workflow

| Command | Script | Purpose |
|---------|--------|---------|
| `./lfs prepare` | `prepare-host.sh` | Debian/Ubuntu build deps, book symlinks (`/bin/sh` → bash, `awk` → gawk, `yacc` → bison), install **axel**, run **`version-check.sh`** |
| `./lfs download` | `download-sources.sh` | Download **`lfs-packages-13.0.tar`**, extract and verify in **`~/sources`** (`LFS_HOST_SOURCES`); copy to **`$LFS/sources`** only when `$LFS` is mounted (or `./lfs download --sync-only`) |
| `./lfs build` | `build_lfs.py` | Run generated package scripts in manifest order |

`version-check.sh` is the script from LFS 13.0-systemd §2.2; `prepare` runs it automatically and fails if the host is unsuitable.

Package tarball (stable book, single archive): **`lfs-packages-13.0.tar`** — see [LFS file mirrors](https://www.linuxfromscratch.org/mirrors.html#files). Default URL: `https://ftp.ludd.ltu.se/mirrors/lfs/lfs-packages/lfs-packages-13.0.tar` (override with `LFS_PACKAGES_URL`).

## Stages

Scripts are grouped to match the book’s build stages (Chapter 2.3):

1. **stage-01-host-prep** — Chapters 2–4 (host, partition, `lfs` user, environment)
2. **stage-02-cross-toolchain** — Chapter 5 (`lfs` user, `$LFS/sources`)
3. **stage-03-temp-tools** — Chapter 6
4. **stage-04-chroot** — Chapter 7 (root until chroot, then chroot)
5. **stage-05-system-build** — Chapter 8 (inside chroot)
6. **stage-06-system-config** — Chapters 9–10
7. **stage-07-finish** — Chapter 11 (reboot / after LFS)

## Build orchestrator

**Must be run as root** on a Linux host meeting LFS Chapter 2 requirements.

`build_lfs.py` prompts for mount point, partition, hostname, timezone, locale, and related options. It saves `lfs-build-config.json` and `lfs-build-state.json` for resume.

### Execution model

| Context | How it runs |
|--------|-------------|
| **Host root** | Python spawns `bash` for each script (Ch 2–4 host prep, Ch 7 ownership/kernfs, optional backup, Ch 11) |
| **LFS user** | One `run-lfs-session.sh` does `su - lfs` and runs `iterate-lfs.sh`, which **sources** each package script in order (Ch 4.4 + 5 + 6) in a single login shell |
| **Chroot** | One `run-chroot-session.sh` enters chroot with the book’s clean env and runs `iterate-chroot.sh`, which sources each in-chroot script (Ch 7 after entry, then Ch 8–10 after re-entry) |

Chapter 7.4 (interactive `chroot … bash --login`) is not a package script; `run-chroot-session.sh` replaces it. Section 7.13 is split into in-chroot cleaning and host-side backup scripts.

Before **each chroot session**, `build_lfs.py` runs `ensure_kernfs_mounted()` (reuses `stage-04-chroot/0026-07-kernfs.sh` if `/proc` is not already mounted). That remounts virtual filesystems after `cleanup-host` umounts them between the Chapter 7 and Chapter 8 chroot blocks.

**Skipped book pages** (no `.sh` generated; see **`lfs-script-skip-rules.json`** and `script-skip-rules.js`):

The extractor **never emits** a script when a page matches:

1. **`skipPages`** — explicit `chapterNN/page.html` entries (stable across book point releases; extend when new sections are added).
2. **`skipPagePatterns`** — regex on the HTML path (e.g. any `chapter07/chroot.html`).
3. **`contentRules`** — heuristics on filtered command blocks (placeholders `/dev/<xxx>`, `version-check.sh`, bulk `wget-list`, chroot login, host `umount`, pkgmgt tutorials, lfs `.bashrc`, etc.).

Skipped pages are still listed in `manifest.json` with `runAs: "skip"`, plus `skipHandler`, `skipReason`, and `skipMatchedRule`. Re-run `npm run extract` after editing the JSON.

| Page | Handler |
|------|---------|
| Ch 2.2 hostreqs | `tool-prepare` |
| Ch 2.5–2.7 mkfs/mount | `manual-disk` (also matched by placeholder heuristic) |
| Ch 2.6 `$LFS` / umask | `orchestrator-env` |
| Ch 3.1 introduction | `tool-download` |
| Ch 4.4 settingenvironment | `session-lfs-environment` |
| Ch 7.4 chroot | `session-chroot-entry` |
| Ch 8.2 pkgmgt | `documentation-only` |
| Ch 10.2 fstab | `manual-disk` |
| Ch 11.3 reboot | `manual-reboot` |

After `npm run extract`:

- `lfs-scripts/sessions/lfs/` and `sessions/chroot/` — ordered symlinks to package scripts
- `lfs-scripts/runners/iterate-session.sh` — generic loop: `for script in sessions/<name>/*.sh`
- `run-lfs-session.sh` / `run-chroot-session.sh` — enter the session and call the iterator

Each package script’s `#` header lines (title, source, stage) are printed and appended to `logs/build-<session>.log` before it runs.

## Per-script build log and resume

`lfs-build-lib.sh` is copied into `lfs-scripts/` and sourced by every package script. At the top of each script:

- **`lfs_script_begin`** — logs a `start` event; if the script id is already in `logs/completed-scripts`, logs `skip` and **exits 0** (no rebuild).
- **`lfs_log`** — append arbitrary events to `logs/build-events.jsonl` (JSON lines: script, title, source, chapter, stage, session, package, timestamps, duration, status).
- **`lfs_script_finish`** — logs `end` with duration; on success, appends the script id to `logs/completed-scripts`.

Set `LFS_FORCE_RERUN=1` to ignore the skip check. `build_lfs.py` reads the same `completed-scripts` file when resuming.

**Note:** macOS can extract scripts but cannot run a build.

## Package tarballs in scripts

For chapters 5–8, each package script starts with `cd $LFS/sources`, extract, and `cd` into the build tree (per the book’s general instructions).

Resolution order:

1. **`package-tarball-exceptions.json`** — `source` (book HTML path) → `tarball` filename from `wget-list-systemd`
2. **Heading parse** — `Name-x.y` from the section title, matched against the wget-list index

Non-package pages (ownership, kernfs, cleanup, etc.) get no extract preamble. After `npm run extract`, warnings list package-like pages that still need an exception entry.

```json
{
  "exceptions": [
    {
      "source": "chapter08/tcl.html",
      "tarball": "tcl8.6.17-src.tar.gz",
      "comment": "optional note"
    }
  ]
}
```

Override path: `LFS_PACKAGE_EXCEPTIONS=/path/to/exceptions.json`

## Command filters (automated builds)

The book often says to run test suites before `make install`. For unattended builds, `extract-commands.js` applies **`lfs-command-filters.json`** after parsing each page:

- **Global** — drops lines/blocks matching `make check`, `make test`, `su tester … make check`, expect/spawn test drivers, GMP log/awk checks, OpenSSL `HARNESS_JOBS`, Perl `test_harness`, and similar patterns from Chapter 8 (and any other chapter where they appear).
- **glibc** — removes `make check`, per-locale `localedef` lines, and interactive timezone helpers; inserts **`make localedata/install-locales`** once (book’s “install all locales” alternative).
- **bash** — removes tester/expect blocks and **`exec /usr/bin/bash --login`** (would break a non-interactive session driver).
- **gcc / coreutils** — removes multi-step tester/dummy-group test blocks.

Edit the JSON to add regexes or page-specific rules, then run `npm run extract`. `manifest.json` records `filterStats` (pages/blocks affected).

### Documentation filters

The `documentation` section in **`lfs-command-filters.json`** lists optional doc install steps found in the book (`documentation.catalog` maps each pattern to HTML pages). The extractor drops:

- Extra HTML/info installs (`make install-html`, `makeinfo`, `install`/`cp` into `/usr/share/doc` or `/usr/share/info`, optional HTML tarballs for Tcl/Python, kernel `Documentation/`, etc.)
- The bzip2 `install_docs` patch (docs via `make install` are not enabled)
- Rebuild of `/usr/share/info/dir` (Texinfo optional block)

`--docdir=` and `-D docdir=` are **stripped from configure/meson lines** (not removed wholesale). `make install` may still install some package docs; only explicit book steps are skipped.

## Regenerating scripts

Each `npm run extract` **wipes generated package scripts** under `lfs-scripts/` first (`stage-*/*.sh`, `manifest.json`, `sessions/`, and `logs/`) so a new book version cannot leave stale scripts. The **`runners/`** tree (iterate/session wrappers) is kept and refreshed in place. To keep build resume logs across re-extracts on the same book:

```bash
LFS_PRESERVE_BUILD_LOGS=1 npm run extract
```

```bash
LFS_BOOK_DIR=13.0 LFS_SCRIPTS_DIR=lfs-scripts npm run extract
```

## License

Book command extraction is permitted under the LFS book’s MIT license for instructions. See `13.0/appendices/mit.html`.
