module c3::parser::test @test;

import c3::parser;
import c3::lexer;
import std::io;

fn void trivia_is_split_from_code()
{
	String src = "module demo;\n// a comment\nfn void f() { }\n";
	TokenList toks;
	toks.init(mem);
	defer toks.free();
	toks.lex(src);

	assert(!toks.lex_failed, "clean source must lex");
	// The comment is in `all` but must not appear in `code`.
	assert(toks.all.len() > toks.code.len(), "trivia must be held back from code");
	foreach (i : toks.code) assert(!parser::is_trivia(toks.all[i].type), "code holds no trivia");

	// First code token is `module`, and spans survive into the code view.
	assert(toks.type_at(0) == MODULE, "first code token is 'module'");
	assert(toks.text_at(1) == "demo", "second code token is the module name");
	assert(toks.tok(0).ln == 1, "line numbers are preserved");
}

fn void contract_is_found_for_the_declaration_it_precedes()
{
	String src = "module demo;\n<* @param x : \"in\" *>\nfn void f(int x) { }\n";
	TokenList toks;
	toks.init(mem);
	defer toks.free();
	toks.lex(src);

	// Find the `fn` code token, then ask for its contract.
	uint fn_idx = parser::NO_TOKEN;
	for (uint i = 0; (sz)i < toks.len(); i++)
	{
		if (toks.type_at(i) == FUNC) { fn_idx = i; break; }
	}
	assert(fn_idx != parser::NO_TOKEN, "the 'fn' token must be found");

	uint c = toks.contract_before(fn_idx);
	assert(c != parser::NO_TOKEN, "fn must see its preceding contract");
	assert(toks.all[(sz)c].type == CONTRACT, "and it must be a CONTRACT token");

	// `module` has no contract of its own.
	assert(toks.contract_before(0) == parser::NO_TOKEN, "module has no contract");
}

fn void invalid_input_is_not_fatal()
{
	TokenList toks;
	toks.init(mem);
	defer toks.free();
	toks.lex("fn void f() { int x = 1; }\n");
	assert(toks.len() > 0, "tokens survive");
}

fn void ast_sentinel_and_children()
{
	Ast ast;
	ast.init(mem);
	defer ast.free();

	assert(ast.len() == 1, "a fresh arena holds only the NONE sentinel");
	assert(ast.kind(parser::NONE) == NONE_NODE, "index 0 is the sentinel");

	NodeId a = ast.add(IDENT, 0, 0, 0);
	NodeId b = ast.add(IDENT, 1, 1, 1);
	assert(a != parser::NONE && b != parser::NONE, "real nodes are never NONE");
	assert(ast.kind(a).is_expr(), "IDENT is an expression");
	assert(ast.kind(a).family == EXPR, "and its family says so");

	NodeId[<2>] range = ast.add_children({ a, b });
	NodeId blk = ast.add(BLOCK, 2, 0, 3, range[0], range[1]);
	NodeId[] kids = ast.children(blk);
	assert(kids.len == 2, "the block has two children");
	assert(kids[0] == a && kids[1] == b, "in order");

	// A non-list node yields an empty slice rather than garbage.
	assert(ast.children(a).len == 0, "leaf nodes have no children");
	assert(NodeKind.ERROR_STMT.is_error(), "error kinds are flagged");
	assert(!NodeKind.BLOCK.is_error(), "and ordinary kinds are not");
}
