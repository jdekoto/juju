package juju

import "core:fmt"
import "core:os"

usage :: proc() {
    fmt.println("usage: juju <file.juju> [--target host|ps1|gba] [--ast] [-o out.ll]")
    os.exit(2)
}

main :: proc() {
    path, target, out_path := "", "host", ""
    show_ast := false
    args := os.args[1:]
    for i := 0; i < len(args); i += 1 {
        switch args[i] {
        case "--ast":    show_ast = true
        case "--target":
            i += 1
            if i >= len(args) { usage() }
            target = args[i]
        case "-o":
            i += 1
            if i >= len(args) { usage() }
            out_path = args[i]
        case: path = args[i]
        }
    }
    if path == "" { usage() }
    if target != "host" && target != "ps1" && target != "gba" {
        fmt.printf("unknown target '%s' (expected host, ps1 or gba)\n", target)
        os.exit(2)
    }

    data, read_err := os.read_entire_file_from_path(path, context.allocator)
    if read_err != nil {
        fmt.printf("cannot read '%s'\n", path)
        os.exit(2)
    }
    src := string(data)

    diags: [dynamic]Diagnostic
    module := parse_source(src, &diags)

    ir := ""
    if len(diags) == 0 {
        if show_ast { dump_module(module) }
        sema := check_module(module, &diags, target)
        if len(diags) == 0 { ir = generate(sema, &diags) } // only generate code for a program that checked cleanly
    }
    print_diagnostics(path, src, diags[:])
    if len(diags) > 0 { os.exit(1) }

    if out_path == "" {
        fmt.print(ir)
    } else {
        if werr := os.write_entire_file(out_path, ir); werr != nil {
            fmt.printf("cannot write '%s'\n", out_path)
            os.exit(2)
        }
        fmt.printf("wrote %s\n", out_path)
    }
}
