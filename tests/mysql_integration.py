"""Compare MoonDDL's report to real MySQL 8.4 behavior in a test database."""
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples" / "orders"
DATABASE = "moonddl_test"


def read_sql(name):
    return (EXAMPLES / name).read_text(encoding="utf-8")


def mysql(sql, expected_error=None):
    command = [
        os.environ.get("MYSQL_BIN", "mysql"),
        "--protocol=TCP",
        "--host=" + os.environ.get("MYSQL_HOST", "127.0.0.1"),
        "--port=" + os.environ.get("MYSQL_PORT", "3306"),
        "--user=" + os.environ.get("MYSQL_USER", "moonddl"),
        "--default-character-set=utf8mb4",
        "--batch",
        "--skip-column-names",
        DATABASE,
    ]
    result = subprocess.run(
        command, input=sql, text=True, encoding="utf-8", capture_output=True, check=False
    )
    if expected_error is None:
        if result.returncode:
            raise AssertionError(result.stderr)
    elif not result.returncode or f"ERROR {expected_error} " not in result.stderr:
        raise AssertionError(f"Expected MySQL error {expected_error}, got {result.stderr!r}")
    return result.stdout.strip()


def report(migration):
    command = [os.environ["MOONDDL_BIN"]] if "MOONDDL_BIN" in os.environ else [
        "moon", "run", "--target", "native", "cmd/moon-ddl", "--"
    ]
    return subprocess.check_output(
        command + [
            "check", "--schema", "examples/orders/schema.sql",
            "--migration", f"examples/orders/{migration}",
        ],
        cwd=ROOT, encoding="utf-8",
    )


def query_for(migration):
    queries = re.findall(r"^```sql\n(.*?)\n^```$", report(migration), re.M | re.S)
    if len(queries) != 1:
        raise AssertionError(f"Expected one query for {migration}, got {len(queries)}")
    return queries[0]


class MySQLIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        version = mysql("SELECT VERSION();")
        if not version.startswith("8.4."):
            raise AssertionError(f"Expected MySQL 8.4, got {version}")

    def setUp(self):
        mysql("DROP TABLE IF EXISTS orders;\n" + read_sql("schema.sql"))
        self.addCleanup(mysql, "DROP TABLE IF EXISTS orders;")

    def test_duplicate_detection_and_repaired_data(self):
        mysql(read_sql("duplicates.sql"))
        query = query_for("add-unique.sql")
        self.assertEqual(mysql(query), "PAY-1001\t2")
        mysql(read_sql("add-unique.sql"), expected_error=1062)
        mysql("UPDATE orders SET payment_no = 'PAY-1002' WHERE id = 2;")
        self.assertEqual(mysql(query), "")
        mysql(read_sql("add-unique.sql"))

    def test_unique_allows_multiple_nulls(self):
        mysql("INSERT INTO orders (id, payment_no) VALUES (1, NULL), (2, NULL), (3, 'PAY-1');")
        self.assertEqual(mysql(query_for("add-unique.sql")), "")
        mysql(read_sql("add-unique.sql"))


    def test_composite_unique_detects_only_duplicate_nonnull_pairs(self):
        mysql(
            "INSERT INTO orders (id, merchant_id, payment_no) VALUES "
            "(1, 10, 'PAY-1'), (2, 10, 'PAY-1'), (3, 20, 'PAY-1'), "
            "(4, NULL, 'PAY-1'), (5, NULL, 'PAY-1'), "
            "(6, 10, NULL), (7, 10, NULL), (8, NULL, NULL), (9, NULL, NULL);"
        )
        query = query_for("add-merchant-payment-unique.sql")
        self.assertEqual(mysql(query), "10\tPAY-1\t2")
        mysql(read_sql("add-merchant-payment-unique.sql"), expected_error=1062)
        mysql("UPDATE orders SET payment_no = 'PAY-2' WHERE id = 2;")
        self.assertEqual(mysql(query), "")
        mysql(read_sql("add-merchant-payment-unique.sql"))

    def test_create_unique_index_reuses_composite_check(self):
        mysql(
            "INSERT INTO orders (id, merchant_id, payment_no) VALUES "
            "(1, 10, 'PAY-1'), (2, 10, 'PAY-1'), (3, 20, 'PAY-1'), "
            "(4, 10, NULL), (5, 10, NULL);"
        )
        migration = "create-unique-index.sql"
        query = query_for(migration)
        self.assertEqual(query, query_for("add-merchant-payment-unique.sql"))
        self.assertEqual(mysql(query), "10\tPAY-1\t2")
        mysql(read_sql(migration), expected_error=1062)
        mysql("UPDATE orders SET payment_no = 'PAY-2' WHERE id = 2;")
        self.assertEqual(mysql(query), "")
        mysql(read_sql(migration))

    def test_nullability_query_matches_strict_mysql(self):
        mysql("INSERT INTO orders (id, payment_no) VALUES (1, NULL), (2, 'PAY-1');")
        self.assertEqual(mysql(query_for("require-payment.sql")), "1")
        mysql(
            "SET SESSION sql_mode = 'STRICT_ALL_TABLES';\n" + read_sql("require-payment.sql"),
            expected_error=1138,
        )
        mysql("UPDATE orders SET payment_no = 'PAY-2' WHERE id = 1;")
        self.assertEqual(mysql(query_for("require-payment.sql")), "0")
        mysql("SET SESSION sql_mode = 'STRICT_ALL_TABLES';\n" + read_sql("require-payment.sql"))


    def test_drop_column_reports_manual_review(self):
        output = report("drop-legacy-note.sql")
        self.assertIn("待核查 1 项，未分析 0 项", output)
        self.assertIn("examples/orders/drop-legacy-note.sql:1", output)
        self.assertIn("orders.legacy\\_note", output)
        self.assertIn("MyBatis XML", output)
        self.assertNotIn("```sql", output)
        mysql("INSERT INTO orders (id, payment_no, legacy_note) VALUES (1, 'PAY-1', 'old value');")
        mysql(read_sql("drop-legacy-note.sql"))
        columns = mysql(
            "SELECT COLUMN_NAME FROM information_schema.COLUMNS "
            "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders' ORDER BY ORDINAL_POSITION;"
        )
        self.assertEqual(columns.splitlines(), ["id", "merchant_id", "payment_no"])
        self.assertEqual(mysql("SELECT payment_no FROM orders WHERE id = 1;"), "PAY-1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
