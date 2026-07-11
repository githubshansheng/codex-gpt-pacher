#!/usr/bin/env python3
"""Patch Codex Desktop for third-party GPT-5.6 catalogs.

The patch creates a separate signed application copy, exposes Sol/Terra/Luna
with low/medium/high/xhigh/max/ultra, and configures the active third-party
provider so the Desktop can run with an API key without a ChatGPT account login.
It never copies, embeds, prints, or changes API credentials.
"""

from __future__ import annotations

import argparse
import copy
import ctypes
import datetime as dt
import glob
import json
import os
import platform
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


PATCH_ID = "codex-gpt56-model-picker-v2"
MODEL_TIERS = {
    "sol": ("gpt-5.6-sol", "GPT-5.6 Sol"),
    "terra": ("gpt-5.6-terra", "GPT-5.6 Terra"),
    "luna": ("gpt-5.6-luna", "GPT-5.6 Luna"),
}
EFFORT_DESCRIPTIONS = {
    "low": "Fast responses with lighter reasoning",
    "medium": "Balances speed and reasoning depth for everyday tasks",
    "high": "Greater reasoning depth for complex problems",
    "xhigh": "Extra high reasoning depth for complex problems",
    "max": "Maximum reasoning depth for the hardest problems",
    "ultra": "Ultra parallel reasoning; requires explicit provider support",
}
DEFAULT_PROVIDER = "custom"
DEFAULT_BASE_URL = "https://ai.heigh.vip/v1"
DEFAULT_WIRE_API = "responses"
DEFAULT_ENV_KEY = "CODEX_CUSTOM_API_KEY"
OFFICIAL_PROVIDERS = {"openai", "chatgpt"}


@dataclass
class AppLayout:
    kind: str
    root: Path
    asar: Path | None
    source: Path
    launcher: Path | None = None


def log(message: str) -> None:
    print(f"[codex-gpt56] {message}", flush=True)


def fail(message: str) -> "NoReturn":
    raise RuntimeError(message)


def timestamp() -> str:
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S")


def run(
    command: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    capture: bool = True,
    timeout: int = 300,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    log("Run: " + " ".join(command))
    result = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=capture,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        details = (result.stderr or result.stdout or "").strip()
        fail(f"Command failed ({result.returncode}): {' '.join(command)}\n{details}")
    return result


def platform_name() -> str:
    if sys.platform == "win32":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux"
    fail(f"Unsupported platform: {sys.platform}")


def expand(path: str | Path) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(str(path)))).resolve()


def windows_short_path(path: Path) -> Path:
    if platform_name() != "windows":
        return path
    buffer = ctypes.create_unicode_buffer(32768)
    length = ctypes.windll.kernel32.GetShortPathNameW(str(path), buffer, len(buffer))
    if length == 0 or length >= len(buffer):
        return path
    return Path(buffer.value)


def create_temp_root() -> Path:
    if platform_name() == "windows":
        drive = Path(os.environ.get("SystemDrive", "C:") + os.sep)
        try:
            return Path(tempfile.mkdtemp(prefix="c56-", dir=drive))
        except OSError:
            parent = windows_short_path(Path.home())
            return Path(tempfile.mkdtemp(prefix="c56-", dir=parent))
    return Path(tempfile.mkdtemp(prefix="codex-gpt56-patch-"))


def remove_temp_root(path: Path) -> None:
    if platform_name() == "windows":
        extended = "\\\\?\\" + str(path.resolve())
        result = run(["cmd", "/d", "/c", "rmdir", "/s", "/q", extended], check=False, timeout=120)
        if result.returncode == 0 or not path.exists():
            return
    try:
        shutil.rmtree(path)
    except OSError as exc:
        log(f"WARNING: Could not fully remove temporary directory {path}: {exc}")


def normalize_layout(path: Path) -> AppLayout | None:
    path = expand(path)
    if path.is_file() and path.name == "app.asar":
        resources = path.parent
        if resources.parent.name == "Contents":
            root = resources.parent.parent
            return AppLayout("mac_app", root, path, path)
        return AppLayout(f"{platform_name()}_dir", resources.parent, path, path)

    if path.is_file() and path.suffix.lower() == ".appimage":
        return AppLayout("linux_appimage", path, None, path, path)

    if path.is_file() and path.suffix.lower() == ".exe":
        root = path.parent
        asar = root / "resources" / "app.asar"
        if asar.exists():
            return AppLayout("windows_dir", root, asar, path, path)

    if path.is_dir() and path.suffix.lower() == ".app":
        asar = path / "Contents" / "Resources" / "app.asar"
        if asar.exists():
            return AppLayout("mac_app", path, asar, path)

    if path.is_dir():
        candidates = [
            path / "resources" / "app.asar",
            path / "Contents" / "Resources" / "app.asar",
            path / "app" / "resources" / "app.asar",
        ]
        for asar in candidates:
            if asar.exists():
                kind = "mac_app" if "Contents" in asar.parts else f"{platform_name()}_dir"
                root = path
                return AppLayout(kind, root, asar, path)
    return None


def official_candidates() -> list[Path]:
    system = platform_name()
    home = Path.home()
    candidates: list[Path] = []

    if system == "windows":
        local = Path(os.environ.get("LOCALAPPDATA", home / "AppData" / "Local"))
        program_files = Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
        patterns = [
            str(program_files / "WindowsApps" / "OpenAI.Codex_*" / "app"),
            str(local / "Programs" / "Codex"),
            str(local / "Programs" / "ChatGPT"),
            str(local / "OpenAI" / "Codex"),
            str(local / "OpenAI" / "ChatGPT"),
        ]
        for pattern in patterns:
            candidates.extend(Path(item) for item in glob.glob(pattern))
        powershell = shutil.which("powershell") or shutil.which("pwsh")
        if powershell:
            result = run(
                [
                    powershell,
                    "-NoProfile",
                    "-Command",
                    "Get-AppxPackage OpenAI.Codex -ErrorAction SilentlyContinue | "
                    "ForEach-Object { Join-Path $_.InstallLocation 'app' }",
                ],
                check=False,
                timeout=30,
            )
            candidates.extend(Path(line.strip()) for line in result.stdout.splitlines() if line.strip())

    elif system == "macos":
        candidates.extend(
            [
                Path("/Applications/Codex.app"),
                Path("/Applications/ChatGPT.app"),
                home / "Applications" / "Codex.app",
                home / "Applications" / "ChatGPT.app",
            ]
        )
        if shutil.which("mdfind"):
            result = run(
                [
                    "mdfind",
                    "kMDItemFSName == 'Codex.app'c || kMDItemFSName == 'ChatGPT.app'c",
                ],
                check=False,
                timeout=30,
            )
            candidates.extend(Path(line.strip()) for line in result.stdout.splitlines() if line.strip())

    else:
        candidates.extend(
            [
                Path("/opt/Codex"),
                Path("/opt/codex"),
                Path("/opt/ChatGPT"),
                Path("/opt/chatgpt"),
                Path("/usr/lib/codex"),
                Path("/usr/lib/codex-desktop"),
                Path("/usr/lib/chatgpt"),
                Path("/usr/share/codex"),
                Path("/usr/share/codex-desktop"),
                Path("/usr/share/chatgpt"),
                Path("/usr/local/lib/codex"),
                home / ".local" / "share" / "codex",
                home / ".local" / "share" / "codex-desktop",
                home / ".local" / "share" / "chatgpt",
                home / ".local" / "opt" / "codex",
            ]
        )
        for executable in ["codex-desktop", "codex-app", "chatgpt"]:
            resolved = shutil.which(executable)
            if resolved:
                candidates.extend([Path(resolved).resolve(), Path(resolved).resolve().parent])
        for base in [home / "Applications", home / "Downloads", Path("/opt")]:
            if base.exists():
                candidates.extend(base.glob("*Codex*.AppImage"))
                candidates.extend(base.glob("*ChatGPT*.AppImage"))

    return list(dict.fromkeys(candidates))


def detect_layout(explicit: str | None, *, prefer_patched: bool = False) -> AppLayout:
    if explicit:
        layout = normalize_layout(expand(explicit))
        if not layout:
            fail(f"Could not find app.asar or an AppImage under: {explicit}")
        return layout

    candidates = official_candidates()
    layouts = [layout for item in candidates if (layout := normalize_layout(item))]
    if not prefer_patched:
        layouts = [
            layout
            for layout in layouts
            if "patched" not in str(layout.root).lower()
            and "gpt56" not in str(layout.root).lower()
        ]
    if not layouts:
        fail(
            "Codex Desktop was not found in common install paths. "
            "Pass --app with the .app, AppImage, application directory, executable, or app.asar path."
        )
    layouts.sort(
        key=lambda item: item.asar.stat().st_mtime if item.asar and item.asar.exists() else item.root.stat().st_mtime,
        reverse=True,
    )
    return layouts[0]


def default_output(layout: AppLayout) -> Path:
    home = Path.home()
    system = platform_name()
    if system == "windows":
        return home / "Applications" / "Codex-GPT56-Patched"
    if system == "macos":
        return home / "Applications" / "Codex-GPT56-Patched.app"
    return home / ".local" / "opt" / "codex-gpt56-patched"


def patch_marker_path(app_root: Path) -> Path:
    return (
        app_root / "Contents" / "Resources" / ".codex-gpt56-patch.json"
        if platform_name() == "macos"
        else app_root / ".codex-gpt56-patch.json"
    )


def is_managed_patched_copy(path: Path) -> bool:
    marker = patch_marker_path(path)
    if not marker.is_file():
        return False
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return data.get("patch") == PATCH_ID


def remove_managed_copy(path: Path) -> None:
    if not path.exists():
        return
    if not is_managed_patched_copy(path):
        fail(f"Refusing to remove unrecognized application: {path}")
    log(f"Remove obsolete managed copy: {path}")
    shutil.rmtree(path)


def cleanup_legacy_backups(destination: Path) -> int:
    """Remove only timestamped app copies created by older patcher versions."""
    removed = 0
    pattern = f"{destination.name}.backup-*"
    for candidate in destination.parent.glob(pattern):
        if candidate.is_dir() and is_managed_patched_copy(candidate):
            remove_managed_copy(candidate)
            removed += 1
        else:
            log(f"WARNING: Skipped unrecognized legacy backup: {candidate}")
    if removed:
        log(f"Removed {removed} legacy backup app(s) so Finder shows only one patched Codex app")
    return removed


def staging_path(destination: Path) -> Path:
    return destination.with_name(f".{destination.name}.building")


def install_staged_copy(staged: Path, destination: Path) -> None:
    """Atomically replace the managed destination without retaining Finder-visible .app backups."""
    previous = destination.with_name(f".{destination.name}.previous")
    if previous.exists():
        if is_managed_patched_copy(previous):
            remove_managed_copy(previous)
        else:
            fail(f"Temporary replacement path is occupied: {previous}")

    had_destination = destination.exists()
    if had_destination and not is_managed_patched_copy(destination):
        fail(
            f"Destination already exists but was not created by this patcher: {destination}. "
            "Choose another --output path or move it manually."
        )

    try:
        if had_destination:
            destination.rename(previous)
        staged.rename(destination)
    except Exception:
        if not destination.exists() and previous.exists():
            previous.rename(destination)
        raise
    else:
        if previous.exists():
            remove_managed_copy(previous)


def backup_existing(path: Path, *, dry_run: bool) -> Path | None:
    """Deprecated compatibility helper: no longer creates Finder-visible app backups."""
    if not path.exists():
        return None
    log(f"Existing managed patched copy will be replaced in place: {path}")
    if not dry_run and not is_managed_patched_copy(path):
        fail(f"Destination exists but is not a managed patched copy: {path}")
    return path


def backup_file(path: Path) -> Path | None:
    if not path.exists():
        return None
    backup = path.with_name(f"{path.name}.backup-{timestamp()}")
    shutil.copy2(path, backup)
    log(f"Backup created: {backup}")
    return backup


def copy_windows_tree(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    result = run(
        [
            "robocopy",
            str(source),
            str(destination),
            "/E",
            "/COPY:DAT",
            "/DCOPY:DAT",
            "/R:1",
            "/W:1",
            "/NFL",
            "/NDL",
            "/NJH",
            "/NJS",
            "/NP",
        ],
        capture=True,
        check=False,
        timeout=900,
    )
    if result.returncode > 7:
        fail(f"robocopy failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")


def copy_layout(layout: AppLayout, destination: Path, temp_root: Path) -> AppLayout:
    if layout.kind == "linux_appimage":
        log(f"Extract AppImage: {layout.source}")
        result = run(
            [str(layout.source), "--appimage-extract"],
            cwd=temp_root,
            timeout=900,
        )
        del result
        extracted = temp_root / "squashfs-root"
        if not extracted.exists():
            fail("AppImage extraction did not create squashfs-root")
        shutil.copytree(extracted, destination, symlinks=True)
        normalized = normalize_layout(destination)
        if not normalized:
            fail("Extracted AppImage does not contain resources/app.asar")
        normalized.launcher = destination / "AppRun"
        return normalized

    log(f"Copy official app: {layout.root} -> {destination}")
    if platform_name() == "windows":
        copy_windows_tree(layout.root, destination)
    elif platform_name() == "macos" and shutil.which("ditto"):
        run(["ditto", str(layout.root), str(destination)], capture=True, timeout=900)
    else:
        shutil.copytree(layout.root, destination, symlinks=True)

    relative_asar = layout.asar.relative_to(layout.root) if layout.asar else Path("resources/app.asar")
    copied = AppLayout(layout.kind, destination, destination / relative_asar, layout.source)
    if platform_name() == "windows":
        copied.launcher = next(
            (item for item in [destination / "ChatGPT.exe", destination / "Codex.exe"] if item.exists()),
            None,
        )
    elif platform_name() == "linux":
        copied.launcher = next(
            (item for item in [destination / "AppRun", destination / "codex", destination / "chatgpt"] if item.exists()),
            None,
        )
    return copied


def asar_command() -> list[str]:
    direct = shutil.which("asar")
    if direct:
        return [direct]
    node = shutil.which("node")
    npm_cache = expand(os.environ.get("NPM_CONFIG_CACHE", str(Path.home() / ".npm")))
    cached = sorted(
        npm_cache.glob("_npx/*/node_modules/@electron/asar/bin/asar.js"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if node and cached:
        return [node, str(cached[0])]
    npx = shutil.which("npx")
    if npx:
        return [npx, "--yes", "@electron/asar"]
    fail("Neither asar nor npx was found. Install Node.js 20+ and retry.")


def asar_run(arguments: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return run(asar_command() + arguments, **kwargs)


MODEL_FILTER_RE = re.compile(
    r"if\(\s*(?P<gate>[$A-Za-z_][\w$]*)\s*\?\s*"
    r"(?P<allowed>[$A-Za-z_][\w$]*)\.has\(\s*"
    r"(?P<item>[$A-Za-z_][\w$]*)\.model\s*\)\s*:\s*!\s*"
    r"(?P=item)\.hidden\s*\)"
)
REASONING_FILTER_RE = re.compile(
    r"\.filter\(\(\{\s*reasoningEffort\s*:\s*(?P<effort>[$A-Za-z_][\w$]*)\s*\}\)\s*=>\s*"
    r"(?P<valid>[$A-Za-z_][\w$]*)\(\s*(?P=effort)\s*\)\s*&&\s*"
    r"(?P<enabled>[$A-Za-z_][\w$]*)\.has\(\s*(?P=effort)\s*\)\s*\)"
)


def patch_filter_file(path: Path, *, enable_ultra: bool) -> tuple[bool, bool]:
    original = path.read_text(encoding="utf-8")
    text = original
    model_changed = False
    reasoning_changed = False

    match = MODEL_FILTER_RE.search(text)
    if match:
        replacement = f"if(!{match.group('item')}.hidden)"
        text = text[: match.start()] + replacement + text[match.end() :]
        model_changed = True
    elif not re.search(r"if\(\s*![$A-Za-z_][\w$]*\.hidden\s*\)", text):
        fail(f"Model allowlist condition was not found in {path.name}; the Desktop build may have changed")

    match = REASONING_FILTER_RE.search(text)
    if match:
        effort = match.group("effort")
        valid = match.group("valid")
        predicate = f"{valid}({effort})"
        if not enable_ultra:
            predicate += f"&&{effort}!==`ultra`"
        replacement = f".filter(({{reasoningEffort:{effort}}})=>{predicate})"
        text = text[: match.start()] + replacement + text[match.end() :]
        reasoning_changed = True
    else:
        has_patched_filter = "reasoningEffort" in text and (
            "!==`ultra`" in text or (enable_ultra and ".has(" not in text)
        )
        if not has_patched_filter:
            fail(f"Reasoning allowlist condition was not found in {path.name}; the Desktop build may have changed")

    if text != original:
        path.write_text(text, encoding="utf-8")
    return model_changed, reasoning_changed


def find_and_patch_webview(extracted: Path, *, enable_ultra: bool) -> Path:
    assets = extracted / "webview" / "assets"
    if not assets.exists():
        fail("The extracted app.asar does not contain webview/assets")

    exact_matches: list[Path] = []
    patched_matches: list[Path] = []
    for path in assets.glob("*.js"):
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if "includeUltraReasoningEffort" not in text or "supportedReasoningEfforts" not in text:
            continue
        if MODEL_FILTER_RE.search(text) and REASONING_FILTER_RE.search(text):
            exact_matches.append(path)
        elif (
            "hasModelSupportingMaxReasoningEffort" in text
            and re.search(r"if\(\s*![$A-Za-z_][\w$]*\.hidden\s*\)", text)
        ):
            patched_matches.append(path)

    matches = exact_matches or patched_matches

    if len(matches) != 1:
        names = ", ".join(path.name for path in matches) or "none"
        fail(f"Expected one model filter bundle, found {len(matches)}: {names}")

    model_changed, reasoning_changed = patch_filter_file(matches[0], enable_ultra=enable_ultra)
    log(
        f"Patched {matches[0].name}: model_allowlist={model_changed}, "
        f"reasoning_allowlist={reasoning_changed}, ultra={enable_ultra}"
    )
    return matches[0]


def unpack_entries(asar: Path) -> set[str]:
    result = asar_run(["list", str(asar), "--is-pack"], timeout=300)
    entries: set[str] = set()
    for line in result.stdout.splitlines():
        if not line.startswith("unpack :"):
            continue
        archive_path = line.split(":", 1)[1].strip().lstrip("\\/").replace("\\", "/")
        if archive_path:
            entries.add(archive_path)
    return entries


def derive_unpack_rules(entries: set[str]) -> tuple[str | None, str | None]:
    if not entries:
        return None, None
    file_extensions = sorted(
        {
            Path(entry).suffix.lower().lstrip(".")
            for entry in entries
            if Path(entry).suffix.lower() in {".node", ".dll", ".exe", ".so", ".dylib"}
        }
    )
    unpack_expression = None
    if file_extensions:
        unpack_expression = (
            f"**/*.{file_extensions[0]}"
            if len(file_extensions) == 1
            else "**/*.{" + ",".join(file_extensions) + "}"
        )

    directories = sorted(
        entry
        for entry in entries
        if any(candidate.startswith(entry + "/") for candidate in entries)
        and ("/" not in entry or entry.rsplit("/", 1)[0] not in entries)
    )
    unpack_dir_expression = None
    if directories:
        unpack_dir_expression = (
            directories[0]
            if len(directories) == 1
            else "{" + ",".join(directories) + "}"
        )
    return unpack_expression, unpack_dir_expression


def pack_asar(extracted: Path, source_asar: Path, output_asar: Path) -> Path | None:
    entries = unpack_entries(source_asar)
    unpack_expression, unpack_dir_expression = derive_unpack_rules(entries)
    arguments = ["pack"]
    if unpack_expression:
        arguments.extend(["--unpack", unpack_expression])
    if unpack_dir_expression:
        arguments.extend(["--unpack-dir", unpack_dir_expression])
    if entries:
        log(f"Preserve {len(entries)} original unpacked ASAR entries")
    arguments.extend([str(extracted), str(output_asar)])
    asar_run(arguments, timeout=900)
    generated_entries = unpack_entries(output_asar)
    if generated_entries != entries:
        missing = sorted(entries - generated_entries)
        extra = sorted(generated_entries - entries)
        fail(
            "Repacked app.asar did not preserve native-module unpack metadata. "
            f"Missing={missing[:5]}, Extra={extra[:5]}"
        )
    unpacked = output_asar.with_name(output_asar.name + ".unpacked")
    return unpacked if unpacked.exists() else None


def merge_tree(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    shutil.copytree(source, destination, dirs_exist_ok=True, symlinks=True)


def patch_asar(layout: AppLayout, *, enable_ultra: bool, temp_root: Path) -> Path:
    """Patch one archived JS file in place without rebuilding ASAR metadata.

    Repacking recent ChatGPT ASARs is unsafe because they contain hundreds of
    selectively unpacked native-module entries. An equal-length byte replacement
    preserves the original ASAR header, offsets and app.asar.unpacked layout.
    """
    if not layout.asar or not layout.asar.exists():
        fail(f"app.asar not found in copied application: {layout.asar}")

    extract_dir = temp_root / "app-asar"
    asar_run(["extract", str(layout.asar), str(extract_dir)], timeout=900)
    filter_file = find_and_patch_webview(extract_dir, enable_ultra=enable_ultra)
    relative_filter = filter_file.relative_to(extract_dir)

    original_extract = temp_root / "app-asar-original"
    asar_run(["extract", str(layout.asar), str(original_extract)], timeout=900)
    original_file = original_extract / relative_filter
    original_bytes = original_file.read_bytes()
    patched_bytes = filter_file.read_bytes()
    if len(patched_bytes) > len(original_bytes):
        fail(
            f"Patched bundle grew by {len(patched_bytes) - len(original_bytes)} bytes; "
            "cannot safely preserve ASAR offsets"
        )
    patched_bytes += b" " * (len(original_bytes) - len(patched_bytes))

    archive_bytes = layout.asar.read_bytes()
    occurrences = archive_bytes.count(original_bytes)
    if occurrences != 1:
        fail(f"Expected one archived copy of {relative_filter}, found {occurrences}")
    patched_archive_bytes = archive_bytes.replace(original_bytes, patched_bytes, 1)
    original_backup = layout.asar.with_name("app.asar.original")
    if not original_backup.exists():
        shutil.copy2(layout.asar, original_backup)
    versioned_backup = backup_file(layout.asar)
    staged_asar = layout.asar.with_name(f".{layout.asar.name}.gpt56-new-{os.getpid()}")
    restore_asar = layout.asar.with_name(f".{layout.asar.name}.gpt56-restore-{os.getpid()}")
    replaced = False
    try:
        staged_asar.write_bytes(patched_archive_bytes)
        shutil.copystat(layout.asar, staged_asar)
        os.replace(staged_asar, layout.asar)
        replaced = True

        verify_dir = temp_root / "verify-asar"
        asar_run(["extract", str(layout.asar), str(verify_dir)], timeout=900)
        verified = verify_dir / relative_filter
        if not verified.is_file():
            fail("Patched model filter bundle was not found after in-place ASAR update")
        verified_text = verified.read_text(encoding="utf-8")
        if MODEL_FILTER_RE.search(verified_text):
            fail("Model account allowlist condition still exists after in-place update")
        if REASONING_FILTER_RE.search(verified_text):
            fail("Reasoning account allowlist condition still exists after in-place update")
        if not enable_ultra and "!==`ultra`" not in verified_text:
            fail("Ultra exclusion is missing from the patched bundle")
    except Exception:
        if replaced and versioned_backup and versioned_backup.exists():
            shutil.copy2(versioned_backup, restore_asar)
            os.replace(restore_asar, layout.asar)
            log(f"Restored app.asar from backup after failed verification: {versioned_backup}")
        raise
    finally:
        for leftover in (staged_asar, restore_asar):
            try:
                if leftover.exists():
                    leftover.unlink()
            except OSError:
                pass
    log("app.asar in-place verification passed; original native-module layout preserved")
    return filter_file


def codex_home() -> Path:
    return expand(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))


def read_catalog_setting(config_path: Path) -> str | None:
    if not config_path.exists():
        return None
    text = config_path.read_text(encoding="utf-8")
    match = re.search(r'(?m)^\s*model_catalog_json\s*=\s*["\']([^"\']+)["\']\s*$', text)
    return match.group(1) if match else None


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def set_toml_string_value(text: str, key: str, value: str) -> tuple[str, bool]:
    line = f"{key} = {toml_string(value)}"
    pattern = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
    if pattern.search(text):
        updated = pattern.sub(line, text, count=1)
    else:
        updated = line + "\n" + text
    return updated, updated != text


def set_catalog_setting(config_path: Path, value: str) -> None:
    text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    text, _ = set_toml_string_value(text, "model_catalog_json", value)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(text, encoding="utf-8")


def locate_cli(layout: AppLayout) -> Path | None:
    candidates = []
    if platform_name() == "windows":
        candidates.extend([layout.root / "resources" / "codex.exe"])
        local_app_data = os.environ.get("LOCALAPPDATA")
        if local_app_data:
            runtime_candidates = [
                Path(value)
                for value in glob.glob(str(Path(local_app_data) / "OpenAI" / "Codex" / "bin" / "*" / "codex.exe"))
            ]
            runtime_candidates = [path for path in runtime_candidates if path.is_file()]
            runtime_candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
            candidates.extend(runtime_candidates)
    elif platform_name() == "macos":
        candidates.extend([layout.root / "Contents" / "Resources" / "codex"])
    else:
        candidates.extend([layout.root / "resources" / "codex", layout.root / "usr" / "bin" / "codex"])
    system_cli = shutil.which("codex")
    if system_cli:
        candidates.append(Path(system_cli))
    return next((path for path in candidates if path.is_file()), None)


def load_or_create_catalog(catalog_path: Path, cli: Path | None) -> dict[str, Any]:
    if catalog_path.exists():
        data = json.loads(catalog_path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or not isinstance(data.get("models"), list):
            fail(f"Invalid model catalog shape: {catalog_path}")
        return data

    if not cli:
        fail("No existing model catalog and no Codex CLI was found to generate a base catalog")
    result = run([str(cli), "debug", "models"], timeout=120)
    data = json.loads(result.stdout)
    if not isinstance(data, dict) or not isinstance(data.get("models"), list):
        fail("codex debug models did not return a model catalog")
    return data


def select_template(models: list[dict[str, Any]]) -> dict[str, Any]:
    preferred = ["gpt-5.5", "gpt-5.4", "gpt-5.3-codex"]
    for slug in preferred:
        for model in models:
            if model.get("slug") == slug:
                return model
    for model in models:
        if isinstance(model.get("supported_reasoning_levels"), list):
            return model
    fail("The catalog does not contain a reusable reasoning model template")


def effort_options(*, enable_ultra: bool) -> list[dict[str, str]]:
    efforts = ["low", "medium", "high", "xhigh", "max"]
    if enable_ultra:
        efforts.append("ultra")
    return [
        {"effort": effort, "description": EFFORT_DESCRIPTIONS[effort]}
        for effort in efforts
    ]


def update_catalog(
    catalog_path: Path,
    *,
    tiers: list[str],
    enable_ultra: bool,
    cli: Path | None,
    dry_run: bool,
) -> None:
    data = load_or_create_catalog(catalog_path, cli)
    models: list[dict[str, Any]] = data["models"]
    template = select_template(models)
    priorities = [model.get("priority", 0) for model in models if isinstance(model.get("priority"), int)]
    next_priority = max(priorities, default=1000) + 1

    for tier in tiers:
        slug, display_name = MODEL_TIERS[tier]
        model = next((item for item in models if item.get("slug") == slug), None)
        if model is None:
            model = copy.deepcopy(template)
            models.append(model)
            model["priority"] = next_priority
            next_priority += 1
        existing_efforts = {
            item.get("effort")
            for item in model.get("supported_reasoning_levels", [])
            if isinstance(item, dict)
        }
        desired_efforts = {item["effort"] for item in effort_options(enable_ultra=enable_ultra)}
        if model.get("visibility") == "list" and model.get("display_name") == display_name:
            if desired_efforts.issubset(existing_efforts):
                log(f"Catalog entry already current: {slug}")
        model.update(
            {
                "slug": slug,
                "display_name": display_name,
                "description": display_name,
                "visibility": "list",
                "supported_in_api": True,
                "upgrade": None,
                "supported_reasoning_levels": effort_options(enable_ultra=enable_ultra),
            }
        )

    log(f"Catalog models updated: {', '.join(MODEL_TIERS[tier][0] for tier in tiers)}")
    if dry_run:
        return
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    if catalog_path.exists():
        shutil.copy2(catalog_path, catalog_path.with_name(f"{catalog_path.name}.backup-{timestamp()}"))
    catalog_path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def resolve_catalog_path(explicit: str | None, config_path: Path) -> tuple[Path, bool]:
    if explicit:
        return expand(explicit), False
    configured = read_catalog_setting(config_path)
    if configured:
        candidate = Path(os.path.expanduser(os.path.expandvars(configured)))
        if not candidate.is_absolute():
            candidate = config_path.parent / candidate
        return candidate.resolve(), False
    return (config_path.parent / "model_catalog.json").resolve(), True


def active_model_provider(text: str) -> str | None:
    match = re.search(r'(?m)^\s*model_provider\s*=\s*["\']([^"\']+)["\']\s*$', text)
    return match.group(1) if match else None


def provider_section_bounds(text: str, provider: str) -> tuple[int, int] | None:
    header = re.compile(rf'(?m)^\s*\[model_providers\.{re.escape(provider)}\]\s*$')
    match = header.search(text)
    if not match:
        return None
    next_section = re.search(r'(?m)^\s*\[[^\]]+\]\s*$', text[match.end() :])
    end = match.end() + next_section.start() if next_section else len(text)
    return match.start(), end


def section_value(section: str, key: str) -> str | None:
    match = re.search(rf'(?m)^\s*{re.escape(key)}\s*=\s*["\']([^"\']*)["\']\s*(?:#.*)?$', section)
    return match.group(1) if match else None


def insert_after_section_header(section: str, line: str) -> str:
    header_end = section.find("\n")
    if header_end < 0:
        return section + "\n" + line + "\n"
    return section[: header_end + 1] + line + "\n" + section[header_end + 1 :]


def set_section_string_value(section: str, key: str, value: str, *, force: bool) -> tuple[str, bool]:
    pattern = re.compile(
        rf'(?m)^(\s*{re.escape(key)}\s*=\s*)(["\'])([^"\']*)(["\'])(\s*(?:#.*)?)$'
    )
    if pattern.search(section):
        if not force:
            return section, False
        line_value = toml_string(value)

        def replace(match: re.Match[str]) -> str:
            return f"{match.group(1)}{line_value}{match.group(5)}"

        updated = pattern.sub(replace, section, count=1)
        return updated, updated != section
    updated = insert_after_section_header(section, f"{key} = {toml_string(value)}")
    return updated, True


def configure_default_provider_text(
    text: str,
    *,
    provider: str,
    base_url: str,
    force_provider: bool = False,
    force_base_url: bool = False,
) -> tuple[str, bool, str]:
    active = active_model_provider(text)
    if force_provider or not active or active.lower() in OFFICIAL_PROVIDERS:
        target_provider = provider
        text, root_changed = set_toml_string_value(text, "model_provider", target_provider)
    else:
        target_provider = active
        root_changed = False

    bounds = provider_section_bounds(text, target_provider)
    if not bounds:
        suffix = "" if not text or text.endswith("\n") else "\n"
        section = (
            f"\n[model_providers.{target_provider}]\n"
            f"name = {toml_string(target_provider)}\n"
            f"base_url = {toml_string(base_url)}\n"
            f"wire_api = {toml_string(DEFAULT_WIRE_API)}\n"
            f"env_key = {toml_string(DEFAULT_ENV_KEY)}\n"
            "requires_openai_auth = false\n"
        )
        return text + suffix + section, True, target_provider

    start, end = bounds
    section = text[start:end]
    section_changed = False
    existing_base_url = section_value(section, "base_url")
    should_force_base_url = force_base_url or not existing_base_url
    if existing_base_url and re.match(r"https://api\.openai\.com(?:/|$)", existing_base_url, re.I):
        should_force_base_url = True

    for key, value, force in [
        ("name", target_provider, False),
        ("base_url", base_url, should_force_base_url),
        ("wire_api", DEFAULT_WIRE_API, False),
        ("env_key", DEFAULT_ENV_KEY, False),
    ]:
        section, changed = set_section_string_value(section, key, value, force=force)
        section_changed = section_changed or changed

    if section_changed:
        text = text[:start] + section + text[end:]
    return text, root_changed or section_changed, target_provider


def enable_no_chatgpt_login_mode_text(text: str, provider: str | None = None) -> tuple[str, bool, str | None]:
    provider = provider or active_model_provider(text)
    if not provider or provider.lower() in OFFICIAL_PROVIDERS:
        return text, False, None
    bounds = provider_section_bounds(text, provider)
    if not bounds:
        fail(f"Active model provider section was not found: [model_providers.{provider}]")
    start, end = bounds
    section = text[start:end]
    base_match = re.search(r'(?m)^\s*base_url\s*=\s*["\']([^"\']+)["\']\s*$', section)
    if base_match and re.match(r"https://api\.openai\.com(?:/|$)", base_match.group(1), re.I):
        return text, False, None
    pattern = re.compile(r"(?m)^(\s*requires_openai_auth\s*=\s*)(?:true|false)(\s*(?:#.*)?)$")
    if pattern.search(section):
        updated = pattern.sub(r"\1false\2", section, count=1)
    else:
        updated = insert_after_section_header(section, "requires_openai_auth = false")
    if updated == section:
        return text, False, None
    return text[:start] + updated + text[end:], True, provider


def enable_no_chatgpt_login_mode(config_path: Path) -> bool:
    """Set requires_openai_auth=false only for the active non-OpenAI provider."""
    if not config_path.exists():
        return False
    text = config_path.read_text(encoding="utf-8")
    text, changed, provider = enable_no_chatgpt_login_mode_text(text)
    if not changed:
        return False
    config_path.write_text(text, encoding="utf-8")
    log(f"Enabled API-key/no-ChatGPT-login mode for provider: {provider}")
    return True


def update_default_model(config_path: Path, slug: str) -> None:
    text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    text, _ = set_toml_string_value(text, "model", slug)
    config_path.write_text(text, encoding="utf-8")


def read_json_lines(process: subprocess.Popen[str], output: queue.Queue[str]) -> None:
    assert process.stdout is not None
    for line in process.stdout:
        output.put(line.rstrip("\r\n"))


def app_server_probe(cli: Path, timeout: int = 45) -> tuple[dict[str, Any], dict[str, Any]]:
    process = subprocess.Popen(
        [str(cli), "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    assert process.stdin is not None
    lines: queue.Queue[str] = queue.Queue()
    thread = threading.Thread(target=read_json_lines, args=(process, lines), daemon=True)
    thread.start()

    requests = [
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {"name": "gpt56-patcher", "title": "GPT-5.6 Patcher", "version": "1.0.0"},
                "capabilities": {"experimentalApi": True},
            },
        },
        {"method": "initialized"},
        {"id": 2, "method": "account/read", "params": {}},
        {"id": 3, "method": "model/list", "params": {"includeHidden": False, "limit": 100}},
    ]
    for request in requests:
        process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()

    deadline = time.monotonic() + timeout
    responses: dict[int, dict[str, Any]] = {}
    try:
        while time.monotonic() < deadline and ({2, 3} - responses.keys()):
            try:
                line = lines.get(timeout=0.25)
            except queue.Empty:
                if process.poll() is not None:
                    break
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            message_id = message.get("id")
            if message_id in {2, 3}:
                responses[message_id] = message
    finally:
        try:
            process.stdin.close()
        except OSError:
            pass
        if process.poll() is None:
            process.kill()

    if {2, 3} - responses.keys():
        stderr = process.stderr.read() if process.stderr else ""
        fail(f"Timed out waiting for app-server account/read and model/list. {stderr.strip()}")
    for message_id, method in [(2, "account/read"), (3, "model/list")]:
        if "error" in responses[message_id]:
            fail(f"app-server {method} failed: {responses[message_id]['error']}")
    return responses[3]["result"], responses[2]["result"]


def app_server_model_list(cli: Path, timeout: int = 45) -> dict[str, Any]:
    result, _account = app_server_probe(cli, timeout=timeout)
    return result


def verify_catalog(
    cli: Path,
    *,
    tiers: list[str],
    enable_ultra: bool,
    require_no_chatgpt_login: bool = True,
) -> None:
    result, account = app_server_probe(cli)
    if require_no_chatgpt_login:
        if account.get("account") is not None:
            fail("Verification expected no ChatGPT account, but account/read returned a logged-in account")
        if account.get("requiresOpenaiAuth") is not False:
            fail("Active provider still requires ChatGPT/OpenAI login")
        log("Verified no-ChatGPT-login mode: account=null, requiresOpenaiAuth=false")
    by_model = {model["model"]: model for model in result.get("data", [])}
    expected_efforts = {"low", "medium", "high", "xhigh", "max"}
    if enable_ultra:
        expected_efforts.add("ultra")

    for tier in tiers:
        slug, display_name = MODEL_TIERS[tier]
        model = by_model.get(slug)
        if not model:
            fail(f"app-server model/list does not include {slug}")
        if model.get("hidden"):
            fail(f"app-server still marks {slug} as hidden")
        if model.get("displayName") != display_name:
            fail(f"Unexpected display name for {slug}: {model.get('displayName')}")
        efforts = {
            item.get("reasoningEffort")
            for item in model.get("supportedReasoningEfforts", [])
        }
        missing = expected_efforts - efforts
        if missing:
            fail(f"{slug} is missing reasoning efforts: {', '.join(sorted(missing))}")
        log(f"Verified {display_name}: {', '.join(sorted(efforts))}")


def sign_macos(app: Path) -> None:
    if platform_name() != "macos":
        return
    if not shutil.which("codesign"):
        fail("codesign was not found")
    run(["codesign", "--force", "--deep", "--sign", "-", str(app)], timeout=300)
    if shutil.which("xattr"):
        run(["xattr", "-cr", str(app)], timeout=120)
    log("Applied ad-hoc macOS signature and cleared quarantine")


def stop_desktop_processes() -> None:
    system = platform_name()
    log("Closing running Codex/ChatGPT Desktop processes")
    if system == "windows":
        for image in ["ChatGPT.exe", "Codex.exe"]:
            run(["taskkill", "/IM", image, "/T", "/F"], check=False, timeout=30)
        time.sleep(1)
        return
    for name in ["Codex", "ChatGPT"]:
        run(["pkill", "-x", name], check=False, timeout=30)
    time.sleep(1)


def write_marker(layout: AppLayout, filter_file: Path, enable_ultra: bool) -> None:
    marker = {
        "patch": PATCH_ID,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "platform": platform_name(),
        "filter_bundle": filter_file.name,
        "ultra_enabled": enable_ultra,
    }
    target = patch_marker_path(layout.root)
    target.write_text(json.dumps(marker, indent=2) + "\n", encoding="utf-8")


def launch_hint(layout: AppLayout) -> str:
    if platform_name() == "macos":
        return f'open "{layout.root}"'
    if layout.launcher:
        return f'"{layout.launcher}"'
    return str(layout.root)


def parse_tiers(value: str) -> list[str]:
    tiers = [item.strip().lower() for item in value.split(",") if item.strip()]
    unknown = sorted(set(tiers) - set(MODEL_TIERS))
    if unknown:
        fail(f"Unknown GPT-5.6 tiers: {', '.join(unknown)}")
    return list(dict.fromkeys(tiers))


def self_test() -> None:
    sample = (
        "function r({availableModels:n,models:o}){return o.forEach(r=>{"
        "if(u?n.has(r.model):!r.hidden){let n=r.supportedReasoningEfforts.filter("
        "({reasoningEffort:e})=>t(e)&&i.has(e));}})}"
    )
    with tempfile.TemporaryDirectory(prefix="codex-gpt56-selftest-") as temp:
        root = Path(temp)
        path = root / "model-list-filter-test.js"
        path.write_text(sample, encoding="utf-8")
        changed = patch_filter_file(path, enable_ultra=False)
        result = path.read_text(encoding="utf-8")
        assert changed == (True, True)
        assert "if(!r.hidden)" in result
        assert "e!==`ultra`" in result
        assert "i.has(e)" not in result

        # Regression: reruns must leave exactly one Finder-visible patched app.
        destination = root / "Applications" / "Codex-GPT56-Patched.app"
        destination.parent.mkdir(parents=True)

        def make_managed_app(app: Path, payload: str) -> None:
            marker = patch_marker_path(app)
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text(json.dumps({"patch": PATCH_ID}), encoding="utf-8")
            (app / "payload.txt").write_text(payload, encoding="utf-8")

        make_managed_app(destination, "old")
        make_managed_app(destination.with_name(destination.name + ".backup-20260710-120000"), "legacy")
        unmanaged = destination.with_name(destination.name + ".backup-manual")
        unmanaged.mkdir()
        cleanup_legacy_backups(destination)
        assert not destination.with_name(destination.name + ".backup-20260710-120000").exists()
        assert unmanaged.exists(), "Unrecognized user directories must never be deleted"

        staged = staging_path(destination)
        make_managed_app(staged, "new")
        install_staged_copy(staged, destination)
        assert (destination / "payload.txt").read_text(encoding="utf-8") == "new"
        assert not staged.exists()
        assert not destination.with_name(f".{destination.name}.previous").exists()
        visible_apps = [item for item in destination.parent.iterdir() if item.name.endswith(".app")]
        assert visible_apps == [destination], visible_apps
    log("Self-test passed")


def prompt_yes_no(question: str, *, default: bool) -> bool:
    suffix = "[Y/n]" if default else "[y/N]"
    yes_values = {"y", "yes", "1", "true", "t", "是", "好", "确定"}
    no_values = {"n", "no", "0", "false", "f", "否", "不"}
    while True:
        answer = input(f"{question} {suffix} ").strip().lower()
        if not answer:
            return default
        if answer in yes_values:
            return True
        if answer in no_values:
            return False
        print("Please answer y or n.")


def prompt_text(question: str, *, default: str | None = None) -> str:
    if default:
        answer = input(f"{question}\n  Default: {default}\n> ").strip()
        return answer or default
    while True:
        answer = input(f"{question}\n> ").strip()
        if answer:
            return answer
        print("This value cannot be empty.")


def guided_setup(args: argparse.Namespace) -> bool:
    if not sys.stdin.isatty():
        log("Guided mode requested, but stdin is not interactive; continuing with default answers.")
        args.yes = True
        return True

    log("Guided setup started. Press Enter to accept the default in brackets.")
    if not args.catalog_only and not args.desktop_only:
        if not prompt_yes_no("Patch Desktop UI as well as model config?", default=True):
            args.catalog_only = True

    detected_layout: AppLayout | None = None
    if not args.catalog_only:
        if args.app:
            detected_layout = detect_layout(args.app)
            log(f"Using source app from --app: {detected_layout.root}")
        else:
            try:
                detected_layout = detect_layout(None)
                if prompt_yes_no(f"Detected source app:\n  {detected_layout.root}\nUse this install directory?", default=True):
                    args.app = str(detected_layout.root)
                else:
                    args.app = prompt_text("Enter the Codex/Codex.app/AppImage/app.asar source path")
                    detected_layout = detect_layout(args.app)
            except RuntimeError as exc:
                log(str(exc))
                args.app = prompt_text("Enter the Codex/Codex.app/AppImage/app.asar source path")
                detected_layout = detect_layout(args.app)

        if args.output:
            log(f"Using patched clone path from --output: {expand(args.output)}")
        else:
            assert detected_layout is not None
            default_destination = default_output(detected_layout)
            if prompt_yes_no(f"Create/update the patched Codex clone here?\n  {default_destination}", default=True):
                args.output = str(default_destination)
            else:
                args.output = prompt_text("Enter the new patched clone install path", default=str(default_destination))
            log(f"Patched clone install path: {expand(args.output)}")

    if not args.desktop_only and not args.skip_provider_config:
        provider_name = args.provider or DEFAULT_PROVIDER
        provider_base_url = args.base_url or DEFAULT_BASE_URL
        if prompt_yes_no(
            f"Configure API-key provider '{provider_name}' with base_url?\n  {provider_base_url}",
            default=True,
        ):
            args.provider = provider_name
            if not args.base_url:
                if prompt_yes_no(f"Use default relay base_url?\n  {DEFAULT_BASE_URL}", default=True):
                    args.base_url = DEFAULT_BASE_URL
                else:
                    args.base_url = prompt_text("Enter custom base_url", default=DEFAULT_BASE_URL)
        else:
            args.skip_provider_config = True

        if args.enable_ultra and not prompt_yes_no("Show Ultra reasoning effort in the model picker?", default=True):
            args.enable_ultra = False

    if not prompt_yes_no("Start now?", default=True):
        log("Cancelled")
        return False
    args.yes = True
    return True


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Create a separate Codex Desktop copy that shows third-party GPT-5.6 models and Max reasoning."
    )
    parser.add_argument("--app", help="Official app, AppImage, executable, app directory, or app.asar path")
    parser.add_argument("--output", help="Destination for the separate patched application")
    parser.add_argument("--catalog", help="Explicit Codex model catalog JSON path")
    parser.add_argument("--guided", action="store_true", help="Start a beginner-friendly interactive setup")
    parser.add_argument("--tiers", default="sol,terra,luna", help="Comma-separated tiers: sol,terra,luna")
    parser.add_argument(
        "--default-model",
        choices=["keep", "sol", "terra", "luna"],
        default="sol",
        help="Default to GPT-5.6 Sol; use keep to preserve the existing model",
    )
    parser.add_argument(
        "--enable-ultra",
        dest="enable_ultra",
        action="store_true",
        help="Accepted for compatibility; Ultra is enabled by default.",
    )
    parser.add_argument(
        "--disable-ultra",
        dest="enable_ultra",
        action="store_false",
        help="Hide Ultra for providers that reject reasoning.effort=ultra. Full mode enables it by default.",
    )
    parser.set_defaults(enable_ultra=True)
    parser.add_argument("--desktop-only", action="store_true", help="Patch app.asar but do not update the model catalog")
    parser.add_argument("--catalog-only", action="store_true", help="Update the catalog but do not copy or patch Desktop")
    parser.add_argument("--provider", help=f"Model provider name to create or activate; default is {DEFAULT_PROVIDER}")
    parser.add_argument("--base-url", help=f"Provider base_url to write when creating or explicitly updating a provider; default is {DEFAULT_BASE_URL}")
    parser.add_argument("--skip-provider-config", action="store_true", help="Do not create or update model_provider/base_url settings")
    parser.add_argument("--dry-run", action="store_true", help="Detect and report without writing changes")
    parser.add_argument("--yes", action="store_true", help="Run without an interactive confirmation")
    parser.add_argument("--verify-only", action="store_true", help="Verify an existing patched application and catalog")
    parser.add_argument("--self-test", action="store_true", help="Run patch pattern tests and exit")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.desktop_only and args.catalog_only:
        fail("--desktop-only and --catalog-only cannot be used together")
    if args.guided and not args.verify_only and not guided_setup(args):
        return 1
    if args.enable_ultra:
        log("Full reasoning mode enabled: low, medium, high, xhigh, max, ultra. Provider must accept the selected effort.")

    tiers = parse_tiers(args.tiers)
    config_path = codex_home() / "config.toml"
    catalog_path, needs_catalog_setting = resolve_catalog_path(args.catalog, config_path)

    if args.verify_only:
        layout = detect_layout(args.app or args.output, prefer_patched=True)
        cli = locate_cli(layout)
        if not cli:
            fail("Codex CLI was not found in the patched application")
        verify_catalog(cli, tiers=tiers, enable_ultra=args.enable_ultra)
        log("Verification passed")
        return 0

    layout: AppLayout | None = None
    destination: Path | None = None
    if not args.catalog_only:
        layout = detect_layout(args.app)
        destination = expand(args.output) if args.output else default_output(layout)
        log(f"Platform: {platform_name()}")
        log(f"Official app: {layout.root}")
        log(f"Patched copy: {destination}")
    log(f"Model catalog: {catalog_path}")

    if args.dry_run:
        log("Dry run complete; no files were changed")
        return 0

    if not args.yes:
        answer = input("Create/update the separate GPT-5.6 patched copy? [y/N] ").strip().lower()
        if answer not in {"y", "yes"}:
            log("Cancelled")
            return 1

    patched_layout: AppLayout | None = None
    temp_root = create_temp_root()
    try:
        if layout and destination:
            stop_desktop_processes()
            destination.parent.mkdir(parents=True, exist_ok=True)
            cleanup_legacy_backups(destination)
            staged = staging_path(destination)
            if staged.exists():
                if is_managed_patched_copy(staged):
                    remove_managed_copy(staged)
                else:
                    fail(f"Staging path already exists and is not managed by this patcher: {staged}")
            patched_layout = copy_layout(layout, staged, temp_root)
            filter_file = patch_asar(patched_layout, enable_ultra=args.enable_ultra, temp_root=temp_root)
            write_marker(patched_layout, filter_file, args.enable_ultra)
            sign_macos(patched_layout.root)
            install_staged_copy(staged, destination)
            patched_layout.root = destination
            if patched_layout.asar:
                patched_layout.asar = destination / patched_layout.asar.relative_to(staged)
            if patched_layout.launcher:
                patched_layout.launcher = destination / patched_layout.launcher.relative_to(staged)

        cli = locate_cli(patched_layout) if patched_layout else None
        if not args.desktop_only:
            update_catalog(
                catalog_path,
                tiers=tiers,
                enable_ultra=args.enable_ultra,
                cli=cli or (locate_cli(layout) if layout else None),
                dry_run=False,
            )
            config_text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
            updated_config = config_text
            if needs_catalog_setting:
                updated_config, _ = set_toml_string_value(updated_config, "model_catalog_json", str(catalog_path))
            configured_provider: str | None = None
            provider_changed = False
            if not args.skip_provider_config:
                provider_name = (args.provider or DEFAULT_PROVIDER).strip()
                base_url = (args.base_url or DEFAULT_BASE_URL).strip()
                if not provider_name:
                    fail("--provider cannot be empty")
                if not base_url:
                    fail("--base-url cannot be empty")
                updated_config, provider_changed, configured_provider = configure_default_provider_text(
                    updated_config,
                    provider=provider_name,
                    base_url=base_url,
                    force_provider=args.provider is not None,
                    force_base_url=args.base_url is not None,
                )
            updated_config, no_login_changed, no_login_provider = enable_no_chatgpt_login_mode_text(
                updated_config,
                configured_provider,
            )
            if args.default_model != "keep":
                updated_config, _ = set_toml_string_value(updated_config, "model", MODEL_TIERS[args.default_model][0])
            if updated_config != config_text:
                backup_file(config_path)
                config_path.parent.mkdir(parents=True, exist_ok=True)
                config_path.write_text(updated_config, encoding="utf-8")
                if needs_catalog_setting:
                    log(f"Added model_catalog_json to {config_path}")
                if provider_changed:
                    log(f"Model provider ready: {configured_provider}")
                if no_login_changed:
                    log(f"Enabled API-key/no-ChatGPT-login mode for provider: {no_login_provider}")
                if args.default_model != "keep":
                    log(f"Default model set to {MODEL_TIERS[args.default_model][0]}")

        verification_cli = cli or (locate_cli(layout) if layout else None)
        if verification_cli and not args.desktop_only:
            verify_catalog(verification_cli, tiers=tiers, enable_ultra=args.enable_ultra)
        elif not args.desktop_only:
            log("WARNING: Codex CLI not found; app-server model/list verification was skipped")
    finally:
        remove_temp_root(temp_root)

    if patched_layout:
        log("Patch completed")
        log(f"Launch the patched app with: {launch_hint(patched_layout)}")
    else:
        log("Catalog update completed")
    if not args.enable_ultra:
        log("Ultra was disabled explicitly; low through max remain available.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nCancelled", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"[codex-gpt56] ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
