# juju
an experimental compiled language made in odin

```python
# juju: Python syntax, C performance, zero garbage collection

const GP1 = bitcast(*volatile u32, usize(0x1F801814))  # Hardware register pointer

struct Vec2:
    x: i16
    y: i16

# Method-call sugar: v.move(5) rewrites to move(&v, 5)
fn move(v: *Vec2, dx: i16):
    v.x += dx  # Auto-dereferences pointers

fn length_sq(v: Vec2) -> i32:
    return i32(v.x) * i32(v.x) + i32(v.y) * i32(v.y)

@export("main")
fn main() -> i32:
    var v = Vec2(x=10, y=20)  # Keyword construction
    v.move(5)
    
    var frame: u32 = 0
    while frame < 60:
        frame += 1
        *GP1 = 0x03000000      # Volatile hardware write
        
    return 0

```

## feats:
python like syntax
static typed declarations
explicit memory management
a really good C FFI
asm blocks

## building and usage
just run `odin build src/ --out:juju` and you should be good to go.
right now, the language isnt done so all you can do is compile to an LLVM IR, with it missing a bunch of features already.

## whats the purpose of this?
before you say nim can do this already, ik. but ikiab, i feel like the nim syntax is more inline with pascal than python. especially with the naming scheme. so i had an idea to come up with a language that was basically nim, but with no memory management, snake naming scheme, and a direct compliation to binary rather than go thru C. i also wanted a really easy language people can come and pick up for homebrew and microcontroller programming and nim is lowk a lil too niche for it.

### real talk by the dev
1. im not gonna lie, i larped the fuck out of this. claude has generated the tokenizer, parser, checker, and code generator for this compiler. ofc since im broke and dont spend bands on the big C, it missed some things like **tuples, function pointers, returning tuples and a bunch more.** so for that, i will add myself.

2. like i said before, the idea for this language was to have a python that ran at native speeds on things like homebrew and/or microcontrollers (mainly homebrew for me). but since LLVM does NOT have proper MIPS-I support (PSX) and the main target i was looking at (SuperH/Dreamcast) just does NOT exist yet, the language does not fufill the purpose i intended it to do. hopefully in the meantime as these backends mature (like 2-6 years), i hope to have the language fully developed with a mostly platform dependent system library and actually implemented features.

3. despite my intentions with the language, nothing is really stopping me from having this as a desktop language. so as soon as the compiler, the c ffi, and a basic core lib is done, we'll start binding shi like sokol, miniaudio, gobject, portmidi, sdl2, etc.



