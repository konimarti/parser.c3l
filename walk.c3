<*
 Generic AST visitor.

 FROZEN INTERFACE. Every check traverses through this, so the two node shapes
 (see ast.c3) are interpreted in exactly one place.
*>
module c3::parser;

import std::collections::list;

<*
 Called once per node, parents before children.
 @return "false to skip this node's children"
*>
alias VisitFn = fn bool(Ast* ast, NodeId id, any ctx);

<*
 Visit `root` and its descendants, depth first, parents first.

 Stops descending where `visit` returns false. Skips NONE edges, so a visitor
 never sees the sentinel.
*>
fn void walk(Ast* ast, NodeId root, VisitFn visit, any ctx = null)
{
	if (root == NONE) return;
	if (!visit(ast, root, ctx)) return;
	foreach (kid : child_ids(ast, root)) walk(ast, kid, visit, ctx);
}

<*
 The node-id edges out of `id`, whichever shape it uses.

 For a list-bearing kind these are its children; otherwise they are `lhs` and
 `rhs`. NONE edges are dropped. The result is in temp memory.
*>
fn NodeId[] child_ids(Ast* ast, NodeId id)
{
	Node* n = ast.node(id);
	if (n.kind.is_list_bearing())
	{
		List{NodeId} out;
		out.tinit();
		foreach (kid : ast.children(id)) if (kid != NONE) out.push(kid);
		return out.to_tarray();
	}
	List{NodeId} out;
	out.tinit();
	if (n.lhs != NONE) out.push(n.lhs);
	if (n.rhs != NONE) out.push(n.rhs);
	return out.to_tarray();
}
