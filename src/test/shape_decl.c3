<*
 Node-shape assertions for the declaration grammar (lane 1C). One @test per
 grammar area, following parse_test.c3's style: parse a snippet, then assert
 node kinds/shape via Ast.node()/Ast.children().
*>
module c3::parser::shape_decl_test @test;

import c3::parser;
import std::io;

fn void module_with_generics_and_attrs()
{
	ParseResult r = parser::parse(mem, "module std::collections::list <Type> @private;");
	defer r.free();
	assert(!r.has_errors(), "a generic module declaration must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* n = r.ast.node(decl);
	assert(n.kind == MODULE, "expected MODULE, got %s", n.kind);
	NodeId[] kids = r.ast.children(decl);
	assert(r.ast.node(kids[0]).kind == PATH, "first child is the module PATH");
	bool saw_generic_param = false;
	bool saw_attr = false;
	foreach (k : kids)
	{
		if (r.ast.kind(k) == IDENT) saw_generic_param = true;
		if (r.ast.kind(k) == ATTR) saw_attr = true;
	}
	assert(saw_generic_param, "<Type> must appear as a generic-param IDENT child");
	assert(saw_attr, "@private must appear as an ATTR child");
}

fn void import_multi_path_with_attrs()
{
	ParseResult r = parser::parse(mem, "import std::io, std::math @public;");
	defer r.free();
	assert(!r.has_errors(), "a multi-path import with an attribute must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == IMPORT, "expected IMPORT, got %s", r.ast.node(decl).kind);
	NodeId[] kids = r.ast.children(decl);
	int paths = 0;
	int attrs = 0;
	foreach (k : kids)
	{
		if (r.ast.kind(k) == PATH) paths++;
		if (r.ast.kind(k) == ATTR) attrs++;
	}
	assert(paths == 2, "two imported module paths expected, got %d", paths);
	assert(attrs == 1, "one attribute (@public, on the second path) expected, got %d", attrs);
}

fn void fn_decl_with_real_signature()
{
	ParseResult r = parser::parse(mem, "fn int add(int a, int b) { return a; }");
	defer r.free();
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* n = r.ast.node(decl);
	assert(n.kind == FN_DECL, "expected FN_DECL, got %s", n.kind);
	assert(n.rhs != parser::NONE, "a fn with a body must record it");
	assert(r.ast.node(n.rhs).kind == BLOCK, "the body is a BLOCK");

	Node* sig = r.ast.node(n.lhs);
	assert(sig.kind == SIGNATURE, "expected SIGNATURE, got %s", sig.kind);
	NodeId[] sig_kids = r.ast.children(n.lhs);
	assert(sig_kids[0] != parser::NONE, "the return type (int) must be recorded");
	assert(sig_kids[1] == parser::NONE, "a plain function has no method-receiver type");
	int params = 0;
	foreach (k : sig_kids)
	{
		if (r.ast.kind(k) == PARAM) params++;
	}
	assert(params == 2, "two parameters expected, got %d", params);
}

fn void fn_decl_method_with_dot_syntax()
{
	ParseResult r = parser::parse(mem, "fn void Vector.add(&self, int x) { }");
	defer r.free();
	assert(!r.has_errors(), "a method declaration must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* sig = r.ast.node(r.ast.node(decl).lhs);
	NodeId[] sig_kids = r.ast.children(r.ast.node(decl).lhs);
	assert(sig_kids[0] != parser::NONE, "the return type (void) must be recorded");
	assert(sig_kids[1] != parser::NONE, "the method receiver type (Vector) must be recorded");
	assert(r.ast.node(sig_kids[1]).kind == TYPE_NAME, "the receiver type is a TYPE_NAME");
}

fn void fn_short_body_expression()
{
	ParseResult r = parser::parse(mem, "fn int square(int x) => x;");
	defer r.free();
	assert(!r.has_errors(), "a short-body fn must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* n = r.ast.node(decl);
	assert(n.rhs != parser::NONE, "the short body expression must be recorded");
	assert(r.ast.node(n.rhs).kind != BLOCK, "a short body is the raw expression, not a BLOCK");
}

fn void macro_with_trailing_block_param()
{
	ParseResult r = parser::parse(mem, "macro void foo(int x; @body()) { }");
	defer r.free();
	assert(!r.has_errors(), "a macro with a trailing block param must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == MACRO_DECL, "expected MACRO_DECL, got %s", r.ast.node(decl).kind);
	NodeId[] sig_kids = r.ast.children(r.ast.node(decl).lhs);
	bool saw_body_param = false;
	foreach (k : sig_kids)
	{
		if (r.ast.kind(k) == PARAM && r.toks.type_at(r.ast.node(k).tok) == AT_IDENT) saw_body_param = true;
	}
	assert(saw_body_param, "the trailing '@body()' param must appear, tok'd as AT_IDENT");
}

fn void struct_with_shared_type_members_and_attrs()
{
	ParseResult r = parser::parse(mem, "struct Point { int x, y; bool visible @private; }");
	defer r.free();
	assert(!r.has_errors(), "a plain struct must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* n = r.ast.node(decl);
	assert(n.kind == STRUCT_DECL, "expected STRUCT_DECL, got %s", n.kind);
	NodeId[] members = r.ast.children(decl);
	assert(members.len == 3, "x, y, visible: three MEMBER nodes expected, got %d", members.len);
	foreach (m : members) assert(r.ast.node(m).kind == MEMBER, "every child must be a MEMBER");
	// x and y share one type node (span starts at the type, not the comma).
	NodeId shared_type = r.ast.children(members[0])[0];
	assert(shared_type == r.ast.children(members[1])[0], "x and y must share the same type node");
	Node* x = r.ast.node(members[0]);
	Node* y = r.ast.node(members[1]);
	assert(x.first_tok == y.first_tok, "x and y's spans both start at the shared type");
	bool last_has_attr = false;
	foreach (k : r.ast.children(members[2])) if (r.ast.kind(k) == ATTR) last_has_attr = true;
	assert(last_has_attr, "the '@private' on visible must appear as an ATTR child");
}

fn void struct_with_nested_anonymous_union()
{
	ParseResult r = parser::parse(mem, "struct Outer { int tag; union { int i; float f; } }");
	defer r.free();
	assert(!r.has_errors(), "a nested anonymous union must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	NodeId[] members = r.ast.children(decl);
	assert(members.len == 2, "tag + the nested union: two children expected, got %d", members.len);
	assert(r.ast.node(members[1]).kind == UNION_DECL, "the nested member is a UNION_DECL");
	assert(r.ast.children(members[1]).len == 2, "the nested union has its own two MEMBERs");
}

fn void bitstruct_with_bit_ranges()
{
	ParseResult r = parser::parse(mem, "bitstruct Flags : int { bool a : 0; bool b : 1..3; }");
	defer r.free();
	assert(!r.has_errors(), "a bitstruct with bit ranges must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* n = r.ast.node(decl);
	assert(n.kind == BITSTRUCT_DECL, "expected BITSTRUCT_DECL, got %s", n.kind);
	NodeId[] kids = r.ast.children(decl);
	assert(r.ast.node(kids[0]).kind == TYPE_BASE, "the container type (int) is the first child");
	NodeId field_a = kids[1];
	NodeId field_b = kids[2];
	assert(r.ast.node(field_a).kind == MEMBER, "expected MEMBER for field 'a'");
	NodeId[] a_kids = r.ast.children(field_a);
	assert(a_kids[1] != parser::NONE, "field 'a' has a start-bit expression");
	assert(a_kids[2] == parser::NONE, "field 'a' has no end-bit (single position)");
	NodeId[] b_kids = r.ast.children(field_b);
	assert(b_kids[2] != parser::NONE, "field 'b' has an end-bit expression (a range)");
}

fn void enum_with_associated_values()
{
	ParseResult r = parser::parse(mem, "enum Color : int (String name) { RED{\"red\"}, BLUE{\"blue\"} }");
	defer r.free();
	assert(!r.has_errors(), "an enum with associated values must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == ENUM_DECL, "expected ENUM_DECL, got %s", r.ast.node(decl).kind);
	NodeId[] kids = r.ast.children(decl);
	int params = 0;
	int consts = 0;
	foreach (k : kids)
	{
		if (r.ast.kind(k) == PARAM) params++;
		if (r.ast.kind(k) == ENUM_CONST) consts++;
	}
	assert(params == 1, "one enum_param_decl (String name) expected, got %d", params);
	assert(consts == 2, "RED and BLUE expected, got %d", consts);
}

fn void constset_with_equals_values()
{
	ParseResult r = parser::parse(mem, "constset Flags : char { A = 1, B = 2 }");
	defer r.free();
	assert(!r.has_errors(), "a constset must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == CONSTSET, "expected CONSTSET, got %s", r.ast.node(decl).kind);
	NodeId[] kids = r.ast.children(decl);
	int consts = 0;
	foreach (k : kids)
	{
		if (r.ast.kind(k) == ENUM_CONST)
		{
			consts++;
			NodeId[] vals = r.ast.children(k);
			assert(vals.len == 1, "a constset constant carries exactly one '=' value");
		}
	}
	assert(consts == 2, "A and B expected, got %d", consts);
}

fn void interface_with_parents_and_methods()
{
	ParseResult r = parser::parse(mem, "interface Shape : Printable, Comparable { fn double area(); }");
	defer r.free();
	assert(!r.has_errors(), "an interface with parents and a method must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == INTERFACE_DECL, "expected INTERFACE_DECL, got %s", r.ast.node(decl).kind);
	NodeId[] kids = r.ast.children(decl);
	int parents = 0;
	int methods = 0;
	foreach (k : kids)
	{
		if (r.ast.kind(k) == TYPE_NAME) parents++;
		if (r.ast.kind(k) == FN_DECL) methods++;
	}
	assert(parents == 2, "Printable and Comparable expected, got %d", parents);
	assert(methods == 1, "area() expected, got %d", methods);
}

fn void typedef_declaration()
{
	ParseResult r = parser::parse(mem, "typedef Meters = double;");
	defer r.free();
	assert(!r.has_errors(), "a typedef must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* n = r.ast.node(decl);
	assert(n.kind == TYPEDEF_DECL, "expected TYPEDEF_DECL, got %s", n.kind);
	NodeId target = r.ast.children(decl)[0];
	assert(r.ast.node(target).kind == TYPE_BASE, "the target type (double) must be recorded");
}

fn void alias_to_expr()
{
	ParseResult r = parser::parse(mem, "alias FOO = 1;");
	defer r.free();
	assert(!r.has_errors(), "a const-style alias must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == ALIAS_DECL, "expected ALIAS_DECL, got %s", r.ast.node(decl).kind);
	NodeId value = r.ast.children(decl)[0];
	assert(r.ast.node(value).kind == INT_LIT, "the aliased value (1) must be recorded");
}

fn void const_decl_with_attr()
{
	ParseResult r = parser::parse(mem, "const int MAX @private = 100;");
	defer r.free();
	assert(!r.has_errors(), "a const with a visibility attribute must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* n = r.ast.node(decl);
	assert(n.kind == CONST_DECL, "expected CONST_DECL, got %s", n.kind);
	NodeId[] kids = r.ast.children(decl);
	assert(r.ast.node(kids[0]).kind == TYPE_BASE, "the declared type (int) must be recorded");
	assert(r.ast.node(kids[1]).kind == INT_LIT, "the initializer (100) must be recorded");
	bool saw_attr = false;
	foreach (k : kids) if (r.ast.kind(k) == ATTR) saw_attr = true;
	assert(saw_attr, "'@private' must appear as an ATTR child");
}

fn void global_multi_name_declaration()
{
	ParseResult r = parser::parse(mem, "int a, b, c;");
	defer r.free();
	assert(!r.has_errors(), "a multi-name global must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == GLOBAL_DECL, "expected GLOBAL_DECL, got %s", r.ast.node(decl).kind);
	NodeId[] kids = r.ast.children(decl);
	int names = 0;
	foreach (k : kids) if (r.ast.kind(k) == IDENT) names++;
	assert(names == 3, "a, b, c: three names expected, got %d", names);
}

fn void faultdef_multiple_names()
{
	ParseResult r = parser::parse(mem, "faultdef IO_ERROR, PARSE_ERROR;");
	defer r.free();
	assert(!r.has_errors(), "a multi-name faultdef must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == FAULTDEF, "expected FAULTDEF, got %s", r.ast.node(decl).kind);
	NodeId[] kids = r.ast.children(decl);
	assert(kids.len == 2, "two fault names expected, got %d", kids.len);
}

fn void legacy_excuse_declaration()
{
	ParseResult r = parser::parse(mem, "excuse { ONE, TWO }");
	defer r.free();
	assert(!r.has_errors(), "the legacy 'excuse' spelling must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == FAULTDEF, "'excuse' reuses the FAULTDEF kind, got %s", r.ast.node(decl).kind);
	NodeId[] kids = r.ast.children(decl);
	assert(kids.len == 2, "two fault names expected, got %d", kids.len);
}

fn void attrdef_with_params_and_aliased_attrs()
{
	ParseResult r = parser::parse(mem, "attrdef @MyAttr(x) = @inline;");
	defer r.free();
	assert(!r.has_errors(), "an attrdef must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == ATTRDEF, "expected ATTRDEF, got %s", r.ast.node(decl).kind);
	NodeId[] kids = r.ast.children(decl);
	int params = 0;
	int attrs = 0;
	foreach (k : kids)
	{
		if (r.ast.kind(k) == PARAM) params++;
		if (r.ast.kind(k) == ATTR) attrs++;
	}
	assert(params == 1, "one declared param (x) expected, got %d", params);
	assert(attrs == 1, "one aliased attribute (@inline) expected, got %d", attrs);
}

fn void attribute_with_multiple_arguments()
{
	ParseResult r = parser::parse(mem, "const int X @tag(1, 2) = 1;");
	defer r.free();
	assert(!r.has_errors(), "an attribute with multiple arguments must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	NodeId attr = parser::NONE;
	foreach (k : r.ast.children(decl)) if (r.ast.kind(k) == ATTR) attr = k;
	assert(attr != parser::NONE, "the @tag(...) attribute must be present");
	NodeId[] args = r.ast.children(attr);
	assert(args.len == 3, "the reserved qualifier slot + two arguments expected, got %d", args.len);
	assert(args[0] == parser::NONE, "the qualifier slot is NONE: no path-prefixed attribute names");
}

fn void generic_param_on_struct()
{
	ParseResult r = parser::parse(mem, "struct Box <Type> { Type value; }");
	defer r.free();
	assert(!r.has_errors(), "a generic struct declaration must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	bool saw_generic_param = false;
	foreach (k : r.ast.children(decl)) if (r.ast.kind(k) == IDENT) saw_generic_param = true;
	assert(saw_generic_param, "<Type> must appear as a generic-param IDENT child");
}

fn void ct_include_at_top_level()
{
	ParseResult r = parser::parse(mem, `$include("foo.c3");`);
	defer r.free();
	assert(!r.has_errors(), "a top-level $include must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	assert(r.ast.node(decl).kind == CT_INCLUDE, "expected CT_INCLUDE, got %s", r.ast.node(decl).kind);
}

fn void ct_assert_with_message_at_top_level()
{
	ParseResult r = parser::parse(mem, `$assert 1 : "message";`);
	defer r.free();
	assert(!r.has_errors(), "a top-level $assert with a message must parse cleanly");
	NodeId decl = r.ast.children(r.ast.root)[0];
	Node* n = r.ast.node(decl);
	assert(n.kind == CT_ASSERT_DECL, "expected CT_ASSERT_DECL, got %s", n.kind);
	NodeId[] kids = r.ast.children(decl);
	assert(kids[0] != parser::NONE, "the condition must be recorded");
	assert(kids[1] != parser::NONE, "the message must be recorded");
}

<*
 Malformed top-level input must recover with one ERROR_DECL and let the next
 real declaration parse normally -- not consume the rest of the file.
*>
fn void malformed_decl_recovers_and_resumes()
{
	ParseResult r = parser::parse(mem, "@@@ garbage ;; fn void f() { }");
	defer r.free();
	assert(r.has_errors(), "garbage at top level must be reported");
	NodeId[] decls = r.ast.children(r.ast.root);
	assert(decls.len >= 2, "the garbage and the following fn must both appear, got %d", decls.len);
	assert(r.ast.node(decls[0]).kind == ERROR_DECL, "the garbage recovers as ERROR_DECL");
	bool saw_fn = false;
	foreach (d : decls) if (r.ast.kind(d) == FN_DECL) saw_fn = true;
	assert(saw_fn, "parsing must resume and still find 'fn void f() {}'");
}

<* A malformed struct body must not consume the rest of the file. *>
fn void malformed_struct_member_recovers()
{
	ParseResult r = parser::parse(mem, "struct Foo { @@@ ; int x; } fn void f() { }");
	defer r.free();
	assert(r.has_errors(), "garbage inside a struct body must be reported");
	NodeId[] decls = r.ast.children(r.ast.root);
	bool saw_struct = false;
	bool saw_fn = false;
	foreach (d : decls)
	{
		if (r.ast.kind(d) == STRUCT_DECL) saw_struct = true;
		if (r.ast.kind(d) == FN_DECL) saw_fn = true;
	}
	assert(saw_struct, "the struct declaration itself must still be produced");
	assert(saw_fn, "the following top-level fn must still parse, proving the struct body stayed bounded");
}
