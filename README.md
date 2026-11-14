# C3 Parser

A standalone parser for the [C3 programming language](https://c3-lang.org/).
It turns C3 source into a concrete, inspectable AST, built specifically for
tools that read code rather than compile it: linters, formatters, refactoring
tools. Implemented in pure C3, depending only on
[lexer.c3l](https://github.com/konimarti/lexer.c3l).

For most production tooling today — syntax highlighting, editor integration,
incremental re-parsing while typing — [tree-sitter-c3](https://github.com/c3lang/tree-sitter-c3)
is the mature, battle-tested choice; it already powers `c3-lsp` and C3 support
in Neovim and Emacs. This library fills a different gap: a dependency-free
parser for tools that are themselves written in C3 and want a real AST
without an FFI/C toolchain, checked directly against the compiler's own
grammar rather than a separately maintained one.

## Features

- **Resilient on purpose.** Parsing never fails. Malformed or half-typed input
  comes back as a tree with `ERROR_DECL`/`ERROR_STMT`/`ERROR_EXPR` nodes at
  valid positions, so a caller can still analyse whatever did parse — the
  point, since a tool built on this runs on code while it's being edited.

- **A flat arena, not a tree of pointers.** Every node lives in one
  contiguous array; a node's children are a slice into one shared array, not
  individually heap-allocated lists. Cache-friendly, and makes the whole tree
  one `Ast.free()` away from gone.

- **One generic visitor.** `parser::walk` depth-first visits every node,
  parents before children; a visitor returns `false` to stop descending into
  one subtree without affecting the rest of the walk.

- **Verified against the real compiler, not a second grammar spec.** The test
  suite parses the real C3 standard library and compiler test suite (a
  sibling `c3c` checkout) and checks for zero unexpected `ERROR_*` nodes on
  valid code, and that the parser never crashes on deliberately invalid code.

## Example

```c3
import c3::parser;

ParseResult r = parser::parse(mem, src);
defer r.free();
// r.ast, r.toks, r.errors -- never fails; malformed input yields ERROR_*
// nodes with valid spans, so it works on code that is being typed.

parser::walk(r.ast, r.ast.root, fn bool(ast, id, ctx) {
	// called once per node, parents before children
	return true; // false skips this node's children
}, null);
```

## Testing

```sh
c3l sync    # fetch lexer.c3l
c3c test
```

The conformance/resilience test suite looks for a sibling `c3c` checkout via
the `C3C_CHECKOUT` environment variable (default `/home/km/Documents/c3c`);
without one, those specific tests report it and skip rather than fail.

## History

Originally built inside [c3vet](https://github.com/konimarti/c3vet), a vet
tool for C3, and carved out into its own library once it had proven itself.
Before this, C3 had no reusable parser: `c3f` built its own bespoke token
model, and `c3c-fuzz` reached for tree-sitter, for lack of a native one.
c3vet was its first consumer, never its owner.

## License

MIT License [konimarti](https://github.com/konimarti)
