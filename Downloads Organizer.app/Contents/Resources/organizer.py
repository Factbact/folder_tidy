#!/usr/bin/env python3
"""
Downloads Organizer - GUI App with Undo Support
Uses AppleScript dialogs for Mac-native experience
"""

import json
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# Default rules
DEFAULT_RULES = {
    "Documents": [".pdf", ".doc", ".docx", ".txt", ".rtf", ".md"],
    "Spreadsheets": [".xls", ".xlsx", ".csv"],
    "Presentations": [".ppt", ".pptx"],
    "Images": [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".bmp", ".svg"],
    "Videos": [".mp4", ".mov", ".mkv", ".avi", ".wmv", ".webm"],
    "Audio": [".mp3", ".wav", ".m4a", ".aac", ".flac"],
    "Archives": [".zip", ".rar", ".7z", ".tar", ".gz", ".tar.gz", ".tgz"],
    "Installers": [".dmg", ".pkg", ".msi", ".exe"],
}

DEFAULT_IGNORE = {".crdownload", ".part", ".download", ".tmp"}

# History file for undo
HISTORY_FILE = Path.home() / ".downloads_organizer_history.json"


def show_dialog(message, title="Downloads Organizer", buttons=["OK"], default_button="OK"):
    """Show a native Mac dialog using AppleScript."""
    buttons_str = ", ".join(f'"{b}"' for b in buttons)
    script = f'''
    display dialog "{message}" with title "{title}" buttons {{{buttons_str}}} default button "{default_button}"
    '''
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            # Parse button pressed
            output = result.stdout.strip()
            if "button returned:" in output:
                return output.split("button returned:")[-1].strip()
        return None
    except Exception:
        return None


def show_notification(message, title="Downloads Organizer"):
    """Show a Mac notification."""
    script = f'display notification "{message}" with title "{title}"'
    subprocess.run(["osascript", "-e", script], capture_output=True)


def get_extension(filename):
    """Get the longest matching extension."""
    lower_name = filename.lower()
    all_extensions = set()
    for exts in DEFAULT_RULES.values():
        all_extensions.update(exts)
    all_extensions.update(DEFAULT_IGNORE)
    
    best_match = None
    for ext in all_extensions:
        if lower_name.endswith(ext):
            if best_match is None or len(ext) > len(best_match):
                best_match = ext
    return best_match


def get_category(extension):
    """Get category for an extension."""
    for category, extensions in DEFAULT_RULES.items():
        if extension in extensions:
            return category
    return None


def load_history():
    """Load move history from file."""
    if HISTORY_FILE.exists():
        try:
            with open(HISTORY_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return []
    return []


def save_history(history):
    """Save move history to file."""
    try:
        with open(HISTORY_FILE, "w", encoding="utf-8") as f:
            json.dump(history, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"Failed to save history: {e}")


def organize_downloads(downloads_dir, dry_run=False):
    """Organize files and return list of moves."""
    downloads_path = Path(downloads_dir).expanduser()
    
    if not downloads_path.exists():
        show_dialog(f"フォルダが見つかりません:\n{downloads_path}", buttons=["OK"])
        return []
    
    moves = []
    files = [f for f in downloads_path.iterdir() if f.is_file()]
    
    for source in sorted(files, key=lambda p: p.name.lower()):
        ext = get_extension(source.name)
        
        if ext in DEFAULT_IGNORE:
            continue
        
        category = get_category(ext) if ext else None
        if not category:
            continue
        
        dest_dir = downloads_path / category
        dest = dest_dir / source.name
        
        # Handle collision
        if dest.exists():
            base = source.stem
            suffix = source.suffix
            index = 1
            while dest.exists():
                dest = dest_dir / f"{base} ({index}){suffix}"
                index += 1
        
        moves.append({
            "source": str(source),
            "destination": str(dest),
            "category": category
        })
    
    if dry_run:
        return moves
    
    # Actually move files
    successful_moves = []
    for move in moves:
        try:
            dest_path = Path(move["destination"])
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(move["source"], move["destination"])
            successful_moves.append(move)
        except Exception as e:
            print(f"Error moving {move['source']}: {e}")
    
    # Save to history for undo
    if successful_moves:
        history = load_history()
        history.append({
            "timestamp": datetime.now().isoformat(),
            "moves": successful_moves
        })
        # Keep only last 10 operations
        history = history[-10:]
        save_history(history)
    
    return successful_moves


def undo_last_organize():
    """Undo the last organize operation."""
    history = load_history()
    
    if not history:
        show_dialog("元に戻す履歴がありません。", buttons=["OK"])
        return 0
    
    last_operation = history[-1]
    moves = last_operation["moves"]
    timestamp = last_operation["timestamp"]
    
    # Show confirmation
    result = show_dialog(
        f"最後の整理操作を元に戻しますか？\n\n"
        f"実行日時: {timestamp[:19].replace('T', ' ')}\n"
        f"移動ファイル数: {len(moves)}件",
        buttons=["キャンセル", "元に戻す"],
        default_button="元に戻す"
    )
    
    if result != "元に戻す":
        return 0
    
    # Undo moves
    restored = 0
    for move in reversed(moves):
        try:
            source = Path(move["destination"])
            dest = Path(move["source"])
            
            if source.exists() and not dest.exists():
                shutil.move(str(source), str(dest))
                restored += 1
                
                # Remove empty category folder
                if source.parent.exists() and not any(source.parent.iterdir()):
                    source.parent.rmdir()
        except Exception as e:
            print(f"Error restoring {move['destination']}: {e}")
    
    # Remove from history
    history.pop()
    save_history(history)
    
    show_notification(f"{restored}件のファイルを元の場所に戻しました")
    return restored


def main():
    downloads_dir = Path.home() / "Downloads"
    
    # Show main menu
    while True:
        result = show_dialog(
            f"対象フォルダ: {downloads_dir}\n\n"
            "何をしますか？",
            buttons=["終了", "元に戻す", "プレビュー", "整理実行"],
            default_button="プレビュー"
        )
        
        if result == "終了" or result is None:
            break
        
        elif result == "プレビュー":
            moves = organize_downloads(downloads_dir, dry_run=True)
            if not moves:
                show_dialog("整理するファイルがありません。", buttons=["OK"])
            else:
                # Show preview (max 10 files)
                preview_text = "\n".join(
                    f"• {Path(m['source']).name} → {m['category']}/"
                    for m in moves[:10]
                )
                if len(moves) > 10:
                    preview_text += f"\n\n...他 {len(moves) - 10} 件"
                
                show_dialog(
                    f"移動予定のファイル ({len(moves)}件):\n\n{preview_text}",
                    buttons=["OK"]
                )
        
        elif result == "整理実行":
            # Confirm before executing
            moves = organize_downloads(downloads_dir, dry_run=True)
            if not moves:
                show_dialog("整理するファイルがありません。", buttons=["OK"])
                continue
            
            confirm = show_dialog(
                f"{len(moves)}件のファイルを整理しますか？",
                buttons=["キャンセル", "実行"],
                default_button="実行"
            )
            
            if confirm == "実行":
                moved = organize_downloads(downloads_dir, dry_run=False)
                show_notification(f"{len(moved)}件のファイルを整理しました！")
                show_dialog(
                    f"完了！\n\n{len(moved)}件のファイルを整理しました。\n\n"
                    "「元に戻す」で復元できます。",
                    buttons=["OK"]
                )
        
        elif result == "元に戻す":
            undo_last_organize()


if __name__ == "__main__":
    main()
