///|
priv struct Table {
  columns : Map[String, Unit]
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
  for item in split_items(tokens[name_index + 2:close]) {
    if keyword(item, 0, "CONSTRAINT") ||
      keyword(item, 0, "PRIMARY") ||
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
      guard item.get(1) is Some(token) && token.kind == Word else {
        return invalid
      }
      let key = column.to_lower()
      if columns.contains(key) {
        return invalid
      }
      columns[key] = ()
    }
  }
  if columns.is_empty() {
    return invalid
  }
  Some((name, Some({ columns, })))
}
