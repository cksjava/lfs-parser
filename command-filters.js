/**
 * Filter LFS book commands unsuitable for unattended automated builds.
 * Rules live in lfs-command-filters.json (editable).
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let cachedRules = null;

export function loadCommandFilters(filtersPath) {
  if (cachedRules && cachedRules._path === filtersPath) return cachedRules;
  const file =
    filtersPath ||
    process.env.LFS_COMMAND_FILTERS ||
    path.join(__dirname, "lfs-command-filters.json");
  if (!fs.existsSync(file)) {
    cachedRules = {
      _path: file,
      dropLinePatterns: [],
      dropBlockPatterns: [],
      pageRules: {},
    };
    return cachedRules;
  }
  const raw = JSON.parse(fs.readFileSync(file, "utf8"));
  const doc = raw.documentation || {};
  cachedRules = {
    _path: file,
    dropLinePatterns: compilePatterns(raw.dropLinePatterns || []),
    dropBlockPatterns: compilePatterns(raw.dropBlockPatterns || []),
    documentation: {
      catalog: doc.catalog || [],
      dropLinePatterns: compilePatterns(doc.dropLinePatterns || []),
      dropBlockPatterns: compilePatterns(doc.dropBlockPatterns || []),
      stripFromConfigureLines: (doc.stripFromConfigureLines || []).map(
        (p) => new RegExp(p, "gim")
      ),
    },
    pageRules: Object.fromEntries(
      Object.entries(raw.pageRules || {}).map(([src, rule]) => [
        src.replace(/\\/g, "/"),
        {
          ...rule,
          dropBlocksMatching: compilePatterns(rule.dropBlocksMatching || []),
          dropLinePatterns: compilePatterns(rule.dropLinePatterns || []),
        },
      ])
    ),
    description: raw.description,
  };
  return cachedRules;
}

function compilePatterns(list) {
  return list.map((p) => new RegExp(p, "im"));
}

function normalizeRelPath(relPath) {
  return relPath.replace(/\\/g, "/");
}

function shouldDropLine(line, linePatterns) {
  const t = line.trim();
  if (!t || t.startsWith("#")) return false;
  return linePatterns.some((re) => re.test(t));
}

function filterBlockLines(block, linePatterns) {
  const lines = block.split("\n");
  const kept = lines.filter((ln) => !shouldDropLine(ln, linePatterns));
  const text = kept.join("\n").trim();
  return text || null;
}

function blockMatchesAny(block, patterns) {
  return patterns.some((re) => re.test(block));
}

function isConfigureLikeLine(line) {
  const t = line.trim();
  return (
    /^\.\/configure\b/.test(t) ||
    /\bconfigure\s+--/.test(t) ||
    /\bmeson\s+setup\b/.test(t) ||
    /\b-D\s+docdir=/.test(t) ||
    /--docdir=/.test(t)
  );
}

function stripDocPathsFromRmLine(line) {
  const t = line.trim();
  if (/^\/usr\/share\/doc\//.test(t)) return null;
  if (!/\brm\b/.test(line) || !/\/usr\/share\/doc\//.test(line)) {
    return line;
  }
  let out = line.replace(/\s*\\?\s*\/usr\/share\/doc\/\S+/g, "");
  out = out.replace(/\s+\\\s*$/g, "").trimEnd();
  return out.trim() ? out : null;
}

/** Remove trailing line-continuation backslashes when the next line was dropped. */
function cleanupLineContinuations(block) {
  const lines = block.split("\n");
  const kept = [];
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    const next = lines.slice(i + 1).find((l) => l.trim());
    const continues =
      next &&
      (/^\s+--/.test(next) ||
        /^\s+-D\s+/.test(next) ||
        /^\s+[A-Z][A-Z0-9_]*=/.test(next) ||
        /^\s+\S/.test(next));
    if (line.trimEnd().endsWith("\\") && !continues) {
      line = line.replace(/\s*\\\s*$/, "");
    }
    if (line.trim()) kept.push(line);
  }
  return kept.join("\n");
}

function sanitizeLineForDocumentation(line, docRules) {
  let out = line;
  if (docRules.stripFromConfigureLines?.length && isConfigureLikeLine(out)) {
    const before = out;
    for (const re of docRules.stripFromConfigureLines) {
      out = out.replace(re, "");
    }
    if (out !== before) {
      out = out.replace(/\s+\\\s*$/g, "").trimEnd();
    }
    if (!out.trim() || /^\\\s*$/.test(out.trim())) return null;
  }
  const rmSanitized = stripDocPathsFromRmLine(out);
  if (rmSanitized === null) return null;
  return rmSanitized;
}

function blockLooksDocumentationRelated(block) {
  return /\/usr\/share\/(?:doc|info)\b|makeinfo\b|install-info\b|install-html|\bmake html\b|\.info\.gz|-html\.tar|install_docs-1\.patch/i.test(
    block
  );
}

function applyDocumentationFilters(blocks, rules) {
  const doc = rules.documentation;
  if (!doc?.dropLinePatterns?.length && !doc?.dropBlockPatterns?.length) {
    return blocks;
  }

  const out = [];
  for (const block of blocks) {
    if (blockMatchesAny(block, doc.dropBlockPatterns)) continue;

    const lines = block.split("\n");
    const kept = [];
    const docBlock = blockLooksDocumentationRelated(block);
    for (const line of lines) {
      if (docBlock && shouldDropLine(line, doc.dropLinePatterns)) continue;
      const sanitized = sanitizeLineForDocumentation(line, doc);
      if (sanitized != null && sanitized.trim()) kept.push(sanitized);
    }

    let text = cleanupLineContinuations(kept.join("\n")).trim();
    if (text) out.push(text);
  }
  return out;
}

function applyGlibcLocaleRule(blocks, rule) {
  const insert =
    rule.replaceLocaledefBlock ||
    "make localedata/install-locales";
  const insertComment =
    "# Automated: install all locales (book alternative to individual localedef)\n";
  const result = [];
  let inserted = false;

  for (const block of blocks) {
    if (/^localedef\s/m.test(block)) continue;
    if (/^make localedata\/install-locales\s*$/im.test(block.trim())) continue;
    result.push(block);
    if (
      !inserted &&
      (/sed.*RTLDLIST/i.test(block) || /^make install$/im.test(block.trim()))
    ) {
      result.push(`${insertComment}${insert}`);
      inserted = true;
    }
  }

  if (!inserted) {
    const installIdx = result.findIndex((b) =>
      /^make install$/im.test(b.trim())
    );
    if (installIdx >= 0) {
      result.splice(installIdx + 1, 0, `${insertComment}${insert}`);
    } else {
      result.push(`${insertComment}${insert}`);
    }
  }

  return result;
}

function applyPageRules(blocks, relPath, rules) {
  const pageRule = rules.pageRules[normalizeRelPath(relPath)];
  if (!pageRule) return blocks;

  let out = [];
  const allDropBlock = [
    ...rules.dropBlockPatterns,
    ...(pageRule.dropBlocksMatching || []),
  ];
  const allDropLine = [
    ...rules.dropLinePatterns,
    ...(pageRule.dropLinePatterns || []),
  ];

  for (const block of blocks) {
    if (blockMatchesAny(block, allDropBlock)) continue;
    if (/^localedef\s/m.test(block)) continue;
    const filtered = filterBlockLines(block, allDropLine);
    if (filtered) out.push(filtered);
  }

  if (pageRule.replaceLocaledefBlock) {
    out = applyGlibcLocaleRule(out, pageRule);
  }

  return out;
}

function replaceInteractivePasswd(blocks) {
  return blocks.map((block) =>
    block
      .split("\n")
      .map((line) => {
        const t = line.trim();
        if (/^passwd\s+root\s*$/.test(t)) {
          return 'echo "root:${LFS_ROOT_PASSWORD:-lfs}" | chpasswd';
        }
        if (/^passwd\s+lfs\s*$/.test(t)) {
          return 'echo "${LFS_USER:-lfs}:${LFS_USER_PASSWORD:-lfs}" | chpasswd';
        }
        return line;
      })
      .join("\n")
  );
}

function dropSuToLfsSession(blocks) {
  return blocks
    .map((block) =>
      block
        .split("\n")
        .filter((line) => {
          const t = line.trim();
          if (/^su\s+-\s+lfs\s*$/.test(t)) return false;
          if (/^su\s+-\s+\$\{?LFS_USER\}?\s*$/.test(t)) return false;
          return true;
        })
        .join("\n")
    )
    .filter((b) => b.trim());
}

/** Use explicit path so commands work even if login profile alters PATH. */
function useFullCrossGccPath(blocks) {
  return blocks.map((block) =>
    block.replace(/\$LFS_TGT-gcc/g, "${LFS}/tools/bin/${LFS_TGT}-gcc")
  );
}

/** gcc-pass1 limits.h must target libgcc include/ (under $LFS/tools, not Ch 4.2 layout). */
function fixGccPass1LimitsHeader(blocks, relPath) {
  if (normalizeRelPath(relPath) !== "chapter05/gcc-pass1.html") return blocks;
  return blocks.map((block) => {
    if (!/print-libgcc-file-name/.test(block)) return block;
    return [
      "cd ..",
      'GCC_BIN="${LFS}/tools/bin/${LFS_TGT}-gcc"',
      'LIBGCC_INCLUDE="$(dirname "$("$GCC_BIN" -print-libgcc-file-name)")/include"',
      'mkdir -p "$LIBGCC_INCLUDE"',
      'cat gcc/limitx.h gcc/glimits.h gcc/limity.h > "$LIBGCC_INCLUDE/limits.h"',
    ].join("\n");
  });
}

/**
 * @param {{ relPath: string }} page
 * @param {string} [filtersPath]
 * @returns {{ blocks: string[], removed: number }}
 */
export function filterCommandBlocks(blocks, page, filtersPath) {
  const rules = loadCommandFilters(filtersPath);
  const relPath = normalizeRelPath(page.relPath);
  let removed = 0;
  const before = blocks.length;

  let working = [];
  for (const block of blocks) {
    if (blockMatchesAny(block, rules.dropBlockPatterns)) {
      removed += 1;
      continue;
    }
    const filtered = filterBlockLines(block, rules.dropLinePatterns);
    if (filtered) {
      working.push(filtered);
    } else if (block.trim()) {
      removed += 1;
    }
  }

  working = applyDocumentationFilters(working, rules);
  working = applyPageRules(working, relPath, rules);
  working = replaceInteractivePasswd(working);
  working = dropSuToLfsSession(working);
  working = useFullCrossGccPath(working);
  working = fixGccPass1LimitsHeader(working, relPath);

  const out = working.filter((b) => b.trim());
  return {
    blocks: out,
    removed: Math.max(0, before - out.length),
  };
}
