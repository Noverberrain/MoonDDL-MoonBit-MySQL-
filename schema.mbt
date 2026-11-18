///|
priv struct Column {
  nullable : Bool
  definition : Array[String]
}

///|
priv struct Table {
  columns : Map[String, Column]
}

///|
fn keyword(tokens : ArrayView[Token], index : Int32, value : String) -> Bool {
  match tokens.get(index) {
    Some(token) => token.is_word(value)
    None => false
  }
}

///|
fn symbol(tokens : ArrayView[Token], index : Int32, value : String) -> Bool {
  match tokens.get(index) {
    Some(token) => token.is_symbol(value)
    None => false
  }
}

///|
fn identifier(tokens : ArrayView[Token], index : Int32) -> String? {
  guard tokens.get(index) is Some(token) else { return None }
  guard token.kind == Word || token.kind == Identifier else { return None }
  guard !token.text.is_empty() && token.text.iter().all(c => c.to_int() >= 32) else {
    return None
  }
  Some(token.text)
}

///|
fn split_items(tokens : ArrayView[Token]) -> Array[ArrayView[Token]] {
  let items = []
  let mut depth = 0
  let mut start = 0
  for i, token in tokens {
    if token.is_symbol("(") {
      depth += 1
    }
    if token.is_symbol(")") {
      depth -= 1
    }
    if token.is_symbol(",") && depth == 0 {
      items.push(tokens[start:i])
      start = i + 1
    }
  }
  items.push(tokens[start:])
  items
}

///|
fn closing_paren(tokens : ArrayView[Token], opening : Int32) -> Int32? {
  guard symbol(tokens, opening, "(") else { return None }
  let mut depth = 0
  for offset, token in tokens[opening:] {
    if token.is_symbol("(") {
      depth += 1
    }
    if token.is_symbol(")") {
      depth -= 1
      if depth == 0 {
        return Some(opening + offset)
      }
    }
  }
  None
}

///|
fn column_definition(tokens : ArrayView[Token]) -> Column? {
  guard tokens.get(0) is Some(first) else { return None }
  guard first.kind == Word else { return None }
  let definition = []
  let mut nullable = true
  let mut seen_nullability = false
  let mut default_null = false
  let mut depth = 0
  let mut i = 0
  while i < tokens.length() {
    let token = tokens[i]
    if token.kind == ExecutableComment {
      return None
    }
    if token.is_symbol("(") {
      depth += 1
    }
    if token.is_symbol(")") {
      depth -= 1
    }
    if depth == 0 {
      if keyword(tokens, i, "NOT") && keyword(tokens, i + 1, "NULL") {
        if seen_nullability {
          return None
        }
        nullable = false
        seen_nullability = true
        i += 2
        continue
      }
      if keyword(tokens, i, "DEFAULT") && keyword(tokens, i + 1, "NULL") {
        if default_null {
          return None
        }
        default_null = true
        i += 2
        continue
      }
      if keyword(tokens, i, "NULL") {
        if seen_nullability {
          return None
        }
        seen_nullability = true
        i += 1
        continue
      }
      if keyword(tokens, i, "PRIMARY") && keyword(tokens, i + 1, "KEY") {
        nullable = false
      }
    }
    let signature = match token.kind {
      Word => "word " + token.text.to_upper()
      Identifier => "identifier " + token.text
      Quoted => "quoted " + token.text
      _ => token.text
    }
    definition.push(signature)
    i += 1
  }
  if default_null && !nullable {
    return None
  }
  Some({ nullable, definition, })
}

///|
fn parse_table(tokens : ArrayView[Token]) -> (String, Table?)? {
  guard keyword(tokens, 0, "CREATE") && keyword(tokens, 1, "TABLE") else {
    return None
  }
  let name_index = if keyword(tokens, 2, "IF") &&
    keyword(tokens, 3, "NOT") &&
    keyword(tokens, 4, "EXISTS") {
    5
  } else {
    2
  }
  guard identifier(tokens, name_index) is Some(name) else { return None }
  let invalid = Some((name, None))
  if tokens.iter().any(token => token.kind == ExecutableComment) {
    return invalid
  }
  guard closing_paren(tokens, name_index + 1) is Some(close) else {
    return invalid
  }
  for token in tokens[close + 1:] {
    if token.is_word("SELECT") || token.is_word("AS") {
      return invalid
    }
  }
  let columns = Map([])
  let primary = []
  for item in split_items(tokens[name_index + 2:close]) {
    let constraint = if keyword(item, 0, "CONSTRAINT") {
      if keyword(item, 1, "PRIMARY") ||
        keyword(item, 1, "UNIQUE") ||
        keyword(item, 1, "FOREIGN") ||
        keyword(item, 1, "CHECK") {
        1
      } else {
        2
      }
    } else {
      0
    }
    if keyword(item, constraint, "PRIMARY") {
      guard keyword(item, constraint + 1, "KEY") else { return invalid }
      let mut opening = constraint + 2
      if keyword(item, opening, "USING") {
        opening += 2
      }
      guard closing_paren(item, opening) is Some(end) else { return invalid }
      for key in split_items(item[opening + 1:end]) {
        guard identifier(key, 0) is Some(column) else { return invalid }
        primary.push(column.to_lower())
      }
    } else if constraint > 0 ||
      keyword(item, 0, "KEY") ||
      keyword(item, 0, "INDEX") ||
      keyword(item, 0, "UNIQUE") ||
      keyword(item, 0, "FOREIGN") ||
      keyword(item, 0, "CHECK") ||
      keyword(item, 0, "FULLTEXT") ||
      keyword(item, 0, "SPATIAL") {
      continue
    } else {
      guard identifier(item, 0) is Some(column) else { return invalid }
      guard column_definition(item[1:]) is Some(def) else { return invalid }
      let key = column.to_lower()
      if columns.contains(key) {
        return invalid
      }
      columns[key] = def
    }
  }
  for key in primary {
    guard columns.get(key) is Some(column) else { return invalid }
    columns[key] = { ..column, nullable: false, }
  }
  if columns.is_empty() {
    return invalid
  }
  Some((name, Some({ columns, })))
}
