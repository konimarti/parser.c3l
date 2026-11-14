<*
 Declaration and top-level grammar.

 LANE 1C (claude). module/import/fn/macro/attrmacro/attrdef/struct/union/
 bitstruct/enum/constdef/constset/interface/typedef/alias/const/global/
 faultdef, parameter lists, attributes, generic parameters and the
 compile-time top-level constructs ($include/$expand/$assert/$echo/$error).

 Grounded in c3c's actual recursive-descent parser
 (src/compiler/parse_global.c), not just grammar.y, which disagrees with the
 shipped lexer on several token names (`EXCUSE` is `FAULTDEF` now,
 `ATTRMACRO` and `ATTRDEF` are two keywords for the same construct) and
 describes some rare constructs (operator-overload attribute arguments,
 generic module parameters) differently from how the compiler actually
 parses them. Where the two disagree, the compiler source wins.

 Deliberate simplifications (all rare constructs, documented here so they are
 easy to find later):
   - Attribute names may not carry a module-path qualifier
     (`somepkg::@attr`); only bare `@ident`/`@Type` is parsed. `ATTR`'s
     reserved qualifier child (see ast.c3) is therefore always `NONE`.
   - `$exec(...)` top-level directives are not parsed (no dedicated NodeKind
     exists for them, and grammar.y itself marks the construct "to fix").
     They fall through to `sync_decl`'s recovery.
   - `@simd` immediately after a vector type suffix is left in the token
     stream for the caller's own `opt_attributes` to pick up, rather than
     attached to the `TYPE_VEC` node, which has no spare slot for it.
*>
module c3::parser;

import c3::lexer;
import std::collections::list;

<* Parse one top-level declaration. *>
fn NodeId parse_decl(Parser* p)
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	switch (p.peek_type())
	{
		case MODULE:
			return parse_module(p);
		case IMPORT:
			return parse_import(p);
		case FUNC:
			return parse_fn(p);
		case MACRO:
			return parse_macro(p);
		case ATTRMACRO:
			return parse_attrdef(p, ATTRMACRO_DECL);
		case ATTRDEF:
			return parse_attrdef(p, ATTRDEF);
		case STRUCT:
		case UNION:
			return parse_struct_or_union(p);
		case BITSTRUCT:
			return parse_bitstruct_decl(p);
		case ENUM:
			return parse_enum_like(p, ENUM);
		case CONSTDEF:
			return parse_enum_like(p, CONSTDEF);
		case CONSTSET:
			return parse_enum_like(p, CONSTSET);
		case INTERFACE:
			return parse_interface(p);
		case TYPEDEF:
			return parse_typedef(p);
		case ALIAS:
			return parse_alias(p);
		case CONST:
			return parse_const(p);
		case FAULTDEF:
			return parse_faultdef(p);
		case CT_INCLUDE:
			return parse_ct_include(p);
		case CT_EXPAND:
			return parse_ct_expand(p);
		case CT_ASSERT:
			return parse_ct_assert(p);
		case CT_ECHO:
			return parse_ct_echo(p);
		case CT_ERROR:
			return parse_ct_error(p);
		case STATIC:
		case TLOCAL:
			return parse_global(p);
		case EXTERN:
			// `extern` prefixes a fn/const/global declaration (grammar.y's
			// top_level_decl lists `EXTERN func_definition` and
			// `EXTERN const_declaration` alongside `EXTERN
			// global_declaration`) -- only the global case is a storage
			// prefix that parse_global's own loop already consumes.
			if (p.peek_type(1) == FUNC)
			{
				p.advance();
				return parse_fn(p);
			}
			if (p.peek_type(1) == CONST)
			{
				p.advance();
				return parse_const(p);
			}
			return parse_global(p);
		default:
			if (p.at(IDENT) && p.peek().text == "excuse")
			{
				return parse_excuse(p);
			}
			if (looks_like_param_type_start(p) || p.at(IDENT))
			{
				return parse_global(p);
			}
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

// --- Recovery ---------------------------------------------------------------

<*
 Skip to just past the next `;` at this nesting level, or to the enclosing
 `}`, and return an ERROR_DECL node spanning everything skipped.

 `Parser.sync_decl` is the wrong tool inside a struct/enum/interface body: it
 hunts for the next top-level-decl keyword and does not stop at a `}` at its
 own depth, so it can run past the end of the body it was called from. This
 is `Parser.sync_stmt`'s logic with an ERROR_DECL result, for decl-shaped
 nesting instead of statement-shaped nesting.
*>
fn NodeId sync_member(Parser* p) @local
{
	uint first = p.pos;
	int depth = 0;
	while (!p.at_end())
	{
		switch (p.peek_type())
		{
			case LBRACE:
				depth++;
			case RBRACE:
				if (depth == 0) return p.error_node(ERROR_DECL, first);
				depth--;
			case EOS:
				if (depth == 0)
				{
					p.advance();
					return p.error_node(ERROR_DECL, first);
				}
			default:
				break;
		}
		p.advance();
	}
	return p.error_node(ERROR_DECL, first);
}

<*
 Consume a required name token of kind `t` and return its index; on failure
 (already reported by `Parser.expect`), return `fallback` instead of the
 un-consumed token's position.

 Using the un-consumed token as a node's `tok` is unsafe: if nothing later
 in the same declaration advances the cursor either (common on malformed
 input, since the missing name usually means everything after it fails to
 match too), the node's span freezes at or before that position while
 `tok` points past it -- `tok` escaping the node's own `[first_tok,
 last_tok]` range, which is exactly what docs/DESIGN.md section 6's first
 invariant forbids. `fallback` must be a token already known to be
 consumed -- the construct's own opening keyword, almost always.
*>
fn uint expect_name(Parser* p, TokenType t, String what, uint fallback) @local
{
	uint tok = p.pos;
	if (p.expect(t, what)) return tok;
	return fallback;
}

// --- Attributes --------------------------------------------------------------

<*
 `generic_decl? attribute_list?`: the real compiler's `parse_attributes_for_global`
 parses an optional `<Type, CONST, ...>` declaration-site generic parameter
 list (for a generic `struct`/`fn`/etc., e.g. `struct Foo <Type> { ... }`,
 `fn void Foo.bar <Type> (...)`) immediately before the `@`-attribute list,
 for every declaration kind that can be generic -- so every caller of this
 function picks it up for free, same as the real parser's call sites all
 funnel through one function. Result entries are told apart by kind: a
 generic parameter is `IDENT`, an attribute is `ATTR`.
*>
fn NodeId[] parse_attributes(Parser* p)
{
	List{NodeId} attrs;
	attrs.tinit();
	foreach (g : parse_generic_decl_params(p)) attrs.push(g);
	while (p.at(AT_IDENT) || p.at(AT_TYPE_IDENT))
	{
		attrs.push(parse_attribute(p));
	}
	return attrs.to_tarray();
}

<* `'<' (TYPE_IDENT|CONST_IDENT) (',' ...)* '>'`: a generic declaration's parameters. *>
fn NodeId[] parse_generic_decl_params(Parser* p) @local
{
	List{NodeId} out;
	out.tinit();
	if (!p.match(LESS)) return out.to_tarray();
	while (true)
	{
		uint first = p.pos;
		if (p.at(TYPE_IDENT) || p.at(CONST_IDENT))
		{
			out.push(p.finish(IDENT, p.advance(), first));
		}
		else
		{
			p.error("expected a generic parameter");
			break;
		}
		if (!p.match(COMMA)) break;
	}
	p.expect(GREATER, "expected '>'");
	return out.to_tarray();
}

<* One `@foo` or `@Foo(arg, ...)`. *>
fn NodeId parse_attribute(Parser* p) @local
{
	if (!p.enter()) return sync_member(p);
	defer p.leave();

	uint first = p.pos;
	uint name = p.advance();

	List{NodeId} kids;
	kids.tinit();
	kids.push(NONE); // reserved qualifier slot; see the module doc above.
	if (p.match(LPAREN))
	{
		if (!p.at(RPAREN))
		{
			kids.push(parse_attribute_arg(p));
			while (p.match(COMMA))
			{
				if (p.at(RPAREN)) break;
				kids.push(parse_attribute_arg(p));
			}
		}
		p.expect(RPAREN, "expected ')'");
	}
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(ATTR, name, first, range[0], range[1]);
}

<*
 One attribute argument: a `constant_expr`, or an operator-overload token
 sequence (`@operator(+)`, `@operator([])`, `@operator(&[])`,
 `@operator([]=)`). The operator forms are punctuation, not expressions --
 docs/DESIGN.md section 6 exempts punctuation from the content invariant --
 so they are consumed without a node rather than invented a leaf kind for.
*>
fn NodeId parse_attribute_arg(Parser* p) @local
{
	switch (p.peek_type())
	{
		case PLUS:
		case MINUS:
		case STAR:
		case DIV:
		case MOD:
		case BIT_NOT:
		case BIT_OR:
		case BIT_XOR:
		case SHL_OP:
		case SHR_OP:
		case EQEQ:
		case LESS:
		case BIT_AND_ASSIGN:
		case BIT_OR_ASSIGN:
		case BIT_XOR_ASSIGN:
		case PLUS_ASSIGN:
		case MINUS_ASSIGN:
		case MULT_ASSIGN:
		case DIV_ASSIGN:
		case MOD_ASSIGN:
		case SHL_ASSIGN:
		case SHR_ASSIGN:
			p.advance();
			return NONE;
		case AMP:
			p.advance();
			if (p.match(LBRACKET)) p.match(RBRACKET);
			return NONE;
		case LBRACKET:
			p.advance();
			p.match(RBRACKET);
			p.match(EQ);
			return NONE;
		default:
			return parse_expr(p);
	}
}

<* `'(' type (',' type)* ')'`, or nothing: `opt_interface_impl`. *>
fn NodeId[] parse_interface_impl_list(Parser* p) @local
{
	List{NodeId} out;
	out.tinit();
	if (!p.match(LPAREN)) return out.to_tarray();
	while (!p.at(RPAREN) && !p.at_end())
	{
		out.push(parse_type(p));
		if (!p.match(COMMA)) break;
	}
	p.expect(RPAREN, "expected ')'");
	return out.to_tarray();
}

// --- Parameters ---------------------------------------------------------------

<* True when the cursor starts a parameter's type, per the real parser's `parse_next_is_typed_parameter`. *>
fn bool looks_like_param_type_start(Parser* p) @local
{
	TokenType t = p.peek_type();
	if (is_base_type(t)) return true;
	if (t == TYPE_IDENT || t == CT_TYPEOF || t == CT_TYPEFROM) return true;
	if (t == IDENT) return looks_like_qualified_type_path(p);
	return false;
}

<*
 True when the cursor starts a `foo::bar::Type` qualified type path --
 i.e. one or more `IDENT '::'` segments followed by a `TYPE_IDENT`.

 A single token of lookahead (just checking for `IDENT` then `SCOPE`) is
 not enough: `env::X86_64` and `env::SomeType` both start that way, but
 only the second is a type -- the first is a qualified *constant*
 (`env::X86_64 ? uint : CUInt`, a real alias target in the corpus) and
 must fall through to `parse_expr` instead. Walk the whole path with
 lookahead, consuming nothing, and check what the final segment actually
 is.
*>
fn bool looks_like_qualified_type_path(Parser* p) @local
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

<*
 Like `looks_like_param_type_start`, but also accepts `$Type` (relevant
 wherever a bare compile-time type placeholder can stand for a whole type,
 e.g. `alias Foo = $Type;`, which parameter position never allows).
*>
fn bool looks_like_type_start(Parser* p) @local
{
	return looks_like_param_type_start(p) || p.at(CT_TYPE_IDENT);
}

<* One parameter: `type? ('...' | IDENT | '&' IDENT | '#'IDENT | $ident | $Type)? opt_attributes ('=' (expr|type))?`. *>
fn NodeId parse_param(Parser* p) @local
{
	if (!p.enter()) return sync_member(p);
	defer p.leave();

	uint first = p.pos;
	bool ellipsis = false;
	NodeId type = NONE;

	if (p.at(ELLIPSIS))
	{
		p.advance();
		ellipsis = true;
	}
	else if (looks_like_param_type_start(p))
	{
		type = parse_type(p);
		if (p.match(ELLIPSIS)) ellipsis = true;
	}

	uint tok = p.pos;
	TokenType name_type = INVALID;
	bool has_name = false;

	if (p.at(CT_IDENT) || p.at(HASH_IDENT) || p.at(CT_TYPE_IDENT))
	{
		name_type = p.peek_type();
		tok = p.advance();
		has_name = true;
	}
	else if (p.at(IDENT))
	{
		name_type = IDENT;
		tok = p.advance();
		has_name = true;
		if (p.match(ELLIPSIS)) ellipsis = true;
	}
	else if (p.match(AMP))
	{
		tok = p.pos;
		if (p.at(IDENT))
		{
			name_type = IDENT;
			tok = p.advance();
			has_name = true;
		}
		else
		{
			p.error("expected a parameter name after '&'");
		}
	}
	else
	{
		// A bare type, or a bare "...": no name token of its own.
		tok = type != NONE ? p.ast.node(type).tok : first;
	}

	NodeId[] attrs = parse_attributes(p);

	NodeId default_val = NONE;
	if (has_name && p.match(EQ))
	{
		if (p.match(ELLIPSIS))
		{
			// Macro "...=..." no-init marker: punctuation only.
		}
		else if (name_type == CT_TYPE_IDENT)
		{
			default_val = parse_type(p);
		}
		else
		{
			default_val = parse_expr(p);
		}
	}

	List{NodeId} kids;
	kids.tinit();
	kids.push(type);
	kids.push(default_val);
	foreach (a : attrs) kids.push(a);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(PARAM, tok, first, range[0], range[1]);
}

<* `'(' parameters ')'`: a plain function/attrdef/fn-type parameter list. *>
fn NodeId[] parse_parameters(Parser* p)
{
	if (!p.expect(LPAREN, "expected '('"))
	{
		List{NodeId} empty;
		empty.tinit();
		return empty.to_tarray();
	}
	NodeId[] params = parse_param_list(p);
	p.expect(RPAREN, "expected ')'");
	return params;
}

<*
 The bare comma-separated parameter list, without the surrounding parens --
 shared with `parse_expr.c3`'s call-argument grammar: `call_arg_list ::=
 opt_arg_list (';' parameters)?` lets a call site declare typed block
 parameters for a trailing macro body, e.g.
 `@loop_over_addresses(ai; NativeSocket sockfd, AddrInfo* ai_candidate) { ... }`
 in lib/std/net/tcp.c3. The caller owns the parens (or the `;` and `)` that
 bound this list in the call-argument case); this just parses `parameters`.
*>
fn NodeId[] parse_param_list(Parser* p)
{
	List{NodeId} out;
	out.tinit();
	while (!p.at(RPAREN) && !p.at(EOS) && !p.at_end())
	{
		uint before = p.pos;
		out.push(parse_param(p));
		if (p.pos == before) p.advance();
		if (!p.match(COMMA)) break;
	}
	return out.to_tarray();
}

<*
 A macro's parameter list: regular parameters, then optionally `;` followed
 by a trailing block parameter (`@body` or `@body(params...)`). The block
 param (if any) is appended as one more `PARAM`-shaped entry whose `tok` is
 the `AT_IDENT`; its own nested parameters (if parenthesised) are appended
 straight after it, flattened into the same list. See `SIGNATURE`'s row in
 ast.c3 for how a consumer tells these apart from regular parameters.
*>
fn NodeId[] parse_macro_parameters(Parser* p) @local
{
	List{NodeId} out;
	out.tinit();
	if (!p.expect(LPAREN, "expected '('")) return out.to_tarray();
	while (!p.at(RPAREN) && !p.at(EOS) && !p.at_end())
	{
		uint before = p.pos;
		out.push(parse_param(p));
		if (p.pos == before) p.advance();
		if (!p.match(COMMA)) break;
	}
	if (p.match(EOS))
	{
		uint bfirst = p.pos;
		if (p.at(AT_IDENT))
		{
			uint name = p.advance();
			out.push(p.finish(PARAM, name, bfirst));
			if (p.match(LPAREN))
			{
				while (!p.at(RPAREN) && !p.at_end())
				{
					uint before2 = p.pos;
					out.push(parse_param(p));
					if (p.pos == before2) p.advance();
					if (!p.match(COMMA)) break;
				}
				p.expect(RPAREN, "expected ')'");
			}
		}
		else
		{
			p.error("expected a trailing block parameter");
		}
	}
	p.expect(RPAREN, "expected ')'");
	return out.to_tarray();
}

// --- module / import -----------------------------------------------------------

<* `module_path generic_decl? opt_attributes ';'`: the generic params (if any) and attrs both come from `parse_attributes`. *>
fn NodeId parse_module(Parser* p) @local
{
	uint first = p.pos;
	uint kw = p.advance();
	NodeId path = parse_module_path(p);
	NodeId[] rest = parse_attributes(p);
	p.expect(EOS, "expected ';'");

	List{NodeId} kids;
	kids.tinit();
	kids.push(path);
	foreach (r : rest) kids.push(r);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(MODULE, kw, first, range[0], range[1]);
}

fn NodeId parse_import(Parser* p) @local
{
	uint first = p.pos;
	uint kw = p.advance();
	List{NodeId} kids;
	kids.tinit();
	while (true)
	{
		kids.push(parse_module_path(p));
		NodeId[] attrs = parse_attributes(p);
		foreach (a : attrs) kids.push(a);
		if (!p.match(COMMA)) break;
	}
	p.expect(EOS, "expected ';'");
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(IMPORT, kw, first, range[0], range[1]);
}

// --- fn / macro ----------------------------------------------------------------

<* The three pieces of a `func_header`/`macro_header`: return type, method receiver type, name token. *>
struct FuncHeader
{
	NodeId rtype;
	NodeId method_type;
	uint   name;
}

<* True when the cursor is shaped like a function/macro name, not a type. *>
fn bool looks_like_func_name(Parser* p, bool allow_at_ident) @local
{
	if (p.at(IDENT) && p.peek_type(1) != SCOPE) return true;
	if (allow_at_ident && p.at(AT_IDENT)) return true;
	return false;
}

<* True for tokens that cannot start a method-receiver type in this position. *>
fn bool blocks_method_type(TokenType t) @local
{
	switch (t)
	{
		case IDENT:
		case AT_IDENT:
		case TYPE_IDENT:
		case CT_TYPE_IDENT:
		case CT_TYPEOF:
		case CT_TYPEFROM:
			return false;
		default:
			return !is_base_type(t);
	}
}

<*
 `optional_type (type '.')? IDENT` for `fn`, or
 `optional_type? (type '.')? (IDENT|AT_IDENT)` for `macro`.
*>
fn FuncHeader parse_func_macro_header(Parser* p, bool is_macro) @local
{
	uint first = p.pos;
	FuncHeader h = { .rtype = NONE, .method_type = NONE, .name = first };

	if (!(is_macro && looks_like_func_name(p, true)))
	{
		h.rtype = parse_type(p);
		if (!p.at(DOT) && !looks_like_func_name(p, is_macro) && !blocks_method_type(p.peek_type()))
		{
			h.method_type = parse_type(p);
		}
		if (p.match(DOT) && h.method_type == NONE)
		{
			h.method_type = h.rtype;
			h.rtype = NONE;
		}
	}

	// `expect_name`-style fallback: a missing name must not leave `h.name`
	// pointing at an un-consumed token. `first` is always already behind
	// the cursor here (the header's own start, consumed via `parse_type`
	// in every path except the bare-macro-name shortcut above, which
	// never reaches this point with the cursor still at `first`).
	if (p.at(IDENT) || (is_macro && p.at(AT_IDENT)))
	{
		h.name = p.advance();
	}
	else
	{
		p.error(is_macro ? "expected a macro name" : "expected a function name");
		h.name = first;
	}
	return h;
}

<* `implies_body ';' | compound_statement | ';'`: shared by `fn` and `macro`. *>
fn NodeId parse_func_or_macro_body(Parser* p) @local
{
	if (p.match(IMPLIES))
	{
		NodeId value = parse_expr(p);
		// A short body whose expression is itself a call with a trailing
		// block (`=> @pool() { ... }`) is already terminated by that `}`;
		// the real compiler discards the ';' in exactly that case. Rather
		// than reach into lane 1A's CALL shape to detect it, just make the
		// ';' optional here -- permissive on malformed input either way.
		p.match(EOS);
		return value;
	}
	if (p.at(LBRACE)) return parse_block(p);
	p.match(EOS);
	return NONE;
}

fn NodeId build_signature(Parser* p, uint tok, uint first, FuncHeader h, NodeId[] params, NodeId[] attrs) @local
{
	List{NodeId} kids;
	kids.tinit();
	kids.push(h.rtype);
	kids.push(h.method_type);
	foreach (param : params) kids.push(param);
	foreach (a : attrs) kids.push(a);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(SIGNATURE, tok, first, range[0], range[1]);
}

<* A `fn` declaration or definition; also used for interface method signatures. *>
fn NodeId parse_fn(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	uint kw = p.advance();
	FuncHeader h = parse_func_macro_header(p, false);
	NodeId[] params = parse_parameters(p);
	NodeId[] attrs = parse_attributes(p);
	NodeId sig = build_signature(p, kw, first, h, params, attrs);

	NodeId body = parse_func_or_macro_body(p);
	return p.finish(FN_DECL, h.name, first, sig, body);
}

fn NodeId parse_macro(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	uint kw = p.advance();
	FuncHeader h = parse_func_macro_header(p, true);
	NodeId[] params = parse_macro_parameters(p);
	NodeId[] attrs = parse_attributes(p);
	NodeId sig = build_signature(p, kw, first, h, params, attrs);

	NodeId body = parse_func_or_macro_body(p);
	return p.finish(MACRO_DECL, h.name, first, sig, body);
}

// --- attrdef / attrmacro ---------------------------------------------------------

fn NodeId parse_attrdef(Parser* p, NodeKind kind) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	p.advance();
	uint name = expect_name(p, AT_TYPE_IDENT, "expected an attribute type name, like '@MyAttr'", first);

	List{NodeId} kids;
	kids.tinit();
	if (p.match(LPAREN))
	{
		if (!p.at(RPAREN))
		{
			kids.push(parse_param(p));
			while (p.match(COMMA))
			{
				if (p.at(RPAREN)) break;
				kids.push(parse_param(p));
			}
		}
		p.expect(RPAREN, "expected ')'");
	}
	NodeId[] own_attrs = parse_attributes(p);
	foreach (a : own_attrs) kids.push(a);

	if (!p.match(EOS))
	{
		p.expect(EQ, "expected '='");
		if (!p.at(EOS))
		{
			kids.push(parse_attribute(p));
			while (p.match(COMMA))
			{
				if (!(p.at(AT_IDENT) || p.at(AT_TYPE_IDENT))) break;
				kids.push(parse_attribute(p));
			}
		}
		p.expect(EOS, "expected ';'");
	}

	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(kind, name, first, range[0], range[1]);
}

// --- struct / union / bitstruct ---------------------------------------------------

fn NodeId parse_struct_or_union(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	NodeKind kind = p.at(STRUCT) ? STRUCT_DECL : UNION_DECL;
	p.advance();
	uint name = expect_name(p, TYPE_IDENT, "expected a type name", first);
	NodeId[] interfaces = parse_interface_impl_list(p);
	NodeId[] attrs = parse_attributes(p);
	NodeId[] members = parse_struct_body(p);

	List{NodeId} kids;
	kids.tinit();
	foreach (i : interfaces) kids.push(i);
	foreach (a : attrs) kids.push(a);
	foreach (m : members) kids.push(m);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(kind, name, first, range[0], range[1]);
}

fn NodeId[] parse_struct_body(Parser* p) @local
{
	List{NodeId} out;
	out.tinit();
	if (!p.expect(LBRACE, "expected '{'")) return out.to_tarray();
	while (!p.at(RBRACE) && !p.at_end())
	{
		uint before = p.pos;
		NodeId[] produced = parse_struct_member(p);
		foreach (n : produced) out.push(n);
		if (p.pos == before) p.advance();
	}
	p.expect(RBRACE, "expected '}'");
	return out.to_tarray();
}

<*
 One struct/union member declaration. Usually several sibling `MEMBER`s
 (`int x, y, z;` shares one type across three names), occasionally one
 nested anonymous STRUCT_DECL/UNION_DECL/BITSTRUCT_DECL -- hence the array
 return, flattened by `parse_struct_body`.
*>
fn NodeId[] parse_struct_member(Parser* p) @local
{
	if (!p.enter())
	{
		List{NodeId} err;
		err.tinit();
		err.push(sync_member(p));
		return err.to_tarray();
	}
	defer p.leave();

	uint first = p.pos;
	List{NodeId} out;
	out.tinit();

	if (p.at(STRUCT) || p.at(UNION))
	{
		NodeKind kind = p.at(STRUCT) ? STRUCT_DECL : UNION_DECL;
		p.advance();
		bool has_name = p.at(IDENT);
		uint name_tok = has_name ? p.advance() : first;
		NodeId[] attrs = parse_attributes(p);
		NodeId[] members = parse_struct_body(p);
		List{NodeId} kids;
		kids.tinit();
		foreach (a : attrs) kids.push(a);
		foreach (m : members) kids.push(m);
		NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
		out.push(p.finish(kind, name_tok, first, range[0], range[1]));
		return out.to_tarray();
	}

	if (p.at(BITSTRUCT))
	{
		p.advance();
		bool has_name = p.at(IDENT);
		uint name_tok = has_name ? p.advance() : first;
		p.expect(COLON, "expected ':' followed by a bitstruct type");
		NodeId container = parse_type_no_generic(p);
		NodeId[] attrs = parse_attributes(p);
		NodeId[] fields = parse_bitstruct_body(p);
		List{NodeId} kids;
		kids.tinit();
		kids.push(container);
		foreach (a : attrs) kids.push(a);
		foreach (f : fields) kids.push(f);
		NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
		out.push(p.finish(BITSTRUCT_DECL, name_tok, first, range[0], range[1]));
		return out.to_tarray();
	}

	p.match(INLINE);
	NodeId type = parse_type(p);
	while (true)
	{
		uint name_tok = p.pos;
		if (!p.expect(IDENT, "expected a member name"))
		{
			out.push(sync_member(p));
			return out.to_tarray();
		}
		NodeId[] attrs = parse_attributes(p);
		List{NodeId} kids;
		kids.tinit();
		kids.push(type);
		foreach (a : attrs) kids.push(a);
		NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
		out.push(p.finish(MEMBER, name_tok, first, range[0], range[1]));
		if (!p.match(COMMA)) break;
	}
	p.expect(EOS, "expected ';'");
	return out.to_tarray();
}

fn NodeId parse_bitstruct_decl(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	p.advance();
	uint name = expect_name(p, TYPE_IDENT, "expected a type name", first);
	NodeId[] interfaces = parse_interface_impl_list(p);
	p.expect(COLON, "expected ':' followed by a bitstruct type");
	NodeId container = parse_type_no_generic(p);
	NodeId[] attrs = parse_attributes(p);
	NodeId[] fields = parse_bitstruct_body(p);

	List{NodeId} kids;
	kids.tinit();
	foreach (i : interfaces) kids.push(i);
	kids.push(container);
	foreach (a : attrs) kids.push(a);
	foreach (f : fields) kids.push(f);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(BITSTRUCT_DECL, name, first, range[0], range[1]);
}

fn NodeId[] parse_bitstruct_body(Parser* p) @local
{
	List{NodeId} out;
	out.tinit();
	if (!p.expect(LBRACE, "expected '{'")) return out.to_tarray();
	while (!p.at(RBRACE) && !p.at_end())
	{
		uint before = p.pos;
		out.push(parse_bitstruct_field(p));
		if (p.pos == before) p.advance();
	}
	p.expect(RBRACE, "expected '}'");
	return out.to_tarray();
}

<* `base_type IDENT (':' constant_expr ('..' constant_expr)?)? opt_attributes ';'`. *>
fn NodeId parse_bitstruct_field(Parser* p) @local
{
	if (!p.enter()) return sync_member(p);
	defer p.leave();

	uint first = p.pos;
	NodeId type = parse_base_type(p, first);
	uint name = p.pos;
	if (!p.expect(IDENT, "expected a field name")) return sync_member(p);

	NodeId start = NONE;
	NodeId end = NONE;
	if (p.match(COLON))
	{
		start = parse_expr(p);
		if (p.match(DOTDOT))
		{
			end = parse_expr(p);
		}
	}
	NodeId[] attrs = parse_attributes(p);
	p.expect(EOS, "expected ';'");

	List{NodeId} kids;
	kids.tinit();
	kids.push(type);
	kids.push(start);
	kids.push(end);
	foreach (a : attrs) kids.push(a);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(MEMBER, name, first, range[0], range[1]);
}

// --- enum / constdef / constset ---------------------------------------------------

<* `enum_param_decl`: one `(type IDENT opt_attributes)` associated-value declaration. Reuses PARAM. *>
fn NodeId parse_enum_param(Parser* p) @local
{
	if (!p.enter()) return sync_member(p);
	defer p.leave();

	uint first = p.pos;
	NodeId type = parse_type(p);
	uint name = expect_name(p, IDENT, "expected a parameter name", first);
	NodeId[] attrs = parse_attributes(p);

	List{NodeId} kids;
	kids.tinit();
	kids.push(type);
	kids.push(NONE);
	foreach (a : attrs) kids.push(a);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(PARAM, name, first, range[0], range[1]);
}

<* `enum_spec`: `':' ('inline'|'const' 'inline'?)? base_type opt_enum_params` or `':' '(' enum_params ')'`. *>
fn NodeId[] parse_enum_params(Parser* p) @local
{
	List{NodeId} out;
	out.tinit();
	if (!p.match(LPAREN)) return out.to_tarray();
	while (!p.at(RPAREN) && !p.at_end())
	{
		out.push(parse_enum_param(p));
		if (!p.match(COMMA)) break;
	}
	p.expect(RPAREN, "expected ')'");
	return out.to_tarray();
}

<*
 `CONST_IDENT opt_attributes ('{' arg_list '}')?` for a plain `enum`, or
 `CONST_IDENT opt_attributes ('=' constant_expr)?` for `constdef`/`constset`
 -- the two share a NodeKind (`ENUM_CONST`) but not a value grammar; see
 the real compiler's `parse_enum_values`.
*>
fn NodeId parse_enum_constant(Parser* p, bool is_constset) @local
{
	if (!p.enter()) return sync_member(p);
	defer p.leave();

	uint first = p.pos;
	uint name = expect_name(p, CONST_IDENT, "expected a constant name", first);
	NodeId[] attrs = parse_attributes(p);

	List{NodeId} kids;
	kids.tinit();
	foreach (a : attrs) kids.push(a);
	if (is_constset)
	{
		if (p.match(EQ)) kids.push(parse_expr(p));
	}
	else if (p.match(LBRACE))
	{
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
	}
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(ENUM_CONST, name, first, range[0], range[1]);
}

<* Shared by `enum`, `constdef` and `constset`: all three share the real compiler's `parse_enum_declaration`. *>
fn NodeId parse_enum_like(Parser* p, TokenType keyword) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	p.advance();
	uint name = expect_name(p, TYPE_IDENT, "expected a type name", first);
	NodeId[] interfaces = parse_interface_impl_list(p);

	NodeId[] params = {};
	if (p.match(COLON))
	{
		if (!p.at(LPAREN))
		{
			p.match(INLINE);
			p.match(CONST);
			parse_type_no_generic(p); // underlying type: not retained, no slot (rare to need it)
		}
		if (keyword == ENUM) params = parse_enum_params(p);
	}
	NodeId[] attrs = parse_attributes(p);

	List{NodeId} kids;
	kids.tinit();
	foreach (i : interfaces) kids.push(i);
	foreach (a : attrs) kids.push(a);
	foreach (prm : params) kids.push(prm);

	if (!p.expect(LBRACE, "expected '{'"))
	{
		NodeId[<2>] range0 = p.ast.add_children(kids.to_tarray());
		return p.finish(decl_kind_for(keyword), name, first, range0[0], range0[1]);
	}
	bool is_constset = keyword == CONSTDEF || keyword == CONSTSET;
	while (!p.at(RBRACE) && !p.at_end())
	{
		uint before = p.pos;
		kids.push(parse_enum_constant(p, is_constset));
		if (p.pos == before) p.advance();
		if (!p.match(COMMA)) break;
	}
	p.expect(RBRACE, "expected '}'");

	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(decl_kind_for(keyword), name, first, range[0], range[1]);
}

fn NodeKind decl_kind_for(TokenType keyword) @local
{
	switch (keyword)
	{
		case CONSTDEF: return CONSTDEF;
		case CONSTSET: return CONSTSET;
		default: return ENUM_DECL;
	}
}

// --- interface -----------------------------------------------------------------

fn NodeId parse_interface(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	p.advance();
	uint name = expect_name(p, TYPE_IDENT, "expected a type name", first);

	List{NodeId} kids;
	kids.tinit();
	if (p.match(COLON))
	{
		while (true)
		{
			kids.push(parse_type_no_generic(p));
			if (!p.match(COMMA)) break;
		}
	}
	NodeId[] attrs = parse_attributes(p);
	foreach (a : attrs) kids.push(a);

	if (!p.expect(LBRACE, "expected '{'"))
	{
		NodeId[<2>] range0 = p.ast.add_children(kids.to_tarray());
		return p.finish(INTERFACE_DECL, name, first, range0[0], range0[1]);
	}
	while (!p.at(RBRACE) && !p.at_end())
	{
		uint before = p.pos;
		if (p.at(FUNC))
		{
			kids.push(parse_fn(p));
		}
		else
		{
			p.error("interfaces may only have function declarations");
			kids.push(sync_member(p));
		}
		if (p.pos == before) p.advance();
	}
	p.expect(RBRACE, "expected '}'");

	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(INTERFACE_DECL, name, first, range[0], range[1]);
}

// --- typedef / alias -------------------------------------------------------------

fn NodeId parse_typedef(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	p.advance();
	uint name = expect_name(p, TYPE_IDENT, "expected a type name", first);
	NodeId[] interfaces = parse_interface_impl_list(p);
	NodeId[] attrs = parse_attributes(p);
	p.expect(EQ, "expected '='");
	p.match(INLINE);
	NodeId target = parse_type(p);
	while (p.at(AT_IDENT)) p.advance(); // '@align(...)' and similar: no dedicated slot
	p.expect(EOS, "expected ';'");

	List{NodeId} kids;
	kids.tinit();
	kids.push(target);
	foreach (i : interfaces) kids.push(i);
	foreach (a : attrs) kids.push(a);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(TYPEDEF_DECL, name, first, range[0], range[1]);
}

<*
 `ALIAS alias_ident ';'` or `ALIAS TYPE_IDENT opt_attributes '=' (type|func_typedef) opt_attributes ';'`.

 grammar.y calls the non-`fn` alternative `type`, but the REAL compiler's
 `parse_alias_type` always calls `parse_expr` for it instead -- e.g.
 `alias ListType = IS_SLICE ??? Type : Type*;` (a `???` compile-time
 ternary) and `alias EnumSetType = type_for_enum_elements(ENUM_COUNT);`
 (a call) are both common in the corpus, and neither is a `type`
 production at all. But always using `parse_expr` is worse in practice:
 lane 1A's expression grammar does not yet accept a bare type name with a
 `*` or `{...}` postfix as a primary expression, and `alias X = Y*;` /
 `alias X = Y{Z};` are far more common than the expression-only forms.
 So: dispatch on whether the RHS *looks* type-shaped
 (`looks_like_type_start`) and call `parse_type` only then, `parse_expr`
 otherwise. This loses nothing `parse_type` alone could do and gains the
 call/ternary/other-expression cases that lane 1A already supports
 structurally (CALL, qualified paths) -- it only still fails on `???`,
 which lane 1A hasn't implemented yet either way.
*>
fn NodeId parse_alias(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	p.advance();

	if (p.at(TYPE_IDENT))
	{
		uint name = p.advance();
		NodeId[] own_attrs = parse_attributes(p);
		p.expect(EQ, "expected '='");
		NodeId value;
		if (p.at(FUNC))
		{
			value = parse_fn_type(p);
		}
		else if (looks_like_type_start(p))
		{
			value = parse_type(p);
		}
		else
		{
			value = parse_expr(p);
		}
		NodeId[] tail_attrs = parse_attributes(p);
		p.expect(EOS, "expected ';'");

		List{NodeId} kids;
		kids.tinit();
		kids.push(value);
		foreach (a : own_attrs) kids.push(a);
		foreach (a : tail_attrs) kids.push(a);
		NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
		return p.finish(ALIAS_DECL, name, first, range[0], range[1]);
	}

	uint name = p.pos;
	NodeId value = NONE;
	if (p.at(IDENT) || p.at(CONST_IDENT) || p.at(AT_IDENT))
	{
		p.advance();
		NodeId[] attrs0 = parse_attributes(p);
		p.expect(EQ, "expected '='");
		if (p.at(MODULE))
		{
			p.advance();
			value = parse_module_path(p);
		}
		else
		{
			value = parse_expr(p);
		}
		p.expect(EOS, "expected ';'");

		List{NodeId} kids;
		kids.tinit();
		kids.push(value);
		foreach (a : attrs0) kids.push(a);
		NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
		return p.finish(ALIAS_DECL, name, first, range[0], range[1]);
	}

	p.error("expected a name to alias");
	return p.sync_decl();
}

// --- const / global --------------------------------------------------------------

<* `CONST (CONST_IDENT | optional_type CONST_IDENT) opt_attributes ('=' expr)? ';'`. *>
fn NodeId parse_const(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	p.advance();

	NodeId type = NONE;
	if (!p.at(CONST_IDENT)) type = parse_type(p);
	uint name = expect_name(p, CONST_IDENT, "expected a constant name", first);
	NodeId[] attrs = parse_attributes(p);

	NodeId init = NONE;
	if (p.match(EQ)) init = parse_expr(p);
	p.expect(EOS, "expected ';'");

	List{NodeId} kids;
	kids.tinit();
	kids.push(type);
	kids.push(init);
	foreach (a : attrs) kids.push(a);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(CONST_DECL, name, first, range[0], range[1]);
}

<*
 `(static|tlocal|extern)? optional_type IDENT ((',' IDENT)* | ('=' expr)?) opt_attributes ';'`.
*>
fn NodeId parse_global(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	while (p.at(STATIC) || p.at(EXTERN) || p.at(TLOCAL)) p.advance();

	NodeId type = parse_type(p);
	uint name1 = p.pos;
	bool has_name1 = p.expect(IDENT, "expected a variable name");

	List{NodeId} names;
	names.tinit();
	if (has_name1) names.push(p.finish(IDENT, name1, name1));
	if (!has_name1) name1 = first;

	NodeId init = NONE;
	if (p.match(EQ))
	{
		init = parse_expr(p);
	}
	else
	{
		while (p.match(COMMA))
		{
			uint ntok = p.pos;
			if (!p.expect(IDENT, "expected a variable name")) break;
			names.push(p.finish(IDENT, ntok, ntok));
		}
	}
	NodeId[] attrs = parse_attributes(p);
	p.expect(EOS, "expected ';'");

	List{NodeId} kids;
	kids.tinit();
	kids.push(type);
	kids.push(init);
	foreach (n : names.to_tarray()) kids.push(n);
	foreach (a : attrs) kids.push(a);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(GLOBAL_DECL, name1, first, range[0], range[1]);
}

// --- faultdef --------------------------------------------------------------------

<* `FAULTDEF CONST_IDENT opt_attributes (',' CONST_IDENT opt_attributes)* ','? ';'`. *>
fn NodeId parse_faultdef(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	p.advance();

	List{NodeId} kids;
	kids.tinit();
	while (!p.at(EOS) && !p.at_end())
	{
		uint ntok = p.pos;
		if (!p.expect(CONST_IDENT, "expected a fault name")) break;
		kids.push(p.finish(IDENT, ntok, ntok));
		NodeId[] attrs = parse_attributes(p);
		foreach (a : attrs) kids.push(a);
		if (!p.match(COMMA)) break;
	}
	p.expect(EOS, "expected ';'");

	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(FAULTDEF, first, first, range[0], range[1]);
}

<*
 The legacy `excuse` spelling of `faultdef`: `excuse CONST_IDENT opt_attributes
 (',' ...)* ';'` or `excuse '{' CONST_IDENT opt_attributes (',' ...)* '}'`.
 `excuse` is a soft keyword (a plain `IDENT` whose text happens to be
 "excuse"), not its own `TokenType`, matching how the real compiler
 recognizes it -- see `parse_decl`'s dispatcher. Reuses the `FAULTDEF`
 NodeKind: same construct, just an older spelling.
*>
fn NodeId parse_excuse(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	p.advance();
	bool braced = p.match(LBRACE);

	List{NodeId} kids;
	kids.tinit();
	while (!p.at(EOS) && !p.at(RBRACE) && !p.at_end())
	{
		uint ntok = p.pos;
		if (!p.expect(CONST_IDENT, "expected a fault name")) break;
		kids.push(p.finish(IDENT, ntok, ntok));
		NodeId[] attrs = parse_attributes(p);
		foreach (a : attrs) kids.push(a);
		if (!p.match(COMMA)) break;
	}
	if (braced)
	{
		p.expect(RBRACE, "expected '}'");
	}
	else
	{
		p.expect(EOS, "expected ';'");
	}

	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(FAULTDEF, first, first, range[0], range[1]);
}

// --- top-level compile-time directives --------------------------------------------

fn NodeId parse_ct_include(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	uint kw = p.advance();
	NodeId filename = parse_expr(p);
	NodeId[] attrs = parse_attributes(p);
	p.expect(EOS, "expected ';'");

	List{NodeId} kids;
	kids.tinit();
	kids.push(filename);
	foreach (a : attrs) kids.push(a);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(CT_INCLUDE, kw, first, range[0], range[1]);
}

fn NodeId parse_ct_expand(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	uint kw = p.advance();
	p.expect(LPAREN, "expected '('");
	NodeId value = parse_expr(p);
	p.expect(RPAREN, "expected ')'");
	NodeId[] attrs = parse_attributes(p);
	p.expect(EOS, "expected ';'");

	List{NodeId} kids;
	kids.tinit();
	kids.push(value);
	foreach (a : attrs) kids.push(a);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(CT_EXPAND, kw, first, range[0], range[1]);
}

fn NodeId parse_ct_assert(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	uint kw = p.advance();
	NodeId cond = parse_expr(p);
	NodeId message = NONE;
	List{NodeId} extra;
	extra.tinit();
	if (p.match(COLON))
	{
		message = parse_expr(p);
		while (p.match(COMMA)) extra.push(parse_expr(p));
	}
	p.expect(EOS, "expected ';'");

	List{NodeId} kids;
	kids.tinit();
	kids.push(cond);
	kids.push(message);
	foreach (e : extra.to_tarray()) kids.push(e);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(CT_ASSERT_DECL, kw, first, range[0], range[1]);
}

fn NodeId parse_ct_echo(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	uint kw = p.advance();
	NodeId value = parse_expr(p);
	p.expect(EOS, "expected ';'");

	List{NodeId} kids;
	kids.tinit();
	kids.push(value);
	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(CT_ECHO_DECL, kw, first, range[0], range[1]);
}

fn NodeId parse_ct_error(Parser* p) @local
{
	if (!p.enter()) return p.sync_decl();
	defer p.leave();

	uint first = p.pos;
	uint kw = p.advance();
	NodeId message = parse_expr(p);
	List{NodeId} kids;
	kids.tinit();
	kids.push(message);
	while (p.match(COMMA)) kids.push(parse_expr(p));
	p.expect(EOS, "expected ';'");

	NodeId[<2>] range = p.ast.add_children(kids.to_tarray());
	return p.finish(CT_ERROR_DECL, kw, first, range[0], range[1]);
}
