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
  const trimmed = block.trim();
  return patterns.some((re) => {
    const src = re.source;
    // Patterns with explicit newlines target multi-line blocks; keep multiline ^/$.
    if (/\\n|\\r/.test(src)) {
      return re.test(trimmed);
    }
    // ^...$ patterns match one whole block only (avoids dropping make install when
    // a later line is make install-html).
    if (/^\^/.test(src) && /\$$/.test(src)) {
      const flags = re.flags.replace(/m/g, "");
      const full = new RegExp(`^(?:${src})$`, flags);
      return full.test(trimmed);
    }
    // Other patterns may appear anywhere in a block (e.g. su tester … make check).
    return re.test(trimmed);
  });
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
    if (!line.trim()) continue;

    let j = i + 1;
    while (j < lines.length && !lines[j].trim()) j++;
    const next = j < lines.length ? lines[j] : null;
    const trimmed = line.trim().replace(/\s*\\\s*$/, "");

    // e.g. tar: FORCE_UNSAFE_CONFIGURE=1 \ then ./configure — prefix form exports to configure.
    if (
      next &&
      /^[A-Za-z_][A-Za-z0-9_]*=\S+/.test(trimmed) &&
      /^\.\/configure\b/.test(next.trim())
    ) {
      kept.push(`${trimmed} ${next.trim()}`);
      i = j;
      continue;
    }

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

/** Replace interactive menuconfig with automated kernel configuration. */
function kernelConfigBlock() {
  return `# Automated: localyesconfig when host config is visible; else defconfig (typical in chroot).
if ! make localyesconfig; then
  make defconfig
fi
make olddefconfig`;
}

function applyKernelHostConfigRule(blocks) {
  const insert = kernelConfigBlock();
  const result = [];
  let inserted = false;

  for (const block of blocks) {
    if (/^make\s+menuconfig\s*$/im.test(block.trim())) continue;
    result.push(block);
    if (!inserted && /^make\s+mrproper\s*$/im.test(block.trim())) {
      result.push(insert);
      inserted = true;
    }
  }

  if (!inserted) {
    const mrIdx = result.findIndex((b) => /^make\s+mrproper\s*$/im.test(b.trim()));
    if (mrIdx >= 0) {
      result.splice(mrIdx + 1, 0, insert);
    } else {
      result.unshift(kernelConfigBlock());
    }
  }

  return result.map((block) => {
    if (/^mount\s+\/boot\s*$/im.test(block.trim())) {
      return `# Mount /boot only when fstab defines a separate boot partition.
if grep -q '[[:space:]]/boot[[:space:]]' /etc/fstab 2>/dev/null && ! mountpoint -q /boot 2>/dev/null; then
  mount /boot
fi`;
    }
    return block;
  });
}

/** Parameterize GRUB install and grub.cfg; drop optional rescue-ISO steps. */
function grubInstallBlock() {
  return `# Automated: GRUB target from build_lfs.py (GPT+ESP/UEFI → x86_64-efi; else i386-pc).
if [[ "\${LFS_GRUB_MODE:-bios}" == efi ]]; then
  mkdir -pv /boot/efi
  if ! mountpoint -q /boot/efi 2>/dev/null; then
    mount -t vfat "\${LFS_ESP_PARTITION:?LFS_ESP_PARTITION must be set for UEFI GRUB}" /boot/efi
  fi
  if ! grep -q '[[:space:]]/boot/efi[[:space:]]' /etc/fstab 2>/dev/null; then
    echo "\${LFS_ESP_PARTITION} /boot/efi vfat defaults,umask=0077 0 0" >> /etc/fstab
  fi
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot
else
  grub-install --target=i386-pc "\${LFS_GRUB_INSTALL_DEVICE:-/dev/sdb}"
fi`;
}

function applyGrubBuildPlatformsRule(blocks) {
  return blocks.map((block) => {
    if (!/^\.\/configure\b/m.test(block.trim())) return block;
    if (/--with-platform=/.test(block)) return block;
    return block.replace(
      /--disable-werror\s*$/,
      "--disable-werror \\\n            --with-platform=i386-pc,x86_64-efi"
    );
  });
}

function applyGrubBuildConfigRule(blocks) {
  return blocks
    .filter((block) => !/grub-mkrescue|xorriso\s+-as\s+cdrecord/.test(block))
    .flatMap((block) => {
      if (/^grub-install\b/m.test(block.trim())) {
        return [grubInstallBlock()];
      }
      let b = block;
      b = b.replace(/set root=\(hd\d+,\d+\)/, "set root=${LFS_GRUB_SET_ROOT:-(hd1,2)}");
      b = b.replace(
        /root=\/dev\/\S+(\s+ro)/,
        "root=${LFS_PARTITION:-/dev/sdb2}$1"
      );
      if (/\/boot\/grub\/grub\.cfg/.test(b)) {
        b = b.replace(/<<\s*"EOF"/, "<< EOF");
      }
      return [b];
    });
}

/** Replace book network templates with host-probed systemd-networkd config. */
function applyNetworkConfigRule() {
  return [
    `# Automated: systemd-networkd from build host probe (build_lfs.py probe_host_network).
# systemd-resolved manages /etc/resolv.conf on boot — no static resolv.conf here.
mkdir -p /etc/systemd/network

if [[ "\${LFS_NETWORK_MODE:-dhcp}" == static && -n "\${LFS_NETWORK_ADDRESS:-}" ]]; then
  cat > /etc/systemd/network/80-lfs.network << EOF
[Match]
\${LFS_NETWORK_MATCH:-Name=en* eth*}

[Network]
Address=\${LFS_NETWORK_ADDRESS}
Gateway=\${LFS_NETWORK_GATEWAY}
DNS=\${LFS_NETWORK_DNS:-8.8.8.8}
\${LFS_NETWORK_DNS2:+DNS=\${LFS_NETWORK_DNS2}}
\${LFS_NETWORK_DOMAIN:+Domains=\${LFS_NETWORK_DOMAIN}}
EOF
else
  cat > /etc/systemd/network/80-lfs.network << EOF
[Match]
\${LFS_NETWORK_MATCH:-Name=en* eth* wl*}

[Network]
DHCP=ipv4

[DHCPv4]
UseDomains=true
EOF
fi

echo "\${LFS_HOSTNAME:-lfs}" > /etc/hostname

cat > /etc/hosts << EOF
# Begin /etc/hosts
127.0.0.1 localhost
127.0.1.1 \${LFS_HOSTNAME:-lfs}.localdomain \${LFS_HOSTNAME:-lfs}
::1       ip6-localhost ip6-loopback
ff02::1   ip6-allnodes
ff02::2   ip6-allrouters
# End /etc/hosts
EOF`,
  ];
}

/** §9.4 udev symlink examples are device-specific; skip in automated builds. */
function applySymlinksConfigRule() {
  return [
    "# §9.4 device-specific udev symlinks skipped (add /etc/udev/rules.d/*.rules manually if needed).",
  ];
}

/** §9.5 clock/timezone without timedatectl (does not work in chroot). */
function applyClockConfigRule() {
  return [
    `# Automated: clock/timezone from build_lfs.py (timedatectl does not work in chroot).
cat > /etc/adjtime << 'EOF'
0.0 0 0.0
0
EOF
if [[ "\${LFS_HWCLOCK_LOCAL:-0}" == 1 ]]; then
  echo LOCAL >> /etc/adjtime
fi
ln -sfv /usr/share/zoneinfo/\${LFS_TIMEZONE:-UTC} /etc/localtime`,
  ];
}

/** §9.6 console keymap and font from build prompts. */
function applyConsoleConfigRule() {
  return [
    `# Automated: console keymap/font from build_lfs.py prompts.
cat > /etc/vconsole.conf << EOF
KEYMAP=\${LFS_KEYMAP:-us}
FONT=\${LFS_CONSOLE_FONT:-LatArC-16}
EOF`,
  ];
}

/** §9.7 locale.conf and /etc/profile; skip book diagnostics and localectl. */
function applyLocaleConfigRule() {
  return [
    `cat > /etc/locale.conf << EOF
LANG=\${LFS_LOCALE:-en_US.UTF-8}
EOF`,
    `cat > /etc/profile << 'EOF'
# Begin /etc/profile

for i in $(locale); do
  unset \${i%=*}
done

if [[ "$TERM" = linux ]]; then
  export LANG=C.UTF-8
else
  source /etc/locale.conf

  for i in $(locale); do
    key=\${i%=*}
    if [[ -v $key ]]; then
      export $key
    fi
  done
fi

# End /etc/profile
EOF`,
  ];
}

/** §9.10 useful systemd tweaks only (no book examples or risky tmp.mount disable). */
function applySystemdCustomConfigRule() {
  return [
    `mkdir -pv /etc/systemd/system/getty@tty1.service.d

cat > /etc/systemd/system/getty@tty1.service.d/noclear.conf << EOF
[Service]
TTYVTDisallocate=no
EOF`,
    `mkdir -p /etc/tmpfiles.d
cp /usr/lib/tmpfiles.d/tmp.conf /etc/tmpfiles.d`,
  ];
}

/** §11.1 release identity files from build_lfs.py (not book placeholders). */
function applyLfsReleaseConfigRule() {
  return [
    `echo "\${LFS_RELEASE_VERSION:-13.0-systemd}" > /etc/lfs-release`,
    `cat > /etc/lsb-release << EOF
DISTRIB_ID="Linux From Scratch"
DISTRIB_RELEASE="\${LFS_RELEASE_VERSION:-13.0-systemd}"
DISTRIB_CODENAME="\${LFS_RELEASE_CODENAME:-lfs}"
DISTRIB_DESCRIPTION="Linux From Scratch"
EOF`,
    `cat > /etc/os-release << EOF
NAME="Linux From Scratch"
VERSION="\${LFS_RELEASE_VERSION:-13.0-systemd}"
ID=lfs
PRETTY_NAME="Linux From Scratch \${LFS_RELEASE_VERSION:-13.0-systemd}"
VERSION_CODENAME="\${LFS_RELEASE_CODENAME:-lfs}"
HOME_URL="https://www.linuxfromscratch.org/lfs/"
RELEASE_TYPE="stable"
EOF`,
  ];
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

  if (pageRule.useHostKernelConfig) {
    out = applyKernelHostConfigRule(out);
  }

  if (pageRule.useGrubBuildConfig) {
    out = applyGrubBuildConfigRule(out);
  }

  if (pageRule.useGrubBuildPlatforms) {
    out = applyGrubBuildPlatformsRule(out);
  }

  if (pageRule.useHostNetworkConfig) {
    out = applyNetworkConfigRule();
  }

  if (pageRule.useHostSymlinksConfig) {
    out = applySymlinksConfigRule();
  }

  if (pageRule.useHostClockConfig) {
    out = applyClockConfigRule();
  }

  if (pageRule.useHostConsoleConfig) {
    out = applyConsoleConfigRule();
  }

  if (pageRule.useHostLocaleConfig) {
    out = applyLocaleConfigRule();
  }

  if (pageRule.useHostSystemdCustomConfig) {
    out = applySystemdCustomConfigRule();
  }

  if (pageRule.useLfsReleaseConfig) {
    out = applyLfsReleaseConfigRule();
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
  working = working
    .map((b) => cleanupLineContinuations(b).trim())
    .filter(Boolean);

  const out = working.filter((b) => b.trim());
  return {
    blocks: out,
    removed: Math.max(0, before - out.length),
  };
}
