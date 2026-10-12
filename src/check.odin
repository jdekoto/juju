package juju

import "core:fmt"

// ===========================================================================
// Semantic types: what the checker works with (not the syntax in ast.odin)
// ===========================================================================

Basic_Kind :: enum {
    Void, Bool,
    I8, I16, I32, I64, U8, U16, U32, U64, Isize, Usize,
    F32, F64, Str, Cstr,
    Untyped_Int, // a literal like 5 that hasn't picked a type yet
    Untyped_Nil, // the literal nil
    Invalid,     // an error was already reported; stay quiet about it
}

Type :: struct { info: Type_Info }

Type_Info :: union { Basic_Type, Pointer_Type, Slice_Type, Array_Type, Struct_Type, Enum_Type, Func_Type, Tuple_Type }

Basic_Type   :: struct { kind: Basic_Kind, name: string }
Pointer_Type :: struct { elem: ^Type, volatile: bool }
Slice_Type   :: struct { elem: ^Type }
Array_Type   :: struct { elem: ^Type, len: u64 }
Struct_Field :: struct { name: string, type: ^Type }
Struct_Type  :: struct { name: string, fields: [dynamic]Struct_Field, packed: bool, is_union: bool }
Enum_Type    :: struct { name: string, base: ^Type, members: [dynamic]string, values: [dynamic]i64 }
Tuple_Type   :: struct { elems: [dynamic]^Type } // multiple return values
Func_Type    :: struct {
    param_types: [dynamic]^Type,
    param_names: [dynamic]string,
    has_default: [dynamic]bool,
    ret:         ^Type, // ty_void if the function returns nothing
}

// Singletons for the types the checker needs to name directly.
ty_void, ty_bool, ty_i32, ty_u8, ty_usize, ty_str, ty_cstr: ^Type
ty_untyped_int, ty_untyped_nil, ty_invalid: ^Type

new_type :: proc(info: Type_Info) -> ^Type {
    t := new(Type)
    t.info = info
    return t
}

// ===========================================================================
// Symbols and scopes
// ===========================================================================

Symbol_Kind :: enum { Type, Const, Let, Var, Param, Fn }

Symbol :: struct {
    name:          string,
    kind:          Symbol_Kind,
    type:          ^Type, // for Kind.Type: the type it names
    span:          Span,  // where it was declared (line 0 = built in)
    has_const_int: bool,  // const with an integer literal value (enough for array lengths)
    const_int:     u64,
    // used by codegen:
    decl:          ^Decl,   // the top-level declaration this came from
    init:          ^Expr,   // initializer of a global const/let/var
    is_global:     bool,
    is_extern:     bool,    // declared inside `foreign "abi":`
    is_generic:    bool,
    ir_name:       string,  // the alloca register of a local, filled in by codegen
}

// Everything the checker learned, handed to codegen.
Sema :: struct {
    decls:      [dynamic]^Decl,              // top-level decls with `when` and `foreign` flattened away
    decl_syms:  map[^Decl]^Symbol,
    local_syms: map[^Stmt]^Symbol,           // a Var_Decl statement's variable, or a For_Stmt's item variable
    index_syms: map[^Stmt]^Symbol,           // the index variable of `for i, item in xs`
    param_syms: map[^Decl][dynamic]^Symbol,
    extern_abi: map[^Decl]string,            // functions declared inside `foreign "abi":`
    target:     string,
    ptr_bits:   int,
}

Scope :: struct {
    parent:  ^Scope,
    symbols: map[string]^Symbol,
}

new_scope :: proc(parent: ^Scope) -> ^Scope {
    s := new(Scope)
    s.parent = parent
    s.symbols = make(map[string]^Symbol)
    return s
}

lookup :: proc(scope: ^Scope, name: string) -> ^Symbol {
    for s := scope; s != nil; s = s.parent {
        if sym, ok := s.symbols[name]; ok { return sym }
    }
    return nil
}

Checker :: struct {
    diags:      ^[dynamic]Diagnostic,
    globals:    ^Scope,
    scope:      ^Scope,                  // the scope we're currently inside
    sema:       ^Sema,
    ret_type:   ^Type,                   // return type of the function being checked
    loop_depth: int,                     // > 0 inside a loop (for break/continue)
}

sem_err :: proc(c: ^Checker, span: Span, msg: string, hint := "") {
    report(c.diags, span, msg, hint)
}

declare :: proc(c: ^Checker, sym: ^Symbol) -> bool {
    if prev, exists := c.scope.symbols[sym.name]; exists {
        hint := "that name is built in"
        if prev.span.line > 0 { hint = fmt.aprintf("the first definition is on line %d", prev.span.line) }
        sem_err(c, sym.span, fmt.aprintf("'%s' is already defined in this scope", sym.name), hint)
        return false
    }
    c.scope.symbols[sym.name] = sym
    return true
}

push_scope :: proc(c: ^Checker) { c.scope = new_scope(c.scope) }
pop_scope  :: proc(c: ^Checker) { c.scope = c.scope.parent }

// ===========================================================================
// Type predicates and helpers
// ===========================================================================

basic_kind :: proc(t: ^Type) -> Basic_Kind {
    if t == nil { return .Invalid }
    if b, ok := t.info.(Basic_Type); ok { return b.kind }
    return .Invalid // not a basic type; callers only compare against specific kinds
}

is_basic :: proc(t: ^Type) -> bool {
    if t == nil { return false }
    _, ok := t.info.(Basic_Type)
    return ok
}

is_invalid     :: proc(t: ^Type) -> bool { return t == nil || (is_basic(t) && basic_kind(t) == .Invalid) }
is_void        :: proc(t: ^Type) -> bool { return is_basic(t) && basic_kind(t) == .Void }
is_bool        :: proc(t: ^Type) -> bool { return is_basic(t) && basic_kind(t) == .Bool }
is_untyped_int :: proc(t: ^Type) -> bool { return is_basic(t) && basic_kind(t) == .Untyped_Int }
is_untyped_nil :: proc(t: ^Type) -> bool { return is_basic(t) && basic_kind(t) == .Untyped_Nil }

is_integer :: proc(t: ^Type) -> bool {
    if !is_basic(t) { return false }
    #partial switch basic_kind(t) {
    case .I8 ..= .Usize, .Untyped_Int: return true
    }
    return false
}

is_float   :: proc(t: ^Type) -> bool { return is_basic(t) && (basic_kind(t) == .F32 || basic_kind(t) == .F64) }
is_numeric :: proc(t: ^Type) -> bool { return is_integer(t) || is_float(t) }

int_bits :: proc(t: ^Type, ptr_bits: int) -> int {
    if is_enum(t) { return int_bits(t.info.(Enum_Type).base, ptr_bits) }
    #partial switch basic_kind(t) {
    case .Bool:                        return 1
    case .I8, .U8:                     return 8
    case .I16, .U16:                   return 16
    case .I32, .U32, .Untyped_Int:     return 32
    case .I64, .U64:                   return 64
    case .Isize, .Usize:               return ptr_bits
    }
    return 0
}

is_signed :: proc(t: ^Type) -> bool {
    if is_enum(t) { return is_signed(t.info.(Enum_Type).base) }
    #partial switch basic_kind(t) {
    case .I8, .I16, .I32, .I64, .Isize, .Untyped_Int: return true
    }
    return false
}

int_fits :: proc(value: u64, t: ^Type, negated: bool, ptr_bits: int) -> bool {
    bits := int_bits(t, ptr_bits)
    if is_signed(t) {
        limit := (u64(1) << u64(bits - 1)) - 1
        if negated { limit += 1 }
        return value <= limit
    }
    if negated { return value == 0 }
    if bits >= 64 { return true }
    return value <= (u64(1) << u64(bits)) - 1
}

is_pointer :: proc(t: ^Type) -> bool {
    if t == nil { return false }
    _, ok := t.info.(Pointer_Type)
    return ok
}

is_pointer_to :: proc(ptr, elem: ^Type) -> bool {
    if ptr == nil { return false }
    if p, ok := ptr.info.(Pointer_Type); ok { return types_equal(p.elem, elem) }
    return false
}

types_equal :: proc(a, b: ^Type) -> bool {
    if a == b { return true }
    if a == nil || b == nil { return false }
    switch x in a.info {
    case Basic_Type:
        if y, ok := b.info.(Basic_Type); ok { return x.kind == y.kind }
    case Pointer_Type:
        if y, ok := b.info.(Pointer_Type); ok { return x.volatile == y.volatile && types_equal(x.elem, y.elem) }
    case Slice_Type:
        if y, ok := b.info.(Slice_Type); ok { return types_equal(x.elem, y.elem) }
    case Array_Type:
        if y, ok := b.info.(Array_Type); ok { return x.len == y.len && types_equal(x.elem, y.elem) }
    case Func_Type:
        if y, ok := b.info.(Func_Type); ok {
            if len(x.param_types) != len(y.param_types) || !types_equal(x.ret, y.ret) { return false }
            for i in 0 ..< len(x.param_types) { if !types_equal(x.param_types[i], y.param_types[i]) { return false } }
            return true
        }
    case Tuple_Type:
        if y, ok := b.info.(Tuple_Type); ok {
            if len(x.elems) != len(y.elems) { return false }
            for i in 0 ..< len(x.elems) { if !types_equal(x.elems[i], y.elems[i]) { return false } }
            return true
        }
    case Struct_Type, Enum_Type:
        return false // named types are equal only by identity (a == b above)
    }
    return false
}

type_name :: proc(t: ^Type) -> string {
    if t == nil { return "<unknown>" }
    switch v in t.info {
    case Basic_Type:
        #partial switch v.kind {
        case .Untyped_Int: return "untyped integer"
        case .Untyped_Nil: return "nil"
        }
        return v.name
    case Pointer_Type: return fmt.aprintf("*%s%s", "volatile " if v.volatile else "", type_name(v.elem))
    case Slice_Type:   return fmt.aprintf("[]%s", type_name(v.elem))
    case Array_Type:   return fmt.aprintf("[%d]%s", v.len, type_name(v.elem))
    case Struct_Type:  return v.name
    case Enum_Type:    return v.name
    case Func_Type:    return "fn"
    case Tuple_Type:
        s := "("
        for e, i in v.elems { s = fmt.aprintf("%s%s%s", s, ", " if i > 0 else "", type_name(e)) }
        return fmt.aprintf("%s)", s)
    }
    return "?"
}

// ===========================================================================
// "did you mean" suggestions
// ===========================================================================

edit_distance :: proc(a, b: string) -> int {
    prev := make([]int, len(b) + 1)
    cur  := make([]int, len(b) + 1)
    defer delete(prev)
    defer delete(cur)
    for j in 0 ..= len(b) { prev[j] = j }
    for i in 1 ..= len(a) {
        cur[0] = i
        for j in 1 ..= len(b) {
            cost := 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        }
        prev, cur = cur, prev
    }
    return prev[len(b)]
}

suggest :: proc(candidates: []string, name: string) -> string {
    if len(name) < 3 { return "" }
    best := ""
    best_d := max(int)
    limit := max(2, len(name) / 3)
    for cand in candidates {
        if cand == name { continue }
        d := edit_distance(cand, name)
        if d < best_d && d <= limit {
            best = cand
            best_d = d
        }
    }
    if best == "" { return "" }
    return fmt.aprintf("did you mean '%s'?", best)
}

// Names visible from the current scope: values, or (types = true) type names.
visible_names :: proc(c: ^Checker, types: bool) -> [dynamic]string {
    names: [dynamic]string
    for s := c.scope; s != nil; s = s.parent {
        for name, sym in s.symbols {
            if (sym.kind == .Type) == types { append(&names, name) }
        }
    }
    return names
}

report_undeclared :: proc(c: ^Checker, span: Span, name: string) {
    names := visible_names(c, false)
    defer delete(names)
    sem_err(c, span, fmt.aprintf("'%s' is not declared", name), suggest(names[:], name))
}

// ===========================================================================
// Entry point: four passes over the module
// ===========================================================================

check_module :: proc(m: Module, diags: ^[dynamic]Diagnostic, target: string) -> ^Sema {
    s := new(Sema)
    s.decl_syms  = make(map[^Decl]^Symbol)
    s.local_syms = make(map[^Stmt]^Symbol)
    s.index_syms = make(map[^Stmt]^Symbol)
    s.param_syms = make(map[^Decl][dynamic]^Symbol)
    s.extern_abi = make(map[^Decl]string)
    s.target = target
    s.ptr_bits = 64 if target == "host" else 32

    c := Checker{diags = diags, sema = s}
    c.globals = new_scope(nil)
    c.scope = c.globals

    init_builtins(&c)
    flatten_decls(&c, m.decls[:], "", &s.decls) // 0. resolve `when`, unwrap `foreign`
    collect_decls(&c, m)       // 1. put every top-level NAME in scope (so order doesn't matter)
    resolve_signatures(&c, m)  // 2. fill in struct fields, enum members, function signatures
    check_globals(&c, m)       // 3. type the top-level const/let/var initializers
    check_bodies(&c, m)        // 4. check every function body
    return s
}

// `when` picks one branch at compile time; `foreign` marks its functions as extern.
flatten_decls :: proc(c: ^Checker, decls: []^Decl, abi: string, out: ^[dynamic]^Decl) {
    for d in decls {
        #partial switch v in d.variant {
        case When_Decl:
            chosen := false
            for b in v.branches {
                val, ok := eval_when_cond(c, b.cond)
                if ok && val {
                    flatten_decls(c, b.decls[:], abi, out)
                    chosen = true
                    break
                }
            }
            if !chosen { flatten_decls(c, v.else_decls[:], abi, out) }
        case Foreign_Decl:
            flatten_decls(c, v.decls[:], v.abi, out)
        case Import_Decl, From_Import_Decl:
            sem_err(c, d.span, "imports aren't implemented yet", "the checker needs to load and check the other file first")
        case:
            if abi != "" { c.sema.extern_abi[d] = abi }
            append(out, d)
        }
    }
}

// Understands: TARGET == "ps1", TARGET != "gba", and / or / not, true / false.
eval_when_cond :: proc(c: ^Checker, e: ^Expr) -> (bool, bool) {
    #partial switch v in e.variant {
    case Bool_Lit:
        return v.value, true
    case Unary:
        if v.op == .Not {
            b, ok := eval_when_cond(c, v.operand)
            return !b, ok
        }
    case Binary:
        #partial switch v.op {
        case .And:
            a, ok1 := eval_when_cond(c, v.lhs)
            b, ok2 := eval_when_cond(c, v.rhs)
            return a && b, ok1 && ok2
        case .Or:
            a, ok1 := eval_when_cond(c, v.lhs)
            b, ok2 := eval_when_cond(c, v.rhs)
            return a || b, ok1 && ok2
        case .Eq, .Not_Eq:
            id, is_id := v.lhs.variant.(Ident)
            lit, is_lit := v.rhs.variant.(Str_Lit)
            if is_id && is_lit && id.name == "TARGET" && !lit.is_c {
                same := lit.text[1:len(lit.text) - 1] == c.sema.target
                return same if v.op == .Eq else !same, true
            }
        }
    }
    sem_err(c, e.span, "unsupported compile-time condition",
        "'when' understands TARGET == \"name\", and / or / not, and true / false")
    return false, false
}

has_attr :: proc(d: ^Decl, name: string) -> bool {
    for a in d.attrs { if a.name == name { return true } }
    return false
}

add_builtin_type :: proc(c: ^Checker, kind: Basic_Kind, name: string) -> ^Type {
    t := new_type(Basic_Type{kind = kind, name = name})
    c.globals.symbols[name] = new_symbol(name, .Type, t, Span{})
    return t
}

new_symbol :: proc(name: string, kind: Symbol_Kind, type: ^Type, span: Span) -> ^Symbol {
    s := new(Symbol)
    s.name = name
    s.kind = kind
    s.type = type
    s.span = span
    return s
}

init_builtins :: proc(c: ^Checker) {
    ty_void        = new_type(Basic_Type{kind = .Void, name = "void"})
    ty_invalid     = new_type(Basic_Type{kind = .Invalid, name = "<error>"})
    ty_untyped_int = new_type(Basic_Type{kind = .Untyped_Int, name = "untyped integer"})
    ty_untyped_nil = new_type(Basic_Type{kind = .Untyped_Nil, name = "nil"})

    ty_bool = add_builtin_type(c, .Bool, "bool")
    add_builtin_type(c, .I8, "i8")
    add_builtin_type(c, .I16, "i16")
    ty_i32 = add_builtin_type(c, .I32, "i32")
    add_builtin_type(c, .I64, "i64")
    ty_u8 = add_builtin_type(c, .U8, "u8")
    add_builtin_type(c, .U16, "u16")
    add_builtin_type(c, .U32, "u32")
    add_builtin_type(c, .U64, "u64")
    add_builtin_type(c, .Isize, "isize")
    ty_usize = add_builtin_type(c, .Usize, "usize")
    add_builtin_type(c, .F32, "f32")
    add_builtin_type(c, .F64, "f64")
    ty_str  = add_builtin_type(c, .Str, "str")
    ty_cstr = add_builtin_type(c, .Cstr, "cstr")
}

KNOWN_ATTRS :: [?]string{
    "inline", "noinline", "export", "section", "naked", "packed", "align", "used",
    "weak", "cold", "noreturn", "must_use", "link_name", "no_bounds_check", "deprecated",
}

check_attributes :: proc(c: ^Checker, d: ^Decl) {
    for a in d.attrs {
        known := false
        names: [dynamic]string
        defer delete(names)
        for k in KNOWN_ATTRS {
            append(&names, k)
            if a.name == k { known = true }
        }
        if !known {
            sem_err(c, a.span, fmt.aprintf("unknown attribute '@%s'", a.name), suggest(names[:], a.name))
        }
        // TODO: check each attribute's arguments (@section wants a string, @align a number, ...)
    }
}

// ---------------------------------------------------------------------------
// Pass 1: declare every top-level name
// ---------------------------------------------------------------------------

collect_decls :: proc(c: ^Checker, m: Module) {
    for d in c.sema.decls {
        check_attributes(c, d)
        sym: ^Symbol
        switch v in d.variant {
        case Fn_Decl:
            sym = new_symbol(v.name, .Fn, nil, v.name_span)
            sym.is_generic = len(v.generic_params) > 0
        case Var_Decl:
            kind := Symbol_Kind.Var
            if v.binding == .Const { kind = .Const } else if v.binding == .Let { kind = .Let }
            sym = new_symbol(v.name, kind, nil, v.name_span)
            sym.is_global = true
            sym.init = v.value
            // Integer consts are known right away so they can size arrays in signatures.
            if v.binding == .Const && v.value != nil {
                if lit, ok := v.value.variant.(Int_Lit); ok {
                    sym.has_const_int = true
                    sym.const_int = lit.value
                }
            }
        case Struct_Decl:
            sym = new_symbol(v.name, .Type, new_type(Struct_Type{name = v.name, packed = has_attr(d, "packed")}), v.name_span)
        case Union_Decl:
            sym = new_symbol(v.name, .Type, new_type(Struct_Type{name = v.name, is_union = true}), v.name_span)
        case Enum_Decl:
            sym = new_symbol(v.name, .Type, new_type(Enum_Type{name = v.name}), v.name_span)
        case Import_Decl, From_Import_Decl, When_Decl, Foreign_Decl:
            continue // flatten_decls already dealt with these
        }
        sym.decl = d
        sym.is_extern = d in c.sema.extern_abi
        if declare(c, sym) { c.sema.decl_syms[d] = sym }
    }
}

// ---------------------------------------------------------------------------
// Pass 2: struct fields, enum members, function signatures
// ---------------------------------------------------------------------------

resolve_type :: proc(c: ^Checker, t: ^Type_Expr) -> ^Type {
    switch v in t.variant {
    case Type_Name:
        if v.module != "" {
            sem_err(c, t.span, "module-qualified types aren't supported yet", "imports are still TODO")
            return ty_invalid
        }
        sym := lookup(c.scope, v.name)
        if sym == nil {
            names := visible_names(c, true)
            defer delete(names)
            sem_err(c, t.span, fmt.aprintf("unknown type '%s'", v.name), suggest(names[:], v.name))
            return ty_invalid
        }
        if sym.kind != .Type {
            sem_err(c, t.span, fmt.aprintf("'%s' is not a type", v.name))
            return ty_invalid
        }
        return sym.type
    case Type_Ptr:
        elem := resolve_type(c, v.elem)
        return new_type(Pointer_Type{elem = elem, volatile = v.volatile})
    case Type_Slice:
        return new_type(Slice_Type{elem = resolve_type(c, v.elem)})
    case Type_Tuple:
        tt := Tuple_Type{}
        for el in v.elems { append(&tt.elems, resolve_type(c, el)) }
        return new_type(tt)
    case Type_Fn:
        ft := Func_Type{ret = ty_void}
        for p in v.params { append(&ft.param_types, resolve_type(c, p)) }
        if v.ret != nil { ft.ret = resolve_type(c, v.ret) }
        return new_type(ft)
    case Type_Array:
        elem := resolve_type(c, v.elem)
        n, ok := const_int_value(c, v.len)
        if !ok {
            sem_err(c, v.len.span, "an array length must be a compile-time integer",
                "use a literal or a const; a full constant evaluator is TODO")
            return ty_invalid
        }
        return new_type(Array_Type{elem = elem, len = n})
    }
    return ty_invalid
}

// TODO: a real constant evaluator (2 * 4, size_of(T), ...). For now: literals and simple consts.
const_int_value :: proc(c: ^Checker, e: ^Expr) -> (u64, bool) {
    #partial switch v in e.variant {
    case Int_Lit:
        return v.value, true
    case Ident:
        if sym := lookup(c.scope, v.name); sym != nil && sym.has_const_int { return sym.const_int, true }
    }
    return 0, false
}

resolve_fields :: proc(c: ^Checker, sym: ^Symbol, owner: string, fields: []Field_Decl) {
    st := sym.type.info.(Struct_Type)
    for f in fields {
        for existing in st.fields {
            if existing.name == f.name {
                sem_err(c, f.name_span, fmt.aprintf("'%s' already has a field '%s'", owner, f.name))
            }
        }
        append(&st.fields, Struct_Field{name = f.name, type = resolve_type(c, f.type)})
    }
    sym.type.info = st // TODO: detect a struct that contains itself by value
}

// Enum member values: an integer literal (optionally negative), or the previous value + 1.
enum_member_value :: proc(c: ^Checker, e: ^Expr) -> (i64, bool) {
    #partial switch v in e.variant {
    case Int_Lit: return i64(v.value), true
    case Unary:
        if lit, ok := v.operand.variant.(Int_Lit); ok && v.op == .Neg { return -i64(lit.value), true }
    case Ident:
        if sym := lookup(c.scope, v.name); sym != nil && sym.has_const_int { return i64(sym.const_int), true }
    }
    sem_err(c, e.span, "an enum member's value must be an integer literal for now")
    return 0, false
}

resolve_signatures :: proc(c: ^Checker, m: Module) {
    for d in c.sema.decls {
        sym, found := c.sema.decl_syms[d]
        if !found { continue }
        switch v in d.variant {
        case Struct_Decl:
            resolve_fields(c, sym, v.name, v.fields[:])
        case Union_Decl:
            resolve_fields(c, sym, v.name, v.fields[:])
        case Enum_Decl:
            et := sym.type.info.(Enum_Type)
            et.base = ty_i32
            if v.base != nil {
                et.base = resolve_type(c, v.base)
                if !is_invalid(et.base) && !is_integer(et.base) {
                    sem_err(c, v.base.span, fmt.aprintf("an enum's underlying type must be an integer, found '%s'", type_name(et.base)))
                }
            }
            next: i64 = 0
            for mem in v.members {
                for existing in et.members {
                    if existing == mem.name { sem_err(c, mem.name_span, fmt.aprintf("enum '%s' already has a member '%s'", v.name, mem.name)) }
                }
                if mem.value != nil {
                    if val, ok := enum_member_value(c, mem.value); ok { next = val }
                }
                append(&et.members, mem.name)
                append(&et.values, next)
                next += 1
            }
            sym.type.info = et
        case Fn_Decl:
            if sym.is_generic {
                // TODO: instantiate generics per use. For now the signature is left empty.
                sym.type = new_type(Func_Type{ret = ty_void})
                continue
            }
            ft := Func_Type{ret = ty_void}
            for p in v.params {
                append(&ft.param_types, resolve_type(c, p.type))
                append(&ft.param_names, p.name)
                append(&ft.has_default, p.default != nil)
            }
            if v.ret != nil { ft.ret = resolve_type(c, v.ret) }
            sym.type = new_type(ft)
        case Var_Decl, Import_Decl, From_Import_Decl, When_Decl, Foreign_Decl:
            // variables are typed in pass 3; the rest were flattened away
        }
    }
}

// ---------------------------------------------------------------------------
// Pass 3: top-level const/let/var (checked in source order)
// ---------------------------------------------------------------------------

check_globals :: proc(c: ^Checker, m: Module) {
    for d in c.sema.decls {
        v, is_var := d.variant.(Var_Decl)
        if !is_var { continue }
        sym, found := c.sema.decl_syms[d]
        if !found { continue }
        check_var_decl(c, v, sym)
    }
}

// Shared by globals and locals: works out the variable's type from its
// annotation and/or initializer and stores it in `sym.type`.
check_var_decl :: proc(c: ^Checker, v: Var_Decl, sym: ^Symbol) {
    declared: ^Type
    if v.type != nil { declared = resolve_type(c, v.type) }
    final := declared

    if v.value != nil {
        vt := check_expr(c, v.value, declared)
        if declared != nil {
            coerce(c, v.value, declared, fmt.aprintf("the initializer of '%s'", v.name))
        } else {
            final = vt
            if is_untyped_int(vt) {          // `var count = 5` defaults to i32
                final = ty_i32
                resolve_untyped(c, v.value, ty_i32)
            } else if is_untyped_nil(vt) {
                sem_err(c, v.value.span, "can't infer a type from nil", "write the type: var p: *i32 = nil")
                final = ty_invalid
            }
        }
    } else if v.binding != .Var {
        sem_err(c, v.name_span, fmt.aprintf("a %v needs an initial value", v.binding))
    }

    if final != nil && is_void(final) {
        sem_err(c, v.value.span if v.value != nil else v.name_span, "this has no value to store (the function returns nothing)")
        final = ty_invalid
    }
    sym.type = final if final != nil else ty_invalid
}

// ---------------------------------------------------------------------------
// Pass 4: function bodies
// ---------------------------------------------------------------------------

check_bodies :: proc(c: ^Checker, m: Module) {
    for d in c.sema.decls {
        f, is_fn := d.variant.(Fn_Decl)
        if !is_fn { continue }
        sym, found := c.sema.decl_syms[d]
        if !found || sym.is_extern || sym.is_generic { continue } // no body to check
        ft := sym.type.info.(Func_Type)

        c.scope = new_scope(c.globals) // parameters and body share one scope
        c.ret_type = ft.ret
        c.loop_depth = 0
        psyms: [dynamic]^Symbol
        for p, i in f.params {
            if p.default != nil {
                check_expr(c, p.default, ft.param_types[i])
                coerce(c, p.default, ft.param_types[i], fmt.aprintf("the default of '%s'", p.name))
            }
            psym := new_symbol(p.name, .Param, ft.param_types[i], p.name_span)
            declare(c, psym)
            append(&psyms, psym)
        }
        c.sema.param_syms[d] = psyms
        for s in f.body { check_stmt(c, s) }
        // TODO: "missing return" analysis (every path of a non-void function must return)
        // TODO: unused variable / unused result (@must_use) warnings
        c.scope = c.globals
    }
}

check_block :: proc(c: ^Checker, body: [dynamic]^Stmt) {
    push_scope(c)
    defer pop_scope(c)
    for s in body { check_stmt(c, s) }
}

check_stmt :: proc(c: ^Checker, s: ^Stmt) {
    switch v in s.variant {
    case Var_Decl:
        kind := Symbol_Kind.Var
        if v.binding == .Const { kind = .Const } else if v.binding == .Let { kind = .Let }
        sym := new_symbol(v.name, kind, nil, v.name_span)
        check_var_decl(c, v, sym) // check the initializer BEFORE the name exists: `var x = x` is an error
        declare(c, sym)
        c.sema.local_syms[s] = sym
    case Assign:
        check_assign(c, v)
    case Expr_Stmt:
        check_expr(c, v.expr)
    case If_Stmt:
        for b in v.branches {
            check_condition(c, b.cond)
            check_block(c, b.body)
        }
        check_block(c, v.else_body)
    case While_Stmt:
        check_condition(c, v.cond)
        c.loop_depth += 1
        check_block(c, v.body)
        c.loop_depth -= 1
    case For_Stmt:
        check_for(c, s, v)
    case Return_Stmt:
        check_return(c, s, v)
    case Break_Stmt:
        if c.loop_depth == 0 { sem_err(c, s.span, "'break' can only be used inside a loop") }
    case Continue_Stmt:
        if c.loop_depth == 0 { sem_err(c, s.span, "'continue' can only be used inside a loop") }
    case Pass_Stmt:
    case Defer_Stmt:
        check_stmt(c, v.body) // TODO: defer inside loops, and defer ordering at scope exit (codegen)
    }
}

check_condition :: proc(c: ^Checker, cond: ^Expr) {
    t := check_expr(c, cond, ty_bool)
    if !is_invalid(t) && !is_bool(t) {
        sem_err(c, cond.span, fmt.aprintf("a condition must be a bool, found '%s'", type_name(t)),
            "juju has no truthiness: write a comparison like 'x != 0' or 'p != nil'")
    }
}

check_return :: proc(c: ^Checker, s: ^Stmt, v: Return_Stmt) {
    if v.value == nil {
        if !is_void(c.ret_type) && !is_invalid(c.ret_type) {
            sem_err(c, s.span, fmt.aprintf("this function must return a '%s'", type_name(c.ret_type)))
        }
        return
    }
    if is_void(c.ret_type) {
        check_expr(c, v.value)
        sem_err(c, v.value.span, "this function doesn't return a value", "add '-> Type' to the function signature")
        return
    }
    check_expr(c, v.value, c.ret_type)
    coerce(c, v.value, c.ret_type, "the return value")
}

check_for :: proc(c: ^Checker, s: ^Stmt, v: For_Stmt) {
    item_type := ty_invalid
    is_range := false

    if call, ok := v.iterable.variant.(Call); ok {
        if id, ok2 := call.callee.variant.(Ident); ok2 && id.name == "range" {
            is_range = true
            item_type = check_range(c, v.iterable, call)
            v.iterable.type = item_type
            if v.by_ref { sem_err(c, v.item_span, "'&' can't be used with range()") }
        }
    }
    if !is_range {
        it := check_expr(c, v.iterable)
        if !is_invalid(it) {
            elem: ^Type
            #partial switch info in it.info {
            case Array_Type: elem = info.elem
            case Slice_Type: elem = info.elem
            case:
                sem_err(c, v.iterable.span, fmt.aprintf("can't loop over a value of type '%s'", type_name(it)),
                    "loop over an array, a slice, or range(n)")
            }
            if elem != nil {
                item_type = elem
                if v.by_ref { item_type = new_type(Pointer_Type{elem = elem}) } // for &item in xs
            }
        }
    }

    push_scope(c)
    defer pop_scope(c)
    if v.index_name != "" {
        isym := new_symbol(v.index_name, .Var, ty_usize, v.index_span)
        declare(c, isym)
        c.sema.index_syms[s] = isym
    }
    item_sym := new_symbol(v.item_name, .Var, item_type, v.item_span)
    declare(c, item_sym)
    c.sema.local_syms[s] = item_sym
    c.loop_depth += 1
    for st in v.body { check_stmt(c, st) }
    c.loop_depth -= 1
}

// range(end) | range(start, end) | range(start, end, step). The loop variable
// takes the type of the first typed argument, or usize if all are literals.
check_range :: proc(c: ^Checker, e: ^Expr, call: Call) -> ^Type {
    if len(call.args) < 1 || len(call.args) > 3 {
        sem_err(c, e.span, "range() takes 1 to 3 arguments", "range(end), range(start, end) or range(start, end, step)")
        return ty_invalid
    }
    loop_t: ^Type
    for a in call.args {
        t := check_expr(c, a.value)
        if is_invalid(t) { return ty_invalid }
        if !is_integer(t) {
            sem_err(c, a.value.span, fmt.aprintf("range() needs integers, found '%s'", type_name(t)))
            return ty_invalid
        }
        if !is_untyped_int(t) && loop_t == nil { loop_t = t }
    }
    if loop_t == nil { loop_t = ty_usize }
    for a in call.args { coerce(c, a.value, loop_t, "a range() argument") }
    return loop_t
}

check_assign :: proc(c: ^Checker, v: Assign) {
    tt := check_expr(c, v.target)
    if is_invalid(tt) || !check_assignable(c, v.target) {
        check_expr(c, v.value) // still check the right side so its errors show up
        return
    }
    #partial switch v.op {
    case .Set:
        check_expr(c, v.value, tt)
        coerce(c, v.value, tt, "the assignment")
    case .Shl, .Shr:
        rt := check_expr(c, v.value)
        if !is_invalid(rt) && (!is_integer(tt) || !is_integer(rt)) {
            sem_err(c, v.value.span, "shifts need integers on both sides")
        }
    case:
        check_expr(c, v.value, tt)
        if !coerce(c, v.value, tt, "the compound assignment") { return }
        bitwise := v.op == .Bit_And || v.op == .Bit_Or || v.op == .Bit_Xor
        if bitwise && !is_integer(tt) {
            sem_err(c, v.target.span, fmt.aprintf("bitwise operators need integers, found '%s'", type_name(tt)))
        } else if !bitwise && !is_numeric(tt) {
            sem_err(c, v.target.span, fmt.aprintf("arithmetic needs numbers, found '%s'", type_name(tt)))
        }
    }
}

// Can this expression appear on the left of '='? Reports the error if not.
check_assignable :: proc(c: ^Checker, e: ^Expr) -> bool {
    switch v in e.variant {
    case Ident:
        sym := lookup(c.scope, v.name)
        if sym != nil && (sym.kind == .Const || sym.kind == .Let) {
            what := "const" if sym.kind == .Const else "let"
            sem_err(c, e.span, fmt.aprintf("can't assign to '%s' because it is a %s", v.name, what),
                "declare it with 'var' if it needs to change")
            return false
        }
        return true
    case Unary:
        if v.op == .Deref { return true } // *p = x: the pointer itself may be a const
    case Index:
        if bt := v.base.type; bt != nil {
            if _, ok := bt.info.(Slice_Type); ok { return true } // a slice is a mutable view
        }
        return check_assignable(c, v.base)
    case Field:
        if bt := v.base.type; bt != nil {
            if _, ok := bt.info.(Pointer_Type); ok { return true } // p.x writes through the pointer
        }
        return check_assignable(c, v.base)
    case Int_Lit, Str_Lit, Char_Lit, Bool_Lit, Nil_Lit, Binary, Ternary, Call, Slice_Expr, Array_Lit, Type_Value:
    }
    sem_err(c, e.span, "this expression can't be assigned to")
    return false
}

is_addressable :: proc(c: ^Checker, e: ^Expr) -> bool {
    #partial switch v in e.variant {
    case Ident:
        sym := lookup(c.scope, v.name)
        return sym != nil && (sym.kind == .Var || sym.kind == .Let || sym.kind == .Param)
    case Index, Field:
        return true
    case Unary:
        return v.op == .Deref
    }
    return false
}

// ===========================================================================
// Expressions
// ===========================================================================

// Checks `e`, records its type in e.type, and returns it. `expected` is only a
// hint (it lets array literals and untyped integers know what they're becoming).
check_expr :: proc(c: ^Checker, e: ^Expr, expected: ^Type = nil) -> ^Type {
    t := check_expr_inner(c, e, expected)
    e.type = t
    return t
}

check_expr_inner :: proc(c: ^Checker, e: ^Expr, expected: ^Type) -> ^Type {
    switch v in e.variant {
    case Int_Lit:    return ty_untyped_int
    case Str_Lit:    return ty_cstr if v.is_c else ty_str
    case Char_Lit:   return ty_u8
    case Bool_Lit:   return ty_bool
    case Nil_Lit:    return ty_untyped_nil
    case Ident:      return check_ident(c, e, v)
    case Unary:      return check_unary(c, e, v)
    case Binary:     return check_binary(c, e, v)
    case Ternary:    return check_ternary(c, e, v)
    case Call:       return check_call(c, e, v)
    case Index:      return check_index(c, v)
    case Slice_Expr: return check_slice(c, v)
    case Field:      return check_field(c, v)
    case Array_Lit:  return check_array_lit(c, e, v, expected)
    case Type_Value:
        sem_err(c, e.span, "a type can't be used as a value here",
            "types are only allowed as the first argument of bitcast, size_of and align_of")
        return ty_invalid
    }
    return ty_invalid
}

// Gives an untyped-integer expression its final type, all the way down, and
// range-checks the literals ('300' doesn't fit in a u8).
resolve_untyped :: proc(c: ^Checker, e: ^Expr, t: ^Type, negated := false) {
    if e == nil || !is_untyped_int(e.type) { return }
    e.type = t
    switch v in e.variant {
    case Int_Lit:
        if !int_fits(v.value, t, negated, c.sema.ptr_bits) {
            sem_err(c, e.span, fmt.aprintf("the value %s%d doesn't fit in '%s'", "-" if negated else "", v.value, type_name(t)))
        }
    case Unary:
        if v.op == .Neg { resolve_untyped(c, v.operand, t, true) } else if v.op == .Bit_Not { resolve_untyped(c, v.operand, t) }
    case Binary:
        #partial switch v.op {
        case .Add, .Sub, .Mul, .Div, .Floor_Div, .Mod, .Bit_And, .Bit_Or, .Bit_Xor:
            resolve_untyped(c, v.lhs, t)
            resolve_untyped(c, v.rhs, t)
        case .Shl, .Shr:
            resolve_untyped(c, v.lhs, t)
        }
    case Ternary:
        resolve_untyped(c, v.then_val, t)
        resolve_untyped(c, v.else_val, t)
    case Str_Lit, Char_Lit, Bool_Lit, Nil_Lit, Ident, Call, Index, Slice_Expr, Field, Array_Lit, Type_Value:
    }
}

// An untyped literal (or nil) can become `target`; anything else must match exactly.
coerce :: proc(c: ^Checker, e: ^Expr, target: ^Type, what: string) -> bool {
    from := e.type
    if is_invalid(from) || is_invalid(target) { return true } // already reported
    if types_equal(from, target) { return true }
    if is_untyped_int(from) && is_integer(target) { resolve_untyped(c, e, target); return true }
    if is_untyped_nil(from) && is_pointer(target) { e.type = target; return true }
    hint := ""
    if is_numeric(from) && is_numeric(target) {
        hint = fmt.aprintf("juju never converts implicitly; write %s(...)", type_name(target))
    }
    sem_err(c, e.span, fmt.aprintf("type mismatch in %s: expected '%s', found '%s'", what, type_name(target), type_name(from)), hint)
    return false
}

// Both operands must end up the same type; an untyped literal adopts the other side's.
unify :: proc(c: ^Checker, whole: ^Expr, a, b: ^Expr) -> ^Type {
    ta, tb := a.type, b.type
    if types_equal(ta, tb) { return ta }
    if is_untyped_int(ta) && is_integer(tb) { resolve_untyped(c, a, tb); return tb }
    if is_untyped_int(tb) && is_integer(ta) { resolve_untyped(c, b, ta); return ta }
    if is_untyped_nil(ta) && is_pointer(tb) { a.type = tb; return tb }
    if is_untyped_nil(tb) && is_pointer(ta) { b.type = ta; return ta }
    hint := ""
    if is_numeric(ta) && is_numeric(tb) { hint = fmt.aprintf("convert one side explicitly, e.g. %s(...)", type_name(ta)) }
    sem_err(c, whole.span, fmt.aprintf("mismatched types '%s' and '%s'", type_name(ta), type_name(tb)), hint)
    return ty_invalid
}

check_ident :: proc(c: ^Checker, e: ^Expr, v: Ident) -> ^Type {
    sym := lookup(c.scope, v.name)
    if sym == nil {
        report_undeclared(c, e.span, v.name)
        return ty_invalid
    }
    #partial switch sym.kind {
    case .Type:
        sem_err(c, e.span, fmt.aprintf("'%s' is a type, not a value", v.name),
            "to convert a value, call the type like a function: i32(x)")
        return ty_invalid
    case .Fn:
        sem_err(c, e.span, fmt.aprintf("'%s' is a function; call it with ()", v.name),
            "function pointers as values are TODO")
        return ty_invalid
    }
    if sym.type == nil {
        sem_err(c, e.span, fmt.aprintf("'%s' is used before its type is known", v.name),
            "declare globals before the globals that use them (dependency ordering is TODO)")
        return ty_invalid
    }
    e.sym = sym
    return sym.type
}

check_unary :: proc(c: ^Checker, e: ^Expr, v: Unary) -> ^Type {
    ot := check_expr(c, v.operand)
    if is_invalid(ot) { return ty_invalid }
    switch v.op {
    case .Neg:
        if !is_numeric(ot) { sem_err(c, e.span, fmt.aprintf("can't negate a '%s'", type_name(ot))); return ty_invalid }
        return ot
    case .Bit_Not:
        if !is_integer(ot) { sem_err(c, e.span, fmt.aprintf("'~' needs an integer, found '%s'", type_name(ot))); return ty_invalid }
        return ot
    case .Not:
        if !is_bool(ot) {
            sem_err(c, e.span, fmt.aprintf("'not' needs a bool, found '%s'", type_name(ot)), "write an explicit comparison, e.g. x == 0")
            return ty_invalid
        }
        return ty_bool
    case .Deref:
        if p, ok := ot.info.(Pointer_Type); ok { return p.elem }
        sem_err(c, e.span, fmt.aprintf("can't dereference a '%s' because it isn't a pointer", type_name(ot)))
        return ty_invalid
    case .Addr:
        if !is_addressable(c, v.operand) {
            sem_err(c, e.span, "can't take the address of this expression", "only variables, fields, elements and *p have an address")
            return ty_invalid
        }
        return new_type(Pointer_Type{elem = ot})
    }
    return ty_invalid
}

check_binary :: proc(c: ^Checker, e: ^Expr, v: Binary) -> ^Type {
    lt := check_expr(c, v.lhs)
    rt := check_expr(c, v.rhs)
    if is_invalid(lt) || is_invalid(rt) { return ty_invalid }

    switch v.op {
    case .And, .Or:
        if !is_bool(lt) || !is_bool(rt) {
            sem_err(c, e.span, fmt.aprintf("'%s' needs bool operands, found '%s' and '%s'",
                "and" if v.op == .And else "or", type_name(lt), type_name(rt)),
                "juju has no truthiness: compare explicitly, e.g. x != 0")
            return ty_invalid
        }
        return ty_bool
    case .Shl, .Shr:
        if !is_integer(lt) || !is_integer(rt) {
            sem_err(c, e.span, fmt.aprintf("shifts need integers, found '%s' and '%s'", type_name(lt), type_name(rt)))
            return ty_invalid
        }
        if is_untyped_int(rt) {
            resolve_untyped(c, v.rhs, lt)
            if lit, ok := v.rhs.variant.(Int_Lit); ok && int_bits(lt, c.sema.ptr_bits) > 0 && lit.value >= u64(int_bits(lt, c.sema.ptr_bits)) {
                sem_err(c, v.rhs.span, fmt.aprintf("shifting a '%s' by %d bits is out of range", type_name(lt), lit.value))
            }
        }
        return lt // the shift amount may have any integer type
    case .Eq, .Not_Eq:
        if is_invalid(unify(c, e, v.lhs, v.rhs)) { return ty_invalid }
        return ty_bool
    case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
        t := unify(c, e, v.lhs, v.rhs)
        if is_invalid(t) { return ty_invalid }
        if !is_numeric(t) { sem_err(c, e.span, fmt.aprintf("can't order values of type '%s'", type_name(t))); return ty_invalid }
        return ty_bool
    case .Add, .Sub, .Mul, .Div, .Floor_Div, .Mod:
        t := unify(c, e, v.lhs, v.rhs)
        if is_invalid(t) { return ty_invalid }
        if !is_numeric(t) { sem_err(c, e.span, fmt.aprintf("arithmetic needs numbers, found '%s'", type_name(t))); return ty_invalid }
        return t // TODO: pointer arithmetic is deliberately not allowed yet
    case .Bit_And, .Bit_Or, .Bit_Xor:
        t := unify(c, e, v.lhs, v.rhs)
        if is_invalid(t) { return ty_invalid }
        if !is_integer(t) { sem_err(c, e.span, fmt.aprintf("bitwise operators need integers, found '%s'", type_name(t))); return ty_invalid }
        return t
    }
    return ty_invalid
}

check_ternary :: proc(c: ^Checker, e: ^Expr, v: Ternary) -> ^Type {
    check_condition(c, v.cond)
    a := check_expr(c, v.then_val)
    b := check_expr(c, v.else_val)
    if is_invalid(a) || is_invalid(b) { return ty_invalid }
    return unify(c, e, v.then_val, v.else_val)
}

check_index :: proc(c: ^Checker, v: Index) -> ^Type {
    bt := check_expr(c, v.base)
    it := check_expr(c, v.index)
    if is_invalid(bt) || is_invalid(it) { return ty_invalid }
    if !is_integer(it) {
        sem_err(c, v.index.span, fmt.aprintf("an index must be an integer, found '%s'", type_name(it)))
        return ty_invalid
    }
    if is_untyped_int(it) { resolve_untyped(c, v.index, ty_usize) }
    #partial switch info in bt.info {
    case Array_Type:
        if lit, ok := v.index.variant.(Int_Lit); ok && lit.value >= info.len {
            sem_err(c, v.index.span, fmt.aprintf("index %d is out of bounds for '%s'", lit.value, type_name(bt)))
        }
        return info.elem
    case Slice_Type:
        return info.elem
    }
    sem_err(c, v.base.span, fmt.aprintf("can't index into a '%s'", type_name(bt)))
    return ty_invalid
}

check_slice :: proc(c: ^Checker, v: Slice_Expr) -> ^Type {
    bt := check_expr(c, v.base)
    if v.lo != nil { check_expr(c, v.lo, ty_usize); coerce(c, v.lo, ty_usize, "a slice bound") }
    if v.hi != nil { check_expr(c, v.hi, ty_usize); coerce(c, v.hi, ty_usize, "a slice bound") }
    if is_invalid(bt) { return ty_invalid }
    #partial switch info in bt.info {
    case Array_Type: return new_type(Slice_Type{elem = info.elem})
    case Slice_Type: return bt
    }
    sem_err(c, v.base.span, fmt.aprintf("can't slice a '%s'", type_name(bt)))
    return ty_invalid
}

check_field :: proc(c: ^Checker, v: Field) -> ^Type {
    // Mode.run: an enum member
    if id, ok := v.base.variant.(Ident); ok {
        if sym := lookup(c.scope, id.name); sym != nil && sym.kind == .Type {
            if en, is_enum := sym.type.info.(Enum_Type); is_enum {
                for m in en.members { if m == v.name { return sym.type } }
                sem_err(c, v.name_span, fmt.aprintf("enum '%s' has no member '%s'", en.name, v.name), suggest(en.members[:], v.name))
                return ty_invalid
            }
            sem_err(c, v.base.span, fmt.aprintf("'%s' is a type; only enums have members you can reach with '.'", id.name))
            return ty_invalid
        }
    }

    bt := check_expr(c, v.base)
    if is_invalid(bt) { return ty_invalid }
    t := bt
    if p, ok := bt.info.(Pointer_Type); ok { t = p.elem } // "." auto-dereferences pointers

    #partial switch info in t.info {
    case Struct_Type:
        names: [dynamic]string
        defer delete(names)
        for f in info.fields {
            if f.name == v.name { return f.type }
            append(&names, f.name)
        }
        sem_err(c, v.name_span, fmt.aprintf("struct '%s' has no field '%s'", info.name, v.name), suggest(names[:], v.name))
        return ty_invalid
    case Array_Type, Slice_Type:
        if v.name == "len" { return ty_usize }
    case Basic_Type:
        if info.kind == .Str && v.name == "len" { return ty_usize }
    }
    sem_err(c, v.name_span, fmt.aprintf("type '%s' has no field '%s'", type_name(t), v.name))
    return ty_invalid
}

check_array_lit :: proc(c: ^Checker, e: ^Expr, v: Array_Lit, expected: ^Type) -> ^Type {
    if expected != nil {
        if arr, ok := expected.info.(Array_Type); ok {
            for el in v.elems {
                check_expr(c, el, arr.elem)
                coerce(c, el, arr.elem, "an array element")
            }
            if u64(len(v.elems)) != arr.len {
                sem_err(c, e.span, fmt.aprintf("expected %d elements for '%s' but found %d", arr.len, type_name(expected), len(v.elems)))
            }
            return expected
        }
    }
    if len(v.elems) == 0 {
        sem_err(c, e.span, "can't infer the element type of an empty array literal", "give the variable a type: var xs: [4]i32")
        return ty_invalid
    }
    elem := check_expr(c, v.elems[0])
    if is_untyped_int(elem) { elem = ty_i32; resolve_untyped(c, v.elems[0], ty_i32) }
    for el in v.elems[1:] {
        check_expr(c, el, elem)
        coerce(c, el, elem, "an array element")
    }
    return new_type(Array_Type{elem = elem, len = u64(len(v.elems))})
}

// ===========================================================================
// Calls: functions, conversions, struct constructors, builtins, method sugar
// ===========================================================================

check_call :: proc(c: ^Checker, e: ^Expr, v: Call) -> ^Type {
    #partial switch callee in v.callee.variant {
    case Ident:
        switch callee.name {
        case "bitcast":            return check_bitcast(c, e, v)
        case "size_of", "align_of": return check_size_of(c, e, v, callee.name)
        case "offset_of":
            sem_err(c, e.span, "offset_of isn't implemented yet")
            return ty_invalid
        case "range":
            sem_err(c, e.span, "range() can only be used as the thing a for loop iterates over")
            return ty_invalid
        }
        sym := lookup(c.scope, callee.name)
        if sym == nil {
            report_undeclared(c, v.callee.span, callee.name)
            return ty_invalid
        }
        #partial switch sym.kind {
        case .Fn:   return check_fn_call(c, e, v, sym)
        case .Type: return check_type_call(c, e, v, sym)
        }
        sem_err(c, v.callee.span, fmt.aprintf("'%s' is not a function", callee.name))
        return ty_invalid
    case Field:
        return check_method_call(c, e, v, callee)
    }
    sem_err(c, e.span, "calling this kind of expression isn't supported yet", "function pointers are TODO")
    return ty_invalid
}

check_bitcast :: proc(c: ^Checker, e: ^Expr, v: Call) -> ^Type {
    if len(v.args) != 2 {
        sem_err(c, e.span, "bitcast takes 2 arguments: bitcast(Type, value)")
        return ty_invalid
    }
    tv, ok := v.args[0].value.variant.(Type_Value)
    if !ok { sem_err(c, v.args[0].value.span, "the first argument of bitcast must be a type"); return ty_invalid }
    target := resolve_type(c, tv.type)
    v.args[0].value.type = target
    check_expr(c, v.args[1].value)
    // TODO: both sides must have the same size (needs size_of for every type)
    return target
}

check_size_of :: proc(c: ^Checker, e: ^Expr, v: Call, name: string) -> ^Type {
    if len(v.args) != 1 {
        sem_err(c, e.span, fmt.aprintf("%s takes exactly 1 argument: %s(Type)", name, name))
        return ty_invalid
    }
    tv, ok := v.args[0].value.variant.(Type_Value)
    if !ok { sem_err(c, v.args[0].value.span, fmt.aprintf("the argument of %s must be a type", name)); return ty_invalid }
    v.args[0].value.type = resolve_type(c, tv.type)
    return ty_usize // TODO: computing the actual value needs layout rules per target
}

// i32(x), u8(x), Vec2(1, 2) ...
check_type_call :: proc(c: ^Checker, e: ^Expr, v: Call, sym: ^Symbol) -> ^Type {
    v.callee.sym = sym
    target := sym.type
    #partial switch info in target.info {
    case Struct_Type:
        return check_struct_ctor(c, e, v, target, info)
    case Basic_Type:
        if !is_numeric(target) {
            sem_err(c, e.span, fmt.aprintf("'%s' can't be used as a conversion", info.name))
            return ty_invalid
        }
        if len(v.args) != 1 {
            sem_err(c, e.span, fmt.aprintf("converting to '%s' takes exactly one argument", info.name))
            return ty_invalid
        }
        at := check_expr(c, v.args[0].value)
        if is_invalid(at) { return ty_invalid }
        convertible := is_numeric(at) || is_bool(at) || is_pointer(at) || (at.info != nil && is_enum(at))
        if !convertible {
            sem_err(c, v.args[0].value.span, fmt.aprintf("can't convert a '%s' to '%s'", type_name(at), info.name))
            return ty_invalid
        }
        if is_untyped_int(at) { resolve_untyped(c, v.args[0].value, target) }
        return target
    }
    sem_err(c, e.span, fmt.aprintf("can't call '%s' like a function", sym.name))
    return ty_invalid
}

is_enum :: proc(t: ^Type) -> bool {
    if t == nil { return false }
    _, ok := t.info.(Enum_Type)
    return ok
}

check_struct_ctor :: proc(c: ^Checker, e: ^Expr, v: Call, t: ^Type, st: Struct_Type) -> ^Type {
    if len(v.args) > len(st.fields) {
        sem_err(c, e.span, fmt.aprintf("'%s' has %d fields but %d values were given", st.name, len(st.fields), len(v.args)))
    }
    names: [dynamic]string
    defer delete(names)
    for f in st.fields { append(&names, f.name) }

    for arg, i in v.args {
        idx := i
        if arg.name != "" {
            idx = -1
            for f, j in st.fields { if f.name == arg.name { idx = j; break } }
            if idx < 0 {
                sem_err(c, arg.value.span, fmt.aprintf("struct '%s' has no field '%s'", st.name, arg.name), suggest(names[:], arg.name))
                check_expr(c, arg.value)
                continue
            }
        }
        if idx >= len(st.fields) { check_expr(c, arg.value); continue }
        ft := st.fields[idx].type
        check_expr(c, arg.value, ft)
        coerce(c, arg.value, ft, fmt.aprintf("field '%s'", st.fields[idx].name))
    }
    return t // fields you leave out are zero-initialized
}

check_fn_call :: proc(c: ^Checker, e: ^Expr, v: Call, sym: ^Symbol) -> ^Type {
    v.callee.sym = sym
    if sym.is_generic {
        sem_err(c, e.span, fmt.aprintf("'%s' is generic, and the checker can't instantiate generics yet", sym.name))
        for a in v.args { check_expr(c, a.value) }
        return ty_invalid
    }
    ft := sym.type.info.(Func_Type)
    n := len(ft.param_types)
    given := make([]bool, n)
    defer delete(given)

    names: [dynamic]string
    defer delete(names)
    for nm in ft.param_names { append(&names, nm) }

    pos := 0
    for arg in v.args {
        idx := -1
        if arg.name == "" {
            idx = pos
            pos += 1
            if idx >= n {
                sem_err(c, arg.value.span, fmt.aprintf("'%s' takes %d argument%s, but more were given", sym.name, n, "" if n == 1 else "s"))
                check_expr(c, arg.value)
                continue
            }
        } else {
            for nm, j in ft.param_names { if nm == arg.name { idx = j; break } }
            if idx < 0 {
                sem_err(c, arg.value.span, fmt.aprintf("'%s' has no parameter named '%s'", sym.name, arg.name), suggest(names[:], arg.name))
                check_expr(c, arg.value)
                continue
            }
        }
        if given[idx] {
            sem_err(c, arg.value.span, fmt.aprintf("argument '%s' was given twice", ft.param_names[idx]))
            continue
        }
        given[idx] = true
        check_expr(c, arg.value, ft.param_types[idx])
        coerce(c, arg.value, ft.param_types[idx], fmt.aprintf("argument '%s' of '%s'", ft.param_names[idx], sym.name))
    }
    for i in 0 ..< n {
        if !given[i] && !ft.has_default[i] {
            sem_err(c, e.span, fmt.aprintf("missing argument '%s' in the call to '%s'", ft.param_names[i], sym.name))
            break
        }
    }
    return ft.ret
}

// Method-call sugar:  x.f(args)  becomes  f(x, args)   (or f(&x, args) / f(*x, args))
// There's no dispatch: it's a pure rewrite, decided by the first parameter's type.
check_method_call :: proc(c: ^Checker, e: ^Expr, v: Call, f: Field) -> ^Type {
    bt := check_expr(c, f.base)
    if is_invalid(bt) { return ty_invalid }

    owner := bt
    if p, ok := bt.info.(Pointer_Type); ok { owner = p.elem }
    if st, ok := owner.info.(Struct_Type); ok {
        for fl in st.fields {
            if fl.name == f.name {
                sem_err(c, f.name_span, fmt.aprintf("'%s' is a field, and calling a function stored in a field isn't supported yet", f.name))
                return ty_invalid
            }
        }
    }

    sym := lookup(c.scope, f.name)
    if sym == nil || sym.kind != .Fn {
        names := visible_names(c, false)
        defer delete(names)
        sem_err(c, f.name_span, fmt.aprintf("no field or function '%s' for type '%s'", f.name, type_name(bt)), suggest(names[:], f.name))
        return ty_invalid
    }
    ft := sym.type.info.(Func_Type)
    if len(ft.param_types) == 0 {
        sem_err(c, f.name_span, fmt.aprintf("'%s' takes no parameters, so it can't be called as a method", f.name))
        return ty_invalid
    }

    p0 := ft.param_types[0]
    base := f.base
    switch {
    case is_invalid(p0) || types_equal(p0, bt):
        // passed as is
    case is_pointer_to(p0, bt):          // f(v: *T) called on a T: take its address
        if !is_addressable(c, base) {
            sem_err(c, base.span, fmt.aprintf("can't take the address of this expression to call '%s' as a method", f.name))
            return ty_invalid
        }
        addr := new(Expr)
        addr.span = base.span
        addr.variant = Unary{op = .Addr, operand = base}
        base = addr
    case is_pointer_to(bt, p0):          // f(v: T) called on a *T: dereference
        deref := new(Expr)
        deref.span = base.span
        deref.variant = Unary{op = .Deref, operand = base}
        base = deref
    case:
        sem_err(c, f.name_span, fmt.aprintf("can't call '%s' on a '%s': its first parameter is a '%s'",
            f.name, type_name(bt), type_name(p0)))
        return ty_invalid
    }

    args: [dynamic]Arg
    append(&args, Arg{value = base})
    for a in v.args { append(&args, a) }
    callee := new(Expr)
    callee.span = f.name_span
    callee.variant = Ident{name = f.name}
    callee.sym = sym
    rewritten := Call{callee = callee, args = args}
    e.variant = rewritten // the AST now says f(x, args): codegen never needs to know about the sugar
    return check_fn_call(c, e, rewritten, sym)
}
