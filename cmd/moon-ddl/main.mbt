///|
fn usage() -> String {
  "Usage: moon-ddl check --schema schema.sql --migration migration.sql"
}

///|
fn run(args : ArrayView[String]) -> Int32 {
  if args is ["--help"] || args is ["-h"] {
    println(usage())
    return 0
  }
  let (schema_path, migration_path) = match args {
    ["check", "--schema", schema, "--migration", migration]
    | ["check", "--migration", migration, "--schema", schema] =>
      (schema, migration)
    _ => {
      eprintln(usage())
      return 2
    }
  }
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
  let report = @ddl.review(schema, migration, schema_path~, migration_path~) catch {
    @ddl.InvalidSql(path, line, message) => {
      eprintln("MoonDDL: \{path}:\{line}: \{message}")
      return 2
    }
  }
  println(report.trim_end())
  0
}

///|
fn read_sql(path : String) -> String raise {
  @utf8.decode(@fs.read_file_to_bytes(path)[:], ignore_bom=true)
}

///|
fn main {
  @sys.exit(run(@env.args()[1:]))
}
