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
MOUNT_KERNFS_SCRIPT = ROOT / "mount-kernfs.sh"
STRIP_LFS_SCRIPT = ROOT / "strip-lfs.sh"
CLEANUP_LFS_SCRIPT = ROOT / "cleanup-lfs.sh"
BOOTSTRAP_SCRIPT = ROOT / "bootstrap-lfs.sh"
STAGE_HOST_PREP = "stage-01-host-prep"

CH8_E2FSPROGS_SCRIPT = "stage-05-system-build/0113-08-e2fsprogs.sh"
CH8_POST_HOST_STEPS: list[dict[str, Any]] = [
    {
        "script_id": "stage-05-system-build/0114-08-stripping.sh",
        "host_script": STRIP_LFS_SCRIPT,
        "title": "8.85. Stripping",
        "source": "chapter08/stripping.html",
    },
    {
        "script_id": "stage-05-system-build/0115-08-cleanup.sh",
        "host_script": CLEANUP_LFS_SCRIPT,
        "title": "8.86. Cleaning Up",
        "source": "chapter08/cleanup.html",
    },
]


@dataclass
class BuildConfig:
    lfs_mount: str = "/mnt/lfs"
    lfs_partition: str = "/dev/sdb2"
    swap_partition: str = ""
    filesystem_type: str = "ext4"
    hostname: str = "lfs"
    timezone: str = "UTC"
    locale: str = "en_US.UTF-8"
    keymap: str = "us"
    console_font: str = "LatArC-16"
    sources_dir: str = ""
    book_dir: str = ""
    scripts_dir: str = ""
    lfs_user: str = "lfs"
    lfs_group: str = "lfs"
    root_password: str = "lfs"
    lfs_user_password: str = "lfs"
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
    print("This orchestrator runs host bootstrap (Ch 2–4) then package scripts.")
    print("Must be run as root.\n")

    cfg = BuildConfig()
    cfg.lfs_mount = prompt("LFS mount point", cfg.lfs_mount)
    cfg.lfs_partition = prompt("LFS partition device", cfg.lfs_partition)
    cfg.swap_partition = prompt("Swap partition (optional, leave empty to skip)", "")
    cfg.filesystem_type = prompt("Filesystem type for LFS partition", cfg.filesystem_type)
    cfg.hostname = prompt("Target hostname", cfg.hostname)
    cfg.timezone = prompt("Timezone (e.g. UTC or America/New_York)", cfg.timezone)
    cfg.locale = prompt("Locale", cfg.locale)
    cfg.keymap = prompt("Console keymap", cfg.keymap)
    cfg.console_font = prompt("Console font", cfg.console_font)
    cfg.lfs_user = prompt("LFS build user", cfg.lfs_user)
    cfg.lfs_group = prompt("LFS build group", cfg.lfs_group)
    cfg.root_password = prompt("Root password", cfg.root_password)
    cfg.lfs_user_password = prompt("LFS user password", cfg.lfs_user_password)
    cfg.jobs = prompt("Make parallel jobs (empty = nproc)", cfg.jobs)

    return cfg


def save_config(cfg: BuildConfig) -> None:
    data = {k: getattr(cfg, k) for k in cfg.__dataclass_fields__}
    CONFIG_FILE.write_text(json.dumps(data, indent=2) + "\n")


def load_config() -> BuildConfig | None:
    if not CONFIG_FILE.exists():
        return None
    data = json.loads(CONFIG_FILE.read_text())
    cfg = BuildConfig(**{k: data.get(k, getattr(BuildConfig(), k)) for k in BuildConfig.__dataclass_fields__})
    if not cfg.lfs_partition:
        cfg.lfs_partition = "/dev/sdb2"
    return cfg


def load_state() -> dict[str, Any]:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {"completed": [], "lastError": None, "startedAt": None, "finishedAt": None}


def load_completed_set(
    state: dict[str, Any],
    scripts_root: Path,
    cfg: BuildConfig | None = None,
) -> set[str]:
    """Merge Python state with completed-scripts on disk (repo and $LFS/tmp)."""
    completed = set(state.get("completed", []))
    for comp_file in completed_script_log_paths(scripts_root, cfg):
        if not comp_file.exists():
            continue
        for line in comp_file.read_text().splitlines():
            line = line.strip()
            if line:
                completed.add(line)
    return completed


def completed_script_log_paths(
    scripts_root: Path,
    cfg: BuildConfig | None = None,
) -> list[Path]:
    paths = [scripts_root / COMPLETED_SCRIPTS_NAME]
    if cfg:
        paths.append(lfs_tmp(cfg) / "lfs-scripts" / COMPLETED_SCRIPTS_NAME)
    return paths


def append_completed_script(
    scripts_root: Path,
    script_id: str,
    cfg: BuildConfig | None = None,
) -> None:
    for comp_file in completed_script_log_paths(scripts_root, cfg):
        comp_file.parent.mkdir(parents=True, exist_ok=True)
        existing = set()
        if comp_file.exists():
            existing = {
                ln.strip() for ln in comp_file.read_text().splitlines() if ln.strip()
            }
        if script_id not in existing:
            with comp_file.open("a") as fh:
                fh.write(script_id + "\n")


def merge_logs_dir(src: Path, dest: Path) -> None:
    """Merge session logs and completed-scripts from src into dest."""
    if not src.is_dir():
        return
    dest.mkdir(parents=True, exist_ok=True)

    src_comp = src / COMPLETED_SCRIPTS_NAME.name
    dest_comp = dest / COMPLETED_SCRIPTS_NAME.name
    lines: set[str] = set()
    if dest_comp.exists():
        lines.update(
            ln.strip() for ln in dest_comp.read_text().splitlines() if ln.strip()
        )
    if src_comp.exists():
        lines.update(
            ln.strip() for ln in src_comp.read_text().splitlines() if ln.strip()
        )
    if lines:
        dest_comp.write_text("\n".join(sorted(lines)) + "\n")

    src_events = src / EVENTS_LOG_NAME.name
    dest_events = dest / EVENTS_LOG_NAME.name
    if src_events.exists():
        if dest_events.exists():
            with dest_events.open("a") as out, src_events.open() as inp:
                out.write(inp.read())
        else:
            shutil.copy2(src_events, dest_events)

    for log in src.glob("build-*.log"):
        dest_log = dest / log.name
        if dest_log.exists():
            with dest_log.open("a") as out, log.open() as inp:
                out.write(inp.read())
        else:
            shutil.copy2(log, dest_log)


def persist_build_logs(
    cfg: BuildConfig,
    scripts_root: Path,
    state: dict[str, Any],
    completed: set[str],
) -> None:
    """Copy $LFS/tmp session logs into the repo and refresh state.completed."""
    src = lfs_tmp(cfg) / "lfs-scripts" / "logs"
    dest = scripts_root / "logs"
    merge_logs_dir(src, dest)
    for comp_file in completed_script_log_paths(scripts_root, cfg):
        if not comp_file.exists():
            continue
        for line in comp_file.read_text().splitlines():
            line = line.strip()
            if line:
                completed.add(line)
    state["completed"] = sorted(completed)
    save_state(state)


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
    env["LFS_GROUP"] = cfg.lfs_group
    env["LFS_PARTITION"] = cfg.lfs_partition
    env["LFS_SWAP_PARTITION"] = cfg.swap_partition
    env["LFS_FILESYSTEM_TYPE"] = cfg.filesystem_type
    env["LFS_ROOT_PASSWORD"] = cfg.root_password
    env["LFS_USER_PASSWORD"] = cfg.lfs_user_password
    env["LFS_HOSTNAME"] = cfg.hostname
    env["LFS_TIMEZONE"] = cfg.timezone
    env["LFS_LOCALE"] = cfg.locale
    env["LFS_KEYMAP"] = cfg.keymap
    env["LFS_CONSOLE_FONT"] = cfg.console_font
    env["MAKEFLAGS"] = f"-j{jobs}"
    env["TESTSUITEFLAGS"] = f"-j{jobs}"
    return env


def lfs_tmp(cfg: BuildConfig) -> Path:
    return Path(cfg.lfs_mount) / "tmp"


def sync_scripts_tree(cfg: BuildConfig, scripts_root: Path) -> Path:
    """Copy full lfs-scripts tree to $LFS/tmp (symlinks preserved)."""
    dest = lfs_tmp(cfg) / "lfs-scripts"
    preserved_logs: Path | None = None
    prev_logs = dest / "logs"
    if prev_logs.is_dir():
        tmp_parent = lfs_tmp(cfg) / ".lfs-logs-preserve"
        if tmp_parent.exists():
            shutil.rmtree(tmp_parent)
        shutil.copytree(prev_logs, tmp_parent)
        preserved_logs = tmp_parent
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(scripts_root, dest, symlinks=True)
    if preserved_logs and preserved_logs.is_dir():
        merge_logs_dir(preserved_logs, dest / "logs")
        shutil.rmtree(preserved_logs)
    for f in dest.rglob("*.sh"):
        f.chmod(0o755)
    return dest


def prepare_lfs_session_tree(cfg: BuildConfig, synced: Path) -> int:
    """Root prepares $LFS/tmp so the lfs user can write build logs and state."""
    tmp = lfs_tmp(cfg)
    tmp.mkdir(parents=True, exist_ok=True)
    logs_dir = synced / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    owner = f"{cfg.lfs_user}:{cfg.lfs_group}"
    result = subprocess.run(["chown", "-R", owner, str(tmp)], check=False)
    return result.returncode


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
            prev = phases[-1]["scripts"][-1]
            if (
                run_as == "chroot"
                and prev.get("chapter") == "08"
                and entry.get("chapter") == "09"
            ):
                phases.append({"type": run_as, "scripts": [entry]})
                continue
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
    if session == "lfs" and not cfg.dry_run:
        code = prepare_lfs_session_tree(cfg, synced)
        if code != 0:
            print(
                f"Failed to chown {lfs_tmp(cfg)} for user {cfg.lfs_user}.",
                file=sys.stderr,
            )
            return code
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
    No-op if already mounted (mount-kernfs.sh checks $LFS/proc).
    """
    if not MOUNT_KERNFS_SCRIPT.exists():
        print(f"Warning: kernfs script not found: {MOUNT_KERNFS_SCRIPT}", file=sys.stderr)
        return 0

    lfs = cfg.lfs_mount
    print(f"\n=== Ensure kernfs on {lfs} (before chroot session) ===")
    mount_env = {**env, "LFS": lfs}
    return run_cmd(
        ["bash", str(MOUNT_KERNFS_SCRIPT)],
        env=mount_env,
        cwd=ROOT,
        dry_run=cfg.dry_run,
    )


def ch8_post_steps_pending(completed: set[str]) -> list[dict[str, Any]]:
    """Strip/cleanup after Ch 8 packages; skipped in generated chroot scripts."""
    if CH8_E2FSPROGS_SCRIPT not in completed:
        return []
    return [s for s in CH8_POST_HOST_STEPS if s["script_id"] not in completed]


def run_ch8_post_host_steps(
    cfg: BuildConfig,
    env: dict[str, str],
    completed: set[str],
    state: dict[str, Any],
    scripts_root: Path,
) -> int:
    pending = ch8_post_steps_pending(completed)
    if not pending:
        return 0

    print(
        "\n=== Post-Chapter 8 host steps "
        "(strip + cleanup outside chroot session) ==="
    )
    for step in pending:
        script_path = step["host_script"]
        if not script_path.exists():
            print(f"Missing host script: {script_path}", file=sys.stderr)
            return 1
        print(f"\n--- {step['title']} ---")
        print(f"    {step['source']}")
        code = run_cmd(
            ["bash", str(script_path)],
            env=env,
            cwd=ROOT,
            dry_run=cfg.dry_run,
        )
        if code != 0:
            state["lastError"] = {
                "script": step["script_id"],
                "code": code,
                "phase": "post-ch8",
                "at": datetime.now(timezone.utc).isoformat(),
            }
            save_state(state)
            print(f"\nPost-Chapter 8 step failed: {step['script_id']} (exit {code}).")
            return code
        if not cfg.dry_run:
            mark_completed(state, completed, [step["script_id"]], scripts_root, cfg)
            state["lastError"] = None
            save_state(state)
    return 0


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
    cfg: BuildConfig | None = None,
) -> None:
    for sid in ids:
        completed.add(sid)
        append_completed_script(scripts_root, sid, cfg)
    state["completed"] = sorted(completed)


def is_lfs_mounted(mount: str) -> bool:
    return os.path.ismount(mount)


def has_build_progress(state: dict[str, Any], scripts_root: Path) -> bool:
    if state.get("bootstrapComplete"):
        return True
    if state.get("completed"):
        return True
    comp_file = scripts_root / COMPLETED_SCRIPTS_NAME
    return comp_file.exists() and bool(comp_file.read_text().strip())


def reset_build_logs(scripts_root: Path) -> None:
    for log_file in (
        scripts_root / COMPLETED_SCRIPTS_NAME,
        scripts_root / EVENTS_LOG_NAME,
    ):
        if log_file.exists():
            log_file.unlink()


def unmount_lfs(cfg: BuildConfig) -> None:
    script = ROOT / "unmount-lfs.sh"
    env = os.environ.copy()
    env["LFS"] = cfg.lfs_mount
    if cfg.swap_partition:
        env["LFS_SWAP_PARTITION"] = cfg.swap_partition
    if script.exists():
        subprocess.run(["bash", str(script), "--lazy"], env=env, check=False)
        return
    mount = cfg.lfs_mount
    if is_lfs_mounted(mount):
        print(f"Unmounting {mount} ...")
        subprocess.run(["umount", mount], check=False)
    if cfg.swap_partition:
        subprocess.run(["swapoff", cfg.swap_partition], check=False)


def run_bootstrap(
    cfg: BuildConfig,
    env: dict[str, str],
    *,
    mkfs: bool,
    dry_run: bool = False,
) -> int:
    if not cfg.lfs_partition:
        print("LFS partition device is required for bootstrap.", file=sys.stderr)
        return 1
    if not BOOTSTRAP_SCRIPT.exists():
        print(f"Missing bootstrap script: {BOOTSTRAP_SCRIPT}", file=sys.stderr)
        return 1
    bootstrap_env = {
        **env,
        "LFS_BOOTSTRAP_MKFS": "1" if mkfs else "0",
    }
    print("\n=== LFS host bootstrap (Chapters 2–4) ===")
    return run_cmd(
        ["bash", str(BOOTSTRAP_SCRIPT)],
        env=bootstrap_env,
        cwd=ROOT,
        dry_run=dry_run,
    )


def scripts_for_build(manifest_scripts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Drop stage-01 book scripts; bootstrap replaces Ch 2–4 host prep."""
    return [
        s
        for s in manifest_scripts
        if s.get("stage") != STAGE_HOST_PREP
    ]


def executable_phases(phases: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [p for p in phases if p["type"] != "marker"]


def resolve_startup(
    scripts_root: Path,
) -> tuple[BuildConfig, dict[str, Any], bool, bool]:
    """
    Returns (cfg, state, resume_build, skip_bootstrap).
    skip_bootstrap True when resuming with $LFS already mounted.
    """
    prev_cfg = load_config()
    prev_state = load_state()
    mount_hint = prev_cfg.lfs_mount if prev_cfg else "/mnt/lfs"
    mounted = is_lfs_mounted(mount_hint)
    in_progress = mounted or has_build_progress(prev_state, scripts_root)

    resume = False
    if in_progress:
        if mounted:
            print(f"\nLFS partition is mounted at {mount_hint}.")
        else:
            print("\nSaved build progress was found.")
        resume = prompt_bool("Resume from saved state?", False)

    if resume:
        cfg = prev_cfg
        if not cfg:
            print("No saved config; enter build settings.")
            cfg = collect_preferences()
            save_config(cfg)
        state = prev_state
        skip_bootstrap = mounted
        return cfg, state, True, skip_bootstrap

    if in_progress and mounted:
        unmount_cfg = prev_cfg or BuildConfig(lfs_mount=mount_hint)
        unmount_lfs(unmount_cfg)

    if STATE_FILE.exists() and prompt_bool("Reset previous build state?", True):
        if prev_cfg and is_lfs_mounted(prev_cfg.lfs_mount):
            unmount_lfs(prev_cfg)
        STATE_FILE.unlink()
        log_root = prev_cfg.resolved_scripts() if prev_cfg else scripts_root
        reset_build_logs(log_root)

    cfg = collect_preferences()
    save_config(cfg)
    if is_lfs_mounted(cfg.lfs_mount):
        unmount_lfs(cfg)
    return cfg, {"completed": [], "lastError": None, "startedAt": None, "finishedAt": None}, False, False


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

    cfg, state, resume_build, skip_bootstrap = resolve_startup(scripts_root)

    env = host_env(cfg)
    if not state.get("startedAt"):
        state["startedAt"] = datetime.now(timezone.utc).isoformat()
        save_state(state)

    if not skip_bootstrap:
        mkfs = not resume_build
        code = run_bootstrap(cfg, env, mkfs=mkfs, dry_run=cfg.dry_run)
        if code != 0:
            print("\nBootstrap failed.", file=sys.stderr)
            return code
        if not cfg.dry_run:
            state["bootstrapComplete"] = True
            state["sourcesSyncedToLfs"] = True
            save_state(state)

    completed = load_completed_set(state, scripts_root, cfg)
    build_scripts = scripts_for_build(manifest.get("scripts", []))
    phases = executable_phases(group_phases(build_scripts))

    print(f"\n=== LFS build: {len(phases)} phase(s) from manifest ===\n")

    for phase in phases:
        ptype = phase["type"]

        pending = [e for e in phase["scripts"] if e["script"] not in completed]
        if not pending:
            continue

        if phase_requires_mount(phase) and not cfg.dry_run:
            if not is_lfs_mounted(cfg.lfs_mount):
                print(
                    f"\nLFS partition must be mounted at {cfg.lfs_mount} "
                    f"before phase: {phase_label(phase)}"
                )
                print("Re-run to resume; bootstrap will mount the partition.")
                return 1
            if not state.get("sourcesSyncedToLfs"):
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
                    mark_completed(state, completed, [entry["script"]], scripts_root, cfg)
                    state["lastError"] = None
                    save_state(state)
        elif ptype in ("lfs", "chroot"):
            session_ids = [e["script"] for e in pending]
            if ptype == "chroot":
                first_ch = pending[0].get("chapter") if pending else ""
                if first_ch == "09":
                    code = run_ch8_post_host_steps(
                        cfg, env, completed, state, scripts_root
                    )
                    if code != 0:
                        return code
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
                if not cfg.dry_run:
                    persist_build_logs(cfg, scripts_root, state, completed)
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
                persist_build_logs(cfg, scripts_root, state, completed)
                mark_completed(state, completed, session_ids, scripts_root, cfg)
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
