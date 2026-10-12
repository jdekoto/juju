package juju

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

Token_Type :: enum {
    EOF,
    Error,

    // Layout
    Newline,
    Indent,
    Dedent,

    // Literals & identifiers
    Identifier,
    Int_Literal,
    Str_Literal,    // "text"
    C_Str_Literal,  // c"text"
    Char_Literal,   // 'A'

    // Keywords
    Const, Let, Var,
    Fn, Return, Pass,
    If, Elif, Else, While, For, In, Break, Continue,
    Match, Case, Defer, When,
    Struct, Enum, Union,
    Import, From, As,
    Foreign, Asm, Volatile,
    And, Or, Not,
    True, False, Nil,

    // Brackets & punctuation
    L_Paren, R_Paren,       // ( )
    L_Bracket, R_Bracket,   // [ ]
    Comma, Dot, Colon, At,  // , . : @
    Arrow,                  // ->

    // Operators
    Plus, Minus, Star, Slash, Double_Slash, Percent,   // + - * / // %
    Ampersand, Pipe, Caret, Tilde, Shl, Shr,           // & | ^ ~ << >>
    Eq, Not_Eq, Lt, Lt_Eq, Gt, Gt_Eq,                  // == != < <= > >=

    // Assignment
    Assign,                                            // =
    Plus_Assign, Minus_Assign, Star_Assign,            // += -= *=
    Slash_Assign, Double_Slash_Assign, Percent_Assign, // /= //= %=
    And_Assign, Or_Assign, Xor_Assign,                 // &= |= ^=
    Shl_Assign, Shr_Assign,                            // <<= >>=
}

Token :: struct {
    type:   Token_Type,
    text:   string, // a slice of the source (empty for Indent/Dedent/Newline/EOF)
    line:   int,    // 1-based
    col:    int,    // 1-based
    offset: int,    // byte offset into the source: (offset, len(text)) is the span
}

Lexer :: struct {
    input:          string,
    pos:            int,
    line:           int,
    line_start:     int,          // byte offset where the current line begins
    depth:          int,          // open ( and [ : newlines/indents are ignored inside
    indent_stack:   [dynamic]int,
    pending_tokens: [dynamic]Token,
    at_line_start:  bool,
    last:           Token_Type,   // the token type we returned last
}

init_lexer :: proc(input: string) -> Lexer {
    l := Lexer{
        input         = input,
        line          = 1,
        at_line_start = true,
        last          = .Newline, // so an empty file doesn't invent a Newline
    }
    append(&l.indent_stack, 0)
    return l
}

destroy_lexer :: proc(l: ^Lexer) {
    delete(l.indent_stack)
    delete(l.pending_tokens)
}

// ---------------------------------------------------------------------------
// Token construction
// ---------------------------------------------------------------------------

// A real token: its text is the source from `start` to the current position.
make_token :: proc(l: ^Lexer, type: Token_Type, start: int) -> Token {
    return Token{
        type   = type,
        text   = l.input[start:l.pos],
        line   = l.line,
        col    = start - l.line_start + 1,
        offset = start,
    }
}

// A token with no source text of its own (Indent, Dedent, Newline, EOF).
make_synthetic :: proc(l: ^Lexer, type: Token_Type) -> Token {
    return Token{type = type, line = l.line, col = l.pos - l.line_start + 1, offset = l.pos}
}

make_error :: proc(l: ^Lexer, msg: string) -> Token {
    return Token{type = .Error, text = msg, line = l.line, col = l.pos - l.line_start + 1, offset = l.pos}
}

// ---------------------------------------------------------------------------
// Character helpers
// ---------------------------------------------------------------------------

is_digit       :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
is_hex_digit   :: proc(c: u8) -> bool { return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }
is_ident_start :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
is_ident_char  :: proc(c: u8) -> bool { return is_ident_start(c) || is_digit(c) }

// If the next byte is `c`, consume it and return true.
consume_if :: proc(l: ^Lexer, c: u8) -> bool {
    if l.pos < len(l.input) && l.input[l.pos] == c {
        l.pos += 1
        return true
    }
    return false
}

// Two-way pick: `yes` if the next byte is `next` (and consume it), else `no`.
pick :: proc(l: ^Lexer, next: u8, yes, no: Token_Type) -> Token_Type {
    if consume_if(l, next) { return yes }
    return no
}

// Consume \n, \r\n or a lone \r, and update line bookkeeping.
consume_newline :: proc(l: ^Lexer) {
    if l.input[l.pos] == '\r' && l.pos + 1 < len(l.input) && l.input[l.pos + 1] == '\n' {
        l.pos += 1
    }
    l.pos += 1
    l.line += 1
    l.line_start = l.pos
}

skip_comment :: proc(l: ^Lexer) {
    for l.pos < len(l.input) && l.input[l.pos] != '\n' && l.input[l.pos] != '\r' {
        l.pos += 1
    }
}

keyword_type :: proc(text: string) -> Token_Type {
    switch text {
    case "const":    return .Const
    case "let":      return .Let
    case "var":      return .Var
    case "fn":       return .Fn
    case "return":   return .Return
    case "pass":     return .Pass
    case "if":       return .If
    case "elif":     return .Elif
    case "else":     return .Else
    case "while":    return .While
    case "for":      return .For
    case "in":       return .In
    case "break":    return .Break
    case "continue": return .Continue
    case "match":    return .Match
    case "case":     return .Case
    case "defer":    return .Defer
    case "when":     return .When
    case "struct":   return .Struct
    case "enum":     return .Enum
    case "union":    return .Union
    case "import":   return .Import
    case "from":     return .From
    case "as":       return .As
    case "foreign":  return .Foreign
    case "asm":      return .Asm
    case "volatile": return .Volatile
    case "and":      return .And
    case "or":       return .Or
    case "not":      return .Not
    case "true":     return .True
    case "false":    return .False
    case "nil":      return .Nil
    }
    return .Identifier
}

// ---------------------------------------------------------------------------
// The lexer proper
// ---------------------------------------------------------------------------

// Call repeatedly. Returns EOF forever once the input is exhausted.
next_token :: proc(l: ^Lexer) -> Token {
    tok := scan(l)
    l.last = tok.type
    return tok
}

scan :: proc(l: ^Lexer) -> Token {
    for {
        // 1. Queued Dedents (several can come from one line) go out first.
        if len(l.pending_tokens) > 0 {
            return pop_front(&l.pending_tokens)
        }

        // 2. Indentation, only at the start of a line and never inside ( ) [ ].
        if l.at_line_start && l.depth == 0 {
            l.at_line_start = false
            if tok, ok := lex_indentation(l); ok {
                return tok
            }
        }

        // 3. Skip spaces and trailing comments.
        for l.pos < len(l.input) {
            c := l.input[l.pos]
            if c == ' ' {
                l.pos += 1
            } else if c == '\t' {
                l.pos += 1
                return make_error(l, "Tabs are an error in juju! Use 4 spaces.")
            } else if c == '#' {
                skip_comment(l)
            } else {
                break
            }
        }

        // 4. End of input: finish the last line, close open blocks, then EOF.
        if l.pos >= len(l.input) {
            if l.depth > 0 {
                l.depth = 0
                return make_error(l, "Unclosed '(' or '['.")
            }
            if l.last != .Newline && l.last != .Dedent && l.last != .EOF {
                append(&l.pending_tokens, make_synthetic(l, .Newline))
            }
            for len(l.indent_stack) > 1 {
                pop(&l.indent_stack)
                append(&l.pending_tokens, make_synthetic(l, .Dedent))
            }
            if len(l.pending_tokens) > 0 {
                return pop_front(&l.pending_tokens)
            }
            return make_synthetic(l, .EOF)
        }

        // 5. Newline: ends a statement, unless we're inside ( ) or [ ].
        curr := l.input[l.pos]
        if curr == '\n' || curr == '\r' {
            nl := make_synthetic(l, .Newline)
            consume_newline(l)
            if l.depth > 0 { continue }
            l.at_line_start = true
            return nl
        }

        // 6. Everything else.
        return lex_token(l, curr)
    }
}

// Measures leading spaces. Blank lines and comment-only lines are skipped
// without producing tokens. Returns (token, true) if an Indent, Dedent or
// Error must be returned now.
lex_indentation :: proc(l: ^Lexer) -> (Token, bool) {
    spaces := 0
    measure: for l.pos < len(l.input) {
        switch l.input[l.pos] {
        case ' ':
            spaces += 1
            l.pos += 1
        case '\t':
            l.pos += 1
            return make_error(l, "Tabs are an error in juju! Use 4 spaces."), true
        case '\r', '\n':
            consume_newline(l) // blank line: forget the spaces we counted
            spaces = 0
        case '#':
            skip_comment(l)    // comment-only line: its newline resets `spaces`
        case:
            break measure
        }
    }

    // Only whitespace/comments left: let the EOF handling close the blocks.
    if l.pos >= len(l.input) {
        return Token{}, false
    }

    top := l.indent_stack[len(l.indent_stack) - 1]
    if spaces > top {
        if spaces % 4 != 0 {
            return make_error(l, "Indentation must be a multiple of 4 spaces."), true
        }
        append(&l.indent_stack, spaces)
        return make_synthetic(l, .Indent), true
    }
    if spaces < top {
        for l.indent_stack[len(l.indent_stack) - 1] > spaces {
            pop(&l.indent_stack)
            append(&l.pending_tokens, make_synthetic(l, .Dedent))
        }
        if l.indent_stack[len(l.indent_stack) - 1] != spaces {
            return make_error(l, "Dedent doesn't match any outer indentation level."), true
        }
        return pop_front(&l.pending_tokens), true
    }
    return Token{}, false
}

lex_token :: proc(l: ^Lexer, curr: u8) -> Token {
    start := l.pos
    l.pos += 1 // consume `curr`

    if is_digit(curr) {
        return lex_number(l, start)
    }

    if is_ident_start(curr) {
        // c"..." is a C string literal
        if curr == 'c' && l.pos < len(l.input) && l.input[l.pos] == '"' {
            l.pos += 1
            return lex_string(l, start, .C_Str_Literal)
        }
        for l.pos < len(l.input) && is_ident_char(l.input[l.pos]) {
            l.pos += 1
        }
        return make_token(l, keyword_type(l.input[start:l.pos]), start)
    }

    switch curr {
    case '(':
        l.depth += 1
        return make_token(l, .L_Paren, start)
    case ')':
        if l.depth == 0 { return make_error(l, "Unmatched ')'.") }
        l.depth -= 1
        return make_token(l, .R_Paren, start)
    case '[':
        l.depth += 1
        return make_token(l, .L_Bracket, start)
    case ']':
        if l.depth == 0 { return make_error(l, "Unmatched ']'.") }
        l.depth -= 1
        return make_token(l, .R_Bracket, start)

    case ',': return make_token(l, .Comma, start)
    case '.': return make_token(l, .Dot, start)
    case ':': return make_token(l, .Colon, start)
    case '@': return make_token(l, .At, start)
    case '~': return make_token(l, .Tilde, start)

    case '+': return make_token(l, pick(l, '=', .Plus_Assign, .Plus), start)
    case '*': return make_token(l, pick(l, '=', .Star_Assign, .Star), start)
    case '%': return make_token(l, pick(l, '=', .Percent_Assign, .Percent), start)
    case '&': return make_token(l, pick(l, '=', .And_Assign, .Ampersand), start)
    case '|': return make_token(l, pick(l, '=', .Or_Assign, .Pipe), start)
    case '^': return make_token(l, pick(l, '=', .Xor_Assign, .Caret), start)
    case '=': return make_token(l, pick(l, '=', .Eq, .Assign), start)

    case '-':
        if consume_if(l, '>') { return make_token(l, .Arrow, start) }
        return make_token(l, pick(l, '=', .Minus_Assign, .Minus), start)
    case '/':
        if consume_if(l, '/') {
            return make_token(l, pick(l, '=', .Double_Slash_Assign, .Double_Slash), start)
        }
        return make_token(l, pick(l, '=', .Slash_Assign, .Slash), start)
    case '<':
        if consume_if(l, '<') {
            return make_token(l, pick(l, '=', .Shl_Assign, .Shl), start)
        }
        return make_token(l, pick(l, '=', .Lt_Eq, .Lt), start)
    case '>':
        if consume_if(l, '>') {
            return make_token(l, pick(l, '=', .Shr_Assign, .Shr), start)
        }
        return make_token(l, pick(l, '=', .Gt_Eq, .Gt), start)
    case '!':
        if consume_if(l, '=') { return make_token(l, .Not_Eq, start) }
        return make_error(l, "Unexpected '!'. Use 'not' for boolean negation.")

    case '"':  return lex_string(l, start, .Str_Literal)
    case '\'': return lex_char(l, start)
    }

    return make_error(l, "Unexpected character.")
}

// `l.pos` is just past the first digit. Handles 123, 1_000, 0xFF, 0b1010.
lex_number :: proc(l: ^Lexer, start: int) -> Token {
    at :: proc(l: ^Lexer) -> u8 {
        if l.pos < len(l.input) { return l.input[l.pos] }
        return 0
    }

    if l.input[start] == '0' && (at(l) == 'x' || at(l) == 'X') {
        l.pos += 1
        digits_start := l.pos
        for is_hex_digit(at(l)) || at(l) == '_' { l.pos += 1 }
        if l.pos == digits_start { return make_error(l, "Hex literal has no digits.") }
    } else if l.input[start] == '0' && (at(l) == 'b' || at(l) == 'B') {
        l.pos += 1
        digits_start := l.pos
        for at(l) == '0' || at(l) == '1' || at(l) == '_' { l.pos += 1 }
        if l.pos == digits_start { return make_error(l, "Binary literal has no digits.") }
    } else {
        for is_digit(at(l)) || at(l) == '_' { l.pos += 1 }
    }

    // 12abc, 0b12 and friends
    if is_ident_char(at(l)) {
        return make_error(l, "Invalid character right after a number.")
    }
    return make_token(l, .Int_Literal, start)
}

// `l.pos` is just past the opening quote. The token text keeps the quotes and
// the raw escapes; unescaping is the parser's (or a later pass's) job.
lex_string :: proc(l: ^Lexer, start: int, type: Token_Type) -> Token {
    for l.pos < len(l.input) {
        c := l.input[l.pos]
        if c == '"' {
            l.pos += 1
            return make_token(l, type, start)
        }
        if c == '\n' || c == '\r' { break }
        if c == '\\' && l.pos + 1 < len(l.input) && l.input[l.pos + 1] != '\n' && l.input[l.pos + 1] != '\r' {
            l.pos += 1 // skip the escaped character too
        }
        l.pos += 1
    }
    return make_error(l, "Unterminated string literal.")
}

// 'A' or '\n'. `l.pos` is just past the opening quote.
lex_char :: proc(l: ^Lexer, start: int) -> Token {
    if l.pos < len(l.input) && l.input[l.pos] == '\\' { l.pos += 1 }
    if l.pos < len(l.input) && l.input[l.pos] != '\n' && l.input[l.pos] != '\r' { l.pos += 1 }
    if consume_if(l, '\'') { return make_token(l, .Char_Literal, start) }
    return make_error(l, "Bad character literal. Expected something like 'A'.")
}
