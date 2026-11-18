///|
#derive(Eq)
priv enum TokenKind {
  Word
  Identifier
  Quoted
  Symbol
  ExecutableComment
}

///|
priv struct Token {
  text : String
  kind : TokenKind
  line : Int32
}

///|
pub(all) suberror ScanError {
  InvalidSql(String, Int32, String)
}

///|
fn Token::is_word(self : Token, value : String) -> Bool {
  self.kind == Word && self.text.to_upper() == value
}

///|
fn Token::is_symbol(self : Token, value : String) -> Bool {
  self.kind == Symbol && self.text == value
}

///|
fn word_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '$' ||
  c.to_int() >= 128
}

///|
fn whitespace(c : Char) -> Bool {
  c == ' ' ||
  c == '\n' ||
  c == '\t' ||
  c == '\r' ||
  c == '\u000C' ||
  c == '\u000B'
}

///|
fn scan(sql : String, path : String) -> Array[Array[Token]] raise ScanError {
  let chars = sql.to_array()
  let statements = []
  let mut tokens = []
  let mut i = 0
  let mut line = 1
  let mut depth = 0
  while i < chars.length() {
    let c = chars[i]
    let next = chars.get(i + 1).unwrap_or('\u0000')
    let start_line = line
    if whitespace(c) {
      if c == '\n' || (c == '\r' && next != '\n') {
        line += 1
      }
      i += 1
    } else if c == '#' ||
      (
        c == '-' &&
        next == '-' &&
        (i + 2 == chars.length() || chars[i + 2].to_int() <= 32)
      ) {
      while i < chars.length() && chars[i] != '\n' && chars[i] != '\r' {
        i += 1
      }
    } else if c == '/' && next == '*' {
      let executable = chars.get(i + 2) == Some('!')
      i += 2
      while i + 1 < chars.length() && !(chars[i] == '*' && chars[i + 1] == '/') {
        if chars[i] == '\n' || (chars[i] == '\r' && chars[i + 1] != '\n') {
          line += 1
        }
        i += 1
      }
      if i + 1 >= chars.length() {
        raise InvalidSql(path, start_line, "块注释未闭合")
      }
      i += 2
      if executable {
        tokens.push({ text: "", kind: ExecutableComment, line: start_line, })
      }
    } else if c == '\'' || c == '"' || c == '\u0060' {
      let start = i
      let content = StringBuilder()
      let mut closed = false
      i += 1
      while i < chars.length() {
        let current = chars[i]
        if current == c {
          i += 1
          if chars.get(i) == Some(c) {
            content.write_char(c)
            i += 1
          } else {
            closed = true
            break
          }
        } else if current == '\\' && c != '\u0060' && i + 1 < chars.length() {
          i += 1
          if chars[i] == '\n' ||
            (chars[i] == '\r' && chars.get(i + 1) != Some('\n')) {
            line += 1
          }
          i += 1
        } else {
          if current == '\n' ||
            (current == '\r' && chars.get(i + 1) != Some('\n')) {
            line += 1
          }
          content.write_char(current)
          i += 1
        }
      }
      if !closed {
        raise InvalidSql(path, start_line, "引号未闭合")
      }
      let token = if c == '\u0060' {
        { text: content.to_string(), kind: Identifier, line: start_line, }
      } else {
        {
          text: String::from_array(chars[start:i]),
          kind: Quoted,
          line: start_line,
        }
      }
      tokens.push(token)
    } else if word_char(c) {
      let start = i
      i += 1
      while i < chars.length() && word_char(chars[i]) {
        i += 1
      }
      let text = String::from_array(chars[start:i])
      if tokens.is_empty() && text.to_upper() == "DELIMITER" {
        raise InvalidSql(path, start_line, "首版只支持分号分隔的 SQL")
      }
      tokens.push({ text, kind: Word, line: start_line, })
    } else if c == ';' {
      if depth != 0 {
        raise InvalidSql(path, line, "分号前的括号未闭合")
      }
      if !tokens.is_empty() {
        statements.push(tokens)
        tokens = []
      }
      i += 1
    } else {
      if c == '(' {
        depth += 1
      }
      if c == ')' {
        depth -= 1
      }
      if depth < 0 {
        raise InvalidSql(path, line, "右括号缺少对应的左括号")
      }
      tokens.push({
        text: String::from_array(chars[i:i + 1]),
        kind: Symbol,
        line: start_line,
      })
      i += 1
    }
  }
  if depth != 0 {
    raise InvalidSql(path, line, "文件结束时括号未闭合")
  }
  if !tokens.is_empty() {
    statements.push(tokens)
  }
  statements
}
