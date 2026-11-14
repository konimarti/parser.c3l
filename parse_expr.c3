<*
 Expression grammar.

 LANE 1A (agy). Precedence climbing per docs/DESIGN.md section 3, postfix/call/
 member/subscript/slice, initializer lists, lambdas, try/catch operand grammar
 and $-expressions.
*>
module c3::parser;

import c3::lexer;
import std::collections::list;

<* Return the binary precedence of `t`, or 0 if `t` is not a binary operator. *>
fn Prec get_binary_prec(TokenType t)
{
	switch (t)
	{
		case EQ:
		case PLUS_ASSIGN:
		case MINUS_ASSIGN:
		case MULT_ASSIGN:
		case DIV_ASSIGN:
		case MOD_ASSIGN:
		case SHL_ASSIGN:
		case SHR_ASSIGN:
		case BIT_AND_ASSIGN:
		case BIT_XOR_ASSIGN:
		case BIT_OR_ASSIGN:
		case CT_CONCAT_ASSIGN:
			return Prec.ASSIGNMENT;

		case QUESTION:
		case ELVIS:
		case QUESTQUEST:
			return Prec.TERNARY;

		case OR:
		case CT_OR_OP:
			return Prec.OR;

		case AND:
		case CT_AND_OP:
			return Prec.AND;

		case LESS:
		case GREATER:
		case LESS_EQ:
		case GREATER_EQ:
		case EQEQ:
		case NOT_EQUAL:
			return Prec.RELATIONAL;

		case PLUS:
		case MINUS:
		case CT_CONCAT_OP:
			return Prec.ADDITIVE;

		case AMP:
		case BIT_OR:
		case BIT_XOR:
			return Prec.BIT;

		case SHL_OP:
		case SHR_OP:
			return Prec.SHIFT;

		case STAR:
		case DIV:
		case MOD:
			return Prec.MULT;

		default:
			return Prec.LOWEST;
	}
}

<* True if the binary operator is right-associative. *>
fn bool is_right_assoc(Prec prec) @inline
{
	return prec == Prec.ASSIGNMENT || prec == Prec.TERNARY;
}

<* True for tokens that can start a unary / prefix expression. *>
fn bool can_start_unary_expr(TokenType t)
{
	switch (t)
	{
		case INTEGER:
		case REAL:
		case STRING:
		case CHAR_LITERAL:
		case BYTES:
		case TRUE:
		case FALSE:
		case NULL:
		case IDENT:
		case CONST_IDENT:
		case TYPE_IDENT:
		case AT_IDENT:
		case AT_TYPE_IDENT:
		case AT_CONST_IDENT:
		case HASH_IDENT:
		case CT_IDENT:
		case CT_TYPE_IDENT:
		case CT_CONST_IDENT:
		case AMP:
		case AND:
		case STAR:
		case PLUS:
		case MINUS:
		case BIT_NOT:
		case BIT_XOR:
		case BANG:
		case BANGBANG:
		case PLUSPLUS:
		case MINUSMINUS:
		case ELLIPSIS:
		case LPAREN:
		case LBRACE:
		case BUILTIN:
		case TRY:
		case CATCH:
		case FUNC:
		case CT_VAARG:
		case CT_DEFINED:
		case CT_FEATURE:
		case CT_FEAT:
		case CT_EVAL:
		case CT_STRINGIFY:
		case CT_REFLECT:
		case CT_TYPEOF:
		case CT_TYPEFROM:
			return true;
		default:
			return is_base_type(t);
	}
}

<* True for identifier tokens allowed after '.' in member access. *>
fn bool is_access_ident(TokenType t)
{
	switch (t)
	{
		case IDENT:
		case CONST_IDENT:
		case TYPE_IDENT:
		case AT_IDENT:
		case HASH_IDENT:
		case TYPEID:
			return true;
		default:
			return false;
	}
}

<* Check whether '(' at current pos begins a type cast `(type)expr`. *>
fn bool is_cast(Parser* p)
{
	if (!p.at(LPAREN)) return false;
	TokenType next = p.peek_type(1);
	if (!is_base_type(next) && next != TYPE_IDENT) return false;

	// Scan forward to find the matching ')' at paren depth 0.
	uint depth = 0;
	uint i = p.pos;
	sz len = p.toks.len();
	while ((sz)i < len)
	{
		TokenType tt = p.toks.type_at(i);
		if (tt == LPAREN || tt == LBRACKET || tt == LBRACE)
		{
			depth++;
		}
		else if (tt == RPAREN || tt == RBRACKET || tt == RBRACE)
		{
			depth--;
			if (depth == 0)
			{
				// Found matching ')'. Look at what follows.
				TokenType after = p.toks.type_at(i + 1);
				return can_start_unary_expr(after);
			}
		}
		i++;
	}
	return false;
}

<* Emit an error and produce a safe ERROR_EXPR node that never exceeds the token stream. *>
fn NodeId parse_error_expr(Parser* p, String msg) @local
{
	p.error(msg);
	if (p.at_end())
	{
		uint last = p.toks.len() > 0 ? (uint)p.toks.len() - 1 : 0;
		return p.ast.add(ERROR_EXPR, last, last, last);
	}
	uint at = p.advance();
	return p.error_node(ERROR_EXPR, at);
}

<*
 Parse an expression binding at least as tightly as `min`.
 @param min : "the loosest precedence this call may consume"
*>
fn NodeId parse_expr(Parser* p, Prec min = Prec.LOWEST)
{
	if (!p.enter()) return parse_error_expr(p, "expression nests too deeply");
	defer p.leave();

	NodeId lhs = parse_prefix_or_primary(p, min);

	// Postfix operations bind tighter than any binary operator.
	lhs = parse_postfix(p, lhs);

	// Precedence climbing for binary / infix operators.
	while (!p.at_end())
	{
		TokenType op_type = p.peek_type();
		Prec prec = get_binary_prec(op_type);
		if (prec == Prec.LOWEST || prec < min) break;

		uint op_tok = p.advance();
		uint first = p.ast.node(lhs).first_tok;

		// As soon as an operator is consumed, a following '{' is not a statement block.
		bool saved_no_init = p.no_init_list;
		p.no_init_list = false;

		if (prec == Prec.ASSIGNMENT)
		{
			// Right-associative: recurse at the same precedence.
			NodeId rhs = parse_expr(p, Prec.ASSIGNMENT);
			p.no_init_list = saved_no_init;
			lhs = p.finish(ASSIGN, op_tok, first, lhs, rhs);
		}
		else if (prec == Prec.TERNARY)
		{
			if (op_type == QUESTION)
			{
				NodeId then_expr = parse_expr(p, Prec.LOWEST);
				p.expect(COLON, "expected ':' in ternary expression");
				NodeId else_expr = parse_expr(p, Prec.TERNARY);
				p.no_init_list = saved_no_init;
				NodeId[<2>] range = p.ast.add_children({ lhs, then_expr, else_expr });
				lhs = p.finish(TERNARY, op_tok, first, range[0], range[1]);
			}
			else if (op_type == ELVIS)
			{
				NodeId rhs = parse_expr(p, Prec.TERNARY);
				p.no_init_list = saved_no_init;
				lhs = p.finish(ELVIS, op_tok, first, lhs, rhs);
			}
			else // QUESTQUEST
			{
				NodeId rhs = parse_expr(p, Prec.TERNARY);
				p.no_init_list = saved_no_init;
				lhs = p.finish(OPTELSE, op_tok, first, lhs, rhs);
			}
		}
		else
		{
			// Left-associative: recurse at one level higher.
			Prec next_prec = (Prec)((char)prec + 1);
			NodeId rhs = parse_expr(p, next_prec);
			p.no_init_list = saved_no_init;
			lhs = p.finish(BINARY, op_tok, first, lhs, rhs);
		}

		// Re-apply postfix operators to the newly created lhs (e.g. `(a + b).x` or `a + b[0]`).
		lhs = parse_postfix(p, lhs);
	}

	return lhs;
}

<* Parse prefix operators or primary expressions. *>
fn NodeId parse_prefix_or_primary(Parser* p, Prec min) @local
{
	uint first = p.pos;
	TokenType t = p.peek_type();

	// --- Unary prefix operators -----------------------------------------
	switch (t)
	{
		case AMP:
		case AND:
		case STAR:
		case PLUS:
		case MINUS:
		case BIT_NOT:
		case BIT_XOR:
		case BANG:
		case BANGBANG:
		case PLUSPLUS:
		case MINUSMINUS:
		{
			uint op = p.advance();
			bool saved = p.no_init_list;
			p.no_init_list = false;
			NodeId operand = parse_expr(p, Prec.UNARY);
			p.no_init_list = saved;
			return p.finish(UNARY, op, first, operand);
		}
		case ELLIPSIS:
		{
			uint op = p.advance();
			bool saved = p.no_init_list;
			p.no_init_list = false;
			NodeId operand = parse_expr(p, Prec.UNARY);
			p.no_init_list = saved;
			return p.finish(SPLAT, op, first, operand);
		}
		default:
			break;
	}

	// --- Try / Catch ----------------------------------------------------
	if (t == TRY)
	{
		uint kw = p.advance();
		NodeId operand = parse_try_catch_operand(p);
		return p.finish(TRY_EXPR, kw, first, operand);
	}
	if (t == CATCH)
	{
		uint kw = p.advance();
		NodeId operand = parse_try_catch_operand(p);
		return p.finish(CATCH_EXPR, kw, first, operand);
	}

	// --- Cast or Parenthesised expression -------------------------------
	if (t == LPAREN)
	{
		if (is_cast(p))
		{
			p.advance(); // consume '('
			NodeId type_node = parse_type(p);
			p.expect(RPAREN, "expected ')' after cast type");
			bool saved = p.no_init_list;
			p.no_init_list = false;
			NodeId operand = parse_expr(p, Prec.UNARY);
			p.no_init_list = saved;
			return p.finish(CAST, first, first, type_node, operand);
		}
		// Regular parenthesized expression.
		p.advance(); // consume '('
		bool saved = p.no_init_list;
		p.no_init_list = false;
		NodeId inner = parse_expr(p, Prec.LOWEST);
		p.no_init_list = saved;
		p.expect(RPAREN, "expected ')'");
		return inner;
	}

	// --- Initializer list -----------------------------------------------
	if (t == LBRACE)
	{
		if (p.no_init_list)
		{
			p.error("expected an expression");
			return p.error_node(ERROR_EXPR, p.pos);
		}
		return parse_initializer_list(p);
	}

	// --- Lambda ---------------------------------------------------------
	if (t == FUNC)
	{
		return parse_lambda(p);
	}

	// --- Identifiers, Literals, Builtins --------------------------------
	switch (t)
	{
		case IDENT:
		case CONST_IDENT:
		case TYPE_IDENT:
		case AT_IDENT:
		case AT_TYPE_IDENT:
		case AT_CONST_IDENT:
		case HASH_IDENT:
		{
			uint tok = p.advance();
			if (p.at(SCOPE))
			{
				return parse_path_rest(p, first);
			}
			return p.finish(IDENT, tok, first);
		}

		case CT_IDENT:
		case CT_TYPE_IDENT:
		case CT_CONST_IDENT:
		{
			uint tok = p.advance();
			return p.finish(CT_IDENT_EXPR, tok, first);
		}

		case INTEGER:
			return p.finish(INT_LIT, p.advance(), first);
		case REAL:
			return p.finish(REAL_LIT, p.advance(), first);
		case CHAR_LITERAL:
			return p.finish(CHAR_LIT, p.advance(), first);
		case TRUE:
		case FALSE:
			return p.finish(BOOL_LIT, p.advance(), first);
		case NULL:
			return p.finish(NULL_LIT, p.advance(), first);

		case STRING:
		{
			uint tok = p.advance();
			while (p.at(STRING)) p.advance();
			return p.finish(STRING_LIT, tok, first);
		}

		case BYTES:
		{
			uint tok = p.advance();
			while (p.at(BYTES)) p.advance();
			return p.finish(BYTES_LIT, tok, first);
		}

		case BUILTIN:
		{
			uint tok = p.advance();
			if (p.at(IDENT) || p.at(CONST_IDENT)) p.advance();
			return p.finish(BUILTIN_EXPR, tok, first);
		}

		case CT_VAARG:
		case CT_DEFINED:
		case CT_FEATURE:
		case CT_FEAT:
		case CT_EVAL:
		case CT_STRINGIFY:
		case CT_REFLECT:
		case CT_TYPEOF:
		case CT_TYPEFROM:
		{
			uint tok = p.advance();
			return p.finish(CT_IDENT_EXPR, tok, first);
		}

		default:
			if (is_base_type(t))
			{
				uint tok = p.advance();
				if (p.at(SCOPE))
				{
					return parse_path_rest(p, first);
				}
				return p.finish(TYPE_BASE, tok, first);
			}
			return parse_error_expr(p, "expected an expression");
	}
}

<* Consume '::' segments and return a PATH node spanning from `first`. *>
fn NodeId parse_path_rest(Parser* p, uint first) @local
{
	uint last_id = first;
	while (p.match(SCOPE))
	{
		TokenType tt = p.peek_type();
		if (tt == IDENT || tt == CONST_IDENT || tt == TYPE_IDENT ||
		    tt == AT_IDENT || tt == AT_TYPE_IDENT || tt == AT_CONST_IDENT)
		{
			last_id = p.advance();
		}
		else
		{
			p.error("expected an identifier after '::'");
			break;
		}
	}
	return p.finish(PATH, first, first);
}

<* Parse postfix operations: subscripts, slices, calls, member access, ++, --, !, !!. *>
fn NodeId parse_postfix(Parser* p, NodeId lhs) @local
{
	while (!p.at_end())
	{
		uint first = p.ast.node(lhs).first_tok;
		TokenType t = p.peek_type();

		if (t == LBRACKET)
		{
			uint bracket = p.advance();
			bool saved = p.no_init_list;
			p.no_init_list = false;

			if (p.match(DOTDOT))
			{
				// Slice with omitted low: `[..high]` or `[..]`
				NodeId high = p.at(RBRACKET) ? NONE : parse_expr(p, Prec.LOWEST);
				p.expect(RBRACKET, "expected ']' after slice");
				p.no_init_list = saved;
				NodeId[<2>] range = p.ast.add_children({ lhs, NONE, high });
				lhs = p.finish(SLICE, bracket, first, range[0], range[1]);
			}
			else
			{
				NodeId first_idx = parse_expr(p, Prec.LOWEST);
				if (p.match(DOTDOT) || p.match(COLON))
				{
					// Slice with low: `[low..high]` or `[low..]`
					NodeId high = p.at(RBRACKET) ? NONE : parse_expr(p, Prec.LOWEST);
					p.expect(RBRACKET, "expected ']' after slice");
					p.no_init_list = saved;
					NodeId[<2>] range = p.ast.add_children({ lhs, first_idx, high });
					lhs = p.finish(SLICE, bracket, first, range[0], range[1]);
				}
				else
				{
					// Single index subscript: `[index]`
					p.expect(RBRACKET, "expected ']' after subscript");
					p.no_init_list = saved;
					lhs = p.finish(SUBSCRIPT, bracket, first, lhs, first_idx);
				}
			}
		}
		else if (t == LPAREN)
		{
			uint lparen = p.advance();
			bool saved = p.no_init_list;
			p.no_init_list = false;

			List{NodeId} args;
			args.tinit();
			args.push(lhs); // callee is child 0

			while (!p.at(RPAREN) && !p.at_end())
			{
				NodeId arg = parse_call_arg(p);
				args.push(arg);
				if (!p.match(COMMA)) break;
			}
			p.expect(RPAREN, "expected ')' after call arguments");
			p.no_init_list = saved;

			// Trailing compound statement / block (e.g. `@pool() { ... }`).
			if (p.at(LBRACE))
			{
				NodeId block = parse_block(p);
				args.push(block);
			}

			NodeId[<2>] range = p.ast.add_children(args.to_tarray());
			lhs = p.finish(CALL, lparen, first, range[0], range[1]);
		}
		else if (t == DOT)
		{
			uint dot = p.advance();
			if (is_access_ident(p.peek_type()))
			{
				uint name_tok = p.advance();
				NodeId id_node = p.finish(IDENT, name_tok, name_tok);
				lhs = p.finish(MEMBER_ACCESS, dot, first, lhs, id_node);
			}
			else
			{
				NodeId err = parse_error_expr(p, "expected member name after '.'");
				lhs = p.finish(MEMBER_ACCESS, dot, first, lhs, err);
			}
		}
		else if (t == PLUSPLUS)
		{
			uint op = p.advance();
			lhs = p.finish(POSTFIX, op, first, lhs);
		}
		else if (t == MINUSMINUS)
		{
			uint op = p.advance();
			lhs = p.finish(POSTFIX, op, first, lhs);
		}
		else if (t == BANG)
		{
			uint op = p.advance();
			lhs = p.finish(RETHROW, op, first, lhs);
		}
		else if (t == BANGBANG)
		{
			uint op = p.advance();
			lhs = p.finish(FORCE_UNWRAP, op, first, lhs);
		}
		else if (t == BIT_NOT)
		{
			uint op = p.advance();
			lhs = p.finish(POSTFIX, op, first, lhs);
		}
		else
		{
			break;
		}
	}
	return lhs;
}

<* Parse one argument in a call argument list. *>
fn NodeId parse_call_arg(Parser* p) @local
{
	uint first = p.pos;

	// Named argument: `foo: expr` or `foo = expr` or `.foo = expr`
	if (p.at(DOT))
	{
		uint dot = p.advance();
		if (is_access_ident(p.peek_type()))
		{
			uint id_tok = p.advance();
			NodeId id_node = p.finish(IDENT, id_tok, id_tok);
			if (p.match(EQ))
			{
				NodeId val = parse_expr(p, Prec.LOWEST);
				return p.finish(ARG, dot, first, id_node, val);
			}
			return id_node;
		}
		p.error("expected identifier after '.'");
		return p.error_node(ERROR_EXPR, dot);
	}

	if (p.peek_type() == IDENT && (p.peek_type(1) == COLON || p.peek_type(1) == EQ))
	{
		uint id_tok = p.advance();
		uint op_tok = p.advance();
		NodeId id_node = p.finish(IDENT, id_tok, id_tok);
		NodeId val = parse_expr(p, Prec.LOWEST);
		return p.finish(ARG, op_tok, first, id_node, val);
	}

	return parse_expr(p, Prec.LOWEST);
}

<* Parse an initializer list `{ ... }`. *>
fn NodeId parse_initializer_list(Parser* p) @local
{
	uint first = p.pos;
	p.advance(); // consume '{'
	bool saved = p.no_init_list;
	p.no_init_list = false;

	List{NodeId} elems;
	elems.tinit();

	while (!p.at(RBRACE) && !p.at_end())
	{
		uint elem_first = p.pos;
		if (p.at(DOT))
		{
			// `.field = expr` designator
			uint dot = p.advance();
			if (is_access_ident(p.peek_type()))
			{
				uint id_tok = p.advance();
				NodeId target = p.finish(IDENT, id_tok, id_tok);
				p.expect(EQ, "expected '=' after designator");
				NodeId val = parse_expr(p, Prec.LOWEST);
				NodeId assign = p.finish(ASSIGN, dot, elem_first, target, val);
				elems.push(assign);
			}
			else
			{
				p.error("expected identifier after '.'");
				elems.push(p.error_node(ERROR_EXPR, dot));
			}
		}
		else if (p.at(LBRACKET))
		{
			// `[index] = expr` designator
			uint lbrack = p.advance();
			NodeId idx = parse_expr(p, Prec.LOWEST);
			p.expect(RBRACKET, "expected ']' after index designator");
			p.expect(EQ, "expected '=' after designator");
			NodeId val = parse_expr(p, Prec.LOWEST);
			NodeId assign = p.finish(ASSIGN, lbrack, elem_first, idx, val);
			elems.push(assign);
		}
		else if (p.peek_type() == IDENT && p.peek_type(1) == COLON)
		{
			// `name: expr` named element
			uint id_tok = p.advance();
			uint colon = p.advance();
			NodeId id_node = p.finish(IDENT, id_tok, id_tok);
			NodeId val = parse_expr(p, Prec.LOWEST);
			NodeId arg = p.finish(ARG, colon, elem_first, id_node, val);
			elems.push(arg);
		}
		else
		{
			NodeId elem = parse_expr(p, Prec.LOWEST);
			elems.push(elem);
		}

		if (!p.match(COMMA)) break;
	}

	p.no_init_list = saved;
	p.expect(RBRACE, "expected '}' after initializer list");
	NodeId[<2>] range = p.ast.add_children(elems.to_tarray());
	return p.finish(INIT_LIST, first, first, range[0], range[1]);
}

<* Parse a lambda expression `fn <type> ( params ) => expr` or `{ body }`. *>
fn NodeId parse_lambda(Parser* p) @local
{
	uint first = p.pos;
	p.advance(); // consume 'fn'

	NodeId ret_type = NONE;
	if (!p.at(LPAREN))
	{
		ret_type = parse_type(p);
	}

	p.expect(LPAREN, "expected '(' for lambda parameters");
	List{NodeId} sig_kids;
	sig_kids.tinit();
	sig_kids.push(ret_type);

	while (!p.at(RPAREN) && !p.at_end())
	{
		uint p_first = p.pos;
		if (p.peek_type() == IDENT && (p.peek_type(1) == COMMA || p.peek_type(1) == RPAREN))
		{
			// Inferred lambda parameter without explicit type.
			uint name_tok = p.advance();
			// PARAM is list-bearing: children = [type, default, attrs...].
			// See parse_decl.c3's parse_param, which defines this shape -- a
			// lambda parameter is the same node kind as an ordinary one.
			NodeId[<2>] inferred_range = p.ast.add_children({ NONE, NONE });
			NodeId param = p.finish(PARAM, name_tok, p_first, inferred_range[0], inferred_range[1]);
			sig_kids.push(param);
		}
		else
		{
			NodeId p_type = parse_type(p);
			uint name_tok = p.ast.node(p_type).tok;
			if (p.at(IDENT))
			{
				name_tok = p.advance();
			}
			NodeId p_def = NONE;
			if (p.match(EQ))
			{
				p_def = parse_expr(p, Prec.LOWEST);
			}
			NodeId[<2>] param_range = p.ast.add_children({ p_type, p_def });
			NodeId param = p.finish(PARAM, name_tok, p_first, param_range[0], param_range[1]);
			sig_kids.push(param);
		}

		if (!p.match(COMMA)) break;
	}
	p.expect(RPAREN, "expected ')' after lambda parameters");

	NodeId[<2>] sig_range = p.ast.add_children(sig_kids.to_tarray());
	NodeId sig = p.finish(SIGNATURE, first, first, sig_range[0], sig_range[1]);

	NodeId body = NONE;
	if (p.match(IMPLIES))
	{
		// `=> expr` body at TERNARY precedence.
		body = parse_expr(p, Prec.TERNARY);
	}
	else if (p.at(LBRACE))
	{
		// `{ body }` compound statement.
		body = parse_block(p);
	}
	else
	{
		body = parse_error_expr(p, "expected '=>' or '{' for lambda body");
	}

	NodeId[<2>] lam_range = p.ast.add_children({ sig, body });
	return p.finish(LAMBDA, first, first, lam_range[0], lam_range[1]);
}

<* Parse the operand of a try or catch expression. *>
fn NodeId parse_try_catch_operand(Parser* p) @local
{
	uint first = p.pos;
	if (p.peek_type() == IDENT && p.peek_type(1) == EQ)
	{
		uint name_tok = p.advance();
		uint eq = p.advance();
		NodeId id_node = p.finish(IDENT, name_tok, name_tok);
		NodeId rhs = parse_expr(p, Prec.RELATIONAL);
		return p.finish(ASSIGN, eq, first, id_node, rhs);
	}

	return parse_expr(p, Prec.RELATIONAL);
}
