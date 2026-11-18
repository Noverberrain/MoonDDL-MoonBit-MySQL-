///|
fn escape_markdown(text : String) -> String {
  let escaped = StringBuilder()
  for c in text {
    match c {
      '\r' | '\n' => escaped.write_char(' ')
      '<' => escaped.write_string("&lt;")
      '>' => escaped.write_string("&gt;")
      '&' => escaped.write_string("&amp;")
      '\\' | '\u0060' | '*' | '_' | '[' | ']' | '|' => {
        escaped.write_char('\\')
        escaped.write_char(c)
      }
      _ => escaped.write_char(c)
    }
  }
  escaped.to_string()
}

///|
fn render_report(findings : Array[Finding]) -> String {
  let verify = findings.iter().filter(finding => finding.kind == Verify).count()
  let unanalyzed = findings.length() - verify
  let output = StringBuilder()
  output.write_string(
    "# MoonDDL 迁移预检\n\n待核查 \{verify} 项，未分析 \{unanalyzed} 项。\n",
  )
  for finding in findings {
    let path = escape_markdown(finding.path)
    let detail = escape_markdown(finding.detail)
    let label = if finding.kind == Verify { "待核查" } else { "未分析" }
    output.write_string(
      "\n### \{label} · \{path}:\{finding.line}\n\n\{detail}\n",
    )
    if finding.query is Some(query) {
      output.write_string(
        "\n\u0060\u0060\u0060sql\n\{query}\n\u0060\u0060\u0060\n",
      )
    }
  }
  output.to_string()
}
