///|
fn review_migration(
  migration : String,
  schema~ : String = "CREATE TABLE orders (id BIGINT, payment_no VARCHAR(64) DEFAULT NULL, PRIMARY KEY (id));",
) -> String raise ScanError {
  review(
    schema,
    migration,
    schema_path="schema.sql",
    migration_path="migration.sql",
  )
}

///|
test "unique index yields a read-only query with the statement line" {
  let report = review_migration(
    "# header\r\n\r\nALTER TABLE orders\n ADD UNIQUE KEY uk_pay (payment_no);",
  )
  assert_true(report.contains("待核查 1 项，未分析 0 项"))
  assert_true(report.contains("migration.sql:3"))
  assert_true(report.contains("WHERE \u0060payment_no\u0060 IS NOT NULL"))
  assert_true(
    report.contains("GROUP BY \u0060payment_no\u0060\nHAVING COUNT(*) > 1;"),
  )
}

///|
test "NOT NULL detects nullable columns even in SHOW CREATE TABLE style" {
  let report = review_migration(
    "ALTER TABLE orders MODIFY COLUMN payment_no VARCHAR(64) NOT NULL;",
  )
  assert_true(report.contains("待核查 1 项，未分析 0 项"))
  assert_true(report.contains("WHERE \u0060payment_no\u0060 IS NULL;"))
}

///|
test "already required fields including primary-key columns need no null check" {
  let report = review_migration("ALTER TABLE orders MODIFY id BIGINT NOT NULL;")
  assert_true(report.contains("待核查 0 项，未分析 0 项"))
  let explicit = review_migration(
    "ALTER TABLE orders MODIFY id BIGINT NOT NULL;",
    schema="CREATE TABLE orders (id BIGINT NOT NULL);",
  )
  assert_true(explicit.contains("待核查 0 项，未分析 0 项"))
}

///|
test "changed type and collation are not evaluated against the old column" {
  for
    migration in [
      "ALTER TABLE orders MODIFY payment_no VARCHAR(32) NOT NULL;", "ALTER TABLE orders MODIFY payment_no VARCHAR(64) COLLATE utf8mb4_bin NOT NULL;",
    ] {
    let report = review_migration(migration)
    assert_true(report.contains("待核查 0 项，未分析 1 项"))
    assert_false(report.contains("SELECT"))
  }
}

///|
test "quoted semicolons, comments, and nested commas are not split points" {
  let report = review_migration(
    "/* DROP COLUMN fake;\n   ALTER TABLE fake; */\nALTER TABLE orders ADD UNIQUE (code);",
    schema="CREATE TABLE orders (code ENUM('a,b', 'x;NOT NULL', 'it''s') COMMENT 'semi; and \\'quoted\\'');",
  )
  assert_true(report.contains("migration.sql:3"))
  assert_true(report.contains("待核查 1 项，未分析 0 项"))
}

///|
test "backtick escapes round trip in generated SQL" {
  let report = review_migration(
    "ALTER TABLE \u0060order\u0060 ADD UNIQUE (\u0060pay\u0060\u0060ment\u0060);",
    schema="CREATE TABLE \u0060order\u0060 (\u0060pay\u0060\u0060ment\u0060 VARCHAR(64));",
  )
  assert_true(
    report.contains("SELECT \u0060pay\u0060\u0060ment\u0060, COUNT(*)"),
  )
  assert_true(report.contains("FROM \u0060order\u0060"))
}

///|
test "compound, expression, prefix, and multi-column index clauses are reported" {
  for
    migration in [
      "ALTER TABLE orders ADD UNIQUE (id, payment_no);", "ALTER TABLE orders ADD UNIQUE (payment_no(4));",
      "ALTER TABLE orders ADD UNIQUE ((LOWER(payment_no)));", "ALTER TABLE orders ADD UNIQUE (payment_no), DROP COLUMN id;",
    ] {
    let report = review_migration(migration)
    assert_true(report.contains("待核查 0 项，未分析 1 项"))
    assert_false(report.contains("SELECT"))
  }
}

///|
test "the next statement on a changed table cannot reuse the old baseline" {
  let report = review_migration(
    "ALTER TABLE orders ADD UNIQUE (id);\nALTER TABLE orders ADD UNIQUE (payment_no);\nALTER TABLE other ADD UNIQUE (ref);",
    schema="CREATE TABLE orders (id BIGINT, payment_no VARCHAR(64)); CREATE TABLE other (ref INT);",
  )
  assert_true(report.contains("待核查 2 项，未分析 1 项"))
  assert_eq(report.split("FROM \u0060orders\u0060").count(), 2)
  assert_true(report.contains("FROM \u0060other\u0060"))
}

///|
test "unknown effects invalidate later baseline-dependent checks" {
  let report = review_migration(
    "/*!80400 ALTER TABLE orders DROP COLUMN id */;\nALTER TABLE orders ADD UNIQUE (payment_no);",
  )
  assert_true(report.contains("待核查 0 项，未分析 2 项"))
  assert_true(report.contains("migration.sql:1"))
  assert_true(report.contains("migration.sql:2"))
  assert_false(report.contains("SELECT"))
}

///|
test "unknown and ambiguous baseline entries are visible" {
  let report = review_migration(
    "ALTER TABLE orders ADD UNIQUE (payment_no);\nALTER TABLE missing ADD UNIQUE (id);",
    schema="CREATE TABLE orders (payment_no INT); CREATE TABLE orders (payment_no VARCHAR(64));",
  )
  assert_true(report.contains("待核查 0 项，未分析 3 项"))
}

///|
test "lexical failures identify the path and line" {
  for
    sql in [
      "/* unclosed", "ALTER TABLE t ADD UNIQUE (col;", "DELIMITER $$", "ALTER TABLE t ADD UNIQUE (\u0060unfinished",
    ] {
    let failed = try review_migration("\n" + sql) catch {
      InvalidSql(path, line, _) => {
        assert_eq(path, "migration.sql")
        assert_eq(line, 2)
        true
      }
    } noraise {
      _ => false
    }
    assert_true(failed)
  }
}
