package juju

// A source range: (offset, length) in bytes plus line/col of the start.
Span :: struct {
    offset: int,
    length: int,
    line:   int,
    col:    int,
}

// ---------------------------------------------------------------------------
// Types as written in source (the checker turns these into real `Type`s)
// ---------------------------------------------------------------------------

Type_Expr :: struct {
    span:    Span,
    variant: Type_Variant,
}

Type_Variant :: union { 
	Type_Name, Type_Ptr, Type_Slice, Type_Array,
	Type_Tuple, Type_Fn,
}

Type_Name  :: struct { module: string, name: string }          // i32, Vec2, mem.Arena
Type_Ptr   :: struct { volatile: bool, elem: ^Type_Expr }      // *T, *volatile T
Type_Slice :: struct { elem: ^Type_Expr }                      // []T
Type_Array :: struct { len: ^Expr, elem: ^Type_Expr }          // [N]T
Type_Tuple :: struct { elems: [dynamic]^Type_Expr }
Type_Fn    :: struct { params: [dynamic]^Type_Expr, ret: ^Type_Expr }

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

Expr :: struct {
    span:    Span,
    variant: Expr_Variant,
    type:    ^Type,   // filled in by the checker
    sym:     ^Symbol, // for identifiers (and call callees): what they refer to
}

Expr_Variant :: union {
    Int_Lit, Str_Lit, Char_Lit, Bool_Lit, Nil_Lit, Ident,
    Unary, Binary, Ternary,
    Call, Index, Slice_Expr, Field, Array_Lit,
    Type_Value,
}

Int_Lit  :: struct { value: u64, text: string }
Str_Lit  :: struct { text: string, is_c: bool } // text keeps quotes + raw escapes
Char_Lit :: struct { value: u8 }
Bool_Lit :: struct { value: bool }
Nil_Lit  :: struct {}
Ident    :: struct { name: string }

Unary_Op :: enum { Neg, Bit_Not, Not, Deref, Addr }
Unary    :: struct { op: Unary_Op, operand: ^Expr }

Binary_Op :: enum {
    Add, Sub, Mul, Div, Floor_Div, Mod,
    Bit_And, Bit_Or, Bit_Xor, Shl, Shr,
    Eq, Not_Eq, Lt, Lt_Eq, Gt, Gt_Eq,
    And, Or,
}
Binary :: struct { op: Binary_Op, lhs, rhs: ^Expr }

Ternary :: struct { cond, then_val, else_val: ^Expr } // a if cond else b

Arg  :: struct { name: string, value: ^Expr }          // name == "" when positional
Call :: struct { callee: ^Expr, args: [dynamic]Arg }

Index      :: struct { base, index: ^Expr }            // a[i]
Slice_Expr :: struct { base, lo, hi: ^Expr }           // a[lo:hi], either end may be nil
Field      :: struct { base: ^Expr, name: string, name_span: Span } // a.b
Array_Lit  :: struct { elems: [dynamic]^Expr }         // [1, 2, 3]

// A type in expression position: the first argument of bitcast(T, x), size_of(T), ...
Type_Value :: struct { type: ^Type_Expr }

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

Stmt :: struct {
    span:    Span,
    variant: Stmt_Variant,
}

Stmt_Variant :: union {
    Var_Decl, Assign, Expr_Stmt,
    If_Stmt, While_Stmt, For_Stmt, // TODO: add from, import, when, elif, and else
    Return_Stmt, Break_Stmt, Continue_Stmt, Pass_Stmt, Defer_Stmt,
}

Binding :: enum { Const, Let, Var }

// Also used for top-level const/let/var.
Var_Decl :: struct {
    binding:   Binding,
    name:      string,
    name_span: Span,
    type:      ^Type_Expr, // may be nil (inferred)
    value:     ^Expr,      // may be nil (zero-initialized)
}

Assign_Op :: enum { Set, Add, Sub, Mul, Div, Floor_Div, Mod, Bit_And, Bit_Or, Bit_Xor, Shl, Shr }
Assign    :: struct { op: Assign_Op, target, value: ^Expr }

Expr_Stmt :: struct { expr: ^Expr }

If_Branch :: struct { cond: ^Expr, body: [dynamic]^Stmt }
If_Stmt   :: struct { branches: [dynamic]If_Branch, else_body: [dynamic]^Stmt }

While_Stmt :: struct { cond: ^Expr, body: [dynamic]^Stmt }

// for item in xs / for i, item in xs / for &item in xs
For_Stmt :: struct {
    index_name: string, // "" if absent
    item_name:  string,
    index_span: Span,
    item_span:  Span,
    by_ref:     bool,
    iterable:   ^Expr,
    body:       [dynamic]^Stmt,
}



Return_Stmt   :: struct { value: ^Expr }
Break_Stmt    :: struct {}
Continue_Stmt :: struct {}
Pass_Stmt     :: struct {}
Defer_Stmt    :: struct { body: ^Stmt }
Match_Branch  :: struct { pat: ^Expr, body: [dynamic]^Stmt } 
Match_Stmt 	  :: struct { target: ^Expr, branches: [dynamic]Match_Branch }

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

Attribute :: struct {
    span: Span,
    name: string,
    args: [dynamic]^Expr,
}

Decl :: struct {
    span:    Span,
    attrs:   [dynamic]Attribute,
    variant: Decl_Variant,
}

Decl_Variant :: union { 
	Fn_Decl, Var_Decl, Struct_Decl, Enum_Decl,
	Import_Decl, From_Import_Decl, When_Decl, Foreign_Decl, Union_Decl,
}

Param :: struct {
    name:      string,
    name_span: Span,
    type:      ^Type_Expr,
    default:   ^Expr,
}

Fn_Decl :: struct {
    name:      string,
    name_span: Span,
    generic_params: [dynamic]string,
    params:    [dynamic]Param,
    ret:       ^Type_Expr, // nil = returns nothing
    body:      [dynamic]^Stmt,
}

Field_Decl  :: struct { name: string, name_span: Span, type: ^Type_Expr }
Struct_Decl :: struct { name: string, name_span: Span, fields: [dynamic]Field_Decl }

Enum_Member :: struct { name: string, name_span: Span, value: ^Expr }
Enum_Decl   :: struct { name: string, name_span: Span, base: ^Type_Expr, members: [dynamic]Enum_Member }

Import_Decl :: struct { 
	path: string, 
	alias: string
}

From_Import_Decl :: struct { 
	module: string, 
	names: [dynamic]string 
}

When_Decl_Branch :: struct {
    cond:  ^Expr,
    decls: [dynamic]^Decl,
}

When_Decl :: struct {
    branches:   [dynamic]When_Decl_Branch,
    else_decls: [dynamic]^Decl,
}

Foreign_Decl :: struct { 
	abi: string, 
	decls: [dynamic]^Decl 
}

Union_Decl :: struct { 
	name: string, 
	name_span: Span, 
	fields:[dynamic]Field_Decl
}

Module :: struct {
    decls: [dynamic]^Decl,
}
