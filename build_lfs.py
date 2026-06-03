#!/usr/bin/env python3
"""
Orchestrate an LFS build by running book-derived bash scripts in manifest order.

Execution model (must run as root):
  - host-root scripts: spawned directly by Python (one process per script)
  - lfs scripts: one "su - lfs" session running an iterator over all lfs scripts
  - chroot scripts: one chroot login session running an iterator over all chroot scripts
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
DEFAULT_MANIFEST = ROOT / "lfs-scripts" / "manifest.json"
STATE_FILE = ROOT / "lfs-build-state.json"
CONFIG_FILE = ROOT / "lfs-build-config.json"
RUNNERS_DIR_NAME = "runners"
COMPLETED_SCRIPTS_NAME = Path("logs") / "completed-scripts"
EVENTS_LOG_NAME = Path("logs") / "build-events.jsonl"
KERNFS_SCRIPT_REL = "stage-04-chroot/0026-07-kernfs.sh"


@dataclass
class BuildConfig:
    lfs_mount: str = "/mnt/lfs"
    lfs_partition: str = ""
    swap_partition: str = ""
    filesystem_type: str = "ext4"
    hostname: str = "lfs"
    timezone: str = "UTC"
    locale: str = "en_US.UTF-8"
    keymap: str = "us"
    console_font: str = "LatArC-16"
    run_package_tests: bool = False
    download_packages: bool = False
    sources_dir: str = ""
    book_dir: str = ""
    scripts_dir: str = ""
    lfs_user: str = "lfs"
    lfs_group: str = "lfs"
    jobs: str = ""
    confirm_each_script: bool = False
    dry_run: bool = False

    def resolved_sources(self) -> Path:
        if self.sources_dir:
            return Path(self.sources_dir)
        return Path(self.lfs_mount) / "sources"

    def resolved_book(self) -> Path:
        if self.book_dir:
            return Path(self.book_dir)
        return ROOT / "13.0"

    def resolved_scripts(self) -> Path:
        if self.scripts_dir:
            return Path(self.scripts_dir)
        return ROOT / "lfs-scripts"


def prompt(text: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{text}{suffix}: ").strip()
    return value if value else default


def prompt_bool(text: str, default: bool = False) -> bool:
    default_s = "Y/n" if default else "y/N"
    value = input(f"{text} ({default_s}): ").strip().lower()
    if not value:
        return default
    return value in ("y", "yes", "true", "1")


def collect_preferences() -> BuildConfig:
    print("\n=== Linux From Scratch Build Configuration ===\n")
    print("LFS must be built on a suitable Linux host (see LFS Chapter 2).")
    print("Run ./lfs prepare and ./lfs download before ./lfs build.")
    print("This orchestrator must be run as root.\n")

    cfg = BuildConfig()
    cfg.lfs_mount = prompt("LFS mount point", cfg.lfs_mount)
    cfg.lfs_partition = prompt("LFS partition device (e.g. /dev/sdb2)", cfg.lfs_partition)
    cfg.swap_partition = prompt("Swap partition (optional, leave empty to skip)", "")
    cfg.filesystem_type = prompt("Filesystem type for LFS partition", cfg.filesystem_type)
    cfg.hostname = prompt("Target hostname", cfg.hostname)
    cfg.timezone = prompt("Timezone (e.g. UTC or America/New_York)", cfg.timezone)
    cfg.locale = prompt("Locale", cfg.locale)
    cfg.keymap = prompt("Console keymap", cfg.keymap)
    cfg.console_font = prompt("Console font", cfg.console_font)
    cfg.lfs_user = prompt("LFS build user", cfg.lfs_user)
    cfg.lfs_group = prompt("LFS build group", cfg.lfs_group)
    cfg.jobs = prompt("Make parallel jobs (empty = nproc)", cfg.jobs)
    cfg.run_package_tests = prompt_bool("Run package test suites when present?", False)
    cfg.download_packages = prompt_bool(
        "Download packages via wget-list now? (normally use ./lfs download first)",
        False,
    )
    cfg.sources_dir = prompt(
        "Sources on LFS disk (empty = $LFS/sources; host staging is ~/sources)",
        "",
    )
    cfg.confirm_each_script = prompt_bool("Confirm before each script?", False)
    cfg.dry_run = prompt_bool("Dry run (print commands only)?", False)

    return cfg


def save_config(cfg: BuildConfig) -> None:
    data = {k: getattr(cfg, k) for k in cfg.__dataclass_fields__}
    CONFIG_FILE.write_text(json.dumps(data, indent=2) + "\n")


def load_config() -> BuildConfig | None:
    if not CONFIG_FILE.exists():
        return None
    data = json.loads(CONFIG_FILE.read_text())
    return BuildConfig(**{k: data.get(k, getattr(BuildConfig(), k)) for k in BuildConfig.__dataclass_fields__})


def load_state() -> dict[str, Any]:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {"completed": [], "lastError": None, "startedAt": None, "finishedAt": None}


def load_completed_set(state: dict[str, Any], scripts_root: Path) -> set[str]:
    """Merge Python state with lfs-build-lib.sh completed-scripts file."""
    completed = set(state.get("completed", []))
    comp_file = scripts_root / COMPLETED_SCRIPTS_NAME
    if comp_file.exists():
        for line in comp_file.read_text().splitlines():
            line = line.strip()
            if line:
                completed.add(line)
    return completed


def append_completed_script(scripts_root: Path, script_id: str) -> None:
    comp_file = scripts_root / COMPLETED_SCRIPTS_NAME
    comp_file.parent.mkdir(parents=True, exist_ok=True)
    existing = set()
    if comp_file.exists():
        existing = {ln.strip() for ln in comp_file.read_text().splitlines() if ln.strip()}
    if script_id not in existing:
        with comp_file.open("a") as fh:
            fh.write(script_id + "\n")


def save_state(state: dict[str, Any]) -> None:
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


def require_root() -> None:
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        print("This build orchestrator must be run as root.", file=sys.stderr)
        sys.exit(1)


def require_linux() -> None:
    if sys.platform != "linux":
        print(
            "Warning: LFS builds require Linux. Current platform:",
            sys.platform,
            file=sys.stderr,
        )


def run_cmd(
    cmd: list[str] | str,
    *,
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    dry_run: bool = False,
) -> int:
    if isinstance(cmd, str):
        display = cmd
        run_args: list[str] | str = ["bash", "-c", cmd]
    else:
        display = " ".join(cmd)
        run_args = cmd
    print(f"\n>> {display}")
    if dry_run:
        return 0
    result = subprocess.run(run_args, env=env, cwd=cwd)
    return result.returncode


def detect_lfs_tgt() -> str:
    try:
        machine = subprocess.check_output(["uname", "-m"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        machine = "x86_64"
    return f"{machine}-lfs-linux-gnu"


def nproc_jobs() -> str:
    try:
        out = subprocess.check_output(["nproc"], text=True).strip()
        return out if out.isdigit() else "1"
    except (OSError, subprocess.CalledProcessError):
        return "1"


def host_sources_dir() -> Path:
    return Path(os.environ.get("LFS_HOST_SOURCES", str(Path.home() / "sources")))


def host_env(cfg: BuildConfig) -> dict[str, str]:
    env = os.environ.copy()
    jobs = cfg.jobs or nproc_jobs()
    env["LFS"] = cfg.lfs_mount
    env["LFS_MOUNT"] = cfg.lfs_mount
    env["LFS_TGT"] = env.get("LFS_TGT") or detect_lfs_tgt()
    env["LFS_HOST_SOURCES"] = str(host_sources_dir())
    env["LFS_SOURCES"] = str(cfg.resolved_sources())
    env["LFS_SCRIPTS_DIR"] = str(cfg.resolved_scripts())
    env["LFS_BOOK_DIR"] = str(cfg.resolved_book())
    env["LFS_USER"] = cfg.lfs_user
    env["LFS_HOSTNAME"] = cfg.hostname
    env["LFS_TIMEZONE"] = cfg.timezone
    env["LFS_LOCALE"] = cfg.locale
    env["LFS_KEYMAP"] = cfg.keymap
    env["LFS_CONSOLE_FONT"] = cfg.console_font
    env["LFS_RUN_TESTS"] = "1" if cfg.run_package_tests else "0"
    env["MAKEFLAGS"] = f"-j{jobs}"
    env["TESTSUITEFLAGS"] = f"-j{jobs}"
    return env


def lfs_tmp(cfg: BuildConfig) -> Path:
    return Path(cfg.lfs_mount) / "tmp"


def sync_scripts_tree(cfg: BuildConfig, scripts_root: Path) -> Path:
    """Copy full lfs-scripts tree to $LFS/tmp (symlinks preserved)."""
    dest = lfs_tmp(cfg) / "lfs-scripts"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(scripts_root, dest, symlinks=True)
    for f in dest.rglob("*.sh"):
        f.chmod(0o755)
    return dest


def publish_script(cfg: BuildConfig, script_path: Path, dest_subdir: str) -> str:
    dest_dir = lfs_tmp(cfg) / dest_subdir
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / script_path.name
    shutil.copy2(script_path, dest)
    dest.chmod(0o755)
    return f"/tmp/{dest_subdir}/{script_path.name}"


def write_file(path: Path, content: str, *, executable: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o755)


def rebuild_session_dir(
    scripts_root: Path,
    session: str,
    entries: list[dict[str, Any]],
) -> list[str]:
    """Rebuild sessions/<session>/ with symlinks to pending package scripts only."""
    session_dir = scripts_root / "sessions" / session
    if session_dir.exists():
        shutil.rmtree(session_dir)
    session_dir.mkdir(parents=True)

    ids: list[str] = []
    for entry in entries:
        rel = entry.get("script")
        if not rel:
            continue
        src = (scripts_root / rel).resolve()
        dest = session_dir / Path(rel).name
        dest.symlink_to(os.path.relpath(src, session_dir))
        ids.append(rel)
    return ids


def session_wrapper_on_lfs(cfg: BuildConfig, name: str) -> Path:
    return lfs_tmp(cfg) / "lfs-scripts" / RUNNERS_DIR_NAME / name


def group_phases(scripts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Group consecutive manifest entries by runAs (root | lfs | chroot | skip)."""
    phases: list[dict[str, Any]] = []
    for entry in scripts:
        run_as = entry.get("runAs", "root")
        if run_as == "skip":
            if phases and phases[-1]["type"] == "marker":
                phases[-1]["markers"].append(entry)
            else:
                phases.append({"type": "marker", "markers": [entry]})
            continue
        if not entry.get("script"):
            continue
        if phases and phases[-1]["type"] == run_as:
            phases[-1]["scripts"].append(entry)
        else:
            phases.append({"type": run_as, "scripts": [entry]})
    return phases


def phase_label(phase: dict[str, Any]) -> str:
    t = phase["type"]
    if t == "root":
        return "host root (direct)"
    if t == "lfs":
        return f"LFS user session (su -)"
    if t == "chroot":
        return "chroot session"
    return "checkpoint"


def download_sources(cfg: BuildConfig, env: dict[str, str]) -> None:
    sources = cfg.resolved_sources()
    book = cfg.resolved_book()
    wget_list = book / "wget-list-systemd"
    if not wget_list.exists():
        wget_list = book / "wget-list"
    if not wget_list.exists():
        print("No wget-list found in book; skip package download.")
        return

    sources.mkdir(parents=True, exist_ok=True)
    print(f"\nDownloading packages into {sources} ...")
    code = run_cmd(
        f"cd {sources} && wget --input-file={wget_list} --continue --timestamping",
        env=env,
        dry_run=cfg.dry_run,
    )
    if code != 0:
        raise RuntimeError("Package download failed")


def run_root_script(
    cfg: BuildConfig,
    entry: dict[str, Any],
    script_path: Path,
    env: dict[str, str],
) -> int:
    if cfg.confirm_each_script and not cfg.dry_run:
        ans = input(f"Run {script_path.name}? [Y/n] ").strip().lower()
        if ans in ("n", "no"):
            print("Skipped by user.")
            return 0
    return run_cmd(["bash", str(script_path)], env=env, cwd=ROOT, dry_run=cfg.dry_run)


def run_session(
    cfg: BuildConfig,
    session: str,
    entries: list[dict[str, Any]],
    scripts_root: Path,
    env: dict[str, str],
) -> int:
    pending = [e for e in entries if e.get("script")]
    if not pending:
        return 0

    rebuild_session_dir(scripts_root, session, pending)
    synced = sync_scripts_tree(cfg, scripts_root)
    env = {**env, "LFS_SCRIPTS": str(synced)}

    if session == "lfs":
        wrapper_host = session_wrapper_on_lfs(cfg, "run-lfs-session.sh")
    else:
        wrapper_host = session_wrapper_on_lfs(cfg, "run-chroot-session.sh")

    if not wrapper_host.exists():
        print(f"Missing session wrapper: {wrapper_host}", file=sys.stderr)
        print("Run: npm run extract", file=sys.stderr)
        return 1

    iterator = synced / RUNNERS_DIR_NAME / "iterate-session.sh"
    print(
        f"\n=== {session.upper()} session: {len(pending)} package script(s) "
        f"in one shell ==="
    )
    print(f"    Scripts tree: {synced}")
    print(f"    Session dir:  {synced / 'sessions' / session}")
    print(f"    Iterator:     {iterator}")
    print(f"    Log:            {synced / 'logs' / f'build-{session}.log'}")
    return run_cmd(["bash", str(wrapper_host)], env=env, dry_run=cfg.dry_run)


def ensure_kernfs_mounted(
    cfg: BuildConfig,
    env: dict[str, str],
    scripts_root: Path,
) -> int:
    """
    Mount dev/proc/sys on $LFS before a chroot session.
    cleanup-host (Ch 7.13.2) umounts them; Ch8+ needs them again.
    No-op if already mounted (e.g. first chroot right after root kernfs phase).
    """
    script = scripts_root / KERNFS_SCRIPT_REL
    if not script.exists():
        print(f"Warning: kernfs script not found: {script}", file=sys.stderr)
        return 0

    lfs = cfg.lfs_mount
    wrapper = (
        f'export LFS="{lfs}"\n'
        f'if mountpoint -q "$LFS/proc" 2>/dev/null; then\n'
        f'  echo "Kernfs already mounted under $LFS"\n'
        f'  exit 0\n'
        f"fi\n"
        f'echo "Mounting virtual kernel filesystems on $LFS ..."\n'
        f"bash {script!r}\n"
    )
    print(f"\n=== Ensure kernfs on {lfs} (before chroot session) ===")
    return run_cmd(["bash", "-c", wrapper], env=env, cwd=ROOT, dry_run=cfg.dry_run)


def phase_requires_mount(phase: dict[str, Any]) -> bool:
    for entry in phase.get("scripts", []):
        stage = entry.get("stage", "")
        if stage and stage != "stage-01-host-prep" and stage != "stage-07-finish":
            return True
    return phase["type"] in ("lfs", "chroot")


def ensure_sources_synced_to_lfs(
    cfg: BuildConfig, state: dict[str, Any], env: dict[str, str]
) -> int:
    """Copy ~/sources (host staging) to $LFS/sources when the LFS partition is mounted."""
    if cfg.dry_run or state.get("sourcesSyncedToLfs"):
        return 0
    host = host_sources_dir()
    target = cfg.resolved_sources()
    if host.resolve() == target.resolve():
        state["sourcesSyncedToLfs"] = True
        save_state(state)
        return 0
    if not host.is_dir() or not any(host.iterdir()):
        print(
            f"\nNo package sources in {host}. Run ./lfs download first.",
            file=sys.stderr,
        )
        return 1
    script = ROOT / "download-sources.sh"
    sync_env = {**env, "LFS": cfg.lfs_mount}
    if cfg.sources_dir:
        sync_env["LFS_SOURCES"] = cfg.sources_dir
    print(f"\nSyncing sources from {host} to {target} ...")
    result = subprocess.run(
        ["bash", str(script), "--sync-only"],
        env=sync_env,
    )
    if result.returncode != 0:
        return result.returncode
    state["sourcesSyncedToLfs"] = True
    save_state(state)
    return 0


def mark_completed(
    state: dict[str, Any],
    completed: set[str],
    ids: list[str],
    scripts_root: Path,
) -> None:
    for sid in ids:
        completed.add(sid)
        append_completed_script(scripts_root, sid)
    state["completed"] = sorted(completed)


def main() -> int:
    require_linux()
    require_root()

    manifest_path = Path(os.environ.get("LFS_MANIFEST", DEFAULT_MANIFEST))
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}")
        print("Run: npm run extract")
        return 1

    manifest = json.loads(manifest_path.read_text())
    scripts_root = manifest_path.parent

    resume = prompt_bool("\nResume from saved state?", False)
    if resume:
        cfg = load_config()
        if not cfg:
            print("No saved config; starting fresh.")
            cfg = collect_preferences()
            save_config(cfg)
    else:
        if STATE_FILE.exists() and prompt_bool("Reset previous build state?", True):
            STATE_FILE.unlink()
            prev_cfg = load_config()
            log_root = prev_cfg.resolved_scripts() if prev_cfg else scripts_root
            for log_file in (
                log_root / COMPLETED_SCRIPTS_NAME,
                log_root / EVENTS_LOG_NAME,
            ):
                if log_file.exists():
                    log_file.unlink()
        cfg = collect_preferences()
        save_config(cfg)

    env = host_env(cfg)
    state = load_state()
    if not state.get("startedAt"):
        state["startedAt"] = datetime.now(timezone.utc).isoformat()
        save_state(state)

    completed = load_completed_set(state, scripts_root)
    scripts = manifest.get("scripts", [])
    phases = group_phases(scripts)

    if cfg.download_packages and "packages-downloaded" not in completed:
        try:
            download_sources(cfg, env)
            if not cfg.dry_run:
                completed.add("packages-downloaded")
                state["completed"] = sorted(completed)
                save_state(state)
        except RuntimeError as exc:
            print(exc, file=sys.stderr)
            return 1

    print(f"\n=== LFS build: {len(phases)} phase(s) from manifest ===\n")

    for phase in phases:
        ptype = phase["type"]
        if ptype == "marker":
            for m in phase.get("markers", []):
                print(f"\n--- Checkpoint: {m.get('title', m.get('source'))} ---")
            continue

        pending = [e for e in phase["scripts"] if e["script"] not in completed]
        if not pending:
            continue

        if phase_requires_mount(phase) and not cfg.dry_run:
            if not os.path.ismount(cfg.lfs_mount):
                print(
                    f"\nLFS partition must be mounted at {cfg.lfs_mount} "
                    f"before phase: {phase_label(phase)}"
                )
                print("Mount it, then re-run to resume.")
                return 1
            code = ensure_sources_synced_to_lfs(cfg, state, env)
            if code != 0:
                return code

        print(f"\n######## Phase: {phase_label(phase)} ########")

        if ptype == "root":
            for entry in pending:
                script_path = scripts_root / entry["script"]
                if not script_path.exists():
                    print(f"Missing script: {script_path}", file=sys.stderr)
                    return 1
                print(f"\n--- {entry['title']} ---")
                print(f"    {entry['source']}")
                code = run_root_script(cfg, entry, script_path, env)
                if code != 0:
                    state["lastError"] = {
                        "script": entry["script"],
                        "code": code,
                        "phase": ptype,
                        "at": datetime.now(timezone.utc).isoformat(),
                    }
                    save_state(state)
                    print(f"\nBuild failed at {entry['script']} (exit {code}).")
                    return code
                if not cfg.dry_run:
                    mark_completed(state, completed, [entry["script"]], scripts_root)
                    state["lastError"] = None
                    save_state(state)
        elif ptype in ("lfs", "chroot"):
            session_ids = [e["script"] for e in pending]
            if ptype == "chroot":
                code = ensure_kernfs_mounted(cfg, env, scripts_root)
                if code != 0:
                    state["lastError"] = {
                        "phase": "kernfs",
                        "code": code,
                        "at": datetime.now(timezone.utc).isoformat(),
                    }
                    save_state(state)
                    print("\nFailed to mount virtual kernel filesystems before chroot.")
                    return code
            code = run_session(cfg, ptype, pending, scripts_root, env)
            if code != 0:
                state["lastError"] = {
                    "phase": ptype,
                    "scripts": session_ids,
                    "code": code,
                    "at": datetime.now(timezone.utc).isoformat(),
                }
                save_state(state)
                print(f"\n{ptype} session failed (exit {code}). Re-run to resume.")
                return code
            if not cfg.dry_run:
                mark_completed(state, completed, session_ids, scripts_root)
                state["lastCheckpoint"] = {
                    "phase": ptype,
                    "scripts": session_ids[-1] if session_ids else None,
                    "at": datetime.now(timezone.utc).isoformat(),
                }
                state["lastError"] = None
                save_state(state)
        else:
            print(f"Unknown phase type: {ptype}", file=sys.stderr)
            return 1

    if not cfg.dry_run:
        state["finishedAt"] = datetime.now(timezone.utc).isoformat()
        save_state(state)

    print("\n=== LFS build scripts completed successfully ===")
    print("Follow Chapter 11 in the book to reboot into your new system if needed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
