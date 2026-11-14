<*
 Statement grammar.

 LANE 1B (codex). Phase 0 leaves a minimal stub: blocks, empty statements and
 expression statements. All 28 statement forms of grammar.y's `statement`
 production -- control flow, switch/case/nextcase, foreach, defer, assert,
 labels, $if/$switch/$for/$foreach and asm blocks -- are lane 1B's work.
 See docs/WORKPLAN.md lane 1B.
*>
module c3::parser;

import c3::lexer;
import std::collections::list;

<* Parse one statement. *>
fn NodeId parse_stmt(Parser* p)
{
	if (!p.enter()) return p.sync_stmt();
	defer p.leave();

	uint first = p.pos;
	switch (p.peek_type())
	{
		case LBRACE:
			return parse_block(p);
		case EOS:
			return p.finish(EMPTY_STMT, p.advance(), first);
		default:
			// An expression in statement position: `{` opens a block here,
			// not an initializer list.
			bool saved = p.no_init_list;
			p.no_init_list = true;
			NodeId e = parse_expr(p);
			p.no_init_list = saved;
			p.expect(EOS, "expected ';'");
			return p.finish(EXPR_STMT, first, first, e);
	}
}

<* Parse a `{ ... }` block. The cursor must be on the `{`. *>
fn NodeId parse_block(Parser* p)
{
	if (!p.enter()) return p.sync_stmt();
	defer p.leave();

	uint first = p.pos;
	uint brace = p.pos;
	if (!p.expect(LBRACE, "expected '{'")) return p.sync_stmt();

	List{NodeId} kids;
	kids.tinit();
	while (!p.at_end() && !p.at(RBRACE))
	{
		uint before = p.pos;
		kids.push(parse_stmt(p));
		if (p.pos == before) p.advance();
	}
	p.expect(RBRACE, "expected '}'");

	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(BLOCK, brace, first, range[0], range[1]);
}
