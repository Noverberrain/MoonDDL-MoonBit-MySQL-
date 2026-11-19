///|
priv enum Change {
  Unique(Array[String])
  Modify(String, Column)
  Drop(String)
}

///|
#derive(Eq)
priv enum FindingKind {
  Verify
  Unanalyzed
}

///|
priv struct Finding {
  path : String
  line : Int32
  kind : FindingKind
  detail : String
  query : String?
}

///|
fn parse_change(tokens : ArrayView[Token]) -> Change? {
  if keyword(tokens, 0, "ADD") && keyword(tokens, 1, "UNIQUE") {
    let mut i = 2
    if keyword(tokens, i, "INDEX") || keyword(tokens, i, "KEY") {
      i += 1
    }
    if !symbol(tokens, i, "(") {
      guard identifier(tokens, i) is Some(_) else { return None }
      i += 1
    }
    guard closing_paren(tokens, i) is Some(close) &&
      close == tokens.length() - 1 else {
      return None
    }
    let columns = []
    let seen : Map[String, Unit] = Map([])
    for part in split_items(tokens[i + 1:close]) {
      guard part.length() == 1 && identifier(part, 0) is Some(column) else {
        return None
      }
      let key = column.to_lower()
      if seen.contains(key) {
        return None
      }
      seen[key] = ()
      columns.push(column)
    }
    return Some(Unique(columns))
  }
  if keyword(tokens, 0, "MODIFY") {
    let i = if keyword(tokens, 1, "COLUMN") { 2 } else { 1 }
    guard identifier(tokens, i) is Some(column) else { return None }
    guard column_definition(tokens[i + 1:]) is Some(def) else { return None }
    return Some(Modify(column, def))
  }
  if keyword(tokens, 0, "DROP") {
    let i = if keyword(tokens, 1, "COLUMN") { 2 } else { 1 }
    guard tokens.length() == i + 1 else { return None }
    guard identifier(tokens, i) is Some(column) else { return None }
    return Some(Drop(column))
  }
  None
}

///|
fn quoted_identifier(name : String) -> String {
  "\u0060" + name.replace_all(old="\u0060", new="\u0060\u0060") + "\u0060"
}

///|
fn check_unique(
  columns : Array[String],
  table_name : String,
  table : Table,
  location : Finding,
) -> Finding {
  for column in columns {
    if !table.columns.contains(column.to_lower()) {
      return {
        ..location,
        detail: "基线中缺少字段 " + table_name + "." + column + "。",
      }
    }
  }
  let table_sql = quoted_identifier(table_name)
  let column_sql = columns.map(quoted_identifier)
  let key_sql = column_sql.join(", ")
  let non_null = column_sql.map(column => column + " IS NOT NULL").join(" AND ")
  let detail = if columns.length() == 1 {
    "\{table_name}.\{columns[0]} 新增唯一索引。请核对历史数据中的重复非空值。"
  } else {
    let key = columns.join(", ")
    "\{table_name} (\{key}) 新增联合唯一索引。请核对各列均非空的重复组合。"
  }
  {
    ..location,
    kind: Verify,
    detail,
    query: Some(
      "SELECT \{key_sql}, COUNT(*) AS duplicate_count\n" +
      "FROM \{table_sql}\nWHERE \{non_null}\n" +
      "GROUP BY \{key_sql}\nHAVING COUNT(*) > 1;",
    ),
  }
}

///|
fn check_change(
  change : Change,
  table_name : String,
  table : Table,
  location : Finding,
) -> Finding? {
  let column = match change {
    Unique(columns) =>
      return Some(check_unique(columns, table_name, table, location))
    Modify(column, _) | Drop(column) => column
  }
  let field = table_name + "." + column
  guard table.columns.get(column.to_lower()) is Some(before) else {
    return Some({
      ..location,
      detail: "基线中缺少字段 " + field + "。",
    })
  }
  if change is Modify(_, after) {
    if before.definition != after.definition {
      return Some({
        ..location,
        detail: field + " 的列定义包含空值约束以外的变化。",
      })
    }
    if !before.nullable || after.nullable {
      return None
    }
    let table_sql = quoted_identifier(table_name)
    let column_sql = quoted_identifier(column)
    Some({
      ..location,
      kind: Verify,
      detail: field + " 改为 NOT NULL。请核对历史数据中的空值。",
      query: Some(
        "SELECT COUNT(*) AS null_count\nFROM \{table_sql}\nWHERE \{column_sql} IS NULL;",
      ),
    })
  } else {
    Some({
      ..location,
      kind: Verify,
      detail: field +
      " 将被删除。请核对 Java 实体、MyBatis XML 和其他读写方。",
    })
  }
}

///|
fn collect_findings(
  schema : Array[Array[Token]],
  migration : Array[Array[Token]],
  schema_path : String,
  migration_path : String,
) -> Array[Finding] {
  let findings = []
  let tables : Map[String, Table?] = Map([])
  // Preserve table-name case because MySQL accepts case-sensitive table names.
  // Track invalidation case-insensitively to stay conservative across servers.
  let changed : Map[String, Int32] = Map([])
  let mut unknown_change = None
  for statement in schema {
    let location = {
      path: schema_path,
      line: statement[0].line,
      kind: Unanalyzed,
      detail: "",
      query: None,
    }
    match parse_table(statement[:]) {
      Some((name, table)) =>
        if tables.contains(name) || table is None {
          findings.push({
            ..location,
            detail: "无法读取可靠的表定义 " + name + "。",
          })
          tables[name] = None
        } else {
          tables[name] = table
        }
      None => {
        findings.push({
          ..location,
          detail: "基线包含未支持的语句。",
        })
        if unknown_change is None {
          unknown_change = Some((schema_path, location.line))
        }
      }
    }
  }
  for statement in migration {
    let tokens = statement[:]
    let location = {
      path: migration_path,
      line: statement[0].line,
      kind: Unanalyzed,
      detail: "",
      query: None,
    }
    if keyword(tokens, 0, "ALTER") && keyword(tokens, 1, "TABLE") {
      if identifier(tokens, 2) is Some(name) && !symbol(tokens, 3, ".") {
        let key = name.to_lower()
        let clauses = split_items(tokens[3:])
        if clauses.length() == 1 && parse_change(clauses[0]) is Some(change) {
          if unknown_change is Some((path, line)) {
            findings.push({
              ..location,
              detail: "\{name} 的基线需人工复核（\{path}:\{line} 的语句影响未知）。",
            })
          } else if changed.get(key) is Some(line) {
            findings.push({
              ..location,
              detail: "\{name} 已在第 \{line} 行发生前序变更，请人工复核。",
            })
          } else if tables.get(name) is Some(Some(table)) {
            if check_change(change, name, table, location) is Some(finding) {
              findings.push(finding)
            }
          } else {
            findings.push({
              ..location,
              detail: "缺少 \{name} 的可靠表结构。",
            })
          }
          if !changed.contains(key) {
            changed[key] = location.line
          }
          continue
        }
        // Ordinary ADD operations affect only the named table. Other unsupported
        // clauses may also rename a table or change the meaning of later statements.
        if clauses.length() == 1 &&
          keyword(clauses[0], 0, "ADD") &&
          !clauses[0]
          .iter()
          .any(token => {
            token.kind == ExecutableComment || token.is_word("RENAME")
          }) {
          findings.push({
            ..location,
            detail: "\{name} 的 ADD 子句超出支持范围。",
          })
          if !changed.contains(key) {
            changed[key] = location.line
          }
          continue
        }
      }
    }
    findings.push({
      ..location,
      detail: "语句超出支持范围，请人工复核。",
    })
    if unknown_change is None {
      unknown_change = Some((migration_path, location.line))
    }
  }
  findings
}

///|
/// Generate the Markdown review report for a baseline and an ordered migration.
pub fn review(
  schema : String,
  migration : String,
  schema_path~ : String,
  migration_path~ : String,
) -> String raise ScanError {
  let findings = collect_findings(
    scan(schema, schema_path),
    scan(migration, migration_path),
    schema_path,
    migration_path,
  )
  render_report(findings)
}
