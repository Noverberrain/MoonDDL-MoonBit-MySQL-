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
        mysql("INSERT INTO orders VALUES (1, NULL, NULL), (2, NULL, NULL), (3, 'PAY-1', NULL);")
        self.assertEqual(mysql(query_for("add-unique.sql")), "")
        mysql(read_sql("add-unique.sql"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
