<*
 Node-shape assertions for the type grammar (lane 1C). One @test per grammar
 area, following the style of parse_test.c3: parse a snippet, then assert
 node kinds/shape via Ast.node()/Ast.children() rather than re-deriving the
 whole tree by hand.
*>
module c3::parser::shape_type_support;

import c3::parser;

<* Parse `SRC` and return the type node of `const <type> X = 1;`'s declared type. *>
fn NodeId parse_const_type(ParseResult* r, String src)
{
	*r = parser::parse(mem, src);
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* n = r.ast.node(decl);
	assert(n.kind == CONST_DECL, "expected a CONST_DECL, got %s", n.kind);
	NodeId[] kids = r.ast.children(decl);
	return kids[0]; // CONST_DECL children: [type, init, attr...]
}

module c3::parser::shape_type_test @test;

import c3::parser;
import c3::parser::shape_type_support;
import std::io;

fn void base_type()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const int X = 1;");
	defer r.free();
	assert(r.ast.node(t).kind == TYPE_BASE, "expected TYPE_BASE, got %s", r.ast.node(t).kind);
}

fn void named_type_qualified()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const std::io::Path X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_NAME, "expected TYPE_NAME, got %s", n.kind);
	assert(n.lhs != parser::NONE, "a qualified name carries a PATH qualifier");
	assert(r.ast.node(n.lhs).kind == PATH, "qualifier must be a PATH node");
}

fn void named_type_unqualified()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const Foo X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_NAME, "expected TYPE_NAME, got %s", n.kind);
	assert(n.lhs == parser::NONE, "an unqualified name has no PATH qualifier");
}

fn void pointer_suffix_repeatable()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const int** X = 1;");
	defer r.free();
	Node* outer = r.ast.node(t);
	assert(outer.kind == TYPE_PTR, "expected outer TYPE_PTR, got %s", outer.kind);
	Node* inner = r.ast.node(outer.lhs);
	assert(inner.kind == TYPE_PTR, "expected inner TYPE_PTR, got %s", inner.kind);
	assert(r.ast.node(inner.lhs).kind == TYPE_BASE, "innermost type must be TYPE_BASE");
}

fn void array_suffix_with_length()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const int[4] X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_ARRAY, "expected TYPE_ARRAY, got %s", n.kind);
	assert(n.rhs != parser::NONE, "a fixed array carries its length expression");
	assert(r.ast.node(n.rhs).kind == INT_LIT, "length must be the literal 4");
}

fn void array_suffix_inferred_length()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const int[*] X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_ARRAY, "expected TYPE_ARRAY for '[*]', got %s", n.kind);
	assert(n.rhs == parser::NONE, "'[*]' has no length expression");
}

fn void slice_suffix()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const int[] X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_SLICE, "expected TYPE_SLICE, got %s", n.kind);
	assert(n.rhs == parser::NONE, "a slice has no length expression");
}

fn void vector_suffix()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const int[<4>] X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_VEC, "expected TYPE_VEC, got %s", n.kind);
	assert(n.rhs != parser::NONE, "a fixed vector carries its length expression");
}

fn void vector_suffix_inferred()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const int[<*>] X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_VEC, "expected TYPE_VEC for '[<*>]', got %s", n.kind);
	assert(n.rhs == parser::NONE, "'[<*>]' has no length expression");
}

fn void optional_suffix_question_mark()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const int? X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_OPTIONAL, "expected TYPE_OPTIONAL, got %s", n.kind);
	assert(r.ast.node(n.lhs).kind == TYPE_BASE, "inner type of 'int?' is TYPE_BASE");
}

fn void generic_type_arguments()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const List{int} X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_GENERIC, "expected TYPE_GENERIC, got %s", n.kind);
	NodeId[] kids = r.ast.children(t);
	assert(kids.len == 2, "base type + one argument, got %d children", kids.len);
	assert(r.ast.node(kids[0]).kind == TYPE_NAME, "first child is the base type List");
}

fn void generic_type_multiple_arguments()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const HashMap{String, int} X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_GENERIC, "expected TYPE_GENERIC, got %s", n.kind);
	NodeId[] kids = r.ast.children(t);
	assert(kids.len == 3, "base type + two arguments, got %d children", kids.len);
}

fn void inferred_type_placeholder()
{
	// A bare `$Type` is not a type-start in ordinary parameter position (it is
	// its own complete compile-time-type parameter, per the real compiler's
	// `parse_next_is_typed_parameter`); it reaches TYPE_INFERRED wherever a
	// type is parsed directly, e.g. a `const`'s declared type.
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const $Type X = 1;");
	defer r.free();
	assert(r.ast.node(t).kind == TYPE_INFERRED, "expected TYPE_INFERRED for $Type, got %s", r.ast.node(t).kind);
}

fn void ct_typeof_expr_type()
{
	ParseResult r;
	NodeId t = shape_type_support::parse_const_type(&r, "const $Typeof(1) X = 1;");
	defer r.free();
	Node* n = r.ast.node(t);
	assert(n.kind == TYPE_EXPR, "expected TYPE_EXPR for $Typeof(...), got %s", n.kind);
	assert(n.lhs != parser::NONE, "$Typeof carries its operand expression");
}

fn void fn_type_via_alias()
{
	ParseResult r = parser::parse(mem, "alias Handler = fn void(int, int);");
	defer r.free();
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == ALIAS_DECL, "expected ALIAS_DECL, got %s", r.ast.node(decl).kind);
	NodeId value = r.ast.children(decl)[0];
	Node* fn_type = r.ast.node(value);
	assert(fn_type.kind == TYPE_FN, "expected TYPE_FN, got %s", fn_type.kind);
	NodeId[] kids = r.ast.children(value);
	assert(kids.len == 3, "return type + two bare-type params, got %d children", kids.len);
	assert(r.ast.node(kids[0]).kind == TYPE_BASE, "return type is void");
	assert(r.ast.node(kids[1]).kind == PARAM, "fn-type parameters reuse PARAM");
}

fn void malformed_type_recovers()
{
	ParseResult r = parser::parse(mem, "const = 1;");
	defer r.free();
	assert(r.has_errors(), "a missing type before '=' must be reported");
	assert(r.ast.root != parser::NONE, "a tree is still produced");
}
