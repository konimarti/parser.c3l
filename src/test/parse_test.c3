module c3::parser::parse_test @test;

import c3::parser;
import c3::parser::invariants;
import std::io;

const String SRC = `
module demo;
import std::io;

fn void main()
{
	foo;
	{
		bar;
	}
}
`;

fn void parses_without_error()
{
	ParseResult r = parser::parse(mem, SRC);
	defer r.free();
	assert(!r.lex_failed, "clean source lexes");
	assert(r.ast.root != parser::NONE, "a root is produced");
	assert(r.ast.len() > 1, "nodes beyond the sentinel exist");
}

fn void spans_and_edges_hold()
{
	ParseResult r = parser::parse(mem, SRC);
	defer r.free();
	Report rep = invariants::check(&r);
	assert(rep.edges_valid, "invariant 2, edge validity: %s", rep.detail);
	assert(rep.spans_nest, "invariant 1, span nesting: %s", rep.detail);
}

<*
 Invariant 3 must PASS on input the parser handles completely.

 This is half of the discriminating pair. If it ever fails, the invariant has
 been phrased as something no parser can satisfy -- which is exactly what the
 first formulation (every token inside a leaf span) did, because structural
 tokens like braces live on interior nodes by design.
*>
fn void content_invariant_passes_on_fully_parsed_input()
{
	ParseResult r = parser::parse(mem, "module demo;");
	defer r.free();
	Report rep = invariants::check(&r);
	assert(rep.content_represented,
		"a fully parsed file must satisfy invariant 3: %s", rep.detail);
}

fn void malformed_input_still_returns_a_tree()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { @@@ ; }");
	defer r.free();
	assert(r.has_errors(), "garbage is reported");
	assert(r.ast.root != parser::NONE, "but a tree is still returned");
	Report rep = invariants::check(&r);
	assert(rep.edges_valid, "edges stay valid on malformed input: %s", rep.detail);
	assert(rep.spans_nest, "spans stay valid on malformed input: %s", rep.detail);
}

fn void unterminated_input_does_not_hang()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { ");
	defer r.free();
	assert(r.ast.root != parser::NONE, "truncated input still yields a tree");
}
