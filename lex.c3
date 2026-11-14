<*
 Token collection: drains `c3::lexer` once per file into flat arrays.

 FROZEN INTERFACE. See docs/DESIGN.md section 2.

 The parser walks `code`, the non-trivia stream, and never sees comments or
 contracts. Trivia stays addressable in `all` so that suppression comments can
 be found and contracts read on demand with `lexer::ContractLexer` — contracts
 are never nodes in the AST.
*>
module c3::parser;

import c3::lexer;
import std::collections::list;
import std::io;

<* Returned by lookups that find no token. *>
const uint NO_TOKEN = uint::max;

<*
 Tokens of one source file.

 `code` holds indices into `all`, so a code token keeps its position in the
 original trivia-bearing stream and both views stay in sync.
*>
struct TokenList
{
	<* Every token in source order, trivia included. *>
	List{Token} all;
	<* Indices into `all` of the non-trivia tokens only. *>
	List{uint}  code;
	<* An invalid byte was found. Tokens up to that point are still usable. *>
	bool        lex_failed;
	<* Byte offset where lexing stopped, when `lex_failed`. *>
	sz          fail_offset;
}

<* True for tokens the parser must not see. *>
fn bool is_trivia(TokenType t) @inline
	=> t == LINE_COMMENT || t == BLOCK_COMMENT || t == CONTRACT || t == EOL;

<*
 `size_hint`, if given, is the source length in bytes: both lists default
 to capacity 16 and grow by doubling, which is already amortized O(1) per
 push, but still copies the whole array on every doubling -- reserving
 once up front for a rough token-count estimate avoids that for any file
 past a trivial size. Token count is consistently a few times smaller
 than byte count for real C3 source (short identifiers and single-byte
 punctuation both lex to one token each), so these divisors are a
 deliberate overestimate: wasted slack here is far cheaper than a reallocation.
*>
fn void TokenList.init(&self, Allocator a, sz size_hint = 0)
{
	self.all.init(a, size_hint > 0 ? size_hint / 3 : 16);
	self.code.init(a, size_hint > 0 ? size_hint / 4 : 16);
}

fn void TokenList.free(&self)
{
	self.all.free();
	self.code.free();
}

<*
 Lex `src` into `all` and `code`.

 Never fails: an invalid byte sets `lex_failed` and keeps everything lexed so
 far, so syntax-tier checks still run on the part that did lex.
*>
fn void TokenList.lex(&self, String src)
{
	Lexer lexer;
	lexer.init(src);
	while (true)
	{
		Token? next = lexer.next();
		if (catch err = next)
		{
			// EOF is the normal end of the stream, not a failure.
			if (err != io::EOF)
			{
				self.lex_failed = true;
				self.fail_offset = lexer.pos;
			}
			return;
		}
		uint idx = (uint)self.all.len();
		self.all.push(next);
		if (!is_trivia(next.type)) self.code.push(idx);
	}
}

<* Number of code (non-trivia) tokens. *>
fn sz TokenList.len(&self) @inline => self.code.len();

<*
 The code token at `i`.

 Out-of-range indices yield a synthetic EOF token rather than panicking, so
 the parser can look ahead past the end without bounds checks everywhere.
*>
fn Token TokenList.tok(&self, uint i)
{
	if ((sz)i >= self.code.len()) return { .type = EOF, .offset = (sz)0 };
	return self.all[(sz)self.code[(sz)i]];
}

fn TokenType TokenList.type_at(&self, uint i) @inline => self.tok(i).type;
fn String TokenList.text_at(&self, uint i) @inline => self.tok(i).text;

<*
 The CONTRACT token immediately preceding the code token at `code_idx`,
 as an index into `all`.

 Walks back over blank lines and ordinary comments, and stops at the first
 code token. Returns NO_TOKEN when the declaration has no contract.

 This is the only bridge between contracts and the rest of the tool: the
 Phase 4 contract checks take this token's lexeme and run
 `lexer::ContractLexer` over it. See docs/DESIGN.md section 2.
*>
fn uint TokenList.contract_before(&self, uint code_idx)
{
	if ((sz)code_idx >= self.code.len()) return NO_TOKEN;
	uint at = self.code[(sz)code_idx];
	for (uint i = at; i > 0; i--)
	{
		Token t = self.all[(sz)(i - 1)];
		switch (t.type)
		{
			case CONTRACT:
				return i - 1;
			case LINE_COMMENT:
			case BLOCK_COMMENT:
			case EOL:
				continue;
			default:
				// A code token: this declaration has no contract of its own.
				return NO_TOKEN;
		}
	}
	return NO_TOKEN;
}
