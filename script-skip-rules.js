/**
 * Decide whether a book page should produce a generated .sh script.
 * Rules live in lfs-script-skip-rules.json (explicit list + content heuristics).
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let cached = null;

function normalizeRelPath(relPath) {
  return relPath.replace(/\\/g, "/");
}

function compileRulePatterns(rule) {
  const list = rule.patterns || (rule.pattern ? [rule.pattern] : []);
  return list.map((p) => new RegExp(p, "im"));
}

function blockMatchesAll(block, patterns) {
  return patterns.every((re) => re.test(block));
}

function blockMatchesAny(block, patterns) {
  return patterns.some((re) => re.test(block));
}

function blocksMatchRule(rule, blocks) {
  const patterns = compileRulePatterns(rule);
  if (!patterns.length || !blocks.length) return false;

  const mode = rule.match || "anyBlock";
  if (mode === "allBlocks") {
    const combined = blocks.join("\n\n");
    return blockMatchesAll(combined, patterns);
  }
  if (mode === "anyBlock") {
    return blocks.some((b) => blockMatchesAny(b, patterns));
  }
  if (mode === "everyBlock") {
    return blocks.every((b) => blockMatchesAny(b, patterns));
  }
  return false;
}

export function loadScriptSkipRules(rulesPath) {
  if (cached && cached._path === rulesPath) return cached;

  const file =
    rulesPath ||
    process.env.LFS_SCRIPT_SKIP_RULES ||
    path.join(__dirname, "lfs-script-skip-rules.json");

  if (!fs.existsSync(file)) {
    cached = {
      _path: file,
      handlers: {},
      skipPages: [],
      skipPagePatterns: [],
      contentRules: [],
      runAsOverrides: [],
      bySource: new Map(),
      pathPatterns: [],
    };
    return cached;
  }

  const raw = JSON.parse(fs.readFileSync(file, "utf8"));
  const bySource = new Map();
  for (const entry of raw.skipPages || []) {
    if (!entry.source) continue;
    bySource.set(normalizeRelPath(entry.source), entry);
  }

  cached = {
    _path: file,
    handlers: raw.handlers || {},
    skipPages: raw.skipPages || [],
    skipPagePatterns: (raw.skipPagePatterns || []).map((e) => ({
      ...e,
      re: new RegExp(e.pattern, "i"),
    })),
    contentRules: raw.contentRules || [],
    runAsOverrides: (raw.runAsOverrides || []).map((e) => ({
      ...e,
      source: normalizeRelPath(e.source),
    })),
    bySource,
    pathPatterns: (raw.skipPagePatterns || []).map((e) => ({
      ...e,
      re: new RegExp(e.pattern, "i"),
    })),
  };
  return cached;
}

/**
 * @param {{ relPath: string, title?: string }} page
 * @param {string[]} blocks - command blocks after command-filters
 * @returns {{ skip: boolean, handler?: string, reason?: string, matchedRule?: string }}
 */
export function evaluateScriptSkip(page, blocks, rulesPath) {
  const rules = loadScriptSkipRules(rulesPath);
  const rel = normalizeRelPath(page.relPath);

  const explicit = rules.bySource.get(rel);
  if (explicit) {
    return {
      skip: true,
      handler: explicit.handler,
      reason: explicit.reason,
      matchedRule: "skipPages",
    };
  }

  for (const pat of rules.pathPatterns) {
    if (pat.re.test(rel)) {
      return {
        skip: true,
        handler: pat.handler,
        reason: pat.reason,
        matchedRule: `skipPagePatterns:${pat.pattern}`,
      };
    }
  }

  for (const rule of rules.contentRules) {
    if (blocks.length === 0) continue;
    if (rule.sourcePattern && !new RegExp(rule.sourcePattern, "i").test(rel)) {
      continue;
    }
    if (blocksMatchRule(rule, blocks)) {
      return {
        skip: true,
        handler: rule.handler,
        reason: rule.reason,
        matchedRule: `contentRules:${rule.id}`,
      };
    }
  }

  return { skip: false };
}

/**
 * @param {string} relPath
 * @param {string} [rulesPath]
 * @returns {{ runAs?: string, reason?: string } | null}
 */
export function runAsOverrideForPage(relPath, rulesPath) {
  const rules = loadScriptSkipRules(rulesPath);
  const rel = normalizeRelPath(relPath);
  const hit = rules.runAsOverrides.find((o) => o.source === rel);
  return hit || null;
}

export function skipRulesPathForManifest(repoRoot) {
  return path.join(repoRoot, "lfs-script-skip-rules.json");
}
