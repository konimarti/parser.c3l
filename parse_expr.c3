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
		case CT_TERNARY:
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
		case LENGTHOF:
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
		case CT_IDENT:
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
	if (!is_base_type(next) && next != TYPE_IDENT && next != CT_TYPE_IDENT
		&& next != CT_TYPEOF && next != CT_TYPEFROM) return false;

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
			if (op_type == QUESTION || op_type == CT_TERNARY)
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
			// `is_cast`'s lookahead only predicts that the parens start
			// with a type-shaped token and are followed by something that
			// could continue an expression -- it cannot tell a true cast
			// `(void*)ptr` from a parenthesised type-property expression
			// like `(void*::alignment) * 2`, since both start with
			// `LPAREN base-type` and both are followed by a unary-start
			// token (`::` isn't even checked there). So: try the cast
			// parse, and if what follows the type isn't `)`, the
			// prediction was wrong -- rewind and fall through to the
			// plain parenthesised-expression path, which (via
			// parse_type_as_expr) correctly reads the whole thing as one
			// type-property expression instead.
			uint saved_pos = p.pos;
			p.advance(); // consume '('
			NodeId type_node = parse_type(p);
			if (p.at(RPAREN))
			{
				p.advance();
				bool saved = p.no_init_list;
				p.no_init_list = false;
				NodeId operand = parse_expr(p, Prec.UNARY);
				p.no_init_list = saved;
				return p.finish(CAST, first, first, type_node, operand);
			}
			p.pos = saved_pos;
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
		case TYPE_IDENT:
			return parse_type_as_expr(p, first);

		case IDENT:
		case CONST_IDENT:
		case AT_IDENT:
		case AT_TYPE_IDENT:
		case AT_CONST_IDENT:
		case HASH_IDENT:
		{
			// `std::io::Path` (qualified type) is a type expression, not a
			// plain path: its final segment decides. A plain `IDENT` is the
			// only one of this group that can even start such a chain (a
			// path through CONST_IDENT/AT_IDENT segments is never a type).
			if (t == IDENT && qualified_path_ends_in_type(p))
			{
				return parse_type_as_expr(p, first);
			}
			uint tok = p.advance();
			if (p.at(SCOPE))
			{
				return parse_path_rest(p, first);
			}
			return p.finish(IDENT, tok, first);
		}

		case CT_TYPE_IDENT:
			return parse_type_as_expr(p, first);

		case CT_IDENT:
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

		case CT_TYPEOF:
		case CT_TYPEFROM:
			return parse_type_as_expr(p, first);

		case LENGTHOF:
		{
			uint kw = p.advance();
			p.expect(LPAREN, "expected '(' after 'lengthof'");
			bool saved_len = p.no_init_list;
			p.no_init_list = false;
			NodeId operand = parse_expr(p, Prec.LOWEST);
			p.no_init_list = saved_len;
			p.expect(RPAREN, "expected ')' after 'lengthof'");
			return p.finish(BUILTIN_EXPR, kw, first, operand);
		}

		case CT_DEFINED:
		{
			// `$defined '(' decl_or_expr (',' decl_or_expr)* ')'`: unlike a
			// generic builtin, $defined's arguments can themselves be
			// declarations (`$defined(int x = 12.0)`), not just
			// expressions -- the generic postfix CALL's `parse_call_arg`
			// doesn't know that shape, so this needs its own argument
			// loop.
			uint tok = p.advance();
			NodeId callee = p.finish(CT_IDENT_EXPR, tok, first);
			p.expect(LPAREN, "expected '(' after '$defined'");
			bool saved_def = p.no_init_list;
			p.no_init_list = false;
			List{NodeId} dargs;
			dargs.tinit();
			dargs.push(callee);
			if (!p.at(RPAREN))
			{
				dargs.push(parse_decl_or_expr(p));
				while (p.match(COMMA))
				{
					if (p.at(RPAREN)) break;
					dargs.push(parse_decl_or_expr(p));
				}
			}
			p.no_init_list = saved_def;
			p.expect(RPAREN, "expected ')' after '$defined'");
			NodeId[<2>] range = p.ast.add_children(dargs.to_tarray());
			return p.finish(CALL, tok, first, range[0], range[1]);
		}

		case CT_VAARG:
		case CT_FEATURE:
		case CT_FEAT:
		case CT_EVAL:
		case CT_STRINGIFY:
		case CT_REFLECT:
		{
			uint tok = p.advance();
			return p.finish(CT_IDENT_EXPR, tok, first);
		}

		default:
			if (is_base_type(t))
			{
				return parse_type_as_expr(p, first);
			}
			return parse_error_expr(p, "expected an expression");
	}
}

<*
 A type used in expression position: `type ('::' property)?`, matching the
 real compiler's `parse_type_expression_with_path` / `parse_type_expr`.
 `parse_type` (parse_type.c3) already consumes the type's own suffixes,
 including a `{...}` generic-argument list (`List{int}`, `Foo{Bar{Baz,4},2}`)
 -- that is NOT this function's job to special-case, it falls out of calling
 `parse_type` here instead of treating the primary as a bare leaf. The one
 piece belonging to expression grammar is the trailing `::property` (a type
 property access -- `int::max`, `$Type::kind`, `$Typeof(x)::inner`), reusing
 MEMBER_ACCESS's shape with the `::` token standing in for `.`.
*>
fn NodeId parse_type_as_expr(Parser* p, uint first) @local
{
	NodeId type_node = parse_type(p);
	if (!p.at(SCOPE)) return type_node;

	uint scope_tok = p.advance();
	if (is_access_ident(p.peek_type()))
	{
		uint name_tok = p.advance();
		NodeId name_node = p.finish(IDENT, name_tok, name_tok);
		return p.finish(MEMBER_ACCESS, scope_tok, first, type_node, name_node);
	}
	NodeId err = parse_error_expr(p, "expected a type property after '::'");
	return p.finish(MEMBER_ACCESS, scope_tok, first, type_node, err);
}

<*
 True when the cursor starts a `foo::bar::Type` chain ending in a
 `TYPE_IDENT` -- i.e. a qualified type, not a qualified path to some other
 kind of name (a qualified constant like `env::X86_64`, which is a plain
 `PATH` expression, stays on the `parse_path_rest` route). Mirrors
 parse_decl.c3's `looks_like_qualified_type_path`, duplicated here rather
 than shared across the lane boundary these two files used to have.
*>
fn bool qualified_path_ends_in_type(Parser* p) @local
{
	uint ahead = 0;
	if (p.peek_type(ahead) != IDENT) return false;
	ahead++;
	while (p.peek_type(ahead) == SCOPE)
	{
		ahead++;
		if (p.peek_type(ahead) == TYPE_IDENT) return true;
		if (p.peek_type(ahead) != IDENT) return false;
		ahead++;
	}
	return false;
}

<* True when the cursor starts a type (for `parse_decl_or_expr`'s declaration branch). *>
fn bool looks_like_decl_or_expr_type_start(Parser* p) @local
{
	TokenType t = p.peek_type();
	if (is_base_type(t)) return true;
	if (t == TYPE_IDENT || t == CT_TYPEOF || t == CT_TYPEFROM || t == CT_TYPE_IDENT) return true;
	if (t == IDENT) return qualified_path_ends_in_type(p);
	return false;
}

<*
 `decl_or_expr ::= var_decl | optional_type local_decl_after_type | expr`
 (grammar.y) -- used inside `$defined(...)`'s argument list, where a plain
 `expr` argument and a one-off local declaration (`$defined(int x = 12)`,
 asking "would this declaration type-check") are both legal. `var_decl`
 (the `var` keyword) and the type-prefixed form are tried first since both
 commit textually to a type/name before any possible `=`; if the
 type-prefixed attempt turns out not to be followed by a name after all,
 it backtracks to plain expression parsing, same pattern as this file's
 cast-vs-grouped-expression disambiguation.
*>
fn NodeId parse_decl_or_expr(Parser* p) @local
{
	uint first = p.pos;
	if (p.at(VAR))
	{
		p.advance();
		uint name_tok = p.pos;
		TokenType name_type = p.peek_type();
		bool has_name = p.at(IDENT) || p.at(CT_IDENT) || p.at(CT_TYPE_IDENT);
		if (has_name)
		{
			p.advance();
		}
		else
		{
			p.error("expected a name after 'var'");
		}
		NodeId init = NONE;
		if (p.match(EQ))
		{
			init = name_type == CT_TYPE_IDENT ? parse_type(p) : parse_expr(p, Prec.LOWEST);
		}
		return p.finish(VAR_DECL, has_name ? name_tok : first, first, NONE, init);
	}

	if (looks_like_decl_or_expr_type_start(p))
	{
		uint saved_pos = p.pos;
		NodeId type_node = parse_type(p);
		if (p.at(IDENT) || p.at(CT_IDENT))
		{
			uint name_tok = p.advance();
			NodeId init = NONE;
			if (p.match(EQ)) init = parse_expr(p, Prec.LOWEST);
			return p.finish(VAR_DECL, name_tok, first, type_node, init);
		}
		p.pos = saved_pos;
	}

	return parse_expr(p, Prec.LOWEST);
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

<*
 `'[' expr ']' | '[' expr ('..'|':') expr? ']' | '[' ('..'|':') expr? ']'`:
 a plain subscript, or a slice in either range (`..`) or length (`:`)
 spelling, with either bound optional. Shared by the regular postfix `[`
 and the `.[...]` deref-subscript (`str.[:len]` combines both: a
 deref-subscript that is also a length-slice). The cursor must be at the
 `[`.
*>
fn NodeId parse_subscript_or_slice(Parser* p, NodeId lhs, uint first) @local
{
	uint bracket = p.advance();
	bool saved = p.no_init_list;
	p.no_init_list = false;

	if (p.match(DOTDOT) || p.match(COLON))
	{
		// Slice with omitted low: `[..high]`, `[..]`, `[:len]` (a
		// length-range, grammar.y's `':' range_loc`).
		NodeId high = p.at(RBRACKET) ? NONE : parse_expr(p, Prec.LOWEST);
		p.expect(RBRACKET, "expected ']' after slice");
		p.no_init_list = saved;
		NodeId[<2>] range = p.ast.add_children({ lhs, NONE, high });
		return p.finish(SLICE, bracket, first, range[0], range[1]);
	}
	NodeId first_idx = parse_expr(p, Prec.LOWEST);
	if (p.match(DOTDOT) || p.match(COLON))
	{
		// Slice with low: `[low..high]` or `[low..]`
		NodeId high = p.at(RBRACKET) ? NONE : parse_expr(p, Prec.LOWEST);
		p.expect(RBRACKET, "expected ']' after slice");
		p.no_init_list = saved;
		NodeId[<2>] range = p.ast.add_children({ lhs, first_idx, high });
		return p.finish(SLICE, bracket, first, range[0], range[1]);
	}
	// Single index subscript: `[index]`
	p.expect(RBRACKET, "expected ']' after subscript");
	p.no_init_list = saved;
	return p.finish(SUBSCRIPT, bracket, first, lhs, first_idx);
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
			lhs = parse_subscript_or_slice(p, lhs, first);
		}
		else if (t == LPAREN)
		{
			uint lparen = p.advance();
			bool saved = p.no_init_list;
			p.no_init_list = false;

			List{NodeId} args;
			args.tinit();
			args.push(lhs); // callee is child 0

			while (!p.at(RPAREN) && !p.at(EOS) && !p.at_end())
			{
				NodeId arg = parse_call_arg(p);
				args.push(arg);
				if (!p.match(COMMA)) break;
			}
			if (p.match(EOS))
			{
				// `call_arg_list ::= opt_arg_list (';' parameters)?`: typed
				// block-parameter declarations for a trailing macro body,
				// e.g. `@loop_over_addresses(ai; NativeSocket sockfd, ...)
				// { ... }` in lib/std/net/tcp.c3. Shares parse_decl.c3's
				// parameter grammar; the PARAM children are told apart from
				// plain argument expressions by kind, same as everywhere
				// else a flat child list mixes kinds.
				foreach (param : parse_param_list(p)) args.push(param);
			}
			p.expect(RPAREN, "expected ')' after call arguments");
			p.no_init_list = saved;

			// `opt_call_attributes ::= (AT_INLINE | AT_PURE | AT_NOINLINE)*`
			// (grammar.y) -- these are plain AT_IDENT tokens, not their own
			// TokenType, so any text is accepted here; being permissive on
			// the exact name costs nothing and this parser never validates
			// attribute names anyway. Each becomes a leaf child so the
			// AT_IDENT token is still represented (docs/DESIGN.md section 6).
			while (p.at(AT_IDENT))
			{
				uint attr_first = p.pos;
				uint attr_tok = p.advance();
				args.push(p.finish(CT_IDENT_EXPR, attr_tok, attr_first));
			}

			// Trailing compound statement / block (e.g. `@pool() { ... }`).
			if (p.at(LBRACE))
			{
				NodeId block = parse_block(p);
				args.push(block);
			}

			NodeId[<2>] range = p.ast.add_children(args.to_tarray());
			lhs = p.finish(CALL, lparen, first, range[0], range[1]);
		}
		else if (t == LBRACE)
		{
			// `base_expr generic_expr` (grammar.y): an explicit generic
			// instantiation of a non-type primary, e.g.
			// `clamp_length{$Typeof(self)}(self, min, max)`. A TYPE_IDENT
			// primary's own `{...}` is handled inside parse_type instead
			// (TYPE_GENERIC) and never reaches here, since parse_type
			// already consumed it before returning to parse_postfix.
			uint brace = p.advance();
			bool saved = p.no_init_list;
			p.no_init_list = false;

			List{NodeId} gargs;
			gargs.tinit();
			gargs.push(lhs);
			if (!p.at(RBRACE))
			{
				gargs.push(parse_expr(p, Prec.LOWEST));
				while (p.match(COMMA))
				{
					if (p.at(RBRACE)) break;
					gargs.push(parse_expr(p, Prec.LOWEST));
				}
			}
			p.expect(RBRACE, "expected '}' after generic arguments");
			p.no_init_list = saved;

			NodeId[<2>] range = p.ast.add_children(gargs.to_tarray());
			lhs = p.finish(CT_CALL, brace, first, range[0], range[1]);
		}
		else if (t == DOT)
		{
			uint dot = p.advance();
			if (p.at(LBRACKET))
			{
				// `.[expr]` / `.[low..high]` / `.[:len]` (grammar.y's
				// deref_subscript, which can itself be a slice -- e.g.
				// `str.[:len]`): the deref-vs-not distinction is a
				// semantic nuance this parser does not track, so this is
				// just a subscript/slice on `lhs`.
				lhs = parse_subscript_or_slice(p, lhs, first);
			}
			else if (p.at(CT_EVAL))
			{
				// `.$eval(expr)` (grammar.y's access_ident alternative): a
				// dynamically-named member access. $eval's own `(expr)` is
				// part of this one primary form, not a generic postfix
				// call (unlike a bare top-level `$eval(expr)`, which
				// relies on this same file's CALL postfix to consume the
				// parens) -- `.` binds its child at primary precedence
				// only, with no postfix step of its own.
				uint eval_first = p.pos;
				uint eval_tok = p.advance();
				NodeId eval_leaf = p.finish(CT_IDENT_EXPR, eval_tok, eval_first);
				p.expect(LPAREN, "expected '(' after '$eval'");
				bool saved = p.no_init_list;
				p.no_init_list = false;
				NodeId inner = parse_expr(p, Prec.LOWEST);
				p.no_init_list = saved;
				p.expect(RPAREN, "expected ')' after '$eval'");
				NodeId[<2>] range = p.ast.add_children({ eval_leaf, inner });
				NodeId id_node = p.finish(CALL, eval_tok, eval_first, range[0], range[1]);
				lhs = p.finish(MEMBER_ACCESS, dot, first, lhs, id_node);
			}
			else if (is_access_ident(p.peek_type()))
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

	// Named argument: `arg_name ':' expr` -- grammar.y's arg_name is IDENT,
	// CT_TYPE_IDENT, HASH_IDENT or CT_IDENT (e.g. `mem::load(bytes, $align: 1)`).
	TokenType nt = p.peek_type();
	if ((nt == IDENT || nt == CT_TYPE_IDENT || nt == HASH_IDENT || nt == CT_IDENT)
		&& (p.peek_type(1) == COLON || p.peek_type(1) == EQ))
	{
		uint id_tok = p.advance();
		uint op_tok = p.advance();
		NodeId id_node = p.finish(IDENT, id_tok, id_tok);
		NodeId val = parse_expr(p, Prec.LOWEST);
		return p.finish(ARG, op_tok, first, id_node, val);
	}

	return parse_expr(p, Prec.LOWEST);
}

<*
 One or more chained `.field` / `[index]` / `[low..high]` designator
 segments (grammar.y's `param_path`), e.g. `.c[0..1]`. The first segment
 has no preceding object (a bare `.field` is just that field's IDENT leaf,
 a bare `[idx]` is just the index expression); each later segment wraps
 the chain so far in MEMBER_ACCESS or SUBSCRIPT.
*>
fn NodeId parse_designator_path(Parser* p, uint elem_first) @local
{
	NodeId target = NONE;
	while (true)
	{
		if (p.at(DOT))
		{
			uint dot = p.advance();
			if (!is_access_ident(p.peek_type()))
			{
				p.error("expected identifier after '.'");
				return target == NONE ? p.error_node(ERROR_EXPR, dot) : target;
			}
			uint id_tok = p.advance();
			NodeId id_node = p.finish(IDENT, id_tok, id_tok);
			target = target == NONE ? id_node : p.finish(MEMBER_ACCESS, dot, elem_first, target, id_node);
		}
		else if (p.at(LBRACKET))
		{
			uint lbrack = p.advance();
			NodeId idx = parse_expr(p, Prec.LOWEST);
			if (p.match(DOTDOT))
			{
				NodeId high = parse_expr(p, Prec.LOWEST);
				idx = p.finish(RANGE, lbrack, elem_first, idx, high);
			}
			p.expect(RBRACKET, "expected ']' after index designator");
			target = target == NONE ? idx : p.finish(SUBSCRIPT, lbrack, elem_first, target, idx);
		}
		else
		{
			break;
		}
	}
	return target;
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
		if (p.at(DOT) || p.at(LBRACKET))
		{
			// `param_path '=' expr | param_path` (grammar.y), where
			// `param_path` is one or more chained `.field` / `[index]` /
			// `[low..high]` segments -- e.g. `.c[0..1] = 7`. The value is
			// optional, same as a named call argument (`{.flag1}` is a
			// real shorthand in the corpus, vs. `{.flag1 = true}`).
			NodeId target = parse_designator_path(p, elem_first);
			if (p.match(EQ))
			{
				NodeId val = parse_expr(p, Prec.LOWEST);
				elems.push(p.finish(ASSIGN, elem_first, elem_first, target, val));
			}
			else
			{
				elems.push(target);
			}
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

	// `lambda_decl ::= FN maybe_optional_type fn_parameter_list
	// opt_attributes` (grammar.y): `fn void() @tag("x") { ... }` is a real
	// corpus shape. Attributes land in SIGNATURE's children alongside the
	// params, same as parse_decl.c3's build_signature -- told apart from
	// PARAM entries by kind.
	foreach (attr : parse_attributes(p)) sig_kids.push(attr);

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
