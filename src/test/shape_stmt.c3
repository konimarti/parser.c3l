module c3::parser::shape_stmt @test;

import c3::parser;
import c3::parser::invariants;

fn void if_and_while_shapes()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { if (x) { y; } else { z; } while (x) y; while (String? line = io::treadline(stream), @catch(line) != io::EOF) consume(line); }");
	defer r.free();
	NodeId if_id = parser::NONE;
	bool while_seen = false;
	bool optional_condition_decl = false;
	for (NodeId i = 1; i < r.ast.len(); i++)
	{
		if (r.ast.kind(i) == IF) if_id = i;
		if (r.ast.kind(i) == WHILE) while_seen = true;
		if (r.ast.kind(i) == VAR_DECL && r.ast.kind(r.ast.node(i).lhs) == TYPE_OPTIONAL) optional_condition_decl = true;
	}
	assert(if_id != parser::NONE && r.ast.children(if_id).len == 3, "if has condition, then, else slots");
	assert(while_seen, "while node is present");
	assert(optional_condition_decl, "optional-typed condition declaration is represented");
	assert(!r.has_errors(), "valid control flow parses cleanly");
}

fn void try_unwrap_declarations_and_compile_time_type_comparisons()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { if (try Object* global = maybe()) ; while (try String rv = next()) ; $if true: if ($Type != Other) ; $endif }");
	defer r.free();
	assert(!r.has_errors(), "typed try unwrap declarations and type comparisons parse in conditions: %s", r.errors.len() ? r.errors[0].msg : "none");
	bool declared = false;
	for (NodeId i = 1; i < r.ast.len(); i++) if (r.ast.kind(i) == VAR_DECL && r.ast.kind(r.ast.node(i).rhs) == TRY_EXPR) declared = true;
	assert(declared, "try unwrap declaration is represented as a typed local with TRY_EXPR initializer");
}

fn void for_and_foreach_shapes()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { for (i = 0; i < 3; i++) x; foreach (item : items) x; foreach_r (item : items) x; }");
	defer r.free();
	bool for_seen = false; bool each_seen = false; bool reverse_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++)
	{
		if (r.ast.kind(i) == FOR) { for_seen = true; assert(r.ast.children(i).len == 4, "for has four fixed child slots"); }
		if (r.ast.kind(i) == FOREACH) each_seen = true;
		if (r.ast.kind(i) == FOREACH_R) reverse_seen = true;
	}
	assert(for_seen && each_seen && reverse_seen, "all loop forms are represented");
}

fn void switch_shapes()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { switch (x) @jump { case 1: y; default: z; } }");
	defer r.free();
	bool switch_seen = false; bool case_seen = false; bool default_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++)
	{
		if (r.ast.kind(i) == SWITCH) { switch_seen = true; assert(r.ast.children(i).len == 3, "switch has subject then two arms"); }
		if (r.ast.kind(i) == CASE) { case_seen = true; assert(r.ast.node(i).rhs != parser::NONE, "case carries its body"); }
		if (r.ast.kind(i) == DEFAULT) { default_seen = true; assert(r.ast.node(i).lhs != parser::NONE, "default carries its body"); }
	}
	assert(switch_seen && case_seen && default_seen, "switch arms are represented");
	assert(!r.has_errors(), "switch attributes between subject and body parse cleanly");
}

fn void defer_and_assert_shapes()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { defer cleanup(); defer catch(err) recover(); assert (x, y); }");
	defer r.free();
	bool defer_seen = false; bool assert_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++) { if (r.ast.kind(i) == DEFER) defer_seen = true; if (r.ast.kind(i) == ASSERT) assert_seen = true; }
	assert(defer_seen && assert_seen, "defer and assert are represented");
}

fn void cast_expression_defer_is_not_catch()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { defer (void)process.destroy(); }");
	defer r.free();
	assert(!r.has_errors(), "parenthesized cast expression after defer parses cleanly");
	bool defer_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++) if (r.ast.kind(i) == DEFER) defer_seen = true;
	assert(defer_seen, "cast expression is retained as defer body");
}

fn void expression_prefixes_are_accepted_in_statement_position()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { @pool() { x; }; }");
	defer r.free();
	assert(!r.has_errors(), "attribute expression prefixes are valid statement starts: %s", r.errors.len() ? r.errors[0].msg : "none");
}

fn void repeated_typed_for_initializers()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { for (sz i = size, sz k = size; k > 0; k = i) x; }");
	defer r.free();
	assert(!r.has_errors(), "each comma-separated for initializer may declare its own type");
	bool for_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++) if (r.ast.kind(i) == FOR) for_seen = true;
	assert(for_seen, "for initializer list is retained in the for node");
}

fn void compile_time_switch_accepts_boolean_case_expression()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { $switch: $case $feat(LINUX) || $feat(BSD): x; $default: y; $endswitch $switch TypeElement::kind: $case STRUCT: x; $endswitch }");
	defer r.free();
	assert(!r.has_errors(), "compile-time switch accepts a full constant expression in a case arm");
	bool switch_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++) if (r.ast.kind(i) == CT_SWITCH) switch_seen = true;
	assert(switch_seen, "compile-time switch is represented structurally");
}

fn void declarations_and_return_shapes()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { var item = value; int count = 1; int $generated @noinit; String[1] $ext = { \"x\" }; $Typeof(instance.h[0])[16] m, v; const int LIMIT = 3; static int cached; custom::Type pathValue; $Type* ptrValue = value; int::max; return count; }");
	defer r.free();
	bool vars = false; bool returned = false;
	for (NodeId i = 1; i < r.ast.len(); i++) { if (r.ast.kind(i) == VAR_DECL) vars = true; if (r.ast.kind(i) == RETURN) returned = true; }
	assert(vars && returned, "local declarations and return are represented");
	assert(!r.has_errors(), "valid declarations and return parse cleanly");
}

fn void qualified_generic_types_and_static_method_expressions()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { ref::Ref{Pair} r = ref::wrap(p); mem::volatile::Volatile{int}* v = source; mem::alignment::UnalignedRef{int, 1} unaligned = source; CFType.release(node.mon.mode.src); }");
	defer r.free();
	assert(!r.has_errors(), "generic qualified local types and type static-method calls are disambiguated: %s", r.errors.len() ? r.errors[0].msg : "none");
	bool ref_decl = false; bool volatile_ptr = false; bool static_call = false;
	for (NodeId i = 1; i < r.ast.len(); i++)
	{
		if (r.ast.kind(i) == VAR_DECL && r.ast.kind(r.ast.node(i).lhs) == TYPE_GENERIC) ref_decl = true;
		if (r.ast.kind(i) == VAR_DECL && r.ast.kind(r.ast.node(i).lhs) == TYPE_PTR) volatile_ptr = true;
		if (r.ast.kind(i) == EXPR_STMT) static_call = true;
	}
	assert(ref_decl && volatile_ptr && static_call, "both declaration suffix shapes and the call expression are retained");
}

fn void compile_time_pointer_type_local_declaration()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { $Type* value = source; }");
	defer r.free();
	bool found = false;
	for (NodeId i = 1; i < r.ast.len(); i++) if (r.ast.kind(i) == VAR_DECL) found = true;
	assert(found, "$Type* name = expr is parsed as a local declaration");
	assert(!r.has_errors(), "compile-time pointer type local parses cleanly");
}

fn void compile_time_type_values_use_general_expressions()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { var $Type = true ??? $Typeof(value) : $Typeof(*value); $Type = true ??? $Typeof(value) : $Typeof(*value); }");
	defer r.free();
	assert(!r.has_errors(), "compile-time type variables accept ternary expression initializers and assignments: %s", r.errors.len() ? r.errors[0].msg : "none");
	bool var_ternary = false; bool assign_ternary = false;
	for (NodeId i = 1; i < r.ast.len(); i++)
	{
		if (r.ast.kind(i) == VAR_DECL && r.ast.kind(r.ast.node(i).rhs) == TERNARY) var_ternary = true;
		if (r.ast.kind(i) == CT_EXPAND)
		{
			NodeId[] kids = r.ast.children(i);
			assign_ternary = kids.len == 1 && r.ast.kind(kids[0]) == TERNARY;
		}
	}
	assert(var_ternary && assign_ternary, "compile-time type values preserve their expression child shapes");
}

fn void compile_time_identifier_expression_statement()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { var $v = 8; $v |= $v >> 1; }");
	defer r.free();
	assert(!r.has_errors(), "a compile-time identifier can start an expression statement");
	bool assignment = false;
	for (NodeId i = 1; i < r.ast.len(); i++) if (r.ast.kind(i) == ASSIGN) assignment = true;
	assert(assignment, "compile-time identifier assignment is represented");
}

fn void inferred_var_attributes_parse_before_initializer()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { var square @safeinfer = delta.length_sq(); }");
	defer r.free();
	assert(!r.has_errors(), "plain inferred locals accept attributes before their initializer");
	bool found = false;
	for (NodeId i = 1; i < r.ast.len(); i++) if (r.ast.kind(i) == VAR_DECL) found = true;
	assert(found, "attributed inferred local remains a VAR_DECL");
}

fn void label_and_jump_shapes()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { LOOP: while (x) { break LOOP; continue; } }");
	defer r.free();
	bool label_seen = false; bool break_seen = false; bool continue_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++) { if (r.ast.kind(i) == LABEL) label_seen = true; if (r.ast.kind(i) == BREAK) break_seen = true; if (r.ast.kind(i) == CONTINUE) continue_seen = true; }
	assert(label_seen && break_seen && continue_seen, "labels and jump statements are represented");
}

fn void compile_time_if_and_for_shapes()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { $if true: x; $else y; $endif $for var $i = 0; $i < 2; $i++: x; $endfor $for int $j = 0; $j < 2; $j++: x; $endfor }");
	defer r.free();
	bool if_seen = false; bool for_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++) { if (r.ast.kind(i) == CT_IF) if_seen = true; if (r.ast.kind(i) == CT_FOR) for_seen = true; }
	assert(if_seen && for_seen, "compile-time if and for are structural nodes");
	assert(!r.has_errors(), "compile-time var and typed for clauses parse cleanly");
}

fn void compile_time_switch_and_foreach_shapes()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { $switch T: $case 1..5: x; $default: y; $endswitch $foreach $item: items: x; $endforeach }");
	defer r.free();
	bool switch_seen = false; bool foreach_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++) { if (r.ast.kind(i) == CT_SWITCH) switch_seen = true; if (r.ast.kind(i) == CT_FOREACH) foreach_seen = true; }
	assert(switch_seen && foreach_seen, "compile-time switch and foreach are structural nodes");
	assert(!r.has_errors(), "compile-time range arms parse cleanly: %s", r.errors.len() ? r.errors[0].msg : "none");
}

fn void empty_compile_time_branch_keeps_spans_nested()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { $if true: $else $endif }");
	defer r.free();
	Report rep = invariants::check(&r);
	assert(rep.spans_nest, "empty compile-time branch block remains within its parent span: %s", rep.detail);
}

fn void compile_time_line_and_type_forms()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { $echo true; $assert true; $error \"bad\"; $expand foo; $Type = int; }");
	defer r.free();
	bool echo_seen = false; bool assert_seen = false; bool error_seen = false; bool expand_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++) { if (r.ast.kind(i) == CT_ECHO_DECL) echo_seen = true; if (r.ast.kind(i) == CT_ASSERT_DECL) assert_seen = true; if (r.ast.kind(i) == CT_ERROR_DECL) error_seen = true; if (r.ast.kind(i) == CT_EXPAND) expand_seen = true; }
	assert(echo_seen && assert_seen && error_seen && expand_seen, "compile-time line forms are represented");
}

fn void asm_and_do_shapes()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { asm { nop; } do { x; } while (again); }");
	defer r.free();
	bool asm_seen = false; bool do_seen = false;
	for (NodeId i = 1; i < r.ast.len(); i++) { if (r.ast.kind(i) == ASM_BLOCK) asm_seen = true; if (r.ast.kind(i) == DO) do_seen = true; }
	assert(asm_seen && do_seen, "asm and do nodes are represented");
}

fn void malformed_statement_recovery_returns_tree()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { if ( ) { ; for (x; ; ) { } foreach (: xs) ; switch (x) { case : ; } }");
	defer r.free();
	assert(r.ast.root != parser::NONE, "malformed statements still yield a tree");
	assert(r.has_errors(), "malformed statements report parse errors");
}

fn void unterminated_compile_time_region_recovers()
{
	ParseResult r = parser::parse(mem, "module demo; fn void f() { $if true: x;");
	defer r.free();
	assert(r.ast.root != parser::NONE, "unterminated region still yields a tree");
	assert(r.has_errors(), "unterminated region reports a parse error");
}

fn void unterminated_compile_time_bodies_keep_eof_spans_valid()
{
	String[4] sources = {
		"module demo; fn void f() { $for var $i = 0; $i < 2; $i++: if (true)",
		"module demo; fn void f() { $if true: if (true)",
		"module demo; fn void f() { $foreach $item: items: if (true)",
		"module demo; fn void f() { $switch x: $case 1: if (true)",
	};
	foreach (src : sources)
	{
		ParseResult r = parser::parse(mem, src);
		defer r.free();
		assert(r.has_errors(), "missing terminators are reported");
		Report rep = invariants::check(&r);
		assert(rep.edges_valid && rep.spans_nest, "EOF recovery keeps statement spans valid: %s", rep.detail);
	}
}
