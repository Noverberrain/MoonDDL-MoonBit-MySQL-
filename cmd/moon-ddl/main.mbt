///|
fn usage() -> String {
  "Usage: moon-ddl check --schema schema.sql --migration migration.sql [--fail-on-findings]"
}

///|
priv struct CheckOptions {
  schema_path : String
  migration_path : String
  fail_on_findings : Bool
}

///|
fn parse_check(args : ArrayView[String]) -> CheckOptions? {
  guard args.get(0) == Some("check") else { return None }
  let mut schema = None
  let mut migration = None
  let mut fail_on_findings = false
  let mut index = 1
  while index < args.length() {
    match args[index] {
      "--schema" if schema is None => {
        guard args.get(index + 1) is Some(path) else { return None }
        schema = Some(path)
        index += 2
      }
      "--migration" if migration is None => {
        guard args.get(index + 1) is Some(path) else { return None }
        migration = Some(path)
        index += 2
      }
      "--fail-on-findings" if !fail_on_findings => {
        fail_on_findings = true
        index += 1
      }
      _ => return None
    }
  }
  guard schema is Some(schema_path) && migration is Some(migration_path) else {
    return None
  }
  Some({ schema_path, migration_path, fail_on_findings, })
}

///|
fn run(args : ArrayView[String]) -> Int32 {
  if args is ["--help"] || args is ["-h"] {
    println(usage())
    return 0
  }
  guard parse_check(args) is Some(config) else {
    eprintln(usage())
    return 2
  }
  let { schema_path, migration_path, fail_on_findings, } = config
  let schema = read_sql(schema_path) catch {
    _ => {
      eprintln("MoonDDL: 无法读取 UTF-8 文件 \{schema_path}")
      return 2
    }
  }
  let migration = read_sql(migration_path) catch {
    _ => {
      eprintln("MoonDDL: 无法读取 UTF-8 文件 \{migration_path}")
      return 2
    }
  }
  let report = @ddl.review_result(
    schema,
    migration,
    schema_path~,
    migration_path~,
  ) catch {
    @ddl.InvalidSql(path, line, message) => {
      eprintln("MoonDDL: \{path}:\{line}: \{message}")
      return 2
    }
  }
  println(report.markdown.trim_end())
  if fail_on_findings && report.has_findings {
    1
  } else {
    0
  }
}

///|
fn read_sql(path : String) -> String raise {
  @utf8.decode(@fs.read_file_to_bytes(path)[:], ignore_bom=true)
}

///|
fn main {
  @sys.exit(run(@env.args()[1:]))
}
