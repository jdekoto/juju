package juju

import "core:fmt"
import "core:strings"

type_expr_str :: proc(t: ^Type_Expr) -> string {
    if t == nil { return "_" }
    switch v in t.variant {
    case Type_Name:
        if v.module != "" { return fmt.aprintf("%s.%s", v.module, v.name) }
        return v.name
    case Type_Ptr:
        return fmt.aprintf("*%s%s", "volatile " if v.volatile else "", type_expr_str(v.elem))
    case Type_Slice: return fmt.aprintf("[]%s", type_expr_str(v.elem))
    case Type_Array: return fmt.aprintf("[%s]%s", expr_str(v.len), type_expr_str(v.elem))
    case Type_Tuple: fmt.println("tuple filler\n")
    case Type_Fn: fmt.println("func pointer filler\n")
    }
    return "?"
}

expr_str :: proc(e: ^Expr) -> string {
    if e == nil { return "_" }
    switch v in e.variant {
    case Int_Lit:  return fmt.aprintf("%d", v.value)
    case Str_Lit:  return fmt.aprintf("%s%s", "c" if v.is_c else "", v.text)
    case Char_Lit: return fmt.aprintf("'%c'", rune(v.value))
    case Bool_Lit: return "true" if v.value else "false"
    case Nil_Lit:  return "nil"
    case Ident:    return v.name
    case Unary:    return fmt.aprintf("(%v %s)", v.op, expr_str(v.operand))
    case Binary:   return fmt.aprintf("(%v %s %s)", v.op, expr_str(v.lhs), expr_str(v.rhs))
    case Ternary:  return fmt.aprintf("(if %s %s %s)", expr_str(v.cond), expr_str(v.then_val), expr_str(v.else_val))
    case Call:
        sb := strings.builder_make()
        fmt.sbprintf(&sb, "(call %s", expr_str(v.callee))
        for a in v.args {
            if a.name != "" { fmt.sbprintf(&sb, " %s=%s", a.name, expr_str(a.value)) } else { fmt.sbprintf(&sb, " %s", expr_str(a.value)) }
        }
        strings.write_string(&sb, ")")
        return strings.to_string(sb)
    case Index:      return fmt.aprintf("(index %s %s)", expr_str(v.base), expr_str(v.index))
    case Slice_Expr: return fmt.aprintf("(slice %s %s %s)", expr_str(v.base), expr_str(v.lo), expr_str(v.hi))
    case Field:      return fmt.aprintf("(field %s %s)", expr_str(v.base), v.name)
    case Array_Lit:
        sb := strings.builder_make()
        strings.write_string(&sb, "[")
        for el, i in v.elems {
            if i > 0 { strings.write_string(&sb, " ") }
            strings.write_string(&sb, expr_str(el))
        }
        strings.write_string(&sb, "]")
        return strings.to_string(sb)
    case Type_Value: return fmt.aprintf("type(%s)", type_expr_str(v.type))
    }
    return "?"
}

dump_stmts :: proc(body: [dynamic]^Stmt, ind: int) {
    for s in body { dump_stmt(s, ind) }
}

dump_stmt :: proc(s: ^Stmt, ind: int) {
    pad := strings.repeat("  ", ind)
    switch v in s.variant {
    case Var_Decl:
        fmt.printf("%s%v %s", pad, v.binding, v.name)
        if v.type != nil  { fmt.printf(": %s", type_expr_str(v.type)) }
        if v.value != nil { fmt.printf(" = %s", expr_str(v.value)) }
        fmt.println()
    case Assign:
        fmt.printf("%s%v-assign %s %s\n", pad, v.op, expr_str(v.target), expr_str(v.value))
    case Expr_Stmt:
        fmt.printf("%s%s\n", pad, expr_str(v.expr))
    case If_Stmt:
        for b, i in v.branches {
            fmt.printf("%s%s %s\n", pad, "if" if i == 0 else "elif", expr_str(b.cond))
            dump_stmts(b.body, ind + 1)
        }
        if len(v.else_body) > 0 {
            fmt.printf("%selse\n", pad)
            dump_stmts(v.else_body, ind + 1)
        }
    case While_Stmt:
        fmt.printf("%swhile %s\n", pad, expr_str(v.cond))
        dump_stmts(v.body, ind + 1)
    case For_Stmt:
        fmt.printf("%sfor %s%s%s in %s\n", pad,
            fmt.aprintf("%s, ", v.index_name) if v.index_name != "" else "",
            "&" if v.by_ref else "", v.item_name, expr_str(v.iterable))
        dump_stmts(v.body, ind + 1)
    case Return_Stmt:   fmt.printf("%sreturn %s\n", pad, expr_str(v.value) if v.value != nil else "")
    case Break_Stmt:    fmt.printf("%sbreak\n", pad)
    case Continue_Stmt: fmt.printf("%scontinue\n", pad)
    case Pass_Stmt:     fmt.printf("%spass\n", pad)
    case Defer_Stmt:
        fmt.printf("%sdefer\n", pad)
        dump_stmt(v.body, ind + 1)
    }
}

dump_module :: proc(m: Module) {
    for d in m.decls {
        for a in d.attrs {
            fmt.printf("@%s", a.name)
            if len(a.args) > 0 {
                fmt.print("(")
                for arg, i in a.args {
                    if i > 0 { fmt.print(", ") }
                    fmt.print(expr_str(arg))
                }
                fmt.print(")")
            }
            fmt.println()
        }
        switch v in d.variant {
        case Fn_Decl:
            fmt.printf("fn %s(", v.name)
            for p, i in v.params {
                if i > 0 { fmt.print(", ") }
                fmt.printf("%s: %s", p.name, type_expr_str(p.type))
                if p.default != nil { fmt.printf(" = %s", expr_str(p.default)) }
            }
            fmt.printf(")")
            if v.ret != nil { fmt.printf(" -> %s", type_expr_str(v.ret)) }
            fmt.println()
            dump_stmts(v.body, 1)
        case Var_Decl:
            dump_stmt(&Stmt{variant = v}, 0)
        case Struct_Decl:
            fmt.printf("struct %s\n", v.name)
            for f in v.fields { fmt.printf("  %s: %s\n", f.name, type_expr_str(f.type)) }
        case Enum_Decl:
            fmt.printf("enum %s: %s\n", v.name, type_expr_str(v.base))
            for mem in v.members {
                if mem.value != nil { fmt.printf("  %s = %s\n", mem.name, expr_str(mem.value)) } else { fmt.printf("  %s\n", mem.name) }
            }
        case Import_Decl:
        		fmt.printf("import %s as %s\n", v.path, v.alias)
        case From_Import_Decl:
        		fmt.printf("from %s import %s as %s\n", v.module, v.names)
        	case When_Decl:
        		fmt.printf("when_decl filler\n")
        	case Foreign_Decl:
        		fmt.printf("foriegn_decl filler\n")
        	case Union_Decl:
        		fmt.printf("union_decl filler\n")
        }
    }
}
