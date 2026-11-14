<*
 Expression grammar node shape assertions.

 LANE 1A tests per docs/WORKPLAN.md Phase 1 gate:
   - Precedence climbing (arithmetic, bitwise, relational, logical, ternary, assign)
   - Postfix chains (calls, subscripts, slices, member access, ++, --, !, !!)
   - Initializer lists (positional, designated, named, no_init_list)
   - Lambdas (short `=>` and block `{}`)
   - Try / Catch expressions
   - Casts, paths, literals and invariants
*>
module c3::parser::shape_expr;

import c3::parser;
import c3::parser::invariants;

fn ParseResult parse_snippet(String expr_str)
{
	String src = string::tformat("fn void test() { %s; }", expr_str);
	return parser::parse(mem, src);
}

fn NodeId get_expr(ParseResult* r)
{
	NodeId root = r.ast.root;
	NodeId[] decls = r.ast.children(root);
	assert(decls.len > 0, "decls non-empty");
	Node* fn_node = r.ast.node(decls[0]);
	NodeId block = fn_node.rhs;
	NodeId[] stmts = r.ast.children(block);
	assert(stmts.len > 0, "stmts non-empty");
	Node* s = r.ast.node(stmts[0]);
	assert(s.kind == EXPR_STMT, "stmt is EXPR_STMT");
	return s.lhs;
}

<* Test 1: Precedence climbing across arithmetic, bitwise, relational, logical, ternary and assignment. *>
fn void test_precedence() @test
{
	// 1. Multiplicative binds tighter than additive: `1 + 2 * 3` -> `1 + (2 * 3)`
	{
		ParseResult r = parse_snippet("1 + 2 * 3");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == BINARY, "top is BINARY (+)");
		Node* rhs = r.ast.node(n.rhs);
		assert(rhs.kind == BINARY, "rhs is BINARY (*)");
		Node* lhs = r.ast.node(n.lhs);
		assert(lhs.kind == INT_LIT, "lhs is INT_LIT (1)");
	}

	// 2. Bitwise binds tighter than additive in C3: `1 + 2 & 3` -> `1 + (2 & 3)`
	{
		ParseResult r = parse_snippet("1 + 2 & 3");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == BINARY, "top is BINARY (+)");
		Node* rhs = r.ast.node(n.rhs);
		assert(rhs.kind == BINARY, "rhs is BINARY (&)");
	}

	// 3. Additive binds tighter than relational: `a + b < c - d` -> `(a + b) < (c - d)`
	{
		ParseResult r = parse_snippet("a + b < c - d");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == BINARY, "top is BINARY (<)");
		assert(r.ast.node(n.lhs).kind == BINARY, "lhs is +");
		assert(r.ast.node(n.rhs).kind == BINARY, "rhs is -");
	}

	// 4. Relational binds tighter than AND, AND tighter than OR: `a < b && c > d || e == f`
	{
		ParseResult r = parse_snippet("a < b && c > d || e == f");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == BINARY, "top is BINARY (||)");
		Node* lhs = r.ast.node(n.lhs);
		assert(lhs.kind == BINARY, "lhs is BINARY (&&)");
		Node* rhs = r.ast.node(n.rhs);
		assert(rhs.kind == BINARY, "rhs is BINARY (==)");
	}

	// 5. Assignment is right-associative: `a = b = c` -> `a = (b = c)`
	{
		ParseResult r = parse_snippet("a = b = c");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == ASSIGN, "top is ASSIGN");
		Node* rhs = r.ast.node(n.rhs);
		assert(rhs.kind == ASSIGN, "rhs is ASSIGN");
		Node* lhs = r.ast.node(n.lhs);
		assert(lhs.kind == IDENT, "lhs is IDENT (a)");
	}

	// 6. Ternary, Elvis and Optelse
	{
		ParseResult r = parse_snippet("cond ? 10 : 20");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == TERNARY, "top is TERNARY");
		NodeId[] kids = r.ast.children(e);
		assert(kids.len == 3, "ternary has 3 children");
		assert(r.ast.node(kids[0]).kind == IDENT, "cond is IDENT");
		assert(r.ast.node(kids[1]).kind == INT_LIT, "then is INT_LIT (10)");
		assert(r.ast.node(kids[2]).kind == INT_LIT, "else is INT_LIT (20)");
	}
	{
		ParseResult r = parse_snippet("opt ?: fallback");
		defer r.free();
		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == ELVIS, "top is ELVIS");
		assert(r.ast.node(n.lhs).kind == IDENT, "lhs is IDENT");
		assert(r.ast.node(n.rhs).kind == IDENT, "rhs is IDENT");
	}
	{
		ParseResult r = parse_snippet("opt ?? fallback");
		defer r.free();
		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == OPTELSE, "top is OPTELSE");
		assert(r.ast.node(n.lhs).kind == IDENT, "lhs is IDENT");
		assert(r.ast.node(n.rhs).kind == IDENT, "rhs is IDENT");
	}
}

<* Test 2: Postfix chains (calls, subscripts, slices, member access, ++, --, !, !!). *>
fn void test_postfix_chains() @test
{
	// 1. Function call with multiple arguments: `foo(1, 2, 3)`
	{
		ParseResult r = parse_snippet("foo(1, 2, 3)");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == CALL, "top is CALL");
		NodeId[] kids = r.ast.children(e);
		assert(kids.len == 4, "callee + 3 args");
		assert(r.ast.node(kids[0]).kind == IDENT, "callee is foo");
		assert(r.ast.node(kids[1]).kind == INT_LIT, "arg 1 is 1");
		assert(r.ast.node(kids[2]).kind == INT_LIT, "arg 2 is 2");
		assert(r.ast.node(kids[3]).kind == INT_LIT, "arg 3 is 3");
	}

	// 2. Named arguments: `foo(x: 10, y: 20)`
	{
		ParseResult r = parse_snippet("foo(x: 10, y: 20)");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		assert(r.ast.node(e).kind == CALL, "top is CALL");
		NodeId[] kids = r.ast.children(e);
		assert(kids.len == 3, "callee + 2 args");
		Node* arg1 = r.ast.node(kids[1]);
		assert(arg1.kind == ARG, "arg 1 is ARG");
		assert(r.ast.node(arg1.lhs).kind == IDENT, "arg 1 name is x");
		assert(r.ast.node(arg1.rhs).kind == INT_LIT, "arg 1 val is 10");
	}

	// 3. Subscript vs Slice: `a[0]` vs `a[1..5]` vs `a[..]`
	{
		ParseResult r = parse_snippet("a[0]");
		defer r.free();
		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == SUBSCRIPT, "top is SUBSCRIPT");
		assert(r.ast.node(n.lhs).kind == IDENT, "object is a");
		assert(r.ast.node(n.rhs).kind == INT_LIT, "index is 0");
	}
	{
		ParseResult r = parse_snippet("a[1..5]");
		defer r.free();
		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == SLICE, "top is SLICE");
		NodeId[] kids = r.ast.children(e);
		assert(kids.len == 3, "SLICE has 3 kids");
		assert(r.ast.node(kids[0]).kind == IDENT, "object is a");
		assert(r.ast.node(kids[1]).kind == INT_LIT, "low is 1");
		assert(r.ast.node(kids[2]).kind == INT_LIT, "high is 5");
	}
	{
		ParseResult r = parse_snippet("a[..]");
		defer r.free();
		NodeId e = get_expr(&r);
		assert(r.ast.node(e).kind == SLICE, "top is SLICE");
		NodeId[] kids = r.ast.children(e);
		assert(kids[1] == parser::NONE, "low is NONE");
		assert(kids[2] == parser::NONE, "high is NONE");
	}

	// 4. Member access chain: `a.b.c`
	{
		ParseResult r = parse_snippet("a.b.c");
		defer r.free();
		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == MEMBER_ACCESS, "top is MEMBER_ACCESS (.c)");
		Node* lhs = r.ast.node(n.lhs);
		assert(lhs.kind == MEMBER_ACCESS, "lhs is MEMBER_ACCESS (.b)");
		assert(r.ast.node(lhs.lhs).kind == IDENT, "base is a");
	}

	// 5. Postfix ++, --, !, !!
	{
		ParseResult r = parse_snippet("x++");
		defer r.free();
		NodeId e = get_expr(&r);
		assert(r.ast.node(e).kind == POSTFIX, "top is POSTFIX");
	}
	{
		ParseResult r = parse_snippet("x--");
		defer r.free();
		NodeId e = get_expr(&r);
		assert(r.ast.node(e).kind == POSTFIX, "top is POSTFIX");
	}
	{
		ParseResult r = parse_snippet("call()!");
		defer r.free();
		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == RETHROW, "top is RETHROW");
		assert(r.ast.node(n.lhs).kind == CALL, "operand is CALL");
	}
	{
		ParseResult r = parse_snippet("opt!!");
		defer r.free();
		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == FORCE_UNWRAP, "top is FORCE_UNWRAP");
		assert(r.ast.node(n.lhs).kind == IDENT, "operand is IDENT");
	}
}

<* Test 3: Initializer lists (positional, designated, named, no_init_list). *>
fn void test_initializer_lists() @test
{
	// 1. Positional list: `{ 1, 2, 3 }`
	{
		ParseResult r = parse_snippet("x = { 1, 2, 3 }");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == ASSIGN, "top is ASSIGN");
		Node* rhs = r.ast.node(n.rhs);
		assert(rhs.kind == INIT_LIST, "rhs is INIT_LIST");
		NodeId[] elems = r.ast.children(n.rhs);
		assert(elems.len == 3, "3 elements");
		assert(r.ast.node(elems[0]).kind == INT_LIT, "elem 0 is 1");
		assert(r.ast.node(elems[1]).kind == INT_LIT, "elem 1 is 2");
		assert(r.ast.node(elems[2]).kind == INT_LIT, "elem 2 is 3");
	}

	// 2. Designated initializer list: `{ .x = 1, .y = 2 }`
	{
		ParseResult r = parse_snippet("p = { .x = 1, .y = 2 }");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* rhs = r.ast.node(r.ast.node(e).rhs);
		assert(rhs.kind == INIT_LIST, "rhs is INIT_LIST");
		NodeId[] elems = r.ast.children(r.ast.node(e).rhs);
		assert(elems.len == 2, "2 elements");
		Node* e0 = r.ast.node(elems[0]);
		assert(e0.kind == ASSIGN, "elem 0 is ASSIGN");
		assert(r.ast.node(e0.lhs).kind == IDENT, "target is x");
		assert(r.ast.node(e0.rhs).kind == INT_LIT, "val is 1");
	}

	// 3. no_init_list flag: a bare '{' at statement start is a block, not an expression.
	{
		ParseResult r = parser::parse(mem, "fn void test() { { 1; } }");
		defer r.free();
		assert(!r.has_errors(), "parses cleanly without error");
		NodeId root = r.ast.root;
		NodeId fn_decl = r.ast.children(root)[0];
		NodeId outer_block = r.ast.node(fn_decl).rhs;
		NodeId inner_stmt = r.ast.children(outer_block)[0];
		assert(r.ast.node(inner_stmt).kind == BLOCK, "inner '{ ... }' parsed as BLOCK statement");
	}
}

<* Test 4: Lambdas (short `=>` and block `{}`). *>
fn void test_lambdas() @test
{
	// 1. Short lambda: `fn (int x) => x + 1`
	{
		ParseResult r = parse_snippet("f = fn (int x) => x + 1");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* rhs = r.ast.node(r.ast.node(e).rhs);
		assert(rhs.kind == LAMBDA, "rhs is LAMBDA");
		NodeId[] kids = r.ast.children(r.ast.node(e).rhs);
		assert(kids.len == 2, "LAMBDA has 2 children (SIGNATURE, body)");
		Node* sig = r.ast.node(kids[0]);
		assert(sig.kind == SIGNATURE, "child 0 is SIGNATURE");
		NodeId[] params = r.ast.children(kids[0]);
		assert(params.len == 2, "ret_type + 1 param");
		assert(r.ast.node(params[1]).kind == PARAM, "param is PARAM");
		Node* body = r.ast.node(kids[1]);
		assert(body.kind == BINARY, "body is BINARY (+)");
	}

	// 2. Lambda with block: `fn int(int x) { return x; }`
	{
		ParseResult r = parse_snippet("f = fn int(int x) { return x; }");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* rhs = r.ast.node(r.ast.node(e).rhs);
		assert(rhs.kind == LAMBDA, "rhs is LAMBDA");
		NodeId[] kids = r.ast.children(r.ast.node(e).rhs);
		Node* body = r.ast.node(kids[1]);
		assert(body.kind == BLOCK, "body is BLOCK");
	}

	// 3. Lambda without explicit parameter types: `fn (x, y) => x * y`
	{
		ParseResult r = parse_snippet("f = fn (x, y) => x * y");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* rhs = r.ast.node(r.ast.node(e).rhs);
		assert(rhs.kind == LAMBDA, "rhs is LAMBDA");
		NodeId[] kids = r.ast.children(r.ast.node(e).rhs);
		NodeId[] params = r.ast.children(kids[0]);
		assert(params.len == 3, "ret_type + 2 params");
		assert(r.ast.node(params[1]).kind == PARAM, "param 1 is PARAM");
		assert(r.ast.node(params[2]).kind == PARAM, "param 2 is PARAM");
	}
}

<* Test 5: Try / Catch expressions. *>
fn void test_try_catch() @test
{
	// 1. `try foo()`
	{
		ParseResult r = parse_snippet("try foo()");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == TRY_EXPR, "top is TRY_EXPR");
		assert(r.ast.node(n.lhs).kind == CALL, "operand is CALL");
	}

	// 2. `catch err = foo()`
	{
		ParseResult r = parse_snippet("catch err = foo()");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == CATCH_EXPR, "top is CATCH_EXPR");
		Node* operand = r.ast.node(n.lhs);
		assert(operand.kind == ASSIGN, "operand is ASSIGN");
		assert(r.ast.node(operand.lhs).kind == IDENT, "target is err");
		assert(r.ast.node(operand.rhs).kind == CALL, "val is CALL");
	}

	// 3. `catch foo()`
	{
		ParseResult r = parse_snippet("catch foo()");
		defer r.free();
		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == CATCH_EXPR, "top is CATCH_EXPR");
		assert(r.ast.node(n.lhs).kind == CALL, "operand is CALL");
	}
}

<* Test 6: Casts, paths and literals. *>
fn void test_casts_paths_literals() @test
{
	// 1. Explicit cast: `(int)5`
	{
		ParseResult r = parse_snippet("(int)5");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == CAST, "top is CAST");
		assert(r.ast.node(n.lhs).kind == TYPE_BASE, "type is int");
		assert(r.ast.node(n.rhs).kind == INT_LIT, "operand is 5");
	}

	// 2. Struct cast initializer: `(Point){ 1, 2 }`
	{
		ParseResult r = parse_snippet("(Point){ 1, 2 }");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		Node* n = r.ast.node(e);
		assert(n.kind == CAST, "top is CAST");
		assert(r.ast.node(n.lhs).kind == TYPE_NAME, "type is Point");
		assert(r.ast.node(n.rhs).kind == INIT_LIST, "operand is INIT_LIST");
	}

	// 3. Path expressions: `std::io::printfn` (a module path) vs
	// `int::max` (a type-property access -- MEMBER_ACCESS with the type
	// as the object, not PATH; a bare type is never a module path).
	{
		ParseResult r = parse_snippet("std::io::printfn");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		assert(r.ast.node(e).kind == PATH, "top is PATH");
	}
	{
		ParseResult r = parse_snippet("int::max");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		assert(r.ast.node(e).kind == MEMBER_ACCESS, "top is MEMBER_ACCESS");
	}

	// 4. Literals: string concatenation, bytes, bool, null
	{
		ParseResult r = parse_snippet("\"hello \" \"world\"");
		defer r.free();
		Report rep = invariants::check(&r);
		assert(rep.spans_nest && rep.edges_valid, "invariants hold: %s", rep.detail);

		NodeId e = get_expr(&r);
		assert(r.ast.node(e).kind == STRING_LIT, "concatenated string is STRING_LIT");
	}
}
