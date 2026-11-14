<*
 Type grammar.

 LANE 1C (claude). Phase 0 leaves a minimal stub: base types and named types
 with pointer suffixes. Arrays, slices, vectors, optionals, generics, function
 types and inferred types are lane 1C's work. See docs/WORKPLAN.md lane 1C.
*>
module c3::parser;

import c3::lexer;

<* True for the built-in base type keywords. *>
fn bool is_base_type(TokenType t)
{
	switch (t)
	{
		case VOID:
		case BOOL:
		case CHAR:
		case ICHAR:
		case SHORT:
		case USHORT:
		case INT:
		case UINT:
		case LONG:
		case ULONG:
		case INT128:
		case UINT128:
		case FLOAT:
		case DOUBLE:
		case FLOAT16:
		case BFLOAT:
		case FLOAT128:
		case IPTR:
		case UPTR:
		case ISZ:
		case USZ:
		case FAULT:
		case ANY:
		case TYPEID:
		case UNTYPEDLIST:
			return true;
		default:
			return false;
	}
}

<* Parse a type. *>
fn NodeId parse_type(Parser* p)
{
	if (!p.enter()) return p.error_node(ERROR_EXPR, p.pos);
	defer p.leave();

	uint first = p.pos;
	NodeKind kind;
	if (is_base_type(p.peek_type()))
	{
		kind = TYPE_BASE;
	}
	else if (p.at(TYPE_IDENT))
	{
		kind = TYPE_NAME;
	}
	else
	{
		p.error("expected a type");
		return p.error_node(ERROR_EXPR, p.pos);
	}
	uint name = p.advance();
	// Pointer suffixes.
	while (p.at(STAR)) p.advance();
	return p.finish(kind, name, first);
}
