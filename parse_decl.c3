<*
 Declaration and top-level grammar.

 LANE 1C (claude). Phase 0 leaves a minimal stub: `module`, `import`, and a
 function declaration shaped just enough to reach a body. Everything else --
 macro/attrmacro/struct/union/bitstruct/enum/interface/typedef/alias/const/
 global/faultdef/attrdef/constset, parameter lists, attributes and generic
 parameters -- is lane 1C's work. See docs/WORKPLAN.md lane 1C.
*>
module c3::parser;

import c3::lexer;
import std::collections::list;

<* Parse one top-level declaration. *>
fn NodeId parse_decl(Parser* p)
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	switch (p.peek_type())
	{
		case MODULE:
			uint kw = p.advance();
			NodeId path = parse_module_path(p);
			p.expect(EOS, "expected ';'");
			return p.finish(MODULE, kw, first, path);
		case IMPORT:
			uint kw = p.advance();
			NodeId path = parse_module_path(p);
			p.expect(EOS, "expected ';'");
			return p.finish(IMPORT, kw, first, path);
		case FUNC:
			return parse_fn(p);
		default:
			p.error("expected a declaration");
			return p.sync_decl();
	}
}

<* A `foo::bar::baz` module path. *>
fn NodeId parse_module_path(Parser* p) @local
{
	uint first = p.pos;
	if (!p.at(IDENT))
	{
		p.error("expected a module name");
		return p.error_node(ERROR_EXPR, first);
	}
	uint name = p.advance();
	while (p.at(SCOPE))
	{
		p.advance();
		if (!p.match(IDENT))
		{
			p.error("expected a module name after '::'");
			break;
		}
	}
	return p.finish(PATH, name, first);
}

<*
 A function declaration, stubbed to `fn <type> <name> ( ... ) { ... }`.

 The signature is not yet modelled: lane 1C replaces this with a real
 SIGNATURE node carrying the return type and parameter list.
*>
fn NodeId parse_fn(Parser* p) @local
{
	uint first = p.pos;
	uint kw = p.advance();
	// Skip the return type and name without interpreting them; lane 1C
	// replaces this with parse_type plus a parameter list.
	while (!p.at_end() && !p.at(LPAREN) && !p.at(LBRACE) && !p.at(EOS)) p.advance();
	if (p.at(LPAREN))
	{
		int depth = 0;
		do
		{
			if (p.at(LPAREN)) depth++;
			if (p.at(RPAREN)) depth--;
			p.advance();
		} while (!p.at_end() && depth > 0);
	}
	// Attributes and contracts sit between the parameters and the body.
	while (!p.at_end() && !p.at(LBRACE) && !p.at(EOS) && !p.at(IMPLIES)) p.advance();

	NodeId body = NONE;
	if (p.at(LBRACE))
	{
		body = parse_block(p);
	}
	else
	{
		p.match(EOS);
	}
	return p.finish(FN_DECL, kw, first, NONE, body);
}
