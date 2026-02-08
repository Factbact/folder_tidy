"""GUI application for Downloads Organizer."""
from __future__ import annotations

import logging
import shutil
import tkinter as tk
from dataclasses import dataclass
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Callable


# Default rules (same as cli.py)
DEFAULT_RULES: dict[str, list[str]] = {
    "Documents": [".pdf", ".doc", ".docx", ".txt", ".rtf", ".md"],
    "Spreadsheets": [".xls", ".xlsx", ".csv"],
    "Presentations": [".ppt", ".pptx"],
    "Images": [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".bmp", ".svg"],
    "Videos": [".mp4", ".mov", ".mkv", ".avi", ".wmv", ".webm"],
    "Audio": [".mp3", ".wav", ".m4a", ".aac", ".flac"],
    "Archives": [".zip", ".rar", ".7z", ".tar", ".gz", ".tar.gz", ".tgz"],
    "Installers": [".dmg", ".pkg", ".msi", ".exe"],
}

DEFAULT_IGNORE_EXTENSIONS: set[str] = {".crdownload", ".part", ".download", ".tmp"}


@dataclass
class Summary:
    scanned: int = 0
    excluded: int = 0
    unclassified: int = 0
    planned_moves: int = 0
    moved: int = 0
    collisions: int = 0
    errors: int = 0


def normalize_extension(raw_extension: str) -> str:
    ext = raw_extension.strip().lower()
    if not ext:
        raise ValueError("extension cannot be empty")
    if not ext.startswith("."):
        ext = f".{ext}"
    return ext


def dedupe(items: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def build_effective_rules(overrides: dict[str, list[str]]) -> dict[str, list[str]]:
    rules = {category: dedupe([normalize_extension(ext) for ext in exts]) for category, exts in DEFAULT_RULES.items()}
    for category, exts in overrides.items():
        rules[category] = dedupe([normalize_extension(ext) for ext in exts])
    return rules


def build_extension_to_category(rules: dict[str, list[str]]) -> dict[str, str]:
    extension_map: dict[str, str] = {}
    for category, extensions in rules.items():
        for ext in extensions:
            extension_map[ext] = category
    return extension_map


def find_longest_matching_extension(filename: str, extensions: set[str]) -> str | None:
    lower_name = filename.lower()
    best_match: str | None = None
    for ext in extensions:
        if lower_name.endswith(ext):
            if best_match is None or len(ext) > len(best_match):
                best_match = ext
    return best_match


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
        candidate_name = f"{base} ({index}){suffix}"
        candidate = target.with_name(candidate_name)
        if not candidate.exists() and candidate not in occupied_targets:
            return candidate, True
        index += 1


def iter_files(root: Path) -> list[Path]:
    return [entry for entry in sorted(root.iterdir(), key=lambda p: p.name.lower()) if entry.is_file()]


class LogHandler(logging.Handler):
    """Custom log handler that writes to a callback function."""

    def __init__(self, callback: Callable[[str], None]) -> None:
        super().__init__()
        self.callback = callback

    def emit(self, record: logging.LogRecord) -> None:
        msg = self.format(record)
        self.callback(msg)


class DownloadsOrganizerApp:
    """Main GUI application class."""

    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Downloads Organizer")
        self.root.geometry("700x500")
        self.root.minsize(500, 400)

        # Default directory
        self.downloads_dir = Path.home() / "Downloads"

        # Setup logger
        self.logger = logging.getLogger("downloads_organize_gui")
        self.logger.handlers.clear()
        self.logger.setLevel(logging.INFO)

        self._create_widgets()
        self._setup_logger()

    def _create_widgets(self) -> None:
        """Create all GUI widgets."""
        # Main container with padding
        main_frame = ttk.Frame(self.root, padding="10")
        main_frame.pack(fill=tk.BOTH, expand=True)

        # --- Directory selection ---
        dir_frame = ttk.LabelFrame(main_frame, text="対象フォルダ", padding="5")
        dir_frame.pack(fill=tk.X, pady=(0, 10))

        self.dir_var = tk.StringVar(value=str(self.downloads_dir))
        dir_entry = ttk.Entry(dir_frame, textvariable=self.dir_var, state="readonly")
        dir_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5))

        browse_btn = ttk.Button(dir_frame, text="選択...", command=self._browse_directory)
        browse_btn.pack(side=tk.RIGHT)

        # --- Preview area ---
        preview_frame = ttk.LabelFrame(main_frame, text="プレビュー", padding="5")
        preview_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 10))

        # Text widget with scrollbar
        text_scroll = ttk.Scrollbar(preview_frame)
        text_scroll.pack(side=tk.RIGHT, fill=tk.Y)

        self.preview_text = tk.Text(
            preview_frame,
            height=15,
            wrap=tk.WORD,
            yscrollcommand=text_scroll.set,
            font=("Menlo", 11),
        )
        self.preview_text.pack(fill=tk.BOTH, expand=True)
        text_scroll.config(command=self.preview_text.yview)

        # Configure text tags for colors
        self.preview_text.tag_configure("move", foreground="#2E7D32")
        self.preview_text.tag_configure("skip", foreground="#757575")
        self.preview_text.tag_configure("error", foreground="#C62828")
        self.preview_text.tag_configure("summary", foreground="#1565C0", font=("Menlo", 11, "bold"))

        # --- Button area ---
        button_frame = ttk.Frame(main_frame)
        button_frame.pack(fill=tk.X)

        self.preview_btn = ttk.Button(
            button_frame, text="プレビュー更新", command=self._run_preview
        )
        self.preview_btn.pack(side=tk.LEFT, padx=(0, 10))

        self.apply_btn = ttk.Button(
            button_frame, text="整理を実行", command=self._run_apply
        )
        self.apply_btn.pack(side=tk.LEFT)

        # Status label
        self.status_var = tk.StringVar(value="準備完了")
        status_label = ttk.Label(button_frame, textvariable=self.status_var)
        status_label.pack(side=tk.RIGHT)

    def _setup_logger(self) -> None:
        """Setup logger with custom handler."""
        handler = LogHandler(self._log_message)
        handler.setFormatter(logging.Formatter("%(message)s"))
        self.logger.addHandler(handler)

    def _log_message(self, message: str) -> None:
        """Append message to preview text."""
        tag = None
        if "MOVE:" in message or "DRY-RUN move:" in message:
            tag = "move"
        elif "SKIP" in message:
            tag = "skip"
        elif "ERROR" in message:
            tag = "error"
        elif "SUMMARY" in message:
            tag = "summary"

        self.preview_text.insert(tk.END, message + "\n", tag)
        self.preview_text.see(tk.END)
        self.root.update_idletasks()

    def _browse_directory(self) -> None:
        """Open directory selection dialog."""
        directory = filedialog.askdirectory(
            initialdir=self.downloads_dir,
            title="整理するフォルダを選択",
        )
        if directory:
            self.downloads_dir = Path(directory)
            self.dir_var.set(str(self.downloads_dir))

    def _clear_preview(self) -> None:
        """Clear the preview text area."""
        self.preview_text.delete("1.0", tk.END)

    def _organize(self, apply: bool) -> Summary:
        """Run the organize operation."""
        summary = Summary()
        rules = build_effective_rules({})
        ignore_extensions = set(DEFAULT_IGNORE_EXTENSIONS)
        extension_to_category = build_extension_to_category(rules)
        known_extensions = set(extension_to_category) | ignore_extensions
        occupied_targets: set[Path] = set()

        for source in iter_files(self.downloads_dir):
            summary.scanned += 1
            matched_ext = find_longest_matching_extension(source.name, known_extensions)

            if matched_ext in ignore_extensions:
                summary.excluded += 1
                self.logger.info("SKIP (無視): %s", source.name)
                continue

            if not matched_ext or matched_ext not in extension_to_category:
                summary.unclassified += 1
                continue

            category = extension_to_category[matched_ext]
            destination_dir = self.downloads_dir / category
            destination = destination_dir / source.name
            destination, collided = resolve_collision(destination, occupied_targets)
            occupied_targets.add(destination)

            if collided:
                summary.collisions += 1

            summary.planned_moves += 1

            if not apply:
                self.logger.info("移動予定: %s → %s/", source.name, category)
                continue

            try:
                destination_dir.mkdir(parents=True, exist_ok=True)
                import shutil
                shutil.move(str(source), str(destination))
                summary.moved += 1
                self.logger.info("MOVE: %s → %s/", source.name, category)
            except Exception as exc:
                summary.errors += 1
                self.logger.error("ERROR: %s の移動に失敗 (%s)", source.name, exc)

        return summary

    def _run_preview(self) -> None:
        """Run preview (dry-run)."""
        self._clear_preview()
        self.status_var.set("プレビュー中...")
        self.root.update_idletasks()

        if not self.downloads_dir.exists():
            messagebox.showerror("エラー", f"フォルダが見つかりません: {self.downloads_dir}")
            self.status_var.set("エラー")
            return

        summary = self._organize(apply=False)

        self.logger.info("")
        self.logger.info(
            "SUMMARY: スキャン=%d, 移動予定=%d, 未分類=%d",
            summary.scanned,
            summary.planned_moves,
            summary.unclassified,
        )
        self.status_var.set(f"プレビュー完了: {summary.planned_moves}件の移動予定")

    def _run_apply(self) -> None:
        """Run actual file organization."""
        if not self.downloads_dir.exists():
            messagebox.showerror("エラー", f"フォルダが見つかりません: {self.downloads_dir}")
            return

        # Confirm before applying
        result = messagebox.askyesno(
            "確認",
            f"ファイルを整理しますか？\n\n対象: {self.downloads_dir}",
        )
        if not result:
            return

        self._clear_preview()
        self.status_var.set("整理中...")
        self.root.update_idletasks()

        summary = self._organize(apply=True)

        self.logger.info("")
        self.logger.info(
            "SUMMARY: 移動=%d, エラー=%d",
            summary.moved,
            summary.errors,
        )

        if summary.errors:
            self.status_var.set(f"完了 (エラー: {summary.errors}件)")
            messagebox.showwarning("完了", f"{summary.moved}件のファイルを移動しました。\nエラー: {summary.errors}件")
        else:
            self.status_var.set(f"完了: {summary.moved}件を移動")
            messagebox.showinfo("完了", f"{summary.moved}件のファイルを整理しました！")


def main() -> None:
    """Entry point for GUI application."""
    root = tk.Tk()
    
    # Set macOS native appearance if available
    try:
        root.tk.call("::tk::unsupported::MacWindowStyle", "style", root._w, "document", "closeBox")
    except tk.TclError:
        pass
    
    DownloadsOrganizerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
