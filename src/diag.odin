package juju

import "core:fmt"

Diagnostic :: struct {
    span: Span,
    msg:  string,
    hint: string, // optional "help:" line
}

report :: proc(diags: ^[dynamic]Diagnostic, span: Span, msg: string, hint := "") {
    append(diags, Diagnostic{span = span, msg = msg, hint = hint})
}

// Start and end byte offsets of the line containing `offset` (end excludes the newline).
line_bounds :: proc(src: string, offset: int) -> (start, end: int) {
    off := min(offset, len(src))
    start = off
    for start > 0 && src[start - 1] != '\n' && src[start - 1] != '\r' { start -= 1 }
    end = off
    for end < len(src) && src[end] != '\n' && src[end] != '\r' { end += 1 }
    return
}
// TODO: handle warnings
// clang-style output:
//   file:line:col: error: message
//       the source line
//             ^~~~
//       help: optional hint
// allat gibberish shi u see is the ansi escape code for the color and bolding
print_diagnostics :: proc(filename, src: string, diags: []Diagnostic) {
    for d in diags {
        fmt.printf("\x1b[1m%s:%d:%d: \x1b[91merror:\033[0m %s\n\x1b[0m", filename, d.span.line, d.span.col, d.msg)
        start, end := line_bounds(src, d.span.offset)
        fmt.printf("%s\n", src[start:end])
        for _ in 0 ..< d.span.offset - start { fmt.print(" ") }
        fmt.print("\x1b[31m^\x1b[0m")
        for _ in 1 ..< d.span.length { fmt.print("\x1b[31m~\x1b[0m") }
        fmt.println()
        if d.hint != "" { fmt.printf("  \x1b[1;33mhelp:\033[0m %s\n", d.hint) }
    }
    if len(diags) > 0 {
        fmt.printf("\x1b[1;91m%d error%s\n", len(diags), "" if len(diags) == 1 else "s\x1b[0m")
    }
}
