"""Test the native CLI's report and exit status together."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "examples" / "orders" / "schema.sql"
MIGRATION = ROOT / "examples" / "orders" / "add-unique.sql"


class CliIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.check_output(
            ["moon", "build", "--target", "native", "--output-json", "cmd/moon-ddl"],
            cwd=ROOT, encoding="utf-8",
        )
        artifacts = (json.loads(line) for line in result.splitlines() if line.strip())
        cls.executable = next(
            item["path"] for item in artifacts if item.get("$message_type") == "artifact"
        )

    def run_cli(self, *args):
        return subprocess.run(
            [self.executable, *args], cwd=ROOT, text=True, encoding="utf-8",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def check_sql(self, sql, *options):
        with tempfile.TemporaryDirectory() as directory:
            migration = Path(directory) / "migration.sql"
            migration.write_text(sql, encoding="utf-8")
            return self.run_cli("check", "--schema", SCHEMA, "--migration", migration, *options)

    def test_gate_keeps_the_full_report(self):
        plain = self.run_cli("check", "--schema", SCHEMA, "--migration", MIGRATION)
        gated = self.run_cli(
            "check", "--fail-on-findings", "--migration", MIGRATION, "--schema", SCHEMA
        )
        self.assertEqual(plain.returncode, 0)
        self.assertEqual(gated.returncode, 1)
        self.assertEqual(gated.stdout, plain.stdout)
        self.assertIn("待核查 1 项，未分析 0 项", gated.stdout)
        self.assertEqual(gated.stderr, "")

    def test_unanalyzed_statement_fails_the_gate(self):
        result = self.check_sql("ALTER TABLE orders ADD INDEX (payment_no);", "--fail-on-findings")
        self.assertEqual(result.returncode, 1)
        self.assertIn("待核查 0 项，未分析 1 项", result.stdout)

    def test_empty_report_passes_the_gate(self):
        result = self.check_sql("ALTER TABLE orders MODIFY id BIGINT NOT NULL;", "--fail-on-findings")
        self.assertEqual(result.returncode, 0)
        self.assertIn("待核查 0 项，未分析 0 项", result.stdout)

    def test_input_and_argument_errors_keep_exit_code_two(self):
        invalid = self.check_sql("ALTER TABLE orders ADD UNIQUE (", "--fail-on-findings")
        missing = self.run_cli("check", "--schema", SCHEMA, "--migration", "missing.sql", "--fail-on-findings")
        args = self.run_cli("check", "--fail-on-findings", "--migration", MIGRATION, "--schema")
        for result in (invalid, missing, args):
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertTrue(result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
