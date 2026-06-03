#!/usr/bin/env node
/**
 * Extract user commands from the LFS HTML book and emit stage-organized bash scripts.
 * Book commands are MIT-licensed per https://www.linuxfromscratch.org/
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import * as cheerio from "cheerio";
import { filterCommandBlocks } from "./command-filters.js";
import {
  evaluateScriptSkip,
  runAsOverrideForPage,
  skipRulesPathForManifest,
} from "./script-skip-rules.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const BOOK_DIR = path.resolve(__dirname, process.env.LFS_BOOK_DIR || "13.0");
const OUTPUT_DIR = path.resolve(__dirname, process.env.LFS_SCRIPTS_DIR || "lfs-scripts");

/** LFS build stages aligned with chapter 2.3 (Building LFS in Stages). */
const STAGES = [
  {
    id: "stage-01-host-prep",
    name: "Host preparation (Chapters 2–4)",
    chapters: ["02", "03", "04"],
    runAs: "root",
    host: true,
    requiresLfsMount: false,
    checkpoint: false,
  },
  {
    id: "stage-02-cross-toolchain",
    name: "Cross toolchain (Chapter 5)",
    chapters: ["05"],
    runAs: "lfs",
    host: true,
    requiresLfsMount: true,
    requiresSources: true,
    checkpoint: true,
  },
  {
    id: "stage-03-temp-tools",
    name: "Temporary tools (Chapter 6)",
    chapters: ["06"],
    runAs: "lfs",
    host: true,
    requiresLfsMount: true,
    requiresSources: true,
    checkpoint: true,
  },
  {
    id: "stage-04-chroot",
    name: "Chroot and extra temp tools (Chapter 7)",
    chapters: ["07"],
    runAs: "mixed",
    host: true,
    requiresLfsMount: true,
    checkpoint: true,
  },
  {
    id: "stage-05-system-build",
    name: "Building the LFS system (Chapter 8)",
    chapters: ["08"],
    runAs: "chroot",
    host: false,
    requiresLfsMount: true,
    checkpoint: true,
  },
  {
    id: "stage-06-system-config",
    name: "System configuration (Chapters 9–10)",
    chapters: ["09", "10"],
    runAs: "chroot",
    host: false,
    requiresLfsMount: true,
    checkpoint: true,
  },
  {
    id: "stage-07-finish",
    name: "Reboot and after LFS (Chapter 11)",
    chapters: ["11"],
    runAs: "root",
    host: true,
    requiresLfsMount: false,
    checkpoint: true,
  },
];

const CHAPTER_ORDER = STAGES.flatMap((s) => s.chapters);

const CHROOT_ENTRY_PAGE = "chapter07/chroot.html";

const SCRIPT_SKIP_RULES_FILE = path.resolve(
  __dirname,
  process.env.LFS_SCRIPT_SKIP_RULES || "lfs-script-skip-rules.json"
);

/** Chapters whose package sections expect extract-in-sources first. */
const PACKAGE_CHAPTERS = new Set(["05", "06", "07", "08"]);

/** Split cleanup into in-chroot vs on-host sections (book §7.13.1 vs §7.13.2). */
const SPLIT_PAGES = new Map([
  [
    "chapter07/cleanup.html",
    {
      insideSlug: "07-cleanup-inside",
      insideTitle: "7.13.1 Cleaning (inside chroot)",
      hostSlug: "07-cleanup-host",
      hostTitle: "7.13.2 Backup (host root, outside chroot)",
      hostStart: /^exit$/m,
    },
  ],
]);

let tarballIndex = null;
let tarballExceptionBySource = null;
const chapterPageOrder = new Map();

const EXCEPTIONS_FILE = path.resolve(
  __dirname,
  process.env.LFS_PACKAGE_EXCEPTIONS || "package-tarball-exceptions.json"
);

/** @returns {Map<string, { tarball: string, extractDir?: string, comment?: string }>} */
function loadTarballExceptions() {
  if (tarballExceptionBySource) return tarballExceptionBySource;
  tarballExceptionBySource = new Map();
  if (!fs.existsSync(EXCEPTIONS_FILE)) {
    return tarballExceptionBySource;
  }
  const data = JSON.parse(fs.readFileSync(EXCEPTIONS_FILE, "utf8"));
  for (const entry of data.exceptions || []) {
    if (!entry.source || !entry.tarball) continue;
    const key = entry.source.replace(/\\/g, "/");
    tarballExceptionBySource.set(key, entry);
  }
  return tarballExceptionBySource;
}

function loadTarballs() {
  if (tarballIndex) return tarballIndex;
  tarballIndex = { byKey: new Map(), all: new Set() };
  for (const listName of ["wget-list-systemd", "wget-list"]) {
    const listPath = path.join(BOOK_DIR, listName);
    if (!fs.existsSync(listPath)) continue;
    for (const line of fs.readFileSync(listPath, "utf8").split("\n")) {
      const url = line.trim();
      if (!url.startsWith("http")) continue;
      const base = path.basename(url.split("?")[0]);
      if (base.endsWith(".patch")) continue;
      if (!/\.(tar\.(gz|xz|bz2)|tar\.gz|tar\.xz|tar\.bz2|tar)$/i.test(base)) {
        continue;
      }
      tarballIndex.all.add(base);
      const key = base.replace(/\.(tar\.(gz|xz|bz2)|tar)$/i, "").toLowerCase();
      tarballIndex.byKey.set(key, base);
    }
    break;
  }
  return tarballIndex;
}

function extractDirFromTarball(tarball) {
  return tarball.replace(/\.(tar\.(gz|xz|bz2)|tar)$/i, "");
}

function packageDirFromTitle(title) {
  const m = title.match(
    /(?:^|\s)([A-Za-z0-9][A-Za-z0-9+._-]*-\d[\w.+-]*)(?:\s|$|-)/
  );
  return m ? m[1] : null;
}

/**
 * Resolve which wget-list tarball to extract for a package page.
 * 1. package-tarball-exceptions.json (by source path)
 * 2. Parse heading (name-version) and look up in wget-list index
 */
function resolvePackageTarball(relPath, title, chapter) {
  if (!PACKAGE_CHAPTERS.has(chapter)) return null;

  const index = loadTarballs();
  const exceptions = loadTarballExceptions();
  const normalized = relPath.replace(/\\/g, "/");

  const override = exceptions.get(normalized);
  if (override) {
    const tarball = override.tarball;
    if (!index.all.has(tarball)) {
      console.warn(
        `Warning: exception ${normalized} references missing tarball: ${tarball}`
      );
      return null;
    }
    return {
      tarball,
      extractDir: override.extractDir || extractDirFromTarball(tarball),
      via: "exception",
    };
  }

  const pkgDir = packageDirFromTitle(title);
  if (!pkgDir) return null;

  const tarball = index.byKey.get(pkgDir.toLowerCase());
  if (!tarball) return null;

  return {
    tarball,
    extractDir: extractDirFromTarball(tarball),
    via: "title",
  };
}

function preambleForPackage(relPath, title, chapter) {
  const resolved = resolvePackageTarball(relPath, title, chapter);
  if (!resolved) return [];
  const { tarball, extractDir } = resolved;
  return [
    [
      'cd "${LFS_SOURCES:-$LFS/sources}"',
      `pkg=${JSON.stringify(tarball)}`,
      `dir=${JSON.stringify(extractDir)}`,
      'rm -rf "$dir"',
      'tar -xf "$pkg"',
      'cd "$dir"',
    ].join("\n"),
  ];
}

function stageForChapter(chapter) {
  return STAGES.find((s) => s.chapters.includes(chapter));
}

function slugify(name) {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 80);
}

function readChapterPages(chapter) {
  const chapterDir = path.join(BOOK_DIR, `chapter${chapter}`);
  const tocFile = path.join(chapterDir, `chapter${chapter}.html`);
  if (!fs.existsSync(tocFile)) {
    return [];
  }
  const html = fs.readFileSync(tocFile, "utf8");
  const $ = cheerio.load(html, { xml: false });
  const pages = [];
  $("div.toc a[href]").each((_, el) => {
    const href = $(el).attr("href");
    if (!href || href.startsWith("#") || href.includes("://")) return;
    const file = path.normalize(path.join(chapterDir, href));
    if (!file.startsWith(chapterDir)) return;
    pages.push({
      href,
      title: $(el).text().trim(),
      file,
      relPath: path.relative(BOOK_DIR, file).replace(/\\/g, "/"),
    });
  });
  chapterPageOrder.set(chapter, pages.map((p) => p.relPath));
  return pages;
}

function pageTitle(html) {
  const $ = cheerio.load(html, { xml: false });
  const h1 = $("h1.sect1, h1.chapter").first().text().replace(/\s+/g, " ").trim();
  if (h1) return h1;
  const title = $("title").text().replace(/\s+/g, " ").trim();
  return title || "untitled";
}

function extractCommands(html) {
  const $ = cheerio.load(html, { xml: false });
  const blocks = [];
  $("pre.userinput").each((_, pre) => {
    // Use full <pre> text: nested <kbd class="command"> (e.g. chown --from lfs)
    // breaks when only the outer kbd node is read (words run together after esac).
    const text = $(pre).text().replace(/\r\n/g, "\n").trim();
    if (text) blocks.push(text);
  });
  return blocks;
}

function splitBlocksAtHostBoundary(blocks, hostStartPattern) {
  for (let i = 0; i < blocks.length; i++) {
    if (hostStartPattern.test(blocks[i].trim())) {
      return [blocks.slice(0, i), blocks.slice(i + 1)];
    }
  }
  return [blocks, []];
}

function runAsForPage(relPath, stage, chapter, skipDecision) {
  if (skipDecision?.skip) return "skip";

  const override = runAsOverrideForPage(relPath, SCRIPT_SKIP_RULES_FILE);
  if (override?.runAs) return override.runAs;

  if (stage.id === "stage-04-chroot") {
    const order = chapterPageOrder.get(chapter) || [];
    const chrootIdx = order.indexOf(CHROOT_ENTRY_PAGE);
    const pageIdx = order.indexOf(relPath);
    if (chrootIdx < 0 || pageIdx < 0) return "root";
    if (pageIdx < chrootIdx) return "root";
    return "chroot";
  }

  const stageRunAs = stage.runAs === "host" ? "root" : stage.runAs;
  return stageRunAs;
}

function shellEscapeDouble(s) {
  return String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function installBuildLib() {
  const src = path.join(__dirname, "lfs-build-lib.sh");
  const dest = path.join(OUTPUT_DIR, "lfs-build-lib.sh");
  fs.copyFileSync(src, dest);
  fs.chmodSync(dest, 0o755);
}

/** Source lfs-build-lib.sh, skip if done, trap failures. */
function buildTrackingHeader(scriptRel, meta) {
  const pkg = meta.packageName || "";
  return [
    "# --- LFS build tracking ---",
    '_LFS_STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    '_LFS_SCRIPTS_ROOT="$(cd "$_LFS_STAGE_DIR/.." && pwd)"',
    'source "${LFS_SCRIPTS_DIR:-$_LFS_SCRIPTS_ROOT}/lfs-build-lib.sh"',
    "lfs_script_begin \\",
    `  "${shellEscapeDouble(scriptRel)}" \\`,
    `  "${shellEscapeDouble(meta.title)}" \\`,
    `  "${shellEscapeDouble(meta.source)}" \\`,
    `  "${shellEscapeDouble(meta.chapter)}" \\`,
    `  "${shellEscapeDouble(meta.stageId)}" \\`,
    `  "${shellEscapeDouble(meta.runAs)}" \\`,
    `  "${shellEscapeDouble(pkg)}"`,
    "",
  ].join("\n");
}

const BUILD_TRACKING_FOOTER = ["lfs_script_finish success", ""].join("\n");

function writeScriptBody(blocks, page) {
  const preamble = preambleForPackage(
    page.relPath,
    page.title,
    page.chapter
  );
  const allBlocks = [...preamble, ...blocks];
  const body = allBlocks
    .map((block, i) => {
      if (!block) return "";
      const comment =
        allBlocks.length > 1 ? `# --- command block ${i + 1} ---\n` : "";
      return `${comment}${block}`;
    })
    .filter(Boolean)
    .join("\n\n");
  return body ? `${body}\n\n${BUILD_TRACKING_FOOTER}` : BUILD_TRACKING_FOOTER;
}

function emitScript({ stage, page, blocks, index, runAs, titleOverride }) {
  const title = titleOverride || page.title;
  const pageWithTitle = { ...page, title };
  const resolved = resolvePackageTarball(
    page.relPath,
    title,
    page.chapter
  );
  const base = slugify(`${page.chapter}-${page.slug}`);
  const scriptName = `${String(index).padStart(4, "0")}-${base}.sh`;
  const stageDir = path.join(OUTPUT_DIR, stage.id);
  fs.mkdirSync(stageDir, { recursive: true });

  const headerLines = [
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    `# LFS ${path.basename(BOOK_DIR)} — ${title}`,
    `# Source: ${page.relPath}`,
    `# Stage: ${stage.id} (${stage.name})`,
    `# Session: ${runAs}`,
  ];
  if (resolved) {
    headerLines.push(
      `# Tarball: ${resolved.tarball} (${resolved.via})`,
      `# Extract dir: ${resolved.extractDir}`
    );
  }
  headerLines.push(
    "",
    "# Executed inside the build session assigned by build_lfs.py",
    ""
  );

  const scriptRel = path.relative(OUTPUT_DIR, path.join(stageDir, scriptName)).replace(/\\/g, "/");
  const packageName = resolved
    ? resolved.extractDir || resolved.tarball.replace(/\.tar.*$/i, "")
    : "";

  const header = [
    ...headerLines,
    buildTrackingHeader(scriptRel, {
      title,
      source: page.relPath,
      chapter: page.chapter,
      stageId: stage.id,
      runAs,
      packageName,
    }),
  ].join("\n");

  const body = writeScriptBody(blocks, pageWithTitle);
  const scriptPath = path.join(stageDir, scriptName);
  fs.writeFileSync(scriptPath, `${header}${body}\n`, { mode: 0o755 });

  return {
    stage: stage.id,
    script: path.relative(OUTPUT_DIR, scriptPath).replace(/\\/g, "/"),
    title,
    source: page.relPath,
    chapter: page.chapter,
    runAs,
    commandBlocks: blocks.length,
    tarball: resolved?.tarball ?? null,
    tarballVia: resolved?.via ?? null,
  };
}

/** Dirs under lfs-scripts that are session infrastructure, not per-book package scripts. */
const PRESERVE_OUTPUT_DIRS = new Set(["runners"]);

/**
 * Remove generated package scripts under lfs-scripts before a fresh run.
 * Prevents stale scripts when the book version or skip/filter rules change.
 * Set LFS_PRESERVE_BUILD_LOGS=1 to keep logs/ (completed-scripts, build-events.jsonl).
 */
function cleanOutput() {
  const preserveLogs = process.env.LFS_PRESERVE_BUILD_LOGS === "1";
  const removed = { stages: 0, scripts: 0, dirs: [], files: [] };

  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
    console.log(`Created output directory: ${OUTPUT_DIR}`);
    return;
  }

  for (const name of fs.readdirSync(OUTPUT_DIR)) {
    const p = path.join(OUTPUT_DIR, name);
    const stat = fs.statSync(p);

    if (stat.isDirectory()) {
      if (name.startsWith("stage-")) {
        const count = fs
          .readdirSync(p)
          .filter((f) => f.endsWith(".sh")).length;
        fs.rmSync(p, { recursive: true });
        removed.stages += 1;
        removed.scripts += count;
        continue;
      }
      if (PRESERVE_OUTPUT_DIRS.has(name)) {
        continue;
      }
      if (name === "sessions") {
        fs.rmSync(p, { recursive: true });
        removed.dirs.push(name);
        continue;
      }
      if (name === "logs" && !preserveLogs) {
        fs.rmSync(p, { recursive: true });
        removed.dirs.push(name);
        continue;
      }
      continue;
    }

    if (name === "manifest.json" || name.endsWith(".sh")) {
      fs.unlinkSync(p);
      removed.files.push(name);
    }
  }

  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  const parts = [];
  if (removed.stages) {
    parts.push(`${removed.scripts} script(s) in ${removed.stages} stage dir(s)`);
  }
  if (removed.dirs.length) {
    parts.push(removed.dirs.join(", "));
  }
  if (removed.files.length) {
    parts.push(removed.files.join(", "));
  }
  if (parts.length) {
    console.log(`Cleaned ${OUTPUT_DIR}: ${parts.join("; ")}`);
  } else {
    console.log(`Output directory ready (no prior generated scripts): ${OUTPUT_DIR}`);
  }
  if (preserveLogs) {
    console.log("Preserved logs/ (LFS_PRESERVE_BUILD_LOGS=1)");
  }
}

function populateSessionDir(session, entries) {
  const sessionDir = path.join(OUTPUT_DIR, "sessions", session);
  if (fs.existsSync(sessionDir)) {
    fs.rmSync(sessionDir, { recursive: true });
  }
  fs.mkdirSync(sessionDir, { recursive: true });

  for (const e of entries) {
    const src = path.join(OUTPUT_DIR, e.script);
    const name = path.basename(e.script);
    const dest = path.join(sessionDir, name);
    const target = path.relative(sessionDir, src);
    fs.symlinkSync(target, dest);
  }
  return sessionDir;
}

const RESOLVE_SCRIPTS_DIR = `RUNNER_DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$RUNNER_DIR/../manifest.json" ]]; then
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
elif [[ -n "\${LFS_SCRIPTS:-}" && -f "\${LFS_SCRIPTS}/manifest.json" ]]; then
  SCRIPTS_DIR="$LFS_SCRIPTS"
else
  SCRIPTS_DIR="$(cd "$RUNNER_DIR/.." && pwd)"
fi`;

const ITERATE_SESSION_SH = `#!/usr/bin/env bash
# Generic session iterator: run every *.sh in sessions/<name>/ in sorted order.
# Usage: iterate-session.sh <lfs|chroot>
set -euo pipefail

SESSION="\${1:?usage: iterate-session.sh <lfs|chroot>}"
${RESOLVE_SCRIPTS_DIR}

SESSION_DIR="$SCRIPTS_DIR/sessions/$SESSION"
LOG="\${LFS_BUILD_LOG:-$SCRIPTS_DIR/logs/build-\${SESSION}.log}"
mkdir -p "$(dirname "$LOG")"

if [[ ! -d "$SESSION_DIR" ]]; then
  echo "Session directory not found: $SESSION_DIR" >&2
  echo "Run: npm run extract" >&2
  exit 1
fi

shopt -s nullglob
mapfile -t scripts < <(find "$SESSION_DIR" -maxdepth 1 -name '*.sh' -print | sort)

if (("\${#scripts[@]}" == 0)); then
  echo "No scripts in $SESSION_DIR" >&2
  exit 1
fi

echo "Session: $SESSION (\${#scripts[@]} script(s))"
echo "Log: $LOG"

for script in "\${scripts[@]}"; do
  real="\${script}"
  if command -v readlink &>/dev/null; then
    real="$(readlink -f "$script" 2>/dev/null || echo "$script")"
  fi
  {
    echo ""
    echo "======== $(date -Iseconds 2>/dev/null || date) ========"
    echo "Running: $(basename "$script")"
    grep '^# ' "$real" 2>/dev/null | head -8 || true
  } | tee -a "$LOG"
  # shellcheck source=/dev/null
  source "$real"
done

echo "" | tee -a "$LOG"
echo "Session $SESSION finished successfully." | tee -a "$LOG"
`;

function generateRunners(manifest) {
  const runnersDir = path.join(OUTPUT_DIR, "runners");
  fs.mkdirSync(runnersDir, { recursive: true });

  const lfsEntries = manifest.scripts.filter((s) => s.runAs === "lfs" && s.script);
  const chrootEntries = manifest.scripts.filter(
    (s) => s.runAs === "chroot" && s.script
  );

  populateSessionDir("lfs", lfsEntries);
  populateSessionDir("chroot", chrootEntries);

  fs.writeFileSync(path.join(runnersDir, "iterate-session.sh"), ITERATE_SESSION_SH, {
    mode: 0o755,
  });

  for (const session of ["lfs", "chroot"]) {
    const thin = `#!/usr/bin/env bash\nset -euo pipefail\n${RESOLVE_SCRIPTS_DIR}\nexec "$RUNNER_DIR/iterate-session.sh" ${session}\n`;
    fs.writeFileSync(path.join(runnersDir, `iterate-${session}.sh`), thin, {
      mode: 0o755,
    });
  }

  const lfsUserEnv = `#!/usr/bin/env bash
# LFS book §4.4 — environment for the lfs build user (sourced by run-lfs-session.sh)
set +h
umask 022
LFS="\${LFS:-/mnt/lfs}"
LC_ALL=POSIX
LFS_TGT="\$(uname -m)-lfs-linux-gnu"
PATH=/usr/bin:/bin
if [[ ! -L /bin ]]; then PATH=/bin:\$PATH; fi
PATH="\$LFS/tools/bin:\$PATH"
CONFIG_SITE="\$LFS/usr/share/config.site"
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
export MAKEFLAGS="\${MAKEFLAGS:--j\$(nproc 2>/dev/null || echo 1)}"
export TESTSUITEFLAGS="\${TESTSUITEFLAGS:-\$MAKEFLAGS}"
export LFS_SOURCES="\${LFS_SOURCES:-\$LFS/sources}"
`;

  const runLfs = `#!/usr/bin/env bash
set -euo pipefail
# Run as root: su - lfs with book §4.4 env, then source every lfs script in one login shell.
${RESOLVE_SCRIPTS_DIR}

LFS="\${LFS:-/mnt/lfs}"
LFS_USER="\${LFS_USER:-lfs}"
ITERATOR="$RUNNER_DIR/iterate-session.sh"
LFS_ENV="$RUNNER_DIR/lfs-user-env.sh"
LFS_SESSION=lfs

if ! id -u "$LFS_USER" &>/dev/null; then
  echo "LFS user '$LFS_USER' does not exist. Complete Chapter 4 first." >&2
  exit 1
fi

export LFS
echo "Starting LFS user session (su - $LFS_USER) ..."
exec su - "$LFS_USER" -c "source $LFS_ENV && exec bash --login $ITERATOR $LFS_SESSION"
`;

  fs.writeFileSync(path.join(runnersDir, "lfs-user-env.sh"), lfsUserEnv, {
    mode: 0o755,
  });

  const runChroot = `#!/usr/bin/env bash
set -euo pipefail
# Run as root: chroot with book env, then source every chroot script in one login shell.
${RESOLVE_SCRIPTS_DIR}

LFS="\${LFS:-/mnt/lfs}"
ITERATOR="$RUNNER_DIR/iterate-session.sh"
CHROOT_SESSION=chroot
JOBS="\${MAKEFLAGS:--j$(nproc 2>/dev/null || echo 1)}"
JOBS="\${JOBS#-j}"

if [[ ! -d "$LFS/usr" ]]; then
  echo "Chroot target $LFS does not look like an LFS system tree." >&2
  exit 1
fi

export LFS
echo "Starting chroot session at $LFS ..."
chroot "$LFS" /usr/bin/env -i \\
    HOME=/root \\
    TERM="\${TERM:-linux}" \\
    PS1='(lfs chroot) \\u:\\w\\$ ' \\
    PATH=/usr/bin:/usr/sbin \\
    MAKEFLAGS="-j$JOBS" \\
    TESTSUITEFLAGS="-j$JOBS" \\
    LFS_SOURCES=/sources \\
    /bin/bash --login "$ITERATOR" "$CHROOT_SESSION"
`;

  fs.writeFileSync(path.join(runnersDir, "run-lfs-session.sh"), runLfs, {
    mode: 0o755,
  });
  fs.writeFileSync(path.join(runnersDir, "run-chroot-session.sh"), runChroot, {
    mode: 0o755,
  });

  fs.writeFileSync(
    path.join(runnersDir, "README.txt"),
    [
      "Session runners (generated by npm run extract)",
      "",
      "run-lfs-session.sh     — su - lfs (lfs-user-env.sh), runs iterate-session.sh lfs",
      "lfs-user-env.sh        — book §4.4 environment for cross-toolchain builds",
      "run-chroot-session.sh  — chroot, runs iterate-session.sh chroot",
      "iterate-session.sh     — generic for-loop over sessions/<name>/*.sh",
      "sessions/lfs/          — symlinks to package scripts (manifest order)",
      "sessions/chroot/       — symlinks to in-chroot package scripts",
      "",
      "build_lfs.py refreshes sessions/<name>/ on resume (pending only).",
      "",
    ].join("\n")
  );

  return runnersDir;
}

function main() {
  if (!fs.existsSync(BOOK_DIR)) {
    console.error(`Book directory not found: ${BOOK_DIR}`);
    process.exit(1);
  }

  cleanOutput();
  installBuildLib();

  const manifest = {
    bookVersion: path.basename(BOOK_DIR),
    bookDir: BOOK_DIR,
    generatedAt: new Date().toISOString(),
    commandFilters: path.join(__dirname, "lfs-command-filters.json"),
    scriptSkipRules: SCRIPT_SKIP_RULES_FILE,
    filterStats: { pagesFiltered: 0, blocksRemoved: 0 },
    skipStats: { explicit: 0, heuristic: 0 },
    stages: STAGES,
    scripts: [],
    sessions: {
      "host-root": "Run on host as root (spawned directly by build_lfs.py)",
      lfs: "Single su - lfs login session via run-lfs-session.sh",
      chroot: "Single chroot login session via run-chroot-session.sh",
      skip: "No script; handled by ./lfs prepare|download, session runners, or manual steps",
    },
  };

  let globalIndex = 0;

  for (const chapter of CHAPTER_ORDER) {
    const stage = stageForChapter(chapter);
    const pages = readChapterPages(chapter);
    for (const page of pages) {
      if (!fs.existsSync(page.file)) continue;

      const splitCfg = SPLIT_PAGES.get(page.relPath);
      const html = fs.readFileSync(page.file, "utf8");
      let blocks = extractCommands(html);
      if (blocks.length) {
        const filtered = filterCommandBlocks(blocks, page);
        if (filtered.removed > 0) {
          manifest.filterStats.pagesFiltered += 1;
          manifest.filterStats.blocksRemoved += filtered.removed;
        }
        blocks = filtered.blocks;
      }
      const title = pageTitle(html);
      const skipDecision = evaluateScriptSkip(
        { relPath: page.relPath, title },
        blocks,
        SCRIPT_SKIP_RULES_FILE
      );

      if (skipDecision.skip) {
        if (skipDecision.matchedRule === "skipPages") {
          manifest.skipStats.explicit += 1;
        } else {
          manifest.skipStats.heuristic += 1;
        }
        manifest.scripts.push({
          stage: stage.id,
          script: null,
          title,
          source: page.relPath,
          chapter,
          runAs: "skip",
          commandBlocks: blocks.length,
          skipHandler: skipDecision.handler ?? null,
          skipReason: skipDecision.reason ?? null,
          skipMatchedRule: skipDecision.matchedRule ?? null,
        });
        continue;
      }

      if (!blocks.length) continue;
      const slug = slugify(path.basename(page.href, ".html"));

      if (splitCfg) {
        const [insideBlocks, hostBlocks] = splitBlocksAtHostBoundary(
          blocks,
          splitCfg.hostStart
        );
        if (insideBlocks.length) {
          globalIndex += 1;
          manifest.scripts.push(
            emitScript({
              stage,
              page: { ...page, chapter, title, slug: splitCfg.insideSlug },
              blocks: insideBlocks,
              index: globalIndex,
              runAs: "chroot",
              titleOverride: splitCfg.insideTitle,
            })
          );
        }
        if (hostBlocks.length) {
          globalIndex += 1;
          manifest.scripts.push(
            emitScript({
              stage,
              page: { ...page, chapter, title, slug: splitCfg.hostSlug },
              blocks: hostBlocks,
              index: globalIndex,
              runAs: "root",
              titleOverride: splitCfg.hostTitle,
            })
          );
        }
        continue;
      }

      const runAs = runAsForPage(page.relPath, stage, chapter, skipDecision);
      if (runAs === "skip") continue;

      globalIndex += 1;
      manifest.scripts.push(
        emitScript({
          stage,
          page: { ...page, chapter, title, slug },
          blocks,
          index: globalIndex,
          runAs,
        })
      );
    }
  }

  fs.writeFileSync(
    path.join(OUTPUT_DIR, "manifest.json"),
    JSON.stringify(manifest, null, 2) + "\n"
  );

  const runnersDir = generateRunners(manifest);

  const byRunAs = {};
  for (const s of manifest.scripts) {
    byRunAs[s.runAs] = (byRunAs[s.runAs] || 0) + 1;
  }

  console.log(`Generated ${manifest.scripts.filter((s) => s.script).length} scripts in ${OUTPUT_DIR}`);
  if (manifest.filterStats.blocksRemoved) {
    console.log(
      `Command filters: ${manifest.filterStats.blocksRemoved} block(s) removed from ${manifest.filterStats.pagesFiltered} page(s)`
    );
  }
  const skipped = manifest.scripts.filter((s) => s.runAs === "skip");
  if (skipped.length) {
    console.log(
      `Script skip rules: ${skipped.length} page(s) omitted (${manifest.skipStats.explicit} explicit, ${manifest.skipStats.heuristic} heuristic)`
    );
    console.log(`  Rules file: ${SCRIPT_SKIP_RULES_FILE}`);
  }
  for (const [k, v] of Object.entries(byRunAs)) {
    console.log(`  ${k}: ${v}`);
  }
  console.log(`Session runners written to ${runnersDir}/`);

  const index = loadTarballs();
  const exceptions = loadTarballExceptions();
  let orphanExceptions = 0;
  for (const [src, ex] of exceptions) {
    if (!index.all.has(ex.tarball)) {
      console.warn(`Warning: exception tarball not in wget-list: ${src} -> ${ex.tarball}`);
      orphanExceptions += 1;
    }
  }
  const packageScripts = manifest.scripts.filter(
    (s) => s.script && PACKAGE_CHAPTERS.has(s.chapter)
  );
  const noTarball = packageScripts.filter((s) => !s.tarball);
  const looksLikePackage = (s) =>
    /\d+\.\d+/.test(s.title) &&
    !/cleaning|cleanup|stripping|ownership|kernel file systems|directories|symlinks|package management|backup/i.test(
      s.title
    );
  const missing = noTarball.filter(looksLikePackage);
  if (missing.length) {
    console.warn(
      `Warning: ${missing.length} package-like page(s) have no tarball preamble (add to package-tarball-exceptions.json if needed):`
    );
    for (const s of missing) {
      console.warn(`  - ${s.source} (${s.title})`);
    }
  }
  if (orphanExceptions === 0 && exceptions.size) {
    console.log(`Loaded ${exceptions.size} tarball exception(s) from ${EXCEPTIONS_FILE}`);
  }
}

main();
