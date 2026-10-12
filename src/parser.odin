// TODO: notes where they supposed to be but we cant do
// var _, ok = find(items, 4)
// nor does the ast correctly handle match, forgien or import
package juju

import "core:fmt"

Parser :: struct {
    tokens:   [dynamic]Token,
    pos:      int,
    prev_end: int, // byte offset just past the last real token consumed
    diags:    ^[dynamic]Diagnostic,
}

// Lex the whole file, then parse it. All problems land in `diags`.
parse_source :: proc(src: string, diags: ^[dynamic]Diagnostic) -> Module {
    p := Parser{diags = diags}
    lexer := init_lexer(src)
    defer destroy_lexer(&lexer)
    for {
        tok := next_token(&lexer)
        if tok.type == .Error {
            report(diags, Span{tok.offset, 1, tok.line, tok.col}, tok.text)
        }
        append(&p.tokens, tok) // Error tokens stay in the stream; the parser skips over them quietly
        if tok.type == .EOF { break }
    }
    return parse_module(&p)
}

// ---------------------------------------------------------------------------
// Token helpers
// ---------------------------------------------------------------------------

peek :: proc(p: ^Parser, ahead := 0) -> Token {
    return p.tokens[min(p.pos + ahead, len(p.tokens) - 1)]
}

at :: proc(p: ^Parser, type: Token_Type) -> bool {
    return peek(p).type == type
}

advance :: proc(p: ^Parser) -> Token {
    tok := p.tokens[p.pos]
    if p.pos < len(p.tokens) - 1 { p.pos += 1 }
    if len(tok.text) > 0 && tok.type != .Error {
        p.prev_end = tok.offset + len(tok.text)
    }
    return tok
}

accept :: proc(p: ^Parser, type: Token_Type) -> bool {
    if at(p, type) {
        advance(p)
        return true
    }
    return false
}

token_span :: proc(t: Token) -> Span {
    return Span{t.offset, len(t.text), t.line, t.col}
}

// From the start of `first` to the end of the last token consumed.
span_from :: proc(p: ^Parser, first: Token) -> Span {
    return Span{first.offset, max(p.prev_end - first.offset, 0), first.line, first.col}
}

describe :: proc(t: Token) -> string {
    #partial switch t.type {
    case .Newline: return "end of line"
    case .Indent:  return "an unexpected indent"
    case .Dedent:  return "end of block"
    case .EOF:     return "end of file"
    }
    return fmt.aprintf("'%s'", t.text)
}

// Lexer errors were already reported, so stay quiet when we trip over one.
error_here :: proc(p: ^Parser, msg: string, hint := "") {
    tok := peek(p)
    if tok.type == .Error { return }
    report(p.diags, token_span(tok), msg, hint)
}

error_expected :: proc(p: ^Parser, what: string) {
    error_here(p, fmt.aprintf("expected %s, found %s", what, describe(peek(p))))
}

expect :: proc(p: ^Parser, type: Token_Type, what: string) -> (Token, bool) {
    tok := peek(p)
    if tok.type == type { return advance(p), true }
    error_expected(p, what)
    return tok, false
}

expect_end_of_line :: proc(p: ^Parser) -> bool {
    if accept(p, .Newline) { return true }
    error_expected(p, "end of line")
    return false
}

make_expr :: proc(v: Expr_Variant, span: Span) -> ^Expr {
    e := new(Expr)
    e.span = span
    e.variant = v
    return e
}

make_stmt :: proc(v: Stmt_Variant, span: Span) -> ^Stmt {
    s := new(Stmt)
    s.span = span
    s.variant = v
    return s
}

make_type_expr :: proc(v: Type_Variant, span: Span) -> ^Type_Expr {
    t := new(Type_Expr)
    t.span = span
    t.variant = v
    return t
}

// After an error: skip to the end of the line (and past any indented block
// that belonged to the broken statement) so we can keep parsing and report
// more than one error per run.
synchronize :: proc(p: ^Parser) {
    for {
        #partial switch peek(p).type {
        case .EOF, .Dedent:
            return
        case .Newline:
            advance(p)
            if at(p, .Indent) {
                depth := 0
                for !at(p, .EOF) {
                    #partial switch peek(p).type {
                    case .Indent: depth += 1
                    case .Dedent: depth -= 1
                    }
                    advance(p)
                    if depth == 0 { break }
                }
            }
            return
        case:
            advance(p)
        }
    }
}

// ---------------------------------------------------------------------------
// Types:  i32   mem.Arena   *T   *volatile T   []T   [N]T
// ---------------------------------------------------------------------------

parse_type :: proc(p: ^Parser) -> ^Type_Expr {
    start := peek(p)
    #partial switch start.type {
    case .Star:
        advance(p)
        is_volatile := accept(p, .Volatile)
        elem := parse_type(p)
        if elem == nil { return nil }
        return make_type_expr(Type_Ptr{volatile = is_volatile, elem = elem}, span_from(p, start))
    case .L_Bracket:
        advance(p)
        if accept(p, .R_Bracket) {
            elem := parse_type(p)
            if elem == nil { return nil }
            return make_type_expr(Type_Slice{elem = elem}, span_from(p, start))
        }
        length := parse_expr(p)
        if length == nil { return nil }
        if _, ok := expect(p, .R_Bracket, "']' after the array length"); !ok { return nil }
        elem := parse_type(p)
        if elem == nil { return nil }
        return make_type_expr(Type_Array{len = length, elem = elem}, span_from(p, start))
	case .L_Paren: // <-- ADD THIS: Tuple type e.g. (i32, i32)
        advance(p)
        elems: [dynamic]^Type_Expr
        for !at(p, .R_Paren) {
            t := parse_type(p)
            if t == nil { return nil }
            append(&elems, t)
            if !accept(p, .Comma) { break }
        }
        if _, ok := expect(p, .R_Paren, "')' to close the tuple type"); !ok { return nil }
        return make_type_expr(Type_Tuple{elems = elems}, span_from(p, start))
	case .Fn: // <-- ADD THIS: Function pointer type e.g. fn(i32) -> i32
        advance(p)
        if _, ok := expect(p, .L_Paren, "'(' after 'fn' in function type"); !ok { return nil }
        params: [dynamic]^Type_Expr
        for !at(p, .R_Paren) {
            t := parse_type(p)
            if t == nil { return nil }
            append(&params, t)
            if !accept(p, .Comma) { break }
        }
        if _, ok := expect(p, .R_Paren, "')' to close function type parameters"); !ok { return nil }
        ret: ^Type_Expr
        if accept(p, .Arrow) {
            ret = parse_type(p)
            if ret == nil { return nil }
        }
        return make_type_expr(Type_Fn{params = params, ret = ret}, span_from(p, start))
    case .Identifier:
        advance(p)
        name := start.text
        module := ""
        if at(p, .Dot) && peek(p, 1).type == .Identifier {
            advance(p)
            module = name
            name = advance(p).text
        }
        return make_type_expr(Type_Name{module = module, name = name}, span_from(p, start))
    }
    error_expected(p, "a type")
    return nil
}

// ---------------------------------------------------------------------------
// Expressions (Pratt parser)
//
// Binding powers, loosest to tightest:
//   or 2 | and 4 | not 8 | comparisons 10 | "|" 20 | ^ 30 | & 40 | << >> 50
//   + - 60 | * / // % 70 | prefix - ~ * & 80 | postfix . [] () (always)
// Bitwise operators bind tighter than comparisons (Python/Rust, not C).
// ---------------------------------------------------------------------------

UNARY_BP :: 80
NOT_BP   :: 8

Infix :: struct { bp: int, op: Binary_Op }

infix_info :: proc(t: Token_Type) -> (Infix, bool) {
    #partial switch t {
    case .Or:           return {2,  .Or}, true
    case .And:          return {4,  .And}, true
    case .Eq:           return {10, .Eq}, true
    case .Not_Eq:       return {10, .Not_Eq}, true
    case .Lt:           return {10, .Lt}, true
    case .Lt_Eq:        return {10, .Lt_Eq}, true
    case .Gt:           return {10, .Gt}, true
    case .Gt_Eq:        return {10, .Gt_Eq}, true
    case .Pipe:         return {20, .Bit_Or}, true
    case .Caret:        return {30, .Bit_Xor}, true
    case .Ampersand:    return {40, .Bit_And}, true
    case .Shl:          return {50, .Shl}, true
    case .Shr:          return {50, .Shr}, true
    case .Plus:         return {60, .Add}, true
    case .Minus:        return {60, .Sub}, true
    case .Star:         return {70, .Mul}, true
    case .Slash:        return {70, .Div}, true
    case .Double_Slash: return {70, .Floor_Div}, true
    case .Percent:      return {70, .Mod}, true
    }
    return {}, false
}

// Full expression, including the lowest-precedence `a if cond else b`.
parse_expr :: proc(p: ^Parser) -> ^Expr {
    start := peek(p)
    value := parse_binary(p, 0)
    if value == nil { return nil }
    if accept(p, .If) {
        cond := parse_binary(p, 0)
        if cond == nil { return nil }
        if _, ok := expect(p, .Else, "'else' in a conditional expression"); !ok { return nil }
        other := parse_expr(p)
        if other == nil { return nil }
        return make_expr(Ternary{cond = cond, then_val = value, else_val = other}, span_from(p, start))
    }
    return value
}

parse_binary :: proc(p: ^Parser, min_bp: int) -> ^Expr {
    start := peek(p)
    lhs := parse_prefix(p)
    for lhs != nil {
        tok := peek(p)
        #partial switch tok.type {
        case .L_Paren:
            lhs = parse_call_suffix(p, lhs, start)
        case .L_Bracket:
            lhs = parse_index_suffix(p, lhs, start)
        case .Dot:
            lhs = parse_field_suffix(p, lhs, start)
        case:
            info, ok := infix_info(tok.type)
            // `<=` (not `<`) makes operators left-associative
            if !ok || info.bp <= min_bp { return lhs }
            advance(p)
            rhs := parse_binary(p, info.bp)
            if rhs == nil { return nil }
            lhs = make_expr(Binary{op = info.op, lhs = lhs, rhs = rhs}, span_from(p, start))
        }
    }
    return nil
}

parse_prefix :: proc(p: ^Parser) -> ^Expr {
    #partial switch peek(p).type {
    case .Minus:     return parse_unary(p, .Neg, UNARY_BP)
    case .Tilde:     return parse_unary(p, .Bit_Not, UNARY_BP)
    case .Not:       return parse_unary(p, .Not, NOT_BP)
    case .Star:      return parse_unary(p, .Deref, UNARY_BP) // prefix * is deref, infix * is multiply
    case .Ampersand: return parse_unary(p, .Addr, UNARY_BP)  // prefix & is address-of, infix & is bit-and
    }
    return parse_primary(p)
}

parse_unary :: proc(p: ^Parser, op: Unary_Op, bp: int) -> ^Expr {
    start := advance(p)
    operand := parse_binary(p, bp)
    if operand == nil { return nil }
    return make_expr(Unary{op = op, operand = operand}, span_from(p, start))
}

parse_primary :: proc(p: ^Parser) -> ^Expr {
    tok := peek(p)
    #partial switch tok.type {
    case .Int_Literal:
        advance(p)
        value, ok := parse_int_value(tok.text)
        if !ok {
            report(p.diags, token_span(tok), "integer literal is too large (the maximum is 18446744073709551615)")
            return nil
        }
        return make_expr(Int_Lit{value = value, text = tok.text}, token_span(tok))
    case .Str_Literal:
        advance(p)
        return make_expr(Str_Lit{text = tok.text}, token_span(tok))
    case .C_Str_Literal:
        advance(p)
        return make_expr(Str_Lit{text = tok.text, is_c = true}, token_span(tok))
    case .Char_Literal:
        advance(p)
        value, ok := parse_char_value(tok.text)
        if !ok {
            report(p.diags, token_span(tok), "a character literal must be a single byte or an escape like '\\n'")
            return nil
        }
        return make_expr(Char_Lit{value = value}, token_span(tok))
    case .True:
        advance(p)
        return make_expr(Bool_Lit{value = true}, token_span(tok))
    case .False:
        advance(p)
        return make_expr(Bool_Lit{value = false}, token_span(tok))
    case .Nil:
        advance(p)
        return make_expr(Nil_Lit{}, token_span(tok))
    case .Identifier:
        advance(p)
        return make_expr(Ident{name = tok.text}, token_span(tok))
    case .L_Paren:
        advance(p)
        inner := parse_expr(p)
        if inner == nil { return nil }
        if _, ok := expect(p, .R_Paren, "')'"); !ok { return nil }
        return inner
    case .L_Bracket:
        advance(p)
        lit := Array_Lit{}
        for !at(p, .R_Bracket) {
            elem := parse_expr(p)
            if elem == nil { return nil }
            append(&lit.elems, elem)
            if !accept(p, .Comma) { break }
        }
        if _, ok := expect(p, .R_Bracket, "']' to close the array literal"); !ok { return nil }
        return make_expr(lit, span_from(p, tok))
    }
    error_expected(p, "an expression")
    return nil
}

parse_call_suffix :: proc(p: ^Parser, callee: ^Expr, start: Token) -> ^Expr {
    advance(p) // (
    call := Call{callee = callee}

    // bitcast(T, x), size_of(T) ... take a TYPE as their first argument
    first_is_type := false
    if id, ok := callee.variant.(Ident); ok {
        switch id.name {
        case "bitcast", "size_of", "align_of", "offset_of": first_is_type = true
        }
    }

    first := true
    for !at(p, .R_Paren) {
        arg := Arg{}
        if first && first_is_type {
            t := parse_type(p)
            if t == nil { return nil }
            arg.value = make_expr(Type_Value{type = t}, t.span)
        } else {
            if at(p, .Identifier) && peek(p, 1).type == .Assign { // keyword argument
                arg.name = advance(p).text
                advance(p)
            }
            arg.value = parse_expr(p)
            if arg.value == nil { return nil }
        }
        append(&call.args, arg)
        first = false
        if !accept(p, .Comma) { break }
    }
    if _, ok := expect(p, .R_Paren, "')' to close the call"); !ok { return nil }
    return make_expr(call, span_from(p, start))
}

parse_index_suffix :: proc(p: ^Parser, base: ^Expr, start: Token) -> ^Expr {
    advance(p) // [
    lo: ^Expr
    if !at(p, .Colon) {
        lo = parse_expr(p)
        if lo == nil { return nil }
    }
    if accept(p, .Colon) { // a[lo:hi]
        hi: ^Expr
        if !at(p, .R_Bracket) {
            hi = parse_expr(p)
            if hi == nil { return nil }
        }
        if _, ok := expect(p, .R_Bracket, "']'"); !ok { return nil }
        return make_expr(Slice_Expr{base = base, lo = lo, hi = hi}, span_from(p, start))
    }
    if _, ok := expect(p, .R_Bracket, "']'"); !ok { return nil }
    return make_expr(Index{base = base, index = lo}, span_from(p, start))
}

parse_field_suffix :: proc(p: ^Parser, base: ^Expr, start: Token) -> ^Expr {
    advance(p) // .
    name, ok := expect(p, .Identifier, "a field name after '.'")
    if !ok { return nil }
    return make_expr(Field{base = base, name = name.text, name_span = token_span(name)}, span_from(p, start))
}

// 123, 1_000, 0xFF, 0b1010. Returns false on overflow.
parse_int_value :: proc(text: string) -> (u64, bool) {
    s := text
    base: u64 = 10
    if len(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
        base = 16
        s = s[2:]
    } else if len(s) > 2 && s[0] == '0' && (s[1] == 'b' || s[1] == 'B') {
        base = 2
        s = s[2:]
    }
    value: u64 = 0
    for i in 0 ..< len(s) {
        c := s[i]
        digit: u64
        switch {
        case c == '_':              continue
        case c >= '0' && c <= '9':  digit = u64(c - '0')
        case c >= 'a' && c <= 'f':  digit = u64(c - 'a') + 10
        case c >= 'A' && c <= 'F':  digit = u64(c - 'A') + 10
        }
        if value > (max(u64) - digit) / base { return 0, false }
        value = value * base + digit
    }
    return value, true
}

// 'A' or '\n' (text includes the quotes).
parse_char_value :: proc(text: string) -> (u8, bool) {
    inner := text[1:len(text) - 1]
    if len(inner) == 1 && inner[0] != '\\' { return inner[0], true }
    if len(inner) == 2 && inner[0] == '\\' {
        switch inner[1] {
        case 'n':  return '\n', true
        case 'r':  return '\r', true
        case 't':  return '\t', true
        case '0':  return 0, true
        case '\\': return '\\', true
        case '\'': return '\'', true
        case '"':  return '"', true
        }
    }
    return 0, false
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

// The body after a ':' -- either an indented block or a one-liner.
parse_block :: proc(p: ^Parser) -> (body: [dynamic]^Stmt, ok: bool) {
    if _, colon_ok := expect(p, .Colon, "':' to start the block"); !colon_ok { return body, false }

    if accept(p, .Newline) {
        if _, indent_ok := expect(p, .Indent, "an indented block"); !indent_ok { return body, false }
        for !at(p, .Dedent) && !at(p, .EOF) {
            before := p.pos
            stmt := parse_stmt(p)
            if stmt == nil {
                synchronize(p)
                if p.pos == before { advance(p) } // always make progress
                continue
            }
            append(&body, stmt)
        }
        accept(p, .Dedent)
        return body, true
    }

    stmt := parse_simple_stmt(p) // one-liner: `while x: pass`
    if stmt == nil { return body, false }
    append(&body, stmt)
    return body, true
}

// TODO: we needa parse when, elif, else, and from
parse_stmt :: proc(p: ^Parser) -> ^Stmt {
    #partial switch peek(p).type {
    case .If:    return parse_if(p)
    case .While: return parse_while(p)
    case .For:   return parse_for(p)
    }
    return parse_simple_stmt(p)
}

// A one-line statement plus its trailing newline.
parse_simple_stmt :: proc(p: ^Parser) -> ^Stmt {
    stmt := parse_simple_inner(p)
    if stmt == nil { return nil }
    if !expect_end_of_line(p) { return nil }
    return stmt
}

assign_op_for :: proc(t: Token_Type) -> (Assign_Op, bool) {
    #partial switch t {
    case .Assign:              return .Set, true
    case .Plus_Assign:         return .Add, true
    case .Minus_Assign:        return .Sub, true
    case .Star_Assign:         return .Mul, true
    case .Slash_Assign:        return .Div, true
    case .Double_Slash_Assign: return .Floor_Div, true
    case .Percent_Assign:      return .Mod, true
    case .And_Assign:          return .Bit_And, true
    case .Or_Assign:           return .Bit_Or, true
    case .Xor_Assign:          return .Bit_Xor, true
    case .Shl_Assign:          return .Shl, true
    case .Shr_Assign:          return .Shr, true
    }
    return .Set, false
}

parse_simple_inner :: proc(p: ^Parser) -> ^Stmt {
    start := peek(p)
    #partial switch start.type {
    case .Var, .Let, .Const:
        d, ok := parse_var_decl(p)
        if !ok { return nil }
        return make_stmt(d, span_from(p, start))
    case .Return:
        advance(p)
        value: ^Expr
        if !at(p, .Newline) {
            value = parse_expr(p)
            if value == nil { return nil }
        }
        return make_stmt(Return_Stmt{value = value}, span_from(p, start))
    case .Break:
        advance(p)
        return make_stmt(Break_Stmt{}, span_from(p, start))
    case .Continue:
        advance(p)
        return make_stmt(Continue_Stmt{}, span_from(p, start))
    case .Pass:
        advance(p)
        return make_stmt(Pass_Stmt{}, span_from(p, start))
    case .Defer:
        advance(p)
        inner := parse_simple_inner(p)
        if inner == nil { return nil }
        return make_stmt(Defer_Stmt{body = inner}, span_from(p, start))
    }

    // expression statement or assignment
    target := parse_expr(p)
    if target == nil { return nil }
    if op, is_assign := assign_op_for(peek(p).type); is_assign {
        advance(p)
        value := parse_expr(p)
        if value == nil { return nil }
        return make_stmt(Assign{op = op, target = target, value = value}, span_from(p, start))
    }
    return make_stmt(Expr_Stmt{expr = target}, span_from(p, start))
}

// const/let/var NAME [: Type] [= value]   (no trailing newline)
// TODO: let var be able to handle two values like var _, ok = find(items, 4)
parse_var_decl :: proc(p: ^Parser) -> (Var_Decl, bool) {
    kw := advance(p)
    d := Var_Decl{binding = .Var}
    #partial switch kw.type {
    case .Const: d.binding = .Const
    case .Let:   d.binding = .Let
    }
    name, ok := expect(p, .Identifier, "a name")
    if !ok { return {}, false }
    d.name = name.text
    d.name_span = token_span(name)
    if accept(p, .Colon) {
        d.type = parse_type(p)
        if d.type == nil { return {}, false }
    }
    if accept(p, .Assign) {
        d.value = parse_expr(p)
        if d.value == nil { return {}, false }
    }
    if d.type == nil && d.value == nil {
        report(p.diags, d.name_span,
            fmt.aprintf("'%s' needs a type or an initial value", d.name),
            "write 'var x: i32' or 'var x = 5'")
        return {}, false
    }
    return d, true
}

parse_if :: proc(p: ^Parser) -> ^Stmt {
    start := advance(p) // if
    node := If_Stmt{}
    cond := parse_expr(p)
    if cond == nil { return nil }
    body, ok := parse_block(p)
    if !ok { return nil }
    append(&node.branches, If_Branch{cond = cond, body = body})

    for at(p, .Elif) {
        advance(p)
        cond2 := parse_expr(p)
        if cond2 == nil { return nil }
        body2, ok2 := parse_block(p)
        if !ok2 { return nil }
        append(&node.branches, If_Branch{cond = cond2, body = body2})
    }
    if accept(p, .Else) {
        else_body, ok3 := parse_block(p)
        if !ok3 { return nil }
        node.else_body = else_body
    }
    return make_stmt(node, span_from(p, start))
}

parse_while :: proc(p: ^Parser) -> ^Stmt {
    start := advance(p) // while
    cond := parse_expr(p)
    if cond == nil { return nil }
    body, ok := parse_block(p)
    if !ok { return nil }
    return make_stmt(While_Stmt{cond = cond, body = body}, span_from(p, start))
}

// for item in xs | for i, item in xs | for &item in xs
parse_for :: proc(p: ^Parser) -> ^Stmt {
    start := advance(p) // for
    node := For_Stmt{}
    node.by_ref = accept(p, .Ampersand)
    first, ok := expect(p, .Identifier, "a loop variable name")
    if !ok { return nil }
    node.item_name = first.text
    node.item_span = token_span(first)
    if !node.by_ref && accept(p, .Comma) {
        second, ok2 := expect(p, .Identifier, "the item variable name")
        if !ok2 { return nil }
        node.index_name = first.text
        node.index_span = token_span(first)
        node.item_name = second.text
        node.item_span = token_span(second)
    }
    if _, ok3 := expect(p, .In, "'in'"); !ok3 { return nil }
    node.iterable = parse_expr(p)
    if node.iterable == nil { return nil }
    body, ok4 := parse_block(p)
    if !ok4 { return nil }
    node.body = body
    return make_stmt(node, span_from(p, start))
}

parse_when_decl :: proc(p: ^Parser) -> (When_Decl, bool) {
    advance(p) // when
    node := When_Decl{}
    cond := parse_expr(p)
    if cond == nil { return {}, false }
    
    body, ok := parse_decl_block(p, "an indented list of declarations")
    if !ok { return {}, false }
    append(&node.branches, When_Decl_Branch{cond = cond, decls = body})

    for at(p, .Elif) {
        advance(p)
        cond2 := parse_expr(p)
        if cond2 == nil { return {}, false }
        body2, ok2 := parse_decl_block(p, "an indented list of declarations")
        if !ok2 { return {}, false }
        append(&node.branches, When_Decl_Branch{cond = cond2, decls = body2})
    }
    if accept(p, .Else) {
        else_body, ok3 := parse_decl_block(p, "an indented list of declarations")
        if !ok3 { return {}, false }
        node.else_decls = else_body
    }
    return node, true
}

// Helper similar to parse_member_block_start, but for declarations inside a block (like when / foreign)
parse_decl_block :: proc(p: ^Parser, what: string) -> (decls: [dynamic]^Decl, ok: bool) {
    if _, colon_ok := expect(p, .Colon, "':'"); !colon_ok { return decls, false }
    if !expect_end_of_line(p) { return decls, false }
    if _, indent_ok := expect(p, .Indent, what); !indent_ok { return decls, false }

    for !at(p, .Dedent) && !at(p, .EOF) {
        for accept(p, .Newline) {}
        if at(p, .Dedent) { break }
        before := p.pos
        d := parse_decl(p)
        if d == nil {
            synchronize(p)
            if p.pos == before { advance(p) }
            continue
        }
        append(&decls, d)
    }
    accept(p, .Dedent)
    return decls, true
}

// when, elif, from, and else parser goes here or one of the parsers above

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

parse_import :: proc(p: ^Parser) -> (Import_Decl, bool) {
    advance(p) // import
    path_tok, ok := expect(p, .Identifier, "a module path")
    if !ok { return {}, false }
    path := path_tok.text
    // Handle dotted paths like ps1.gpu
    for accept(p, .Dot) {
        part, ok2 := expect(p, .Identifier, "module path component")
        if !ok2 { return {}, false }
        path = fmt.aprintf("%s.%s", path, part.text)
    }
    alias := ""
    if accept(p, .As) {
        alias_tok, ok3 := expect(p, .Identifier, "an alias name after 'as'")
        if !ok3 { return {}, false }
        alias = alias_tok.text
    }
    return Import_Decl{path = path, alias = alias}, true
}

parse_from_import :: proc(p: ^Parser) -> (From_Import_Decl, bool) {
    advance(p) // from
    mod_tok, ok := expect(p, .Identifier, "a module name")
    if !ok { return {}, false }
    module := mod_tok.text
    for accept(p, .Dot) {
        part, ok2 := expect(p, .Identifier, "module path component")
        if !ok2 { return {}, false }
        module = fmt.aprintf("%s.%s", module, part.text)
    }
    if _, ok3 := expect(p, .Import, "'import' after module path"); !ok3 { return {}, false }
    
    names: [dynamic]string
    for {
        name_tok, ok4 := expect(p, .Identifier, "an imported name")
        if !ok4 { return {}, false }
        append(&names, name_tok.text)
        if !accept(p, .Comma) { break }
    }
    return From_Import_Decl{module = module, names = names}, true
}

parse_module :: proc(p: ^Parser) -> Module {
    m := Module{}
    for {
        for accept(p, .Newline) {}
        if at(p, .EOF) { break }
        before := p.pos
        d := parse_decl(p)
        if d == nil {
            synchronize(p)
            if p.pos == before { advance(p) }
            continue
        }
        append(&m.decls, d)
    }
    return m
}

parse_attribute :: proc(p: ^Parser) -> (Attribute, bool) {
    at_tok := advance(p) // @
    name, ok := expect(p, .Identifier, "an attribute name after '@'")
    if !ok { return {}, false }
    a := Attribute{name = name.text}
    if accept(p, .L_Paren) {
        for !at(p, .R_Paren) {
            arg := parse_expr(p)
            if arg == nil { return {}, false }
            append(&a.args, arg)
            if !accept(p, .Comma) { break }
        }
        if _, ok2 := expect(p, .R_Paren, "')'"); !ok2 { return {}, false }
    }
    a.span = span_from(p, at_tok)
    return a, true
}

parse_decl :: proc(p: ^Parser) -> ^Decl {
    decl := new(Decl)
    for at(p, .At) {
        a, ok := parse_attribute(p)
        if !ok { return nil }
        append(&decl.attrs, a)
        if !expect_end_of_line(p) { return nil }
        for accept(p, .Newline) {}
    }

    start := peek(p)
    #partial switch start.type {
    case .Fn:
        f, ok := parse_fn(p)
        if !ok { return nil }
        decl.variant = f
    case .Const, .Let, .Var:
        v, ok := parse_var_decl(p)
        if !ok { return nil }
        if !expect_end_of_line(p) { return nil }
        decl.variant = v
    case .Struct:
        s, ok := parse_struct(p)
        if !ok { return nil }
        decl.variant = s
    case .Enum:
        e, ok := parse_enum(p)
        if !ok { return nil }
        decl.variant = e
    case .Union:
        u, ok := parse_union(p)
        if !ok { return nil }
        decl.variant = u
    case .Import:
        im, ok := parse_import(p)
        if !ok { return nil }
        if !expect_end_of_line(p) { return nil }
        decl.variant = im
    case .From:
        fm, ok := parse_from_import(p)
        if !ok { return nil }
        if !expect_end_of_line(p) { return nil }
        decl.variant = fm
    case .When:
        w, ok := parse_when_decl(p)
        if !ok { return nil }
        decl.variant = w
    case .Foreign:
        fo, ok := parse_foreign(p)
        if !ok { return nil }
        decl.variant = fo
    case:
        error_expected(p, "a declaration (fn, const, let, var, struct, enum, from, when, import, foreign, or union)")
        return nil
    }
    decl.span = span_from(p, start)
    return decl
}

// TODO: cant do fn divmod(a: i32, b: i32) -> (i32, i32):
//  	                                          ^~~~~~~~~
// or do fn apply(f: fn(i32) -> i32, v: i32) -> i32
// 					 ^~~~~~~~~
// or do fn max_of[T](a: T, b: T) -> T:
//                ^~~~~~~~~
// just add tuple and function pointer support
parse_fn :: proc(p: ^Parser) -> (Fn_Decl, bool) {
    advance(p) // fn
    name, ok := expect(p, .Identifier, "a function name")
    if !ok { return {}, false }
    f := Fn_Decl{name = name.text, name_span = token_span(name)}
    if accept(p, .L_Bracket) {
        for !at(p, .R_Bracket) {
            gen_tok, ok2 := expect(p, .Identifier, "a generic type parameter name")
            if !ok2 { return {}, false }
            append(&f.generic_params, gen_tok.text)
            if !accept(p, .Comma) { break }
        }
        if _, ok2 := expect(p, .R_Bracket, "']' to close generic parameters"); !ok2 { return {}, false }
    }

    if _, ok = expect(p, .L_Paren, "'(' after the function name"); !ok { return {}, false }

    for !at(p, .R_Paren) {
        pname, ok2 := expect(p, .Identifier, "a parameter name")
        if !ok2 { return {}, false }
        if _, ok2 = expect(p, .Colon, "':' and a type after the parameter name"); !ok2 { return {}, false }
        ptype := parse_type(p)
        if ptype == nil { return {}, false }
        param := Param{name = pname.text, name_span = token_span(pname), type = ptype}
        if accept(p, .Assign) {
            param.default = parse_expr(p)
            if param.default == nil { return {}, false }
        }
        append(&f.params, param)
        if !accept(p, .Comma) { break }
    }
    if _, ok = expect(p, .R_Paren, "')' to close the parameter list"); !ok { return {}, false }

    if accept(p, .Arrow) {
        f.ret = parse_type(p)
        if f.ret == nil { return {}, false }
    }
    body, ok3 := parse_block(p)
    if !ok3 { return {}, false }
    f.body = body
    return f, true
}

// Parses ":" NEWLINE INDENT before the members of a struct or enum.
parse_member_block_start :: proc(p: ^Parser, what: string) -> bool {
    if _, ok := expect(p, .Colon, "':'"); !ok { return false }
    if !expect_end_of_line(p) { return false }
    if _, ok := expect(p, .Indent, what); !ok { return false }
    return true
}

parse_struct :: proc(p: ^Parser) -> (Struct_Decl, bool) {
    advance(p) // struct
    name, ok := expect(p, .Identifier, "a struct name")
    if !ok { return {}, false }
    s := Struct_Decl{name = name.text, name_span = token_span(name)}
    if !parse_member_block_start(p, "an indented list of fields") { return {}, false }

    for !at(p, .Dedent) && !at(p, .EOF) {
        before := p.pos
        fname, ok2 := expect(p, .Identifier, "a field name")
        if ok2 {
            if _, ok3 := expect(p, .Colon, "':' and a type after the field name"); ok3 {
                ftype := parse_type(p)
                if ftype != nil && expect_end_of_line(p) {
                    append(&s.fields, Field_Decl{name = fname.text, name_span = token_span(fname), type = ftype})
                    continue
                }
            }
        }
        synchronize(p)
        if p.pos == before { advance(p) }
    }
    accept(p, .Dedent)
    return s, true
}

parse_enum :: proc(p: ^Parser) -> (Enum_Decl, bool) {
    advance(p) // enum
    name, ok := expect(p, .Identifier, "an enum name")
    if !ok { return {}, false }
    e := Enum_Decl{name = name.text, name_span = token_span(name)}

    // enum Mode: u8:    or    enum Mode:
    if _, ok2 := expect(p, .Colon, "':'"); !ok2 { return {}, false }
    if !at(p, .Newline) {
        e.base = parse_type(p)
        if e.base == nil { return {}, false }
        if _, ok2 := expect(p, .Colon, "':' after the underlying type"); !ok2 { return {}, false }
    }
    if !expect_end_of_line(p) { return {}, false }
    if _, ok2 := expect(p, .Indent, "an indented list of members"); !ok2 { return {}, false }

    for !at(p, .Dedent) && !at(p, .EOF) {
        before := p.pos
        mname, ok2 := expect(p, .Identifier, "a member name")
        if ok2 {
            member := Enum_Member{name = mname.text, name_span = token_span(mname)}
            good := true
            if accept(p, .Assign) {
                member.value = parse_expr(p)
                good = member.value != nil
            }
            if good && expect_end_of_line(p) {
                append(&e.members, member)
                continue
            }
        }
        synchronize(p)
        if p.pos == before { advance(p) }
    }
    accept(p, .Dedent)
    return e, true
}

parse_foreign :: proc(p: ^Parser) -> (Foreign_Decl, bool) {
    advance(p) // foreign
    str_tok, ok := expect(p, .Str_Literal, "a string literal for ABI (e.g. \"c\")")
    if !ok { return {}, false }
    decls, ok2 := parse_decl_block(p, "an indented list of foreign declarations")
    if !ok2 { return {}, false }
    return Foreign_Decl{abi = str_tok.text, decls = decls}, true
}

parse_union :: proc(p: ^Parser) -> (Union_Decl, bool) {
    advance(p) // union
    name, ok := expect(p, .Identifier, "a union name")
    if !ok { return {}, false }
    u := Union_Decl{name = name.text, name_span = token_span(name)}
    if !parse_member_block_start(p, "an indented list of union fields") { return {}, false }

    for !at(p, .Dedent) && !at(p, .EOF) {
        before := p.pos
        fname, ok2 := expect(p, .Identifier, "a field name")
        if ok2 {
            if _, ok3 := expect(p, .Colon, "':' and a type after the field name"); ok3 {
                ftype := parse_type(p)
                if ftype != nil && expect_end_of_line(p) {
                    append(&u.fields, Field_Decl{name = fname.text, name_span = token_span(fname), type = ftype})
                    continue
                }
            }
        }
        synchronize(p)
        if p.pos == before { advance(p) }
    }
    accept(p, .Dedent)
    return u, true
}

// TODO: cant parse unions
