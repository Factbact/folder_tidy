from __future__ import annotations

import argparse
import ast
import json
import logging
import os
import re
import shutil
import sys
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.11+ has tomllib
    try:  # pragma: no cover - optional dependency
        import tomli as tomllib
    except ModuleNotFoundError:  # pragma: no cover - fallback parser is used
        tomllib = None

APP_NAME = "downloads-organize"
DEFAULT_UNDO_DIR = Path("~/.downloads-organize/undos").expanduser()
DEFAULT_IGNORE_EXTENSIONS: set[str] = {
    ".crdownload",
    ".part",
    ".partial",
    ".download",
    ".opdownload",
    ".!qb",
    ".tmp",
}
BUNDLE_SUFFIXES = (".app", ".bundle", ".framework", ".plugin")


@dataclass
class Condition:
    type: str
    value: Any


@dataclass
class Rule:
    rule_id: str
    description: str
    subfolder: str
    enabled: bool
    built_in: bool
    mode: str = "all"
    conditions: list[Condition] = field(default_factory=list)


@dataclass
class ItemInfo:
    path: Path
    relative_path: Path
    name: str
    is_dir: bool
    is_symlink: bool
    size_bytes: int
    created_at: datetime
    has_tag: bool

    @property
    def lower_name(self) -> str:
        return self.name.lower()


@dataclass
class MovePlan:
    source: Path
    destination: Path
    rule_id: str
    rule_description: str
    collision_renamed: bool = False


@dataclass
class TidySummary:
    scanned: int = 0
    ignored: int = 0
    total_targets: int = 0
    matched: int = 0
    unclassified: int = 0
    fallback_mime: int = 0
    rule_hits: dict[str, int] = field(default_factory=dict)
    planned_moves: int = 0
    moved: int = 0
    collisions: int = 0
    errors: int = 0
    rules_used: int = 0


@dataclass
class PriorityOptimizationReport:
    enabled: bool = False
    strategy: str = "specificity_v1"
    changed: bool = False
    before_order: list[str] = field(default_factory=list)
    after_order: list[str] = field(default_factory=list)
    scores: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class UndoResult:
    restored: int = 0
    collisions: int = 0
    errors: int = 0


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def normalize_identifier(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.strip().lower()).strip("_")


def normalize_extension(raw_extension: str) -> str:
    ext = raw_extension.strip().lower()
    if not ext:
        raise ValueError("extension cannot be empty")
    if not ext.startswith("."):
        ext = f".{ext}"
    return ext


def dedupe(items: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def matches_extension(filename: str, extensions: Iterable[str]) -> bool:
    lower_name = filename.lower()
    best_match: str | None = None
    for ext in extensions:
        normalized = normalize_extension(ext)
        if lower_name.endswith(normalized):
            if best_match is None or len(normalized) > len(best_match):
                best_match = normalized
    return best_match is not None


def ensure_unix_subfolder(path_fragment: str) -> str:
    cleaned = path_fragment.strip().strip("/")
    if not cleaned:
        raise ValueError("subfolder cannot be empty")
    return cleaned


def split_base_and_suffix(filename: str) -> tuple[str, str]:
    path = Path(filename)
    suffix = "".join(path.suffixes)
    if suffix and filename.lower().endswith(suffix.lower()):
        base = filename[: -len(suffix)]
    else:
        base = filename
    if not base:
        base = filename
        suffix = ""
    return base, suffix


def resolve_collision(target: Path, occupied_targets: set[Path]) -> tuple[Path, bool]:
    if not target.exists() and target not in occupied_targets:
        return target, False

    base, suffix = split_base_and_suffix(target.name)
    index = 1
    while True:
        candidate = target.with_name(f"{base} ({index}){suffix}")
        if not candidate.exists() and candidate not in occupied_targets:
            return candidate, True
        index += 1


def has_finder_tag(path: Path) -> bool:
    if not hasattr(os, "listxattr"):  # pragma: no cover - platform-dependent
        return False
    try:
        attrs = os.listxattr(path)
    except OSError:  # pragma: no cover - platform-dependent
        return False
    return "com.apple.metadata:_kMDItemUserTags" in attrs


def make_rule(
    *,
    rule_id: str,
    description: str,
    subfolder: str,
    enabled: bool,
    built_in: bool,
    mode: str = "all",
    conditions: list[Condition],
) -> Rule:
    return Rule(
        rule_id=normalize_identifier(rule_id),
        description=description.strip(),
        subfolder=ensure_unix_subfolder(subfolder),
        enabled=enabled,
        built_in=built_in,
        mode=mode,
        conditions=conditions,
    )


def ext_condition(*extensions: str) -> Condition:
    return Condition("extension_any", [normalize_extension(ext) for ext in extensions])


def kind_condition(kind: str) -> Condition:
    return Condition("kind", kind.strip().lower())


def built_in_rules() -> list[Rule]:
    # 22 built-in rules. Folders/Aliases default to disabled.
    return [
        make_rule(
            rule_id="aliases",
            description="Aliases",
            subfolder="Aliases",
            enabled=False,
            built_in=True,
            conditions=[Condition("is_alias", True)],
        ),
        make_rule(
            rule_id="folders",
            description="Folders",
            subfolder="Folders",
            enabled=False,
            built_in=True,
            conditions=[Condition("is_folder", True)],
        ),
        make_rule(
            rule_id="screenshots",
            description="Screenshots",
            subfolder="Screenshots",
            enabled=True,
            built_in=True,
            mode="all",
            conditions=[
                kind_condition("image"),
                Condition("name_contains", ["screenshot", "screen shot", "スクリーンショット"]),
            ],
        ),
        make_rule(
            rule_id="png_images",
            description="PNG Images",
            subfolder="Images/PNG",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".png")],
        ),
        make_rule(
            rule_id="jpeg_images",
            description="JPEG Images",
            subfolder="Images/JPEG",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".jpg", ".jpeg")],
        ),
        make_rule(
            rule_id="gif_images",
            description="GIF Images",
            subfolder="Images/GIF",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".gif")],
        ),
        make_rule(
            rule_id="web_images",
            description="Web Images",
            subfolder="Images/Web",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".webp", ".svg", ".avif")],
        ),
        make_rule(
            rule_id="other_images",
            description="Other Images",
            subfolder="Images/Other",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".bmp", ".heic", ".tif", ".tiff", ".ico", ".jfif")],
        ),
        make_rule(
            rule_id="pdf_documents",
            description="PDF Documents",
            subfolder="Documents/PDF",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".pdf")],
        ),
        make_rule(
            rule_id="word_documents",
            description="Word Documents",
            subfolder="Documents/Word",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".doc", ".docx", ".odt", ".pages", ".rtf", ".epub")],
        ),
        make_rule(
            rule_id="plain_text",
            description="Plain Text",
            subfolder="Documents/Text",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".txt", ".text")],
        ),
        make_rule(
            rule_id="markdown",
            description="Markdown",
            subfolder="Documents/Markdown",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".md", ".markdown")],
        ),
        make_rule(
            rule_id="spreadsheets",
            description="Spreadsheets",
            subfolder="Documents/Spreadsheets",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".xls", ".xlsx", ".csv", ".tsv", ".ods", ".numbers")],
        ),
        make_rule(
            rule_id="presentations",
            description="Presentations",
            subfolder="Documents/Presentations",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".ppt", ".pptx", ".pps", ".ppsx", ".key", ".odp")],
        ),
        make_rule(
            rule_id="code",
            description="Code",
            subfolder="Code",
            enabled=True,
            built_in=True,
            conditions=[
                ext_condition(
                    ".py",
                    ".js",
                    ".ts",
                    ".tsx",
                    ".jsx",
                    ".java",
                    ".c",
                    ".cpp",
                    ".h",
                    ".hpp",
                    ".go",
                    ".rs",
                    ".rb",
                    ".php",
                    ".swift",
                    ".kt",
                    ".json",
                    ".sql",
                    ".ini",
                    ".cfg",
                    ".conf",
                    ".toml",
                    ".yaml",
                    ".yml",
                    ".xml",
                    ".html",
                    ".css",
                    ".scss",
                    ".sh",
                    ".zsh",
                )
            ],
        ),
        make_rule(
            rule_id="audio",
            description="Audio",
            subfolder="Audio",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".aif", ".aiff")],
        ),
        make_rule(
            rule_id="videos",
            description="Videos",
            subfolder="Videos",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".mp4", ".mov", ".mkv", ".avi", ".wmv", ".webm", ".m4v", ".ts", ".mts")],
        ),
        make_rule(
            rule_id="archives",
            description="Archives",
            subfolder="Archives",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".zip", ".rar", ".7z", ".tar", ".gz", ".tar.gz", ".tgz", ".bz2", ".xz", ".zst", ".cab")],
        ),
        make_rule(
            rule_id="disk_images",
            description="Disk Images",
            subfolder="Disk Images",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".dmg", ".iso", ".img")],
        ),
        make_rule(
            rule_id="installers",
            description="Installers",
            subfolder="Installers",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".pkg", ".msi", ".exe", ".deb", ".rpm", ".apk")],
        ),
        make_rule(
            rule_id="fonts",
            description="Fonts",
            subfolder="Fonts",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".ttf", ".ttc", ".otf", ".woff", ".woff2")],
        ),
        make_rule(
            rule_id="torrents",
            description="Torrents",
            subfolder="Torrents",
            enabled=True,
            built_in=True,
            conditions=[ext_condition(".torrent")],
        ),
    ]


def build_kind_extensions() -> dict[str, set[str]]:
    return {
        "image": {
            ".png",
            ".jpg",
            ".jpeg",
            ".gif",
            ".webp",
            ".svg",
            ".avif",
            ".bmp",
            ".heic",
            ".tif",
            ".tiff",
            ".ico",
            ".jfif",
        },
        "image_png": {".png"},
        "document": {".pdf", ".doc", ".docx", ".odt", ".pages", ".txt", ".rtf", ".md", ".markdown", ".epub"},
        "audio": {".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".aif", ".aiff"},
        "video": {".mp4", ".mov", ".mkv", ".avi", ".wmv", ".webm", ".m4v", ".ts", ".mts"},
        "archive": {".zip", ".rar", ".7z", ".tar", ".gz", ".tar.gz", ".tgz", ".bz2", ".xz", ".zst", ".cab"},
        "code": {
            ".py",
            ".js",
            ".ts",
            ".tsx",
            ".jsx",
            ".java",
            ".c",
            ".cpp",
            ".h",
            ".hpp",
            ".go",
            ".rs",
            ".rb",
            ".php",
            ".swift",
            ".kt",
            ".json",
            ".sql",
            ".ini",
            ".cfg",
            ".conf",
            ".toml",
            ".yaml",
            ".yml",
            ".xml",
            ".html",
            ".css",
            ".scss",
            ".sh",
            ".zsh",
        },
    }


def default_config_data() -> dict[str, Any]:
    return {}


def parse_toml_fallback_value(value: str) -> Any:
    text = value.strip()
    lower = text.lower()
    if lower == "true":
        return True
    if lower == "false":
        return False
    if lower in {"null", "none"}:
        return None

    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        return [parse_toml_fallback_value(part) for part in split_top_level(inner, ",")]

    if text.startswith("{") and text.endswith("}"):
        inner = text[1:-1].strip()
        if not inner:
            return {}
        table: dict[str, Any] = {}
        for part in split_top_level(inner, ","):
            if "=" not in part:
                raise ValueError("invalid inline table entry")
            key, raw = part.split("=", 1)
            table[key.strip()] = parse_toml_fallback_value(raw)
        return table

    if (text.startswith('"') and text.endswith('"')) or (text.startswith("'") and text.endswith("'")):
        return ast.literal_eval(text)

    if re.fullmatch(r"[+-]?\d+", text):
        return int(text)
    if re.fullmatch(r"[+-]?\d+\.\d+", text):
        return float(text)

    # Bare words become strings for practicality.
    return text


def split_top_level(text: str, separator: str) -> list[str]:
    result: list[str] = []
    current: list[str] = []
    quote: str | None = None
    depth_bracket = 0
    depth_brace = 0
    escape = False

    for char in text:
        if quote is not None:
            current.append(char)
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == quote:
                quote = None
            continue

        if char in {"'", '"'}:
            quote = char
            current.append(char)
            continue

        if char == "[":
            depth_bracket += 1
            current.append(char)
            continue
        if char == "]":
            depth_bracket -= 1
            current.append(char)
            continue
        if char == "{":
            depth_brace += 1
            current.append(char)
            continue
        if char == "}":
            depth_brace -= 1
            current.append(char)
            continue

        if char == separator and depth_bracket == 0 and depth_brace == 0:
            part = "".join(current).strip()
            if part:
                result.append(part)
            current = []
            continue

        current.append(char)

    part = "".join(current).strip()
    if part:
        result.append(part)
    return result


def load_toml_data(config_path: Path) -> dict[str, Any]:
    if tomllib is not None:
        with config_path.open("rb") as fp:
            loaded = tomllib.load(fp)
        if isinstance(loaded, dict):
            return loaded
        raise ValueError("config root must be a table")

    data: dict[str, Any] = {}
    current: dict[str, Any] = data

    for line_number, raw_line in enumerate(config_path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = raw_line.split("#", 1)[0].strip()
        if not stripped:
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1].strip()
            if not section:
                raise ValueError(f"invalid section at line {line_number}")
            current = data
            for part in section.split("."):
                key = part.strip()
                if not key:
                    raise ValueError(f"invalid section at line {line_number}")
                next_value = current.get(key)
                if next_value is None:
                    next_value = {}
                    current[key] = next_value
                if not isinstance(next_value, dict):
                    raise ValueError(f"section conflicts with value at line {line_number}")
                current = next_value
            continue
        if "=" not in stripped:
            raise ValueError(f"invalid syntax at line {line_number}")
        key, raw_value = stripped.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"invalid key at line {line_number}")
        current[key] = parse_toml_fallback_value(raw_value)

    return data


@dataclass
class Config:
    rule_extension_overrides: dict[str, list[str]] = field(default_factory=dict)
    rule_subfolder_overrides: dict[str, str] = field(default_factory=dict)
    rule_enable: set[str] = field(default_factory=set)
    rule_disable: set[str] = field(default_factory=set)
    rule_order: list[str] = field(default_factory=list)
    custom_rules: list[Rule] = field(default_factory=list)
    ignore_extensions: set[str] = field(default_factory=set)
    ignore_paths: set[str] = field(default_factory=set)
    ignore_aliases: bool | None = None
    ignore_folders: bool | None = None
    ignore_tagged: bool | None = None
    include_subfolders: bool | None = None
    include_folders: bool | None = None
    include_empty_folders: bool | None = None
    include_tagged: bool | None = None
    skip_bundles: bool | None = None
    remove_empty_folders: bool | None = None
    create_dated_top_folder: bool | None = None
    extra_logging: bool | None = None


def normalize_rule_aliases(rules: list[Rule]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for rule in rules:
        mapping[rule.rule_id] = rule.rule_id
        mapping[normalize_identifier(rule.description)] = rule.rule_id
        mapping[normalize_identifier(rule.subfolder)] = rule.rule_id
    return mapping


def parse_condition(raw: Any) -> Condition:
    if not isinstance(raw, dict):
        raise ValueError("condition must be a table")
    ctype = raw.get("type")
    if not isinstance(ctype, str):
        raise ValueError("condition.type must be a string")
    if "value" not in raw:
        raise ValueError("condition.value is required")
    return Condition(ctype.strip().lower(), raw["value"])


def parse_custom_rule(rule_id: str, raw: Any) -> Rule:
    if not isinstance(raw, dict):
        raise ValueError(f"custom rule '{rule_id}' must be a table")
    description = raw.get("description") or f"Custom rule {rule_id}"
    subfolder = raw.get("subfolder") or raw.get("folder_name") or f"Custom/{rule_id}"
    enabled = bool(raw.get("enabled", True))
    mode = str(raw.get("mode", "all")).strip().lower()
    if mode not in {"all", "any"}:
        raise ValueError(f"custom rule '{rule_id}' has invalid mode")

    raw_conditions = raw.get("conditions")
    conditions: list[Condition] = []
    if raw_conditions is not None:
        if not isinstance(raw_conditions, list):
            raise ValueError(f"custom rule '{rule_id}' conditions must be an array")
        conditions = [parse_condition(item) for item in raw_conditions]

    # Shortcut fields for compact config.
    if not conditions:
        if "kind" in raw:
            conditions.append(Condition("kind", raw["kind"]))
        if "name_contains" in raw:
            conditions.append(Condition("name_contains", raw["name_contains"]))
        if "created_within_days" in raw:
            conditions.append(Condition("created_within_days", raw["created_within_days"]))
        if "size_gte" in raw:
            conditions.append(Condition("size_gte", raw["size_gte"]))
        if "size_lte" in raw:
            conditions.append(Condition("size_lte", raw["size_lte"]))
        if "extensions" in raw:
            conditions.append(Condition("extension_any", raw["extensions"]))

    if not conditions:
        raise ValueError(f"custom rule '{rule_id}' must define at least one condition")

    return make_rule(
        rule_id=f"custom_{rule_id}",
        description=str(description),
        subfolder=str(subfolder),
        enabled=enabled,
        built_in=False,
        mode=mode,
        conditions=conditions,
    )


def parse_config(raw: dict[str, Any], base_rules: list[Rule]) -> Config:
    config = Config()
    aliases = normalize_rule_aliases(base_rules)

    ignore = raw.get("ignore")
    if isinstance(ignore, dict):
        extensions = ignore.get("extensions", [])
        if isinstance(extensions, list):
            config.ignore_extensions = {normalize_extension(str(ext)) for ext in extensions}
        paths = ignore.get("paths", [])
        if isinstance(paths, list):
            config.ignore_paths = {str(item).strip().lower() for item in paths if str(item).strip()}
        if "aliases" in ignore:
            config.ignore_aliases = bool(ignore["aliases"])
        if "folders" in ignore:
            config.ignore_folders = bool(ignore["folders"])
        if "tagged" in ignore:
            config.ignore_tagged = bool(ignore["tagged"])

    options = raw.get("options")
    if isinstance(options, dict):
        if "include_subfolders" in options:
            config.include_subfolders = bool(options["include_subfolders"])
        if "include_folders" in options:
            config.include_folders = bool(options["include_folders"])
        if "include_empty_folders" in options:
            config.include_empty_folders = bool(options["include_empty_folders"])
        if "include_tagged" in options:
            config.include_tagged = bool(options["include_tagged"])
        if "skip_bundles" in options:
            config.skip_bundles = bool(options["skip_bundles"])
        if "remove_empty_folders" in options:
            config.remove_empty_folders = bool(options["remove_empty_folders"])
        if "create_dated_top_folder" in options:
            config.create_dated_top_folder = bool(options["create_dated_top_folder"])
        if "extra_logging" in options:
            config.extra_logging = bool(options["extra_logging"])

    rules_table = raw.get("rules")
    if isinstance(rules_table, dict):
        enabled = rules_table.get("enable", [])
        if isinstance(enabled, list):
            for rule_ref in enabled:
                rule_id = aliases.get(normalize_identifier(str(rule_ref)))
                if rule_id:
                    config.rule_enable.add(rule_id)
        disabled = rules_table.get("disable", [])
        if isinstance(disabled, list):
            for rule_ref in disabled:
                rule_id = aliases.get(normalize_identifier(str(rule_ref)))
                if rule_id:
                    config.rule_disable.add(rule_id)
        order = rules_table.get("order", [])
        if isinstance(order, list):
            for rule_ref in order:
                token = normalize_identifier(str(rule_ref))
                rule_id = aliases.get(token, token)
                config.rule_order.append(rule_id)

        # Legacy extension overrides in [rules] from earlier version.
        for key, value in rules_table.items():
            if key in {"enable", "disable", "order"}:
                continue
            if isinstance(value, list):
                mapped = aliases.get(normalize_identifier(key), normalize_identifier(key))
                config.rule_extension_overrides[mapped] = [normalize_extension(str(ext)) for ext in value]

    extension_overrides = raw.get("extension_rules")
    if isinstance(extension_overrides, dict):
        for key, value in extension_overrides.items():
            if isinstance(value, list):
                mapped = aliases.get(normalize_identifier(key), normalize_identifier(key))
                config.rule_extension_overrides[mapped] = [normalize_extension(str(ext)) for ext in value]

    subfolder_overrides = raw.get("subfolders")
    if isinstance(subfolder_overrides, dict):
        for key, value in subfolder_overrides.items():
            if isinstance(value, str):
                mapped = aliases.get(normalize_identifier(key), normalize_identifier(key))
                config.rule_subfolder_overrides[mapped] = ensure_unix_subfolder(value)

    custom_rules = raw.get("custom_rules")
    if isinstance(custom_rules, dict):
        for custom_id, custom_value in custom_rules.items():
            config.custom_rules.append(parse_custom_rule(str(custom_id), custom_value))
    elif isinstance(custom_rules, list):
        for idx, custom_value in enumerate(custom_rules, start=1):
            if isinstance(custom_value, dict):
                raw_id = custom_value.get("id", f"rule_{idx}")
                config.custom_rules.append(parse_custom_rule(str(raw_id), custom_value))

    # Custom rule toggles in [rules] can mention custom IDs directly.
    if config.rule_order:
        expanded_order: list[str] = []
        for rule_id in config.rule_order:
            if rule_id.startswith("custom_"):
                expanded_order.append(rule_id)
            elif rule_id in aliases.values():
                expanded_order.append(rule_id)
            elif not rule_id:
                continue
            else:
                expanded_order.append(rule_id)
        config.rule_order = expanded_order

    return config


def load_config(config_path: Path | None, base_rules: list[Rule]) -> Config:
    if config_path is None:
        return Config()
    if not config_path.exists():
        raise FileNotFoundError(f"config file not found: {config_path}")
    raw_data = load_toml_data(config_path)
    return parse_config(raw_data, base_rules)


def configure_logging(
    *,
    verbose: bool = False,
    log_file: Path | None = None,
    stream: Any | None = None,
) -> logging.Logger:
    logger = logging.getLogger("downloads_organize")
    logger.handlers.clear()
    logger.propagate = False
    logger.setLevel(logging.DEBUG)

    level = logging.DEBUG if verbose else logging.INFO
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S")

    stream_handler = logging.StreamHandler(stream or sys.stdout)
    stream_handler.setLevel(level)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)

    if log_file is not None:
        file_handler = logging.FileHandler(log_file, encoding="utf-8")
        file_handler.setLevel(logging.DEBUG)
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)

    return logger


def apply_rule_overrides(rules: list[Rule], config: Config) -> list[Rule]:
    updated: list[Rule] = []
    for rule in rules:
        new_rule = Rule(
            rule_id=rule.rule_id,
            description=rule.description,
            subfolder=config.rule_subfolder_overrides.get(rule.rule_id, rule.subfolder),
            enabled=rule.enabled,
            built_in=rule.built_in,
            mode=rule.mode,
            conditions=[Condition(cond.type, cond.value) for cond in rule.conditions],
        )

        override_exts = config.rule_extension_overrides.get(new_rule.rule_id)
        if override_exts is not None:
            new_rule.conditions = [Condition("extension_any", override_exts)]

        if new_rule.rule_id in config.rule_enable:
            new_rule.enabled = True
        if new_rule.rule_id in config.rule_disable:
            new_rule.enabled = False

        updated.append(new_rule)

    updated.extend(config.custom_rules)

    if config.rule_order:
        by_id = {rule.rule_id: rule for rule in updated}
        ordered: list[Rule] = []
        used: set[str] = set()
        for rule_id in config.rule_order:
            if rule_id in by_id and rule_id not in used:
                ordered.append(by_id[rule_id])
                used.add(rule_id)
        for rule in updated:
            if rule.rule_id not in used:
                ordered.append(rule)
        updated = ordered

    return updated


def condition_specificity_score(condition: Condition) -> float:
    ctype = normalize_identifier(condition.type)
    value = condition.value
    values = value if isinstance(value, list) else [value]

    if ctype == "extension_any":
        normalized_extensions: list[str] = []
        for raw in values:
            try:
                normalized_extensions.append(normalize_extension(str(raw)))
            except ValueError:
                continue
        count = max(1, len(normalized_extensions))
        return 120.0 / count

    if ctype == "name_contains":
        useful = [str(part).strip() for part in values if str(part).strip()]
        return 70.0 + min(len(useful), 5) * 4.0

    if ctype in {"created_within_days", "size_gte", "size_lte"}:
        return 45.0
    if ctype in {"has_tag", "is_alias", "is_folder"}:
        return 40.0
    if ctype == "kind":
        return 35.0
    return 0.0


def rule_specificity_score(rule: Rule) -> float:
    if not rule.enabled:
        return -1_000_000.0

    score = sum(condition_specificity_score(condition) for condition in rule.conditions)
    score += 12.0 if rule.mode == "all" else 0.0
    score += 6.0 if not rule.built_in else 0.0
    score += min(len(rule.conditions), 5) * 3.0

    # Keep MIME fallback as the lowest-priority match if that rule exists.
    if rule.rule_id == "mime_fallback":
        score -= 1_000_000.0
    return score


def optimize_rule_priority(rules: list[Rule]) -> tuple[list[Rule], PriorityOptimizationReport]:
    """
    Safe and explainable ordering:
    - Higher specificity score first
    - Stable on ties (original order)
    - Disabled rules stay at the end in original order
    """
    report = PriorityOptimizationReport(enabled=True, before_order=[rule.rule_id for rule in rules])
    enabled_scored: list[tuple[Rule, float, int]] = []
    disabled_in_order: list[Rule] = []

    for index, rule in enumerate(rules):
        if rule.enabled:
            enabled_scored.append((rule, rule_specificity_score(rule), index))
        else:
            disabled_in_order.append(rule)

    enabled_scored.sort(key=lambda entry: (-entry[1], entry[2]))
    optimized_enabled = [entry[0] for entry in enabled_scored]
    optimized_rules = [*optimized_enabled, *disabled_in_order]

    report.after_order = [rule.rule_id for rule in optimized_rules]
    report.changed = report.before_order != report.after_order

    optimized_positions = {rule.rule_id: idx for idx, rule in enumerate(optimized_enabled)}
    for rule, score, original_index in enabled_scored:
        report.scores.append(
            {
                "rule_id": rule.rule_id,
                "description": rule.description,
                "score": round(score, 3),
                "original_index": original_index,
                "optimized_index": optimized_positions.get(rule.rule_id, original_index),
            }
        )

    return optimized_rules, report


def match_kind(item: ItemInfo, kind_value: str, kind_map: dict[str, set[str]]) -> bool:
    normalized = normalize_identifier(kind_value)
    if normalized == "folder":
        return item.is_dir
    if normalized in {"alias", "symlink"}:
        return item.is_symlink
    extensions = kind_map.get(normalized)
    if extensions is None:
        return False
    return not item.is_dir and matches_extension(item.name, extensions)


def ensure_condition_list(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    return [value]


def evaluate_condition(condition: Condition, item: ItemInfo, reference_time: datetime, kind_map: dict[str, set[str]]) -> bool:
    ctype = normalize_identifier(condition.type)
    value = condition.value

    if ctype == "extension_any":
        values = [normalize_extension(str(ext)) for ext in ensure_condition_list(value)]
        return (not item.is_dir) and matches_extension(item.name, values)
    if ctype == "name_contains":
        substrings = [str(part).lower() for part in ensure_condition_list(value)]
        return any(sub in item.lower_name for sub in substrings)
    if ctype == "kind":
        if not isinstance(value, str):
            return False
        return match_kind(item, value, kind_map)
    if ctype == "created_within_days":
        try:
            days = float(value)
        except (TypeError, ValueError):
            return False
        cutoff = reference_time - timedelta(days=days)
        return item.created_at >= cutoff
    if ctype == "size_gte":
        try:
            threshold = int(value)
        except (TypeError, ValueError):
            return False
        return item.size_bytes >= threshold
    if ctype == "size_lte":
        try:
            threshold = int(value)
        except (TypeError, ValueError):
            return False
        return item.size_bytes <= threshold
    if ctype == "is_folder":
        return item.is_dir == bool(value)
    if ctype == "is_alias":
        return item.is_symlink == bool(value)
    if ctype == "has_tag":
        return item.has_tag == bool(value)
    return False


def matches_rule(rule: Rule, item: ItemInfo, reference_time: datetime, kind_map: dict[str, set[str]]) -> bool:
    if not rule.enabled:
        return False
    if not rule.conditions:
        return False
    results = [evaluate_condition(cond, item, reference_time, kind_map) for cond in rule.conditions]
    if rule.mode == "any":
        return any(results)
    return all(results)


def path_matches_ignore(path: Path, source: Path, ignore_tokens: set[str]) -> bool:
    if not ignore_tokens:
        return False
    rel = str(path.relative_to(source)).lower()
    name = path.name.lower()
    abs_path = str(path.resolve()).lower()
    return rel in ignore_tokens or name in ignore_tokens or abs_path in ignore_tokens


def iter_candidate_items(
    *,
    source_dir: Path,
    destination_dir: Path,
    include_subfolders: bool,
    include_folders: bool,
    include_empty_folders: bool,
    ignore_extensions: set[str],
    ignore_paths: set[str],
    ignore_aliases: bool,
    ignore_folders: bool,
    include_tagged: bool,
    ignore_tagged: bool,
    skip_bundles: bool,
    logger: logging.Logger,
    extra_logging: bool,
) -> tuple[list[ItemInfo], int]:
    candidates: list[ItemInfo] = []
    ignored_count = 0
    destination_resolved = destination_dir.resolve()

    def should_skip_path(path: Path) -> bool:
        nonlocal ignored_count
        if path.resolve() == destination_resolved or destination_resolved in path.resolve().parents:
            ignored_count += 1
            if extra_logging:
                logger.debug("SKIP destination subtree: %s", path)
            return True
        if path_matches_ignore(path, source_dir, ignore_paths):
            ignored_count += 1
            if extra_logging:
                logger.debug("SKIP ignore list: %s", path)
            return True
        return False

    if include_subfolders:
        for root, dirnames, filenames in os.walk(source_dir, topdown=True):
            root_path = Path(root)
            if should_skip_path(root_path):
                dirnames[:] = []
                continue

            filtered_dirs: list[str] = []
            for dirname in dirnames:
                dir_path = root_path / dirname
                if should_skip_path(dir_path):
                    continue
                if skip_bundles and dir_path.suffix.lower() in BUNDLE_SUFFIXES:
                    ignored_count += 1
                    if extra_logging:
                        logger.debug("SKIP bundle: %s", dir_path)
                    continue
                filtered_dirs.append(dirname)
            dirnames[:] = filtered_dirs

            if include_folders:
                for dirname in dirnames:
                    dir_path = root_path / dirname
                    if ignore_folders:
                        ignored_count += 1
                        continue
                    if include_empty_folders and any(dir_path.iterdir()):
                        continue
                    info = build_item_info(source_dir, dir_path, is_dir=True, include_tagged=include_tagged)
                    if ignore_tagged and info.has_tag:
                        ignored_count += 1
                        continue
                    candidates.append(info)

            for filename in filenames:
                file_path = root_path / filename
                if should_skip_path(file_path):
                    continue
                info = build_item_info(source_dir, file_path, is_dir=False, include_tagged=include_tagged)
                if ignore_aliases and info.is_symlink:
                    ignored_count += 1
                    continue
                if ignore_tagged and info.has_tag:
                    ignored_count += 1
                    continue
                if matches_extension(info.name, ignore_extensions):
                    ignored_count += 1
                    continue
                candidates.append(info)
    else:
        for entry in sorted(source_dir.iterdir(), key=lambda p: p.name.lower()):
            if should_skip_path(entry):
                continue
            if entry.is_dir():
                if skip_bundles and entry.suffix.lower() in BUNDLE_SUFFIXES:
                    ignored_count += 1
                    continue
                if not include_folders or ignore_folders:
                    ignored_count += 1
                    continue
                if include_empty_folders and any(entry.iterdir()):
                    ignored_count += 1
                    continue
                info = build_item_info(source_dir, entry, is_dir=True, include_tagged=include_tagged)
                if ignore_tagged and info.has_tag:
                    ignored_count += 1
                    continue
                candidates.append(info)
                continue

            info = build_item_info(source_dir, entry, is_dir=False, include_tagged=include_tagged)
            if ignore_aliases and info.is_symlink:
                ignored_count += 1
                continue
            if ignore_tagged and info.has_tag:
                ignored_count += 1
                continue
            if matches_extension(info.name, ignore_extensions):
                ignored_count += 1
                continue
            candidates.append(info)

    return candidates, ignored_count


def build_item_info(source_dir: Path, path: Path, is_dir: bool, include_tagged: bool) -> ItemInfo:
    stat = os.lstat(path)
    created_at = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc)
    has_tag = has_finder_tag(path) if include_tagged else False
    return ItemInfo(
        path=path,
        relative_path=path.relative_to(source_dir),
        name=path.name,
        is_dir=is_dir,
        is_symlink=path.is_symlink(),
        size_bytes=0 if is_dir else stat.st_size,
        created_at=created_at,
        has_tag=has_tag,
    )


def maybe_make_top_level_destination(destination_dir: Path, create_dated_top_folder: bool, apply: bool) -> Path:
    if not create_dated_top_folder:
        return destination_dir
    dated = now_utc().astimezone().strftime("%Y-%m-%d_%H-%M-%S")
    run_destination = destination_dir / dated
    if apply:
        run_destination.mkdir(parents=True, exist_ok=True)
    return run_destination


def plan_moves(
    *,
    source_dir: Path,
    destination_dir: Path,
    rules: list[Rule],
    include_subfolders: bool,
    include_folders: bool,
    include_empty_folders: bool,
    ignore_extensions: set[str],
    ignore_paths: set[str],
    ignore_aliases: bool,
    ignore_folders: bool,
    include_tagged: bool,
    ignore_tagged: bool,
    skip_bundles: bool,
    logger: logging.Logger,
    extra_logging: bool,
) -> tuple[list[MovePlan], TidySummary]:
    summary = TidySummary()
    reference_time = now_utc()
    kind_map = build_kind_extensions()
    occupied_targets: set[Path] = set()

    candidates, ignored_count = iter_candidate_items(
        source_dir=source_dir,
        destination_dir=destination_dir,
        include_subfolders=include_subfolders,
        include_folders=include_folders,
        include_empty_folders=include_empty_folders,
        ignore_extensions=ignore_extensions,
        ignore_paths=ignore_paths,
        ignore_aliases=ignore_aliases,
        ignore_folders=ignore_folders,
        include_tagged=include_tagged,
        ignore_tagged=ignore_tagged,
        skip_bundles=skip_bundles,
        logger=logger,
        extra_logging=extra_logging,
    )
    summary.ignored += ignored_count
    summary.scanned += len(candidates)
    summary.total_targets = summary.scanned

    plans: list[MovePlan] = []
    used_rules: set[str] = set()
    enabled_rules = [rule for rule in rules if rule.enabled]

    # Move deeper paths first when directories are involved.
    candidates.sort(key=lambda item: (item.relative_path.as_posix().count("/"), item.lower_name), reverse=True)

    for item in candidates:
        matched_rule: Rule | None = None
        for rule in enabled_rules:
            if matches_rule(rule, item, reference_time, kind_map):
                matched_rule = rule
                break

        if matched_rule is None:
            summary.unclassified += 1
            continue

        used_rules.add(matched_rule.rule_id)
        summary.matched += 1
        summary.rule_hits[matched_rule.rule_id] = summary.rule_hits.get(matched_rule.rule_id, 0) + 1
        if matched_rule.rule_id == "mime_fallback":
            summary.fallback_mime += 1
        target_dir = destination_dir / Path(matched_rule.subfolder)
        target = target_dir / item.name
        target, collided = resolve_collision(target, occupied_targets)
        occupied_targets.add(target)

        if collided:
            summary.collisions += 1

        plans.append(
            MovePlan(
                source=item.path,
                destination=target,
                rule_id=matched_rule.rule_id,
                rule_description=matched_rule.description,
                collision_renamed=collided,
            )
        )

    summary.planned_moves = len(plans)
    summary.unclassified = summary.scanned - summary.matched
    summary.rules_used = len(used_rules)
    return plans, summary


def execute_moves(
    plans: list[MovePlan],
    *,
    apply: bool,
    logger: logging.Logger,
) -> tuple[list[dict[str, str]], int]:
    executed: list[dict[str, str]] = []
    errors = 0
    for move in plans:
        if not apply:
            logger.info("DRY-RUN [%s]: %s -> %s", move.rule_description, move.source, move.destination)
            continue
        try:
            move.destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(move.source), str(move.destination))
            executed.append({"from": str(move.source), "to": str(move.destination), "rule_id": move.rule_id})
            logger.info("MOVE [%s]: %s -> %s", move.rule_description, move.source, move.destination)
        except Exception as exc:  # pragma: no cover - runtime filesystem error
            errors += 1
            logger.error("ERROR move failed: %s -> %s (%s)", move.source, move.destination, exc)
    return executed, errors


def remove_empty_dirs(root: Path, *, excluded_roots: set[Path], logger: logging.Logger) -> list[Path]:
    removed: list[Path] = []
    for current_root, dirnames, _filenames in os.walk(root, topdown=False):
        path = Path(current_root)
        if path == root or path in excluded_roots:
            continue
        if any(excluded in path.parents for excluded in excluded_roots):
            continue
        if dirnames:
            # os.walk may provide stale state; check actual filesystem instead.
            pass
        try:
            if not any(path.iterdir()):
                path.rmdir()
                removed.append(path)
                logger.info("REMOVE EMPTY DIR: %s", path)
        except OSError:
            continue
    return removed


def ensure_undo_dir(undo_dir: Path) -> None:
    undo_dir.mkdir(parents=True, exist_ok=True)


def write_transaction(
    *,
    undo_dir: Path,
    source_dir: Path,
    destination_dir: Path,
    executed_moves: list[dict[str, str]],
    removed_empty_dirs: list[Path],
) -> Path:
    ensure_undo_dir(undo_dir)
    tx_id = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
    payload = {
        "id": tx_id,
        "created_at": now_utc().isoformat(),
        "source_dir": str(source_dir),
        "destination_dir": str(destination_dir),
        "moves": executed_moves,
        "removed_empty_dirs": [str(path) for path in removed_empty_dirs],
        "undone_at": None,
    }
    target = undo_dir / f"{tx_id}.json"
    target.write_text(json.dumps(payload, indent=2, ensure_ascii=True), encoding="utf-8")
    return target


def load_transactions(undo_dir: Path) -> list[dict[str, Any]]:
    if not undo_dir.exists():
        return []
    records: list[dict[str, Any]] = []
    for entry in sorted(undo_dir.glob("*.json")):
        try:
            data = json.loads(entry.read_text(encoding="utf-8"))
        except Exception:
            continue
        if isinstance(data, dict) and "id" in data:
            data["_path"] = str(entry)
            records.append(data)
    records.sort(key=lambda item: str(item.get("created_at", "")), reverse=True)
    return records


def pick_transaction(records: list[dict[str, Any]], tx_id: str | None) -> dict[str, Any] | None:
    if tx_id is None:
        for record in records:
            if not record.get("undone_at"):
                return record
        return None
    for record in records:
        if str(record.get("id")) == tx_id:
            return record
    return None


def undo_transaction(record: dict[str, Any], *, apply: bool, logger: logging.Logger) -> UndoResult:
    result = UndoResult()
    moves = record.get("moves", [])
    if not isinstance(moves, list):
        raise ValueError("invalid undo record: moves must be an array")

    occupied_targets: set[Path] = set()
    for move in reversed(moves):
        if not isinstance(move, dict):
            result.errors += 1
            continue
        source = Path(str(move.get("to", "")))
        destination = Path(str(move.get("from", "")))
        if not source.exists():
            result.errors += 1
            logger.error("UNDO source missing: %s", source)
            continue
        destination, collided = resolve_collision(destination, occupied_targets)
        occupied_targets.add(destination)
        if collided:
            result.collisions += 1
        if not apply:
            logger.info("DRY-RUN UNDO: %s -> %s", source, destination)
            continue
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(destination))
            result.restored += 1
            logger.info("UNDO MOVE: %s -> %s", source, destination)
        except Exception as exc:  # pragma: no cover - runtime filesystem error
            result.errors += 1
            logger.error("UNDO ERROR: %s -> %s (%s)", source, destination, exc)

    removed_dirs = record.get("removed_empty_dirs", [])
    if isinstance(removed_dirs, list):
        for dir_path in removed_dirs:
            path = Path(str(dir_path))
            if not apply:
                logger.info("DRY-RUN UNDO DIR CREATE: %s", path)
                continue
            try:
                path.mkdir(parents=True, exist_ok=True)
            except OSError:
                continue

    return result


def mark_transaction_undone(record: dict[str, Any]) -> None:
    path = Path(str(record["_path"]))
    record["undone_at"] = now_utc().isoformat()
    payload = {key: value for key, value in record.items() if key != "_path"}
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True), encoding="utf-8")


def delete_transactions(records: list[dict[str, Any]], *, tx_id: str | None, older_than_days: int | None) -> int:
    deleted = 0
    cutoff: datetime | None = None
    if older_than_days is not None:
        cutoff = now_utc() - timedelta(days=older_than_days)

    for record in records:
        path = Path(str(record.get("_path", "")))
        if not path.exists():
            continue
        if tx_id is not None and str(record.get("id")) != tx_id:
            continue
        if cutoff is not None:
            created_raw = record.get("created_at")
            try:
                created = datetime.fromisoformat(str(created_raw))
                if created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
            except Exception:
                continue
            if created >= cutoff:
                continue
        path.unlink()
        deleted += 1
    return deleted


def format_rule_line(rule: Rule) -> str:
    lock = "[lock]" if rule.built_in else "[custom]"
    state = "on" if rule.enabled else "off"
    return f"{rule.rule_id:16} {state:3} {lock:8} {rule.subfolder} :: {rule.description}"


def bool_or_default(value: bool | None, default: bool) -> bool:
    return default if value is None else value


def combine_ignore_extensions(config: Config, cli_extensions: list[str] | None) -> set[str]:
    result = set(DEFAULT_IGNORE_EXTENSIONS)
    result.update(config.ignore_extensions)
    if cli_extensions:
        result.update(normalize_extension(ext) for ext in cli_extensions)
    return result


def combine_ignore_paths(config: Config, cli_paths: list[str] | None) -> set[str]:
    result = set(config.ignore_paths)
    if cli_paths:
        result.update(path.strip().lower() for path in cli_paths if path.strip())
    return result


def build_rule_hit_report(rules: list[Rule], summary: TidySummary) -> list[dict[str, Any]]:
    report: list[dict[str, Any]] = []
    for rule in rules:
        if not rule.enabled:
            continue
        report.append(
            {
                "rule_id": rule.rule_id,
                "description": rule.description,
                "subfolder": rule.subfolder,
                "hits": int(summary.rule_hits.get(rule.rule_id, 0)),
                "built_in": rule.built_in,
                "enabled": rule.enabled,
            }
        )
    return report


def build_stats_payload(
    *,
    summary: TidySummary,
    rules: list[Rule],
    source_dir: Path,
    destination_dir: Path,
    apply: bool,
    priority_optimization: PriorityOptimizationReport,
) -> dict[str, Any]:
    rule_hit_report = build_rule_hit_report(rules, summary)
    nonzero_rule_hits = {entry["rule_id"]: entry["hits"] for entry in rule_hit_report if entry["hits"] > 0}
    return {
        "generated_at": now_utc().isoformat(),
        "mode": "apply" if apply else "dry-run",
        "source_dir": str(source_dir),
        "destination_dir": str(destination_dir),
        "total_targets": summary.total_targets,
        "rule_hits": rule_hit_report,
        "rule_hits_nonzero": nonzero_rule_hits,
        "unclassified": summary.unclassified,
        "fallback_mime": summary.fallback_mime,
        "priority_optimization": {
            "enabled": priority_optimization.enabled,
            "strategy": priority_optimization.strategy,
            "changed": priority_optimization.changed,
            "before_order": priority_optimization.before_order,
            "after_order": priority_optimization.after_order,
            "scores": priority_optimization.scores,
        },
        "summary": {
            "scanned": summary.scanned,
            "ignored": summary.ignored,
            "matched": summary.matched,
            "planned_moves": summary.planned_moves,
            "moved": summary.moved,
            "collisions": summary.collisions,
            "errors": summary.errors,
            "rules_used": summary.rules_used,
        },
    }


def write_stats_json(stats_path: Path, payload: dict[str, Any], logger: logging.Logger) -> bool:
    try:
        stats_path.parent.mkdir(parents=True, exist_ok=True)
        stats_path.write_text(json.dumps(payload, indent=2, ensure_ascii=True), encoding="utf-8")
    except Exception as exc:
        logger.error("failed to write stats json: %s", exc)
        return False
    logger.info("STATS JSON: %s", stats_path)
    return True


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=APP_NAME,
        description="Folder Tidy style organizer CLI for Downloads/Desktop folders.",
    )
    parser.add_argument("--log-file", help="Optional path to write logs.")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose logs.")

    subparsers = parser.add_subparsers(dest="command")

    tidy_parser = subparsers.add_parser("tidy", help="Run tidy operation (default action).")
    add_tidy_args(tidy_parser)

    rules_parser = subparsers.add_parser("rules-list", help="List built-in and custom rules.")
    rules_parser.add_argument("--config", help="Optional TOML config path.")

    undo_list_parser = subparsers.add_parser("undo-list", help="List available undo transactions.")
    undo_list_parser.add_argument("--undo-dir", default=str(DEFAULT_UNDO_DIR), help="Undo history directory.")

    undo_parser = subparsers.add_parser("undo", help="Undo latest or specific transaction.")
    undo_parser.add_argument("--undo-dir", default=str(DEFAULT_UNDO_DIR), help="Undo history directory.")
    undo_parser.add_argument("--id", dest="tx_id", help="Specific transaction ID.")
    undo_parser.add_argument("--apply", action="store_true", help="Apply undo. Default is dry-run.")

    undo_delete_parser = subparsers.add_parser("undo-delete", help="Delete undo records.")
    undo_delete_parser.add_argument("--undo-dir", default=str(DEFAULT_UNDO_DIR), help="Undo history directory.")
    undo_delete_parser.add_argument("--id", dest="tx_id", help="Delete one transaction by ID.")
    undo_delete_parser.add_argument("--older-than-days", type=int, help="Delete records older than N days.")
    undo_delete_parser.add_argument("--apply", action="store_true", help="Apply delete. Default is dry-run.")

    return parser


def add_tidy_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--source", default="~/Downloads", help="Source folder to organize.")
    parser.add_argument("--destination", help="Destination folder for tidied files. Default: source folder.")
    parser.add_argument(
        "--downloads-dir",
        help=argparse.SUPPRESS,  # backward compatibility with previous version
    )
    parser.add_argument("--config", help="Optional TOML config file.")
    parser.add_argument("--undo-dir", default=str(DEFAULT_UNDO_DIR), help="Undo history directory.")
    parser.add_argument("--apply", action="store_true", help="Move files. Default is dry-run.")
    parser.add_argument("--include-subfolders", action="store_true", help="Include files in subfolders.")
    parser.add_argument("--include-folders", action="store_true", help="Allow folder items to be moved.")
    parser.add_argument(
        "--include-empty-folders",
        action="store_true",
        help="When folders are included, move only empty folders.",
    )
    parser.add_argument(
        "--include-tagged",
        action="store_true",
        help="Include Finder-tagged files/folders during matching.",
    )
    parser.add_argument(
        "--ignore-tagged",
        action="store_true",
        help="Skip Finder-tagged files/folders.",
    )
    parser.add_argument("--ignore-aliases", action="store_true", help="Skip symlinks/aliases.")
    parser.add_argument("--ignore-folders", action="store_true", help="Skip folder candidates.")
    parser.add_argument("--skip-bundles", action="store_true", help="Skip .app/.bundle/.framework directories.")
    parser.add_argument("--remove-empty-folders", action="store_true", help="Remove empty source folders after tidy.")
    parser.add_argument(
        "--create-dated-top-folder",
        action="store_true",
        help="Create timestamped top-level folder in destination.",
    )
    parser.add_argument("--ignore-ext", action="append", help="Additional extension to ignore. Repeatable.")
    parser.add_argument("--ignore-path", action="append", help="Path/name to ignore. Repeatable.")
    parser.add_argument("--stats-json", help="Write detailed stats as JSON (also in dry-run mode).")
    parser.add_argument(
        "--optimize-priority",
        action="store_true",
        help="Safely reorder enabled rules by specificity before matching.",
    )
    parser.add_argument("--extra-logging", action="store_true", help="Verbose matching logs.")


def run_tidy(args: argparse.Namespace, logger: logging.Logger) -> int:
    base_rules = built_in_rules()
    config_path = Path(args.config).expanduser() if args.config else None
    try:
        config = load_config(config_path, base_rules)
    except Exception as exc:
        logger.error("failed to load config: %s", exc)
        return 2

    source_hint = args.downloads_dir if args.downloads_dir else args.source
    source_dir = Path(source_hint).expanduser()
    destination_dir = Path(args.destination).expanduser() if args.destination else source_dir
    undo_dir = Path(args.undo_dir).expanduser()

    if not source_dir.exists() or not source_dir.is_dir():
        logger.error("source directory not found: %s", source_dir)
        return 2

    if not destination_dir.exists() and args.apply:
        destination_dir.mkdir(parents=True, exist_ok=True)
    if not destination_dir.exists():
        logger.info("destination directory will be created when applying: %s", destination_dir)

    rules = apply_rule_overrides(base_rules, config)
    priority_optimization = PriorityOptimizationReport(
        enabled=False,
        before_order=[rule.rule_id for rule in rules],
        after_order=[rule.rule_id for rule in rules],
    )
    if args.optimize_priority:
        rules, priority_optimization = optimize_rule_priority(rules)
        logger.info(
            "OPTIMIZE_PRIORITY enabled=%s changed=%s strategy=%s",
            priority_optimization.enabled,
            priority_optimization.changed,
            priority_optimization.strategy,
        )
        logger.info("OPTIMIZE_ORDER before=%s", ",".join(priority_optimization.before_order))
        logger.info("OPTIMIZE_ORDER after=%s", ",".join(priority_optimization.after_order))

    include_subfolders = args.include_subfolders or bool_or_default(config.include_subfolders, False)
    include_folders = args.include_folders or bool_or_default(config.include_folders, False)
    include_empty_folders = args.include_empty_folders or bool_or_default(config.include_empty_folders, False)
    include_tagged = args.include_tagged or bool_or_default(config.include_tagged, False)
    ignore_tagged = args.ignore_tagged or bool_or_default(config.ignore_tagged, False)
    ignore_aliases = args.ignore_aliases or bool_or_default(config.ignore_aliases, False)
    ignore_folders = args.ignore_folders or bool_or_default(config.ignore_folders, False)
    skip_bundles = args.skip_bundles or bool_or_default(config.skip_bundles, True)
    remove_empty_folders = args.remove_empty_folders or bool_or_default(config.remove_empty_folders, False)
    create_dated_top_folder = args.create_dated_top_folder or bool_or_default(config.create_dated_top_folder, False)
    extra_logging = args.extra_logging or bool_or_default(config.extra_logging, False)

    ignore_extensions = combine_ignore_extensions(config, args.ignore_ext)
    ignore_paths = combine_ignore_paths(config, args.ignore_path)
    run_destination = maybe_make_top_level_destination(destination_dir, create_dated_top_folder, args.apply)

    plans, summary = plan_moves(
        source_dir=source_dir,
        destination_dir=run_destination,
        rules=rules,
        include_subfolders=include_subfolders,
        include_folders=include_folders,
        include_empty_folders=include_empty_folders,
        ignore_extensions=ignore_extensions,
        ignore_paths=ignore_paths,
        ignore_aliases=ignore_aliases,
        ignore_folders=ignore_folders,
        include_tagged=include_tagged,
        ignore_tagged=ignore_tagged,
        skip_bundles=skip_bundles,
        logger=logger,
        extra_logging=extra_logging,
    )

    executed_moves, move_errors = execute_moves(plans, apply=args.apply, logger=logger)
    summary.errors += move_errors
    summary.moved = len(executed_moves)

    removed_empty_dirs: list[Path] = []
    if args.apply and remove_empty_folders:
        removed_empty_dirs = remove_empty_dirs(
            source_dir,
            excluded_roots={run_destination.resolve()},
            logger=logger,
        )

    if args.apply and executed_moves:
        tx_file = write_transaction(
            undo_dir=undo_dir,
            source_dir=source_dir,
            destination_dir=run_destination,
            executed_moves=executed_moves,
            removed_empty_dirs=removed_empty_dirs,
        )
        logger.info("UNDO RECORD: %s", tx_file)

    logger.info(
        "SUMMARY scanned=%d ignored=%d matched=%d planned=%d moved=%d collisions=%d errors=%d rules_used=%d",
        summary.scanned,
        summary.ignored,
        summary.matched,
        summary.planned_moves,
        summary.moved,
        summary.collisions,
        summary.errors,
        summary.rules_used,
    )
    logger.info(
        "REPORT total_targets=%d unclassified=%d fallback_mime=%d",
        summary.total_targets,
        summary.unclassified,
        summary.fallback_mime,
    )
    rule_hit_report = build_rule_hit_report(rules, summary)
    nonzero_rule_hits = [entry for entry in rule_hit_report if entry["hits"] > 0]
    if nonzero_rule_hits:
        logger.info(
            "RULE_HITS %s",
            ", ".join(f"{entry['rule_id']}:{entry['hits']}" for entry in nonzero_rule_hits),
        )
    else:
        logger.info("RULE_HITS (none)")

    if args.stats_json:
        stats_path = Path(args.stats_json).expanduser()
        payload = build_stats_payload(
            summary=summary,
            rules=rules,
            source_dir=source_dir,
            destination_dir=run_destination,
            apply=args.apply,
            priority_optimization=priority_optimization,
        )
        if not write_stats_json(stats_path, payload, logger):
            summary.errors += 1

    return 1 if summary.errors else 0


def run_rules_list(args: argparse.Namespace, logger: logging.Logger) -> int:
    base_rules = built_in_rules()
    config_path = Path(args.config).expanduser() if args.config else None
    try:
        config = load_config(config_path, base_rules)
    except Exception as exc:
        logger.error("failed to load config: %s", exc)
        return 2
    rules = apply_rule_overrides(base_rules, config)
    logger.info("RULE COUNT: %d (built-in=%d custom=%d)", len(rules), len(base_rules), len(config.custom_rules))
    for rule in rules:
        logger.info(format_rule_line(rule))
    return 0


def run_undo_list(args: argparse.Namespace, logger: logging.Logger) -> int:
    undo_dir = Path(args.undo_dir).expanduser()
    records = load_transactions(undo_dir)
    if not records:
        logger.info("No undo records found in %s", undo_dir)
        return 0
    logger.info("UNDO RECORDS: %d", len(records))
    for record in records:
        state = "done" if record.get("undone_at") else "pending"
        logger.info(
            "%s  %s  moves=%d  source=%s  destination=%s",
            record.get("id"),
            state,
            len(record.get("moves", [])) if isinstance(record.get("moves"), list) else 0,
            record.get("source_dir"),
            record.get("destination_dir"),
        )
    return 0


def run_undo(args: argparse.Namespace, logger: logging.Logger) -> int:
    undo_dir = Path(args.undo_dir).expanduser()
    records = load_transactions(undo_dir)
    target = pick_transaction(records, args.tx_id)
    if target is None:
        logger.error("undo record not found")
        return 2

    if target.get("undone_at"):
        logger.error("undo record already applied: %s", target.get("id"))
        return 2

    result = undo_transaction(target, apply=args.apply, logger=logger)
    if args.apply and result.errors == 0:
        mark_transaction_undone(target)

    logger.info(
        "UNDO SUMMARY restored=%d collisions=%d errors=%d",
        result.restored,
        result.collisions,
        result.errors,
    )
    return 1 if result.errors else 0


def run_undo_delete(args: argparse.Namespace, logger: logging.Logger) -> int:
    undo_dir = Path(args.undo_dir).expanduser()
    records = load_transactions(undo_dir)
    if args.tx_id is None and args.older_than_days is None:
        logger.error("specify --id or --older-than-days")
        return 2

    if not args.apply:
        preview = delete_transactions_preview(records, tx_id=args.tx_id, older_than_days=args.older_than_days)
        logger.info("DRY-RUN delete count=%d", preview)
        return 0

    deleted = delete_transactions(records, tx_id=args.tx_id, older_than_days=args.older_than_days)
    logger.info("deleted undo records=%d", deleted)
    return 0


def delete_transactions_preview(records: list[dict[str, Any]], *, tx_id: str | None, older_than_days: int | None) -> int:
    cutoff: datetime | None = None
    if older_than_days is not None:
        cutoff = now_utc() - timedelta(days=older_than_days)
    count = 0
    for record in records:
        if tx_id is not None and str(record.get("id")) != tx_id:
            continue
        if cutoff is not None:
            created_raw = record.get("created_at")
            try:
                created = datetime.fromisoformat(str(created_raw))
                if created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
            except Exception:
                continue
            if created >= cutoff:
                continue
        count += 1
    return count


def normalize_argv(argv: list[str] | None) -> list[str]:
    args = list(argv) if argv is not None else sys.argv[1:]
    known_commands = {"tidy", "rules-list", "undo-list", "undo", "undo-delete"}
    if not args:
        return ["tidy"]
    if any(token in known_commands for token in args):
        return args
    first = args[0]
    if first.startswith("-") or first not in known_commands:
        # compatibility mode: treat arguments as tidy flags when no subcommand is provided
        return ["tidy", *args]
    return args


def main(argv: list[str] | None = None) -> int:
    normalized = normalize_argv(argv)
    parser = build_parser()
    args = parser.parse_args(normalized)

    log_file = Path(args.log_file).expanduser() if getattr(args, "log_file", None) else None
    logger = configure_logging(verbose=getattr(args, "verbose", False), log_file=log_file)

    command = args.command or "tidy"
    if command == "tidy":
        return run_tidy(args, logger)
    if command == "rules-list":
        return run_rules_list(args, logger)
    if command == "undo-list":
        return run_undo_list(args, logger)
    if command == "undo":
        return run_undo(args, logger)
    if command == "undo-delete":
        return run_undo_delete(args, logger)

    parser.error(f"unknown command: {command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
