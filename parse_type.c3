<*
 Type grammar.

 LANE 1C (claude). Base types, named types (with optional module-path
 qualifier and generic arguments), pointer/array/slice/vector suffixes, the
 optional (`?`) suffix, `$typeof`/`$typefrom`, the `$Type` compile-time
 placeholder, and the `fn` function-type grammar used by `alias`
 declarations (`parse_fn_type`, called from `parse_decl.c3`).

 Grounded in c3c's actual recursive-descent parser
 (src/compiler/parse_global.c `parse_base_type`/`parse_type_with_base`), not
 just grammar.y: the two disagree on some token names (`EXCUSE` vs
 `FAULTDEF`, a few compile-time type tokens grammar.y lists do not exist in
 the shipped lexer) and grammar.y's `generic_parameters` production allows a
 bare `type`, but the real parser always parses a generic argument with
 `parse_expr` -- so that is what `parse_generic_suffix` below does too, same
 as `parse_decl.c3`'s interface-impl list.
*>
module c3::parser;

import c3::lexer;
import std::collections::list;

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

<* Parse a type: a base type, its suffixes, and an optional trailing `?`. *>
fn NodeId parse_type(Parser* p)
{
	return parse_type_impl(p, true);
}

<*
 `type_no_generics` from grammar.y: a type whose suffix loop never reads a
 trailing `{` as generic arguments. `parse_decl.c3` needs this wherever a
 type is immediately followed by something else that opens with `{` --
 an `enum`/`constset`'s underlying type, a `bitstruct`'s container type, and
 an `interface`'s parent list -- matching the real compiler's
 `parse_optional_type_no_generic`. Without it, `enum Foo : CInt { A, B }`
 reads `CInt { A, B }` as one generic type and swallows the enum's body.
*>
fn NodeId parse_type_no_generic(Parser* p)
{
	return parse_type_impl(p, false);
}

fn NodeId parse_type_impl(Parser* p, bool allow_generic) @local
{
	if (!p.enter()) return p.error_node(ERROR_EXPR, p.pos);
	defer p.leave();

	uint first = p.pos;
	NodeId t = parse_base_type(p, first);
	t = parse_type_suffixes(p, t, first, allow_generic);
	if (p.at(QUESTION))
	{
		uint q = p.advance();
		t = p.finish(TYPE_OPTIONAL, q, first, t);
	}
	return t;
}

<* `base_type_no_user_defined | TYPE_IDENT opt_generic_parameters | path TYPE_IDENT ... | CT_TYPE_IDENT`. *>
fn NodeId parse_base_type(Parser* p, uint first)
{
	switch (p.peek_type())
	{
		case CT_TYPEOF:
		case CT_TYPEFROM:
			uint kw = p.advance();
			p.expect(LPAREN, "expected '('");
			NodeId operand = parse_expr(p);
			p.expect(RPAREN, "expected ')'");
			return p.finish(TYPE_EXPR, kw, first, operand);
		case CT_TYPE_IDENT:
			return p.finish(TYPE_INFERRED, p.advance(), first);
		case TYPE_IDENT:
			return parse_named_type(p, first, NONE);
		case IDENT:
			if (p.peek_type(1) == SCOPE)
			{
				NodeId qualifier = parse_type_path_prefix(p);
				if (!p.at(TYPE_IDENT))
				{
					p.error("expected a type name after '::'");
					return p.error_node(ERROR_EXPR, p.pos);
				}
				return parse_named_type(p, first, qualifier);
			}
			p.error("expected a type");
			return p.error_node(ERROR_EXPR, p.advance());
		default:
			if (is_base_type(p.peek_type()))
			{
				return p.finish(TYPE_BASE, p.advance(), first);
			}
			p.error("expected a type");
			return p.error_node(ERROR_EXPR, p.advance());
	}
}

<* A `foo::bar::` qualifier preceding a type name. Cursor starts on the first IDENT. *>
fn NodeId parse_type_path_prefix(Parser* p) @local
{
	uint first = p.pos;
	uint name = p.advance();
	p.advance(); // '::'
	while (p.at(IDENT) && p.peek_type(1) == SCOPE)
	{
		p.advance();
		p.advance();
	}
	return p.finish(PATH, name, first);
}

fn NodeId parse_named_type(Parser* p, uint first, NodeId qualifier) @local
{
	uint name = p.advance();
	return p.finish(TYPE_NAME, name, first, qualifier);
}

<* `('*' | array_suffix | vector_suffix | generic_suffix)*`, matching the real parser's unified suffix loop. *>
fn NodeId parse_type_suffixes(Parser* p, NodeId t, uint first, bool allow_generic) @local
{
	while (true)
	{
		switch (p.peek_type())
		{
			case STAR:
				uint star = p.advance();
				t = p.finish(TYPE_PTR, star, first, t);
			case LBRACKET:
				t = parse_array_suffix(p, t, first);
			case LVEC:
				t = parse_vec_suffix(p, t, first);
			case LBRACE:
				if (!allow_generic) return t;
				t = parse_generic_suffix(p, t, first);
			default:
				return t;
		}
	}
}

<* `'[' (constant_expr | '*')? ']'`: a fixed array, an inferred-length array `[*]`, or a slice `[]`. *>
fn NodeId parse_array_suffix(Parser* p, NodeId elem, uint first) @local
{
	uint lb = p.advance();
	if (p.match(STAR))
	{
		p.expect(RBRACKET, "expected ']'");
		return p.finish(TYPE_ARRAY, lb, first, elem, NONE);
	}
	if (p.match(RBRACKET))
	{
		return p.finish(TYPE_SLICE, lb, first, elem);
	}
	NodeId len = parse_expr(p);
	p.expect(RBRACKET, "expected ']'");
	return p.finish(TYPE_ARRAY, lb, first, elem, len);
}

<* `'[<' (constant_expr | '*') '>]'`, optionally followed by `@simd` (left for the caller's own opt_attributes to pick up). *>
fn NodeId parse_vec_suffix(Parser* p, NodeId elem, uint first) @local
{
	uint lv = p.advance();
	if (p.match(STAR))
	{
		p.expect(RVEC, "expected '>]'");
		return p.finish(TYPE_VEC, lv, first, elem, NONE);
	}
	NodeId len = parse_expr(p);
	p.expect(RVEC, "expected '>]'");
	return p.finish(TYPE_VEC, lv, first, elem, len);
}

<*
 `'{' (expr (',' expr)* ','? )? '}'`.

 Each argument is parsed with `parse_expr`, not `parse_type`: the real
 compiler's `parse_generic_expr_list` always calls its expression parser
 here, even for arguments that look like bare types (`List{int}`) -- the
 expression grammar is expected to accept a bare type as a primary
 expression. Mirroring that keeps this file from inventing its own
 disambiguation rule that the real grammar does not have.
*>
fn NodeId parse_generic_suffix(Parser* p, NodeId base, uint first) @local
{
	uint brace = p.advance();
	List{NodeId} kids;
	kids.tinit();
	kids.push(base);
	if (!p.at(RBRACE))
	{
		kids.push(parse_expr(p));
		while (p.match(COMMA))
		{
			if (p.at(RBRACE)) break;
			kids.push(parse_expr(p));
		}
	}
	p.expect(RBRACE, "expected '}'");
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(TYPE_GENERIC, brace, first, range[0], range[1]);
}

<*
 `FN optional_type fn_parameter_list`, the function-type grammar used only by
 `alias Foo = fn ...;` (`parse_decl.c3`'s alias handling). Not reachable from
 `parse_type` itself: the real compiler parses this special-case directly in
 its alias-declaration code, never as a general type suffix.
*>
fn NodeId parse_fn_type(Parser* p)
{
	if (!p.enter()) return p.error_node(ERROR_EXPR, p.pos);
	defer p.leave();

	uint first = p.pos;
	uint kw = p.advance(); // 'fn'
	NodeId rtype = parse_type(p);
	NodeId[] params = parse_parameters(p);

	List{NodeId} kids;
	kids.tinit();
	kids.push(rtype);
	foreach (param : params) kids.push(param);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(TYPE_FN, kw, first, range[0], range[1]);
}
