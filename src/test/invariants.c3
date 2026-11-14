<*
 Structural invariants on a parsed tree. See docs/DESIGN.md section 6.

 These catch the parser bugs that corpus conformance misses. Invariant 3
 (content representation) is the one that earns its keep: it makes "we
 silently did not parse $foreach bodies" impossible to ship.

 ## Why invariant 3 is phrased the way it is

 The obvious formulation -- every token is inside exactly one leaf's span --
 is unsatisfiable by ANY parser, not just an incomplete one. Structural
 tokens live on interior nodes: BLOCK's span holds its braces while its
 children are the statements, and no statement covers a brace. Gating on that
 would have had three lanes driving coverage toward a floor they could never
 reach.

 What we actually want to catch is a parser SKIPPING content. So the rule is
 about content tokens only -- identifiers, literals and type keywords, the
 tokens that carry meaning and must each become part of some node:

   every content token is either the principal token (`tok`) of some node,
   or inside the span of a leaf node.

 Punctuation and keywords are exempt: owning those is exactly what interior
 nodes are for. This passes on a correct parser and fails on one that skips
 a function signature -- the discriminating pair is in parse_test.c3.
*>
module c3::parser::invariants;

import c3::parser;
import c3::lexer;
import std::collections::list;
import std::io;

struct Report
{
	bool   spans_nest;
	bool   edges_valid;
	bool   content_represented;
	<* First failure found, for the test output. *>
	String detail;
	<* Content tokens that no node represents. *>
	sz     unrepresented;
}

fn bool Report.ok(&self) @inline
	=> self.spans_nest && self.edges_valid && self.content_represented;

<*
 True for tokens that carry meaning and so must belong to some node.

 Punctuation, operators and control keywords are deliberately absent: those
 are what interior nodes own.
*>
fn bool is_content(TokenType t)
{
	switch (t)
	{
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
		case INTEGER:
		case REAL:
		case STRING:
		case CHAR_LITERAL:
		case BYTES:
			return true;
		default:
			return parser::is_base_type(t);
	}
}

<*
 Check invariants 1-3 on a parsed tree.
 @param r : "a result from parser::parse"
*>
fn Report check(ParseResult* r)
{
	Report rep = { .spans_nest = true, .edges_valid = true, .content_represented = true };
	sz ntok = r.toks.len();

	List{char} seen;
	seen.tinit();
	for (sz i = 0; i < ntok; i++) seen.push(0);

	// A node's principal token is represented by that node, whatever its shape.
	for (sz i = 1; i < r.ast.len(); i++)
	{
		Node* n = r.ast.node((NodeId)i);
		if ((sz)n.tok < ntok) seen.set((sz)n.tok, 1);
	}

	check_node(r, r.ast.root, &rep, &seen, 0);

	for (sz i = 0; i < ntok; i++)
	{
		if (seen[i]) continue;
		if (!is_content(r.toks.type_at((uint)i))) continue;
		rep.unrepresented++;
		if (!rep.detail.len)
		{
			rep.detail = string::tformat("token %d '%s' (%s) belongs to no node",
				i, r.toks.text_at((uint)i), r.toks.type_at((uint)i));
		}
	}
	if (rep.unrepresented > 0) rep.content_represented = false;
	return rep;
}

<*
 Recursive half of `check`. Verifies invariants 1 and 2 on this node, then
 recurses; marks cover for leaves only, so overlapping leaf spans are caught.
*>
fn void check_node(ParseResult* r, NodeId id, Report* rep, List{char}* seen, uint depth) @local
{
	if (id == parser::NONE) return;
	if (depth > 4096)
	{
		rep.edges_valid = false;
		rep.detail = "tree nests deeper than 4096: probable cycle";
		return;
	}

	// Invariant 2: the id must address a real node.
	if ((sz)id >= r.ast.len())
	{
		rep.edges_valid = false;
		if (!rep.detail.len) rep.detail = string::tformat("node id %d is out of range", id);
		return;
	}

	Node* n = r.ast.node(id);
	sz ntok = r.toks.len();

	// Invariant 1: the span must be ordered and hold the principal token.
	if (n.first_tok > n.last_tok || n.tok < n.first_tok || n.tok > n.last_tok)
	{
		rep.spans_nest = false;
		if (!rep.detail.len)
		{
			rep.detail = string::tformat("node %d (%s) has span [%d,%d] with tok %d",
				id, n.kind, n.first_tok, n.last_tok, n.tok);
		}
	}
	if (ntok > 0 && (sz)n.last_tok >= ntok)
	{
		rep.spans_nest = false;
		if (!rep.detail.len)
		{
			rep.detail = string::tformat("node %d (%s) span ends at %d, past the last token %d",
				id, n.kind, n.last_tok, ntok - 1);
		}
	}

	NodeId[] kids = parser::child_ids(&r.ast, id);
	if (!kids.len)
	{
		// A leaf represents everything in its span: PATH stands for `a::b`,
		// a literal for its token.
		for (sz t = (sz)n.first_tok; t <= (sz)n.last_tok && t < ntok; t++) seen.set(t, 1);
		return;
	}
	foreach (kid : kids)
	{
		if ((sz)kid >= r.ast.len()) continue;
		Node* c = r.ast.node(kid);
		// Invariant 1: a child's span must sit inside its parent's.
		if (c.first_tok < n.first_tok || c.last_tok > n.last_tok)
		{
			rep.spans_nest = false;
			if (!rep.detail.len)
			{
				rep.detail = string::tformat("child %d (%s) span [%d,%d] escapes parent %d (%s) [%d,%d]",
					kid, c.kind, c.first_tok, c.last_tok, id, n.kind, n.first_tok, n.last_tok);
			}
		}
		check_node(r, kid, rep, seen, depth + 1);
	}
}
