<*
 Expression grammar.

 LANE 1A (agy). Phase 0 leaves a minimal stub here: identifiers, literals and
 parenthesised expressions only. The full precedence chain, postfix/call/
 member/subscript/slice, initializer lists, lambdas, the try/catch operand
 grammar and the $-expressions are lane 1A's work. See docs/DESIGN.md
 section 3 and docs/WORKPLAN.md lane 1A.
*>
module c3::parser;

import c3::lexer;

<*
 Parse an expression binding at least as tightly as `min`.
 @param min : "the loosest precedence this call may consume"
*>
fn NodeId parse_expr(Parser* p, Prec min = Prec.LOWEST)
{
	if (!p.enter()) return p.sync_stmt();
	defer p.leave();

	uint first = p.pos;
	switch (p.peek_type())
	{
		case IDENT:
		case CONST_IDENT:
		case TYPE_IDENT:
			return p.finish(IDENT, p.advance(), first);
		case INTEGER:
			return p.finish(INT_LIT, p.advance(), first);
		case REAL:
			return p.finish(REAL_LIT, p.advance(), first);
		case STRING:
			return p.finish(STRING_LIT, p.advance(), first);
		case CHAR_LITERAL:
			return p.finish(CHAR_LIT, p.advance(), first);
		case TRUE:
		case FALSE:
			return p.finish(BOOL_LIT, p.advance(), first);
		case NULL:
			return p.finish(NULL_LIT, p.advance(), first);
		case LPAREN:
			p.advance();
			NodeId inner = parse_expr(p);
			p.expect(RPAREN, "expected ')'");
			return inner;
		default:
			p.error("expected an expression");
			return p.error_node(ERROR_EXPR, p.advance());
	}
}
