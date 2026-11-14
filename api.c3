<*
 The public surface of the standalone parser.

 FROZEN INTERFACE. See docs/DESIGN.md section 1.5.

 This is the whole library as far as consumers are concerned. It may depend
 only on std and c3::lexer; it must never name a c3vet type. Lifting
 src/parser/ into its own parser.c3l is then a copy plus a manifest, with no
 code changes.
*>
module c3::parser;

import std::collections::list;

struct ParseResult
{
	TokenList      toks;
	Ast            ast;
	ParseErrorList errors;
	<* An invalid byte was found; see `TokenList.lex_failed`. *>
	bool           lex_failed;
}

<*
 Parse C3 source.

 Never fails. On malformed input `errors` is non-empty and the tree holds
 ERROR_DECL / ERROR_STMT / ERROR_EXPR nodes with valid spans, so a caller can
 still analyse the parts that did parse. That resilience is the point: vet
 runs on code that is being typed.

 @param a : "allocator for the tokens, the arena and the errors"
 @require src.len >= 0
*>
fn ParseResult parse(Allocator a, String src)
{
	ParseResult r;
	r.toks.init(a);
	r.ast.init(a);
	r.errors.init(a);

	r.toks.lex(src);
	r.lex_failed = r.toks.lex_failed;

	Parser p = {
		.toks   = &r.toks,
		.ast    = &r.ast,
		.errors = &r.errors,
	};
	r.ast.root = p.parse_unit();
	return r;
}

fn void ParseResult.free(&self)
{
	self.toks.free();
	self.ast.free();
	self.errors.free();
}

<* True when the file did not parse cleanly. *>
fn bool ParseResult.has_errors(&self) @inline
	=> self.errors.len() > 0 || self.lex_failed;
