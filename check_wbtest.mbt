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
test "drop column names the field and asks for manual review" {
  for clause in ["DROP COLUMN `legacy_note`", "DROP legacy_note"] {
    let report = review_migration(
      "# old field\nALTER TABLE orders " + clause + ";",
      schema="CREATE TABLE orders (id BIGINT, legacy_note VARCHAR(255));",
    )
    assert_true(report.contains("待核查 1 项，未分析 0 项"))
    assert_true(report.contains("migration.sql:2"))
    assert_true(report.contains("orders.legacy\\_note"))
    assert_true(report.contains("MyBatis XML"))
    assert_false(report.contains("SELECT"))
  }
}

///|
test "drop missing fields and index drops require manual analysis" {
  for clause in ["DROP COLUMN missing", "DROP INDEX payment_no"] {
    let report = review_migration("ALTER TABLE orders " + clause + ";")
    assert_true(report.contains("待核查 0 项，未分析 1 项"))
    assert_false(report.contains("将被删除"))
  }
}

///|
test "a dropped column cannot be checked using the old table definition" {
  let report = review_migration(
    "ALTER TABLE orders DROP COLUMN payment_no;\nALTER TABLE orders ADD UNIQUE (payment_no);",
  )
  assert_true(report.contains("待核查 1 项，未分析 1 项"))
  assert_true(report.contains("migration.sql:2"))
  assert_false(report.contains("SELECT"))
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
test "compound, expression, prefix, and repeated index columns require manual analysis" {
  for
    migration in [
      "ALTER TABLE orders ADD UNIQUE (payment_no, PAYMENT_NO);", "ALTER TABLE orders ADD UNIQUE (payment_no(4));",
      "ALTER TABLE orders ADD UNIQUE ((LOWER(payment_no)));", "ALTER TABLE orders ADD UNIQUE (id, payment_no(4));",
      "ALTER TABLE orders ADD UNIQUE (payment_no), DROP COLUMN id;",
    ] {
    let report = review_migration(migration)
    assert_true(report.contains("待核查 0 项，未分析 1 项"))
    assert_false(report.contains("SELECT"))
  }
}

///|
test "composite unique index groups in index order and excludes any null key part" {
  let report = review_migration(
    "ALTER TABLE orders ADD UNIQUE KEY uk_merchant_payment (\u0060merchant_id\u0060, payment_no);",
    schema="CREATE TABLE orders (payment_no VARCHAR(64), merchant_id BIGINT);",
  )
  assert_true(report.contains("待核查 1 项，未分析 0 项"))
  assert_true(report.contains("新增联合唯一索引"))
  assert_true(
    report.contains(
      "SELECT \u0060merchant_id\u0060, \u0060payment_no\u0060, COUNT(*)",
    ),
  )
  assert_true(
    report.contains(
      "WHERE \u0060merchant_id\u0060 IS NOT NULL AND \u0060payment_no\u0060 IS NOT NULL",
    ),
  )
  assert_true(
    report.contains("GROUP BY \u0060merchant_id\u0060, \u0060payment_no\u0060"),
  )
}

///|
test "composite unique index requires every column in the baseline" {
  let report = review_migration(
    "ALTER TABLE orders ADD UNIQUE (payment_no, unknown);",
  )
  assert_true(report.contains("待核查 0 项，未分析 1 项"))
  assert_true(report.contains("基线中缺少字段 orders.unknown"))
  assert_false(report.contains("SELECT"))
}

///|
test "standalone unique indexes use the same checks as ALTER TABLE" {
  for columns in ["payment_no", "id, `payment_no`"] {
    let standalone = review_migration(
      "-- header\nCREATE UNIQUE INDEX `uk_pay`\nON `orders` (" + columns + ");",
    )
    let alter = review_migration(
      "-- header\nALTER TABLE orders ADD UNIQUE (" + columns + ");",
    )
    assert_true(standalone.contains("migration.sql:2"))
    assert_true(standalone.contains("待核查 1 项，未分析 0 项"))
    assert_eq(standalone, alter)
  }
}

///|
test "standalone index statements outside the supported grammar are reported" {
  for
    migration in [
      "CREATE INDEX idx ON orders (payment_no);", "CREATE UNIQUE INDEX idx ON shop.orders (payment_no);",
      "CREATE UNIQUE INDEX idx ON orders (payment_no(10));", "CREATE UNIQUE INDEX idx ON orders (payment_no) INVISIBLE;",
    ] {
    let report = review_migration(migration)
    assert_true(report.contains("待核查 0 项，未分析 1 项"))
    assert_false(report.contains("SELECT"))
  }
}

///|
test "standalone index statements share baseline and statement order checks" {
  let report = review_migration(
    "CREATE UNIQUE INDEX idx ON orders (missing);\nCREATE UNIQUE INDEX idx2 ON orders (payment_no);",
  )
  assert_true(report.contains("待核查 0 项，未分析 2 项"))
  assert_true(report.contains("基线中缺少字段 orders.missing"))
  assert_true(report.contains("已在第 1 行发生前序变更"))
  assert_false(report.contains("SELECT"))
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
