from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from downloads_organize.cli import built_in_rules, main


class FolderTidyStyleCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.source = self.root / "source"
        self.destination = self.root / "dest"
        self.undo = self.root / "undos"
        self.source.mkdir(parents=True, exist_ok=True)
        self.destination.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_rules_list_has_22_builtin_rules(self) -> None:
        self.assertEqual(len(built_in_rules()), 22)

    def test_default_tidy_is_dry_run(self) -> None:
        sample = self.source / "doc.pdf"
        sample.write_text("x", encoding="utf-8")

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertTrue(sample.exists())
        self.assertFalse((self.destination / "Documents" / "PDF" / "doc.pdf").exists())

    def test_apply_moves_file_and_creates_undo_record(self) -> None:
        sample = self.source / "doc.pdf"
        sample.write_text("x", encoding="utf-8")

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        moved = self.destination / "Documents" / "PDF" / "doc.pdf"
        self.assertTrue(moved.exists())
        self.assertFalse(sample.exists())
        records = list(self.undo.glob("*.json"))
        self.assertEqual(len(records), 1)

    def test_temp_extensions_are_ignored(self) -> None:
        temp_file = self.source / "video.mp4.part"
        temp_file.write_text("partial", encoding="utf-8")

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertTrue(temp_file.exists())
        self.assertFalse((self.destination / "Videos").exists())

    def test_partial_extension_is_ignored(self) -> None:
        temp_file = self.source / "archive.zip.partial"
        temp_file.write_text("partial", encoding="utf-8")

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertTrue(temp_file.exists())
        self.assertFalse((self.destination / "Archives").exists())

    def test_stats_json_is_written_in_dry_run(self) -> None:
        (self.source / "doc.pdf").write_text("x", encoding="utf-8")
        (self.source / "unknown.binx").write_text("x", encoding="utf-8")
        (self.source / "movie.mp4.part").write_text("partial", encoding="utf-8")
        stats_path = self.root / "reports" / "dry-run-stats.json"

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--stats-json",
                str(stats_path),
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertTrue(stats_path.exists())
        stats = json.loads(stats_path.read_text(encoding="utf-8"))
        self.assertEqual(stats["mode"], "dry-run")
        self.assertEqual(stats["total_targets"], 2)
        self.assertEqual(stats["unclassified"], 1)
        self.assertEqual(stats["fallback_mime"], 0)
        self.assertEqual(stats["summary"]["ignored"], 1)
        self.assertEqual(stats["summary"]["planned_moves"], 1)
        self.assertEqual(stats["summary"]["moved"], 0)
        self.assertEqual(stats["rule_hits_nonzero"].get("pdf_documents"), 1)
        self.assertFalse(stats["priority_optimization"]["enabled"])
        self.assertFalse(stats["priority_optimization"]["changed"])

    def test_stats_json_is_written_in_apply_mode(self) -> None:
        sample = self.source / "song.mp3"
        sample.write_text("audio", encoding="utf-8")
        stats_path = self.root / "reports" / "apply-stats.json"

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--stats-json",
                str(stats_path),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertFalse(sample.exists())
        self.assertTrue((self.destination / "Audio" / "song.mp3").exists())
        self.assertTrue(stats_path.exists())
        stats = json.loads(stats_path.read_text(encoding="utf-8"))
        self.assertEqual(stats["mode"], "apply")
        self.assertEqual(stats["summary"]["planned_moves"], 1)
        self.assertEqual(stats["summary"]["moved"], 1)
        self.assertEqual(stats["rule_hits_nonzero"].get("audio"), 1)
        self.assertFalse(stats["priority_optimization"]["enabled"])

    def test_optimize_priority_reorders_rules_and_reports_order(self) -> None:
        config = self.root / "optimize.toml"
        config.write_text(
            "\n".join(
                [
                    "[rules]",
                    "order = [\"custom_wide\", \"custom_narrow\"]",
                    "",
                    "[custom_rules.wide]",
                    "description = \"Wide custom\"",
                    "subfolder = \"Custom/Wide\"",
                    "mode = \"all\"",
                    "enabled = true",
                    "extensions = [\".zzz\", \".zz1\", \".zz2\", \".zz3\"]",
                    "",
                    "[custom_rules.narrow]",
                    "description = \"Narrow custom\"",
                    "subfolder = \"Custom/Narrow\"",
                    "mode = \"all\"",
                    "enabled = true",
                    "extensions = [\".zzz\"]",
                ]
            ),
            encoding="utf-8",
        )

        # Baseline: without optimize-priority, custom_wide wins because it's first.
        baseline_file = self.source / "target.zzz"
        baseline_file.write_text("x", encoding="utf-8")
        baseline_exit = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--config",
                str(config),
                "--apply",
            ]
        )
        self.assertEqual(baseline_exit, 0)
        self.assertTrue((self.destination / "Custom" / "Wide" / "target.zzz").exists())

        # With optimize-priority, narrower rule gets higher priority.
        source_opt = self.root / "source_opt"
        destination_opt = self.root / "dest_opt"
        undo_opt = self.root / "undos_opt"
        source_opt.mkdir(parents=True, exist_ok=True)
        destination_opt.mkdir(parents=True, exist_ok=True)
        (source_opt / "target.zzz").write_text("x", encoding="utf-8")
        stats_path = self.root / "reports" / "optimize-stats.json"

        log_buffer = io.StringIO()
        with contextlib.redirect_stdout(log_buffer):
            optimize_exit = main(
                [
                    "tidy",
                    "--source",
                    str(source_opt),
                    "--destination",
                    str(destination_opt),
                    "--undo-dir",
                    str(undo_opt),
                    "--config",
                    str(config),
                    "--apply",
                    "--optimize-priority",
                    "--stats-json",
                    str(stats_path),
                ]
            )

        self.assertEqual(optimize_exit, 0)
        self.assertTrue((destination_opt / "Custom" / "Narrow" / "target.zzz").exists())

        logs = log_buffer.getvalue()
        self.assertIn("OPTIMIZE_PRIORITY enabled=True", logs)
        self.assertIn("OPTIMIZE_ORDER before=", logs)
        self.assertIn("OPTIMIZE_ORDER after=", logs)

        stats = json.loads(stats_path.read_text(encoding="utf-8"))
        self.assertTrue(stats["priority_optimization"]["enabled"])
        self.assertTrue(stats["priority_optimization"]["changed"])
        self.assertEqual(stats["priority_optimization"]["before_order"][0], "custom_wide")
        self.assertEqual(stats["priority_optimization"]["after_order"][0], "custom_narrow")

    def test_collision_is_renamed(self) -> None:
        existing = self.destination / "Documents" / "PDF" / "doc.pdf"
        existing.parent.mkdir(parents=True, exist_ok=True)
        existing.write_text("old", encoding="utf-8")

        sample = self.source / "doc.pdf"
        sample.write_text("new", encoding="utf-8")

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertTrue(existing.exists())
        self.assertTrue((self.destination / "Documents" / "PDF" / "doc (1).pdf").exists())

    def test_custom_rule_with_predicates(self) -> None:
        screenshot = self.source / "screenshot-001.png"
        screenshot.write_text("png", encoding="utf-8")

        config = self.root / "config.toml"
        config.write_text(
            "\n".join(
                [
                    "[rules]",
                    "disable = [\"screenshots\", \"png_images\"]",
                    "",
                    "[custom_rules.recent_shots]",
                    "description = \"Screenshots from the last 2 weeks\"",
                    "subfolder = \"Recent Screenshots\"",
                    "mode = \"all\"",
                    "enabled = true",
                    "kind = \"image_png\"",
                    "name_contains = \"screenshot\"",
                    "created_within_days = 14",
                ]
            ),
            encoding="utf-8",
        )

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--config",
                str(config),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertFalse(screenshot.exists())
        self.assertTrue((self.destination / "Recent Screenshots" / "screenshot-001.png").exists())

    def test_japanese_screenshot_name_matches_builtin_rule(self) -> None:
        screenshot = self.source / "スクリーンショット 2026-02-07 12.00.00.png"
        screenshot.write_text("png", encoding="utf-8")

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertFalse(screenshot.exists())
        self.assertTrue((self.destination / "Screenshots" / screenshot.name).exists())

    def test_extension_override_via_config(self) -> None:
        log_file = self.source / "server.log"
        log_file.write_text("line", encoding="utf-8")

        config = self.root / "config.toml"
        config.write_text(
            "\n".join(
                [
                    "[extension_rules]",
                    "code = [\".log\"]",
                ]
            ),
            encoding="utf-8",
        )

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--config",
                str(config),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertTrue((self.destination / "Code" / "server.log").exists())

    def test_epub_is_classified_as_documents_word(self) -> None:
        book = self.source / "book.epub"
        book.write_text("ebook", encoding="utf-8")

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertTrue((self.destination / "Documents" / "Word" / "book.epub").exists())

    def test_sql_is_classified_as_code(self) -> None:
        sql = self.source / "query.sql"
        sql.write_text("select 1;", encoding="utf-8")

        exit_code = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )

        self.assertEqual(exit_code, 0)
        self.assertTrue((self.destination / "Code" / "query.sql").exists())

    def test_undo_restores_last_transaction(self) -> None:
        sample = self.source / "doc.pdf"
        sample.write_text("x", encoding="utf-8")

        tidy_exit = main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )
        self.assertEqual(tidy_exit, 0)
        moved = self.destination / "Documents" / "PDF" / "doc.pdf"
        self.assertTrue(moved.exists())

        undo_exit = main(
            [
                "undo",
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )
        self.assertEqual(undo_exit, 0)
        self.assertTrue(sample.exists())
        self.assertFalse(moved.exists())

        record_file = next(self.undo.glob("*.json"))
        record = json.loads(record_file.read_text(encoding="utf-8"))
        self.assertIsNotNone(record["undone_at"])

    def test_undo_delete_dry_run_does_not_delete(self) -> None:
        sample = self.source / "doc.pdf"
        sample.write_text("x", encoding="utf-8")
        main(
            [
                "tidy",
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
                "--undo-dir",
                str(self.undo),
                "--apply",
            ]
        )

        before = list(self.undo.glob("*.json"))
        self.assertEqual(len(before), 1)
        tx_id = before[0].stem

        delete_exit = main(["undo-delete", "--undo-dir", str(self.undo), "--id", tx_id])
        self.assertEqual(delete_exit, 0)
        after = list(self.undo.glob("*.json"))
        self.assertEqual(len(after), 1)


if __name__ == "__main__":
    unittest.main()
