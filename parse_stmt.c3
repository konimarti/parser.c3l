<* Statement grammar; see grammar.y and DESIGN.md section 4. *>
module c3::parser;

import c3::lexer;
import std::collections::list;

fn NodeId parse_stmt(Parser* p)
{
	if (p.at_end())
	{
		p.error("expected a statement before end of file");
		uint last = p.toks.len() > 0 ? (uint)p.toks.len() - 1 : 0;
		return p.ast.add(ERROR_STMT, last, last, last);
	}
	if (!p.enter()) return p.sync_stmt();
	defer p.leave();
	uint first = p.pos;
	switch (p.peek_type())
	{
		case LBRACE: return parse_block(p);
		case EOS: return p.finish(EMPTY_STMT, p.advance(), first);
		case VAR: return parse_var_stmt(p);
		case CONST: return parse_local_const_stmt(p);
		case STATIC: case TLOCAL: return parse_storage_decl_stmt(p);
		case RETURN: return parse_return_stmt(p);
		case IF: return parse_if_stmt(p);
		case WHILE: return parse_while_stmt(p);
		case DO: return parse_do_stmt(p);
		case FOR: return parse_for_stmt(p);
		case FOREACH: return parse_foreach_stmt(p, false);
		case FOREACH_R: return parse_foreach_stmt(p, true);
		case SWITCH: return parse_switch_stmt(p);
		case CASE: return parse_case_stmt(p);
		case DEFAULT: return parse_default_stmt(p);
		case NEXTCASE: return parse_nextcase_stmt(p);
		case BREAK: return parse_jump_stmt(p, BREAK);
		case CONTINUE: return parse_jump_stmt(p, CONTINUE);
		case DEFER: return parse_defer_stmt(p);
		case ASSERT: return parse_assert_stmt(p);
		case ASM: return parse_asm_stmt(p);
		case CT_IF: return parse_ct_if_stmt(p);
		case CT_SWITCH: return parse_ct_switch_stmt(p);
		case CT_FOR: return parse_ct_for_stmt(p);
		case CT_FOREACH: return parse_ct_foreach_stmt(p);
		case CT_ECHO: return parse_ct_line_stmt(p, CT_ECHO);
		case CT_ASSERT: return parse_ct_line_stmt(p, CT_ASSERT);
		case CT_ERROR: return parse_ct_line_stmt(p, CT_ERROR);
		case CT_EXPAND: return parse_ct_line_stmt(p, CT_EXPAND);
		case CT_TYPE_IDENT:
			if (p.peek_type(1) == EQ) return parse_ct_type_stmt(p);
			return parse_decl_stmt(p);
		default:
			if (p.peek_type() == CONST_IDENT && p.peek_type(1) == COLON)
			{
				return parse_label(p);
			}
			if (looks_like_local_decl(p)) return parse_decl_stmt(p);
			if (is_expr_start(p.peek_type())) return parse_expr_stmt(p);
			p.error("expected a statement");
			return p.sync_stmt();
	}
}

fn bool looks_like_local_decl(Parser* p) @local
{
	TokenType first = p.peek_type();
	if (is_local_decl_start(first))
	{
		// A built-in or unqualified type followed by :: is a type property
		// expression (int::max), not a local declaration.
		// Otherwise preserve the parser's original type-start dispatch. The
		// type parser owns the suffix grammar (including arrays and vectors),
		// so trying to infer that suffix here would misclassify valid forms.
		return p.peek_type(1) != SCOPE;
	}
	if (first == CT_TYPEFROM || first == CT_TYPEOF)
	{
		if (p.peek_type(1) != LPAREN) return false;
		uint at = 2; int depth = 1;
		while (!p.at_end() && depth > 0)
		{
			if (p.peek_type(at) == LPAREN) depth++;
			if (p.peek_type(at) == RPAREN) depth--;
			at++;
		}
		if (depth != 0) return false;
		while (true)
		{
			TokenType suffix = p.peek_type(at);
			if (suffix == STAR || suffix == QUESTION)
			{
				at++;
				continue;
			}
			if (suffix == LBRACKET)
			{
				int brackets = 1; at++;
				while (brackets > 0 && p.peek_type(at) != EOF)
				{
					if (p.peek_type(at) == LBRACKET) brackets++;
					if (p.peek_type(at) == RBRACKET) brackets--;
					at++;
				}
				if (brackets != 0) return false;
				continue;
			}
			if (suffix == LVEC)
			{
				at++;
				while (p.peek_type(at) != RVEC && p.peek_type(at) != EOF) at++;
				if (p.peek_type(at) != RVEC) return false;
				at++;
				continue;
			}
			break;
		}
		return p.peek_type(at) == IDENT || p.peek_type(at) == CT_IDENT;
	}
	if (first != IDENT || p.peek_type(1) != SCOPE) return false;
	uint at = 0;
	while (true)
	{
		if (p.peek_type(at) != IDENT) return false;
		at++;
		if (p.peek_type(at) != SCOPE) return false;
		at++;
		TokenType component = p.peek_type(at);
		if (component == TYPE_IDENT)
		{
			at++;
			return p.peek_type(at) == IDENT || p.peek_type(at) == CT_IDENT;
		}
		if (component != IDENT) return false;
	}
}

fn bool is_expr_start(TokenType t) @local
{
	switch (t)
	{
		case IDENT: case CONST_IDENT: case TYPE_IDENT: case CT_IDENT: case INTEGER: case REAL:
		case STRING: case CHAR_LITERAL: case BYTES: case TRUE: case FALSE: case NULL:
		case LPAREN: case AMP: case AND: case STAR: case BIT_NOT: case BIT_XOR:
		case BANG: case BANGBANG: case PLUS: case MINUS: case PLUSPLUS: case MINUSMINUS:
		case ELLIPSIS: case AT_IDENT: case AT_TYPE_IDENT: case AT_CONST_IDENT:
		case HASH_IDENT: case BUILTIN: case FUNC: case CT_DEFINED:
		case CT_FEATURE: case CT_FEAT: case CT_EVAL: case CT_STRINGIFY: case CT_REFLECT:
		case CT_TYPEOF: case CT_TYPEFROM: case LENGTHOF: case TRY: case CATCH:
			return true;
		default:
			// A base type reaches here only when the dispatcher already
			// ruled out a declaration (peek(1) != SCOPE): `int::max` is a
			// type-property expression, which parse_prefix_or_primary
			// already knows how to parse via parse_path_rest.
			return is_base_type(t);
	}
}

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

fn bool is_local_decl_start(TokenType t)
{
	switch (t)
	{
		case VOID: case BOOL: case CHAR: case ICHAR: case SHORT: case USHORT:
		case INT: case UINT: case LONG: case ULONG: case INT128: case UINT128:
		case FLOAT: case DOUBLE: case FLOAT16: case BFLOAT: case FLOAT128:
		case IPTR: case UPTR: case ISZ: case USZ: case FAULT: case ANY:
		case TYPEID: case UNTYPEDLIST: case TYPE_IDENT:
			return true;
		default: return false;
	}
}

fn NodeId parse_var_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance();
	uint name = p.pos;
	if (!p.at(IDENT) && !p.at(CT_IDENT) && !p.at(CT_TYPE_IDENT))
	{
		p.error("expected a variable name"); return p.sync_stmt();
	}
	bool ct_type = p.at(CT_TYPE_IDENT);
	bool ct_name = p.at(CT_IDENT);
	name = p.advance();
	if (!ct_type && !ct_name) parse_attributes(p);
	NodeId init = NONE;
	if (p.match(EQ)) { init = parse_expr(p); }
	else if (!ct_type && !ct_name) { p.error("expected '=' in variable declaration"); return p.sync_stmt(); }
	if (!p.expect(EOS, "expected ';'")) return p.sync_stmt();
	return p.finish(VAR_DECL, name, first, NONE, init);
}

<*
 `TYPE name = init, name2 = init2, ...;`: the declared type is shared across
 every comma-separated name, so it cannot be threaded through `finish()`'s
 ordinary lhs/rhs widening (each VAR_DECL has its own `init`, and `finish()`
 is called once per name, before the shared type could be assigned). Each
 node's span is widened by hand afterward to cover `ty`'s span once it is
 attached -- otherwise invariant 1 breaks the moment the type starts before
 the name `finish()` was given as this node's `first`, which is exactly what
 `for (sz j = 10; ...)` and `char* current = ...;` both do.
*>
fn NodeId parse_decl_stmt(Parser* p) @local
{
	uint first = p.pos;
	NodeId ty = parse_type(p);
	List{NodeId} decls; decls.tinit();
	do
	{
		uint name = p.pos;
		if (!p.at(IDENT) && !p.at(CT_IDENT)) { p.error("expected a local name"); return p.sync_stmt(); }
		p.advance();
		skip_stmt_attributes(p);
		NodeId init = NONE;
		if (p.match(EQ)) init = parse_expr(p);
		decls.push(p.finish(VAR_DECL, name, first, init));
	} while (p.match(COMMA));
	if (!p.expect(EOS, "expected ';'")) return p.sync_stmt();
	NodeId[] kids = decls.to_tarray();
	Node* ty_node = p.ast.node(ty);
	foreach (id : kids)
	{
		Node* n = p.ast.node(id);
		n.lhs = ty;
		if (ty_node.first_tok < n.first_tok) n.first_tok = ty_node.first_tok;
		if (ty_node.last_tok > n.last_tok) n.last_tok = ty_node.last_tok;
	}
	return kids[0];
}

fn NodeId parse_local_const_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId ty = NONE;
	if (!p.at(CONST_IDENT)) ty = parse_type(p);
	uint name = p.pos;
	if (!p.at(CONST_IDENT)) { p.error("expected a constant name"); return p.sync_stmt(); }
	p.advance(); NodeId value = NONE;
	if (p.match(EQ)) value = parse_expr(p);
	if (!p.expect(EOS, "expected ';' after constant declaration")) return p.sync_stmt();
	return p.finish(VAR_DECL, name, first, ty, value);
}

fn NodeId parse_storage_decl_stmt(Parser* p) @local
{
	uint first = p.pos; p.advance();
	NodeId ty = parse_type(p); List{NodeId} decls; decls.tinit();
	do
	{
		uint name = p.pos;
		if (!p.at(IDENT) && !p.at(CT_IDENT)) { p.error("expected a local name"); return p.sync_stmt(); }
		p.advance(); skip_stmt_attributes(p); NodeId value = NONE;
		if (p.match(EQ)) value = parse_expr(p);
		decls.push(p.finish(VAR_DECL, name, name, ty, value));
	} while (p.match(COMMA));
	if (!p.expect(EOS, "expected ';' after local declaration")) return p.sync_stmt();
	return decls[0];
}

fn NodeId parse_return_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance();
	NodeId value = NONE;
	if (!p.at(EOS)) value = parse_expr(p);
	if (!p.expect(EOS, "expected ';'")) return p.sync_stmt();
	return p.finish(RETURN, kw, first, value);
}

fn NodeId parse_label(Parser* p) @local
{
	uint first = p.pos; uint name = p.advance(); p.advance();
	NodeId target = parse_stmt(p);
	return p.finish(LABEL, name, first, target);
}

fn NodeId parse_optional_label(Parser* p) @local
{
	if (p.at(CONST_IDENT) && p.peek_type(1) == COLON)
	{
		uint first = p.pos; uint name = p.advance(); p.advance();
		return p.finish(IDENT, name, first);
	}
	return NONE;
}

fn NodeId parse_condition(Parser* p) @local
{
	p.expect(LPAREN, "expected '('");
	NodeId cond = parse_condition_list(p);
	p.expect(RPAREN, "expected ')' after condition");
	return cond;
}

fn NodeId parse_condition_list(Parser* p) @local
{
	NodeId cond = parse_condition_item(p);
	while (p.at(COMMA))
	{
		uint comma = p.advance();
		NodeId right = parse_condition_item(p);
		cond = p.ast.add(BINARY, comma, p.ast.node(cond).first_tok,
			p.ast.node(right).last_tok, cond, right);
	}
	return cond;
}

fn NodeId parse_condition_item(Parser* p) @local
{
	uint first = p.pos;
	if (p.at(TRY) || p.at(CATCH))
	{
		bool is_try = p.at(TRY); uint unwrap_tok = p.advance();
		bool named = p.at(IDENT) && p.peek_type(1) == EQ;
		if (!named)
		{
			uint saved = p.pos;
			if (looks_like_local_decl(p))
			{
				NodeId maybe_ty = parse_type(p);
				if ((p.at(IDENT) || p.at(CT_IDENT)) && p.peek_type(1) == EQ)
				{
					uint name = p.advance(); p.advance();
					NodeId value = parse_expr(p);
					NodeId wrapped = p.finish(is_try ? TRY_EXPR : CATCH_EXPR, unwrap_tok, first, value);
					return p.finish(VAR_DECL, name, first, maybe_ty, wrapped);
				}
			}
			p.pos = saved;
		}
		if (named)
		{
			uint name = p.advance(); p.advance();
			NodeId value = parse_expr(p);
			NodeId wrapped = p.finish(is_try ? TRY_EXPR : CATCH_EXPR, unwrap_tok, first, value);
			return p.finish(VAR_DECL, name, first, NONE, wrapped);
		}
		p.pos = first;
		return parse_expr(p);
	}
	if (p.at(VAR))
	{
		p.advance(); uint name = p.pos;
		if (!p.at(IDENT) && !p.at(CT_IDENT))
		{
			p.error("expected a variable name in condition");
			return p.sync_stmt();
		}
		p.advance(); p.expect(EQ, "expected '=' in variable condition");
		NodeId value = parse_expr(p);
		return p.finish(VAR_DECL, name, first, NONE, value);
	}
	if (looks_like_local_decl(p) || looks_like_ct_condition_decl(p))
	{
		NodeId ty = parse_type(p); uint name = p.pos;
		if (!p.at(IDENT) && !p.at(CT_IDENT))
		{
			p.error("expected a local name after condition type");
			return p.sync_stmt();
		}
		p.advance(); skip_stmt_attributes(p); NodeId value = NONE;
		if (p.match(EQ)) value = parse_expr(p);
		return p.finish(VAR_DECL, name, first, ty, value);
	}
	return parse_expr(p);
}

fn bool looks_like_ct_condition_decl(Parser* p) @local
{
	if (!p.at(CT_TYPE_IDENT)) return false;
	TokenType suffix = p.peek_type(1);
	if (suffix == IDENT || suffix == CT_IDENT) return true;
	if (suffix == STAR || suffix == QUESTION)
	{
		return p.peek_type(2) == IDENT || p.peek_type(2) == CT_IDENT;
	}
	return false;
}

fn NodeId parse_if_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance();
	NodeId label = parse_optional_label(p);
	NodeId cond = parse_condition(p);
	NodeId yes = parse_stmt(p); NodeId no = NONE;
	if (p.match(ELSE)) { no = parse_stmt(p); }
	NodeId[3] kids = { cond, yes, no };
	NodeId[<2>] range = p.ast.add_children(&kids);
	NodeId n = p.finish(IF, kw, first, range[0], range[1]);
	return wrap_optional_label(p, label, n, first);
}

fn NodeId wrap_optional_label(Parser* p, NodeId label, NodeId target, uint first) @local
{
	if (!label) return target;
	return p.finish(LABEL, p.ast.node(label).tok, first, target);
}

fn NodeId parse_while_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId label = parse_optional_label(p);
	NodeId cond = parse_condition(p); NodeId body = parse_stmt(p);
	NodeId n = p.finish(WHILE, kw, first, cond, body);
	return wrap_optional_label(p, label, n, first);
}

fn NodeId parse_do_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId label = parse_optional_label(p);
	NodeId body = parse_block(p); NodeId cond = NONE;
	if (p.match(WHILE)) { cond = parse_condition(p); p.expect(EOS, "expected ';' after do-while"); }
	else { p.expect(EOS, "expected ';' after do block"); }
	NodeId n = p.finish(DO, kw, first, body, cond);
	return wrap_optional_label(p, label, n, first);
}

fn NodeId parse_for_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId label = parse_optional_label(p);
	List{NodeId} kids; kids.tinit(); p.expect(LPAREN, "expected '(' after for");
	if (p.at(EOS)) { p.advance(); kids.push(NONE); }
	// `for (sz j = 10; ...)`: a declaration-shaped init clause. parse_decl_stmt
	// consumes its own trailing ';', matching exactly the separator the
	// for-loop header needs here. Missing this case does not just mis-parse
	// one node -- parse_expr chokes on the bare type keyword and desyncs
	// the whole clause sequence, which is what test/parser/conformance.c3
	// caught on lib/std/sort/binarysearch.c3.
	else
	{
		NodeId init = parse_for_init_item(p);
		while (p.match(COMMA))
		{
			NodeId right = parse_for_init_item(p);
			init = p.ast.add(BINARY, p.pos - 1, p.ast.node(init).first_tok, p.ast.node(right).last_tok, init, right);
		}
		kids.push(init);
		p.expect(EOS, "expected ';' after for initializer");
	}
	if (p.at(EOS)) { p.advance(); kids.push(NONE); }
	else { kids.push(parse_condition_list(p)); p.expect(EOS, "expected ';' after for condition"); }
	NodeId inc = p.at(RPAREN) ? NONE : parse_expr(p);
	while (p.match(COMMA)) parse_expr(p); kids.push(inc);
	p.expect(RPAREN, "expected ')' after for clauses"); kids.push(parse_stmt(p));
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	NodeId n = p.finish(FOR, kw, first, range[0], range[1]);
	return wrap_optional_label(p, label, n, first);
}

<* One `decl_or_expr` item in a for initializer; its comma and semicolon
   separators belong to parse_for_stmt, so repeated typed declarations work. *>
fn NodeId parse_for_init_item(Parser* p) @local
{
	uint first = p.pos;
	if (p.match(VAR))
	{
		uint name = p.pos;
		if (!p.at(IDENT) && !p.at(CT_IDENT))
		{
			p.error("expected a variable name in for initializer");
			return p.error_node(ERROR_STMT, first);
		}
		p.advance(); p.expect(EQ, "expected '=' in for variable declaration");
		NodeId value = parse_expr(p);
		return p.finish(VAR_DECL, name, first, NONE, value);
	}
	if (looks_like_local_decl(p) || (p.at(CT_TYPE_IDENT) && p.peek_type(1) != EQ))
	{
		NodeId ty = parse_type(p); uint name = p.pos;
		if (!p.at(IDENT) && !p.at(CT_IDENT))
		{
			p.error("expected a local name in for initializer");
			return p.error_node(ERROR_STMT, first);
		}
		p.advance(); skip_stmt_attributes(p); NodeId value = NONE;
		if (p.match(EQ)) value = parse_expr(p);
		return p.finish(VAR_DECL, name, first, ty, value);
	}
	return parse_expr(p);
}

fn NodeId parse_foreach_stmt(Parser* p, bool reverse) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId label = parse_optional_label(p);
	List{NodeId} vars; vars.tinit(); p.expect(LPAREN, "expected '(' after foreach");
	do
	{
		NodeId ty = NONE;
		if (is_local_decl_start(p.peek_type())) ty = parse_type(p);
		p.match(AMP);
		uint name = p.pos;
		if (!p.at(IDENT)) { p.error("expected foreach variable"); return p.sync_stmt(); }
		p.advance(); vars.push(p.finish(IDENT, name, name, ty));
	} while (p.match(COMMA));
	p.expect(COLON, "expected ':' before collection");
	NodeId collection = parse_expr(p); p.expect(RPAREN, "expected ')' after foreach");
	NodeId body = parse_stmt(p); List{NodeId} kids; kids.tinit();
	kids.push(collection); kids.push(body); foreach (v : vars.to_tarray()) kids.push(v);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	NodeId n = p.finish(reverse ? FOREACH_R : FOREACH, kw, first, range[0], range[1]);
	return wrap_optional_label(p, label, n, first);
}

fn NodeId parse_switch_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId label = parse_optional_label(p);
	NodeId subject = NONE;
	if (p.at(LPAREN)) subject = parse_condition(p);
	if (subject) skip_stmt_attributes(p);
	p.expect(LBRACE, "expected '{' after switch"); List{NodeId} kids; kids.tinit(); kids.push(subject);
	while (!p.at_end() && !p.at(RBRACE))
	{
		uint before = p.pos; kids.push(parse_stmt(p)); if (p.pos == before) p.advance();
	}
	p.expect(RBRACE, "expected '}' after switch");
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	NodeId n = p.finish(SWITCH, kw, first, range[0], range[1]);
	return wrap_optional_label(p, label, n, first);
}

fn void skip_stmt_attributes(Parser* p) @local
{
	while (p.at(AT_IDENT) || p.at(AT_TYPE_IDENT) || p.at(AT_CONST_IDENT))
	{
		p.advance();
		if (!p.match(LPAREN)) continue;
		int depth = 1;
		while (!p.at_end() && depth > 0)
		{
			if (p.at(LPAREN)) depth++;
			if (p.at(RPAREN)) depth--;
			p.advance();
		}
	}
}

fn NodeId parse_case_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId label = parse_expr(p);
	if (p.match(DOTDOT)) parse_expr(p);
	p.expect(COLON, "expected ':' after case");
	List{NodeId} body; body.tinit();
	while (!p.at_end() && !p.at(RBRACE) && !p.at(CASE) && !p.at(DEFAULT)) body.push(parse_stmt(p));
	NodeId body_node = make_block(p, body);
	return p.finish(CASE, kw, first, label, body_node);
}

fn NodeId parse_default_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); p.expect(COLON, "expected ':' after default");
	List{NodeId} body; body.tinit();
	while (!p.at_end() && !p.at(RBRACE) && !p.at(CASE) && !p.at(DEFAULT)) body.push(parse_stmt(p));
	NodeId body_node = make_block(p, body);
	return p.finish(DEFAULT, kw, first, body_node);
}

fn NodeId parse_nextcase_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId label = NONE; NodeId value = NONE;
	if (p.at(CONST_IDENT) && p.peek_type(1) == COLON)
	{ uint tok = p.advance(); label = p.finish(IDENT, tok, tok); p.advance(); }
	if (!p.at(EOS) && !p.at(DEFAULT)) { value = parse_expr(p); }
	else if (p.match(DEFAULT)) { value = p.finish(DEFAULT, p.pos - 1, p.pos - 1); }
	p.expect(EOS, "expected ';' after nextcase"); NodeId[2] kids = { label, value };
	NodeId[<2>] range = p.ast.add_children(&kids);
	return p.finish(NEXTCASE, kw, first, range[0], range[1]);
}

fn NodeId parse_jump_stmt(Parser* p, NodeKind kind) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId label = NONE;
	if (p.at(CONST_IDENT)) { uint t = p.advance(); label = p.finish(IDENT, t, t); }
	if (!p.expect(EOS, "expected ';' after jump")) return p.sync_stmt();
	return p.finish(kind, kw, first, label);
}

fn NodeId parse_defer_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance();
	if (p.match(TRY) || p.match(CATCH)) {}
	else if (p.at(LPAREN) && p.peek_type(1) == CATCH)
	{
		p.advance(); p.advance();
		if (!p.at(IDENT)) { p.error("expected catch variable"); }
		else { p.advance(); }
		p.expect(RPAREN, "expected ')'");
	}
	NodeId body = parse_stmt(p); return p.finish(DEFER, kw, first, body);
}

fn NodeId parse_assert_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); List{NodeId} kids; kids.tinit();
	p.expect(LPAREN, "expected '(' after assert");
	if (!p.at(RPAREN)) do { kids.push(parse_expr(p)); } while (p.match(COMMA));
	p.expect(RPAREN, "expected ')' after assert"); p.expect(EOS, "expected ';' after assert");
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(ASSERT, kw, first, range[0], range[1]);
}

fn NodeId parse_asm_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); uint open = p.pos;
	if (p.match(LPAREN))
	{
		int d = 1; while (!p.at_end() && d > 0) { if (p.at(LPAREN)) d++; if (p.at(RPAREN)) d--; p.advance(); }
		p.expect(EOS, "expected ';' after asm");
	}
	else
	{
		p.match(AT_IDENT); p.expect(LBRACE, "expected '{' after asm"); int d = 1;
		while (!p.at_end() && d > 0) { if (p.at(LBRACE)) d++; if (p.at(RBRACE)) d--; p.advance(); }
	}
	List{NodeId} no_kids; no_kids.tinit();
	NodeId[<2>] range = p.ast.add_children(no_kids.to_tarray());
	return p.finish(ASM_BLOCK, kw, first, range[0], range[1]);
}

<*
 `yes`/`no` collect the branch bodies. Every statement-collecting loop here
 guards forward progress the same way `parse_block` does: a construct that
 desyncs the token stream (see `parse_for_stmt`'s declaration-init fix,
 which this guard would otherwise have let spin forever on) must still
 terminate, even if the resulting tree is wrong. See docs/DESIGN.md
 section 4 and the Phase 1 gate (test/parser/conformance.c3), which is
 what caught this.
*>
fn NodeId parse_ct_if_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); NodeId cond = parse_expr(p); p.expect(COLON, "expected ':' after $if");
	List{NodeId} yes; yes.tinit(); List{NodeId} no; no.tinit(); bool in_else = false;
	while (!p.at_end() && !p.at(CT_ENDIF))
	{
		if (p.match(CT_ELSE)) { in_else = true; continue; }
		uint before = p.pos;
		(in_else ? no : yes).push(parse_stmt(p));
		if (p.pos == before) p.advance();
	}
	p.expect(CT_ENDIF, "expected $endif");
	NodeId[3] kids = { cond, make_block(p, yes), no.len() ? make_block(p, no) : NONE };
	NodeId[<2>] range = p.ast.add_children(&kids); return p.finish(CT_IF, kw, first, range[0], range[1]);
}

fn NodeId make_block(Parser* p, List{NodeId} kids) @local
{
	NodeId[] items = kids.to_tarray();
	NodeId[<2>] range = p.ast.add_children(items);
	// An empty branch still spans the delimiter immediately before the
	// cursor (for example `$else $endif`), which belongs to its parent.
	uint first = items.len ? p.ast.node(items[0]).first_tok : (p.pos ? p.pos - 1 : 0);
	uint last = items.len ? p.ast.node(items[items.len - 1]).last_tok : first;
	uint token_count = (uint)p.toks.len();
	if (token_count == 0)
	{
		first = 0;
		last = 0;
	}
	else
	{
		uint final_token = token_count - 1;
		if (first > final_token) first = final_token;
		if (last > final_token) last = final_token;
		if (last < first) last = first;
	}
	return p.ast.add(BLOCK, first, first, last, range[0], range[1]);
}

fn NodeId parse_ct_switch_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance();
	NodeId subject = NONE;
	if (!p.at(COLON))
	{
		bool type_property = p.peek_type(1) == SCOPE;
		subject = is_local_decl_start(p.peek_type()) && !type_property ? parse_type(p) : parse_expr(p);
	}
	p.expect(COLON, "expected ':' after $switch subject");
	List{NodeId} kids; kids.tinit(); kids.push(subject);
	while (!p.at_end() && !p.at(CT_ENDSWITCH))
	{
		if (p.at(CT_CASE) || p.at(CT_DEFAULT))
		{
			uint f = p.pos; bool is_case = p.at(CT_CASE); uint t = p.advance(); NodeId value = NONE;
			if (is_case)
			{
				bool type_property = p.peek_type(1) == SCOPE;
				value = is_local_decl_start(p.peek_type()) && !type_property ? parse_type(p) : parse_expr(p);
				if (p.at(DOTDOT))
				{
					uint dots = p.advance(); NodeId high = parse_expr(p);
					value = p.ast.add(RANGE, dots, p.ast.node(value).first_tok, p.ast.node(high).last_tok, value, high);
				}
			}
			p.expect(COLON, "expected ':' after compile-time switch arm");
			List{NodeId} body; body.tinit();
			while (!p.at_end() && !p.at(CT_CASE) && !p.at(CT_DEFAULT) && !p.at(CT_ENDSWITCH))
			{
				uint before = p.pos;
				body.push(parse_stmt(p));
				if (p.pos == before) p.advance();
			}
			NodeId block = make_block(p, body);
			kids.push(is_case ? p.finish(CASE, t, f, value, block) : p.finish(DEFAULT, t, f, block));
		}
		else { p.error("expected $case or $default in $switch"); kids.push(p.sync_stmt()); }
	}
	p.expect(CT_ENDSWITCH, "expected $endswitch"); NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(CT_SWITCH, kw, first, range[0], range[1]);
}

fn NodeId parse_ct_for_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance();
	NodeId init = NONE; NodeId cond = NONE; NodeId inc = NONE;
	if (!p.at(EOS)) init = parse_ct_for_clause(p);
	while (p.match(COMMA)) parse_expr(p);
	p.expect(EOS, "expected ';' after $for initializer");
	if (!p.at(EOS)) cond = parse_condition_list(p);
	p.expect(EOS, "expected ';' after $for condition");
	if (!p.at(COLON)) inc = parse_expr(p);
	while (p.match(COMMA)) parse_expr(p);
	p.expect(COLON, "expected ':' after $for clauses"); List{NodeId} body; body.tinit();
	while (!p.at_end() && !p.at(CT_ENDFOR))
	{
		uint before = p.pos;
		body.push(parse_stmt(p));
		if (p.pos == before) p.advance();
	}
	p.expect(CT_ENDFOR, "expected $endfor");
	NodeId block = make_block(p, body); NodeId[4] kids = { init, cond, inc, block };
	NodeId[<2>] range = p.ast.add_children(&kids);
	return p.finish(CT_FOR, kw, first, range[0], range[1]);
}

fn NodeId parse_ct_for_clause(Parser* p) @local
{
	uint first = p.pos;
	if (p.at(VAR))
	{
		p.advance(); uint name = p.pos;
		if (!p.at(CT_IDENT) && !p.at(CT_TYPE_IDENT)) { p.error("expected compile-time variable name"); return p.error_node(ERROR_STMT, first); }
		bool is_type = p.at(CT_TYPE_IDENT); p.advance(); NodeId init = NONE;
		if (p.match(EQ)) init = is_type ? parse_type(p) : parse_expr(p);
		return p.finish(VAR_DECL, name, first, NONE, init);
	}
	if (is_local_decl_start(p.peek_type()))
	{
		NodeId ty = parse_type(p); uint name = p.pos;
		if (!p.at(CT_IDENT) && !p.at(IDENT)) { p.error("expected loop variable name"); return p.error_node(ERROR_STMT, first); }
		p.advance(); NodeId init = NONE;
		if (p.match(EQ)) init = parse_expr(p);
		return p.finish(VAR_DECL, name, first, ty, init);
	}
	return parse_expr(p);
}

fn NodeId parse_ct_foreach_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance();
	List{NodeId} vars; vars.tinit();
	if (p.at(CT_IDENT)) { uint v = p.advance(); vars.push(p.finish(IDENT, v, v)); }
	if (p.match(COMMA) && p.at(CT_IDENT)) { uint v = p.advance(); vars.push(p.finish(IDENT, v, v)); }
	p.expect(COLON, "expected ':' after $foreach variables");
	NodeId collection = parse_expr(p); p.expect(COLON, "expected ':' after $foreach collection");
	List{NodeId} body; body.tinit();
	while (!p.at_end() && !p.at(CT_ENDFOREACH))
	{
		uint before = p.pos;
		body.push(parse_stmt(p));
		if (p.pos == before) p.advance();
	}
	p.expect(CT_ENDFOREACH, "expected $endforeach"); NodeId block = make_block(p, body);
	List{NodeId} kids; kids.tinit(); kids.push(collection); kids.push(block);
	foreach (v : vars.to_tarray()) kids.push(v);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(CT_FOREACH, kw, first, range[0], range[1]);
}

fn NodeId parse_ct_line_stmt(Parser* p, TokenType marker) @local
{
	uint first = p.pos; uint kw = p.advance();
	while (!p.at_end() && !p.at(EOS)) p.advance(); p.expect(EOS, "expected ';' after compile-time statement");
	return p.finish(marker == CT_ECHO ? CT_ECHO_DECL : marker == CT_ASSERT ? CT_ASSERT_DECL : marker == CT_ERROR ? CT_ERROR_DECL : CT_EXPAND, kw, first);
}

fn NodeId parse_ct_type_stmt(Parser* p) @local
{
	uint first = p.pos; uint kw = p.advance(); p.expect(EQ, "expected '=' after compile-time type");
	NodeId value = parse_expr(p); p.expect(EOS, "expected ';' after compile-time type");
	NodeId[] kids = { value };
	NodeId[<2>] range = p.ast.add_children(kids);
	return p.finish(CT_EXPAND, kw, first, range[0], range[1]);
}

fn NodeId parse_expr_stmt(Parser* p) @local
{
	uint first = p.pos;
	bool saved = p.no_init_list; p.no_init_list = true;
	NodeId e = parse_expr(p); p.no_init_list = saved;
	if (p.ast.kind(e) == ERROR_EXPR) return p.sync_stmt();
	if (!p.expect(EOS, "expected ';'")) return p.sync_stmt();
	return p.finish(EXPR_STMT, first, first, e);
}
