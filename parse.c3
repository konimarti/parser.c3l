<*
 Parser state, token helpers and recovery.

 FROZEN INTERFACE. See docs/DESIGN.md section 4 and docs/WORKPLAN.md rule 1.

 Lane owners implement the four grammar entry points in their own files and
 reach the token stream only through the helpers here. The four points are:

   parse_expr(Parser*, Prec)   lane 1A, parse_expr.c3
   parse_stmt(Parser*)         lane 1B, parse_stmt.c3
   parse_block(Parser*)        lane 1B, parse_stmt.c3
   parse_decl(Parser*)         lane 1C, parse_decl.c3
   parse_type(Parser*)         lane 1C, parse_type.c3

 Lanes call each other only through those. Agree no other cross-lane entry.
*>
module c3::parser;

import c3::lexer;
import std::collections::list;

<*
 Expression precedence, loosest to tightest, as in c3c's
 resources/grammar/grammar.y. Used by `parse_expr` for precedence climbing.
*>
enum Prec : char
{
	LOWEST,
	ASSIGNMENT,
	TERNARY,
	OR,
	AND,
	RELATIONAL,
	ADDITIVE,
	BIT,
	SHIFT,
	MULT,
	UNARY,
	POSTFIX,
}

<* Deeply nested input is a recovery event, not a stack overflow. *>
const uint MAX_DEPTH = 256;

struct Parser
{
	TokenList*      toks;
	Ast*            ast;
	<* Cursor into `toks.code`. *>
	uint            pos;
	ParseErrorList* errors;
	<*
	 Set while parsing an expression in statement position, where a `{` opens
	 a block rather than an initializer list. This is what c3c's grammar
	 expresses by duplicating the whole precedence chain as `*_stmt_expr`;
	 we thread one flag instead. See docs/DESIGN.md section 3.
	*>
	bool            no_init_list;
	uint            depth;
}

// --- Token access -----------------------------------------------------------

<* The token `ahead` positions from the cursor. Reads past the end are EOF. *>
fn Token Parser.peek(&self, uint ahead = 0) @inline => self.toks.tok(self.pos + ahead);

fn TokenType Parser.peek_type(&self, uint ahead = 0) @inline
	=> self.toks.type_at(self.pos + ahead);

fn bool Parser.at(&self, TokenType t) @inline => self.peek_type() == t;

fn bool Parser.at_end(&self) @inline => (sz)self.pos >= self.toks.len();

<* Consume the current token and return its index. *>
fn uint Parser.advance(&self)
{
	uint at = self.pos;
	if (!self.at_end()) self.pos++;
	return at;
}

<* Consume the current token if it is `t`. *>
fn bool Parser.match(&self, TokenType t)
{
	if (!self.at(t)) return false;
	self.pos++;
	return true;
}

<*
 Consume `t`, or record one error and leave the cursor where it is.
 @return "true when the token was there"
*>
fn bool Parser.expect(&self, TokenType t, String what)
{
	if (self.match(t)) return true;
	self.error(what);
	return false;
}

// --- Errors and recovery ----------------------------------------------------

<*
 Record one problem at the cursor.

 One diagnostic per recovery event: cascades are worse than silence, so
 callers report once and then sync.
*>
fn void Parser.error(&self, String msg)
{
	self.errors.push({ .tok = self.pos, .msg = msg });
}

<*
 Skip to just past the next `;`, or to a `}` at or below the current brace
 depth, and return an ERROR_STMT node spanning everything skipped.
*>
fn NodeId Parser.sync_stmt(&self)
{
	uint first = self.pos;
	int depth = 0;
	while (!self.at_end())
	{
		switch (self.peek_type())
		{
			case LBRACE:
				depth++;
			case RBRACE:
				// A closing brace at our own level ends the statement; leave
				// it for the enclosing block to consume.
				if (depth == 0) return self.error_node(ERROR_STMT, first);
				depth--;
			case EOS:
				if (depth == 0)
				{
					self.advance();
					return self.error_node(ERROR_STMT, first);
				}
			default:
				break;
		}
		self.advance();
	}
	return self.error_node(ERROR_STMT, first);
}

<* True for tokens that can begin a top-level declaration. *>
fn bool starts_decl(TokenType t)
{
	switch (t)
	{
		case MODULE:
		case IMPORT:
		case FUNC:
		case MACRO:
		case ATTRMACRO:
		case STRUCT:
		case UNION:
		case ENUM:
		case BITSTRUCT:
		case INTERFACE:
		case TYPEDEF:
		case ALIAS:
		case CONST:
		case ATTRDEF:
		case FAULTDEF:
		case CONSTDEF:
		case CONSTSET:
		case STATIC:
		case EXTERN:
		case TLOCAL:
			return true;
		default:
			return false;
	}
}

<*
 Skip to the next declaration start at brace depth zero and return an
 ERROR_DECL node spanning what was skipped.
*>
fn NodeId Parser.sync_decl(&self)
{
	uint first = self.pos;
	int depth = 0;
	// Always consume at least one token, or a non-decl token at depth 0 loops.
	self.advance();
	while (!self.at_end())
	{
		switch (self.peek_type())
		{
			case LBRACE:
				depth++;
			case RBRACE:
				if (depth > 0) depth--;
			default:
				if (depth == 0 && starts_decl(self.peek_type()))
				{
					return self.error_node(ERROR_DECL, first);
				}
		}
		self.advance();
	}
	return self.error_node(ERROR_DECL, first);
}

<*
 An error node spanning `first` through the token before the cursor.
 Spans stay valid even for recovery nodes, so the invariants in
 docs/DESIGN.md section 6 hold on malformed files too.
*>
fn NodeId Parser.error_node(&self, NodeKind kind, uint first)
{
	uint last = self.pos > first ? self.pos - 1 : first;
	return self.ast.add(kind, first, first, last);
}

<* Guard deep nesting. Callers that get false must recover, not recurse. *>
fn bool Parser.enter(&self)
{
	if (self.depth >= MAX_DEPTH)
	{
		self.error("expression or statement nests too deeply");
		return false;
	}
	self.depth++;
	return true;
}

fn void Parser.leave(&self) @inline => self.depth--;

<*
 Close a node that began at `first`: its span runs to the last consumed token.
*>
fn NodeId Parser.finish(&self, NodeKind kind, uint tok, uint first,
                        NodeId lhs = NONE, NodeId rhs = NONE)
{
	uint last = self.pos > first ? self.pos - 1 : first;
	return self.ast.add(kind, tok, first, last, lhs, rhs);
}

// --- Translation unit -------------------------------------------------------

<*
 Parse a whole file: declarations until the stream runs out.

 Recovery policy lives here rather than in a lane, so that one malformed
 declaration can never consume the rest of the file.
*>
fn NodeId Parser.parse_unit(&self)
{
	NodeId[] decls = self.collect_decls();
	NodeId[<2>] range = self.ast.add_children(decls);
	uint last = self.toks.len() > 0 ? (uint)self.toks.len() - 1 : 0;
	return self.ast.add(BLOCK, 0, 0, last, range[0], range[1]);
}

fn NodeId[] Parser.collect_decls(&self)
{
	List{NodeId} out;
	out.tinit();
	while (!self.at_end())
	{
		uint before = self.pos;
		NodeId d = parse_decl(self);
		out.push(d);
		// A lane that returns without consuming would spin forever; the
		// parser must always make progress.
		if (self.pos == before) self.advance();
	}
	return out.to_tarray();
}
