<*
 The c3vet abstract syntax tree: a flat arena of nodes addressed by index.

 FROZEN INTERFACE. See docs/DESIGN.md section 1.5 and docs/WORKPLAN.md rule 1.
 Lane owners consume this file and do not edit it; propose changes instead.

 ## The field contract

 Every node is one of exactly two shapes. There is never a mix, which is what
 makes `Ast.children` and `walk` possible without per-kind knowledge:

 **Shape 1 - two node ids.** `lhs` and `rhs` are NodeIds, `NONE` when absent.

 | Kind                 | tok            | lhs            | rhs            |
 |----------------------|----------------|----------------|----------------|
 | BINARY               | the operator   | left operand   | right operand  |
 | ASSIGN               | `=` / compound | target         | value          |
 | ELVIS / OPTELSE      | `?:` / `??`    | left           | right          |
 | UNARY / POSTFIX      | the operator   | operand        | NONE           |
 | SUBSCRIPT            | `[`            | object         | index          |
 | MEMBER_ACCESS        | `.`            | object         | IDENT node     |
 | CAST                 | `(`            | type           | operand        |
 | RANGE                | `..`           | low            | high           |
 | TRY_EXPR/CATCH_EXPR  | keyword        | operand        | NONE           |
 | FORCE_UNWRAP/RETHROW | `!!` / `!`     | operand        | NONE           |
 | SPLAT                | `...`          | operand        | NONE           |
 | WHILE                | `while`        | condition      | body           |
 | DO                   | `do`           | body           | condition/NONE |
 | CASE                 | `case`         | label expr     | body           |
 | DEFAULT              | `default`      | body           | NONE           |
 | RETURN               | `return`       | value / NONE   | NONE           |
 | DEFER                | `defer`        | body           | NONE           |
 | LABEL                | the name       | statement      | NONE           |
 | EXPR_STMT            | first token    | expression     | NONE           |
 | VAR_DECL             | the name       | type / NONE    | init / NONE    |
 | FN_DECL / MACRO_DECL | the name       | SIGNATURE      | body / NONE    |
 | MODULE / IMPORT      | the keyword    | PATH node      | NONE           |
 | PARAM                | the name       | type / NONE    | default / NONE |
 | MEMBER               | the name       | type           | NONE           |
 | TYPE_PTR / OPTIONAL  | `*` / `?`      | inner type     | NONE           |
 | TYPE_ARRAY / _SLICE  | `[`            | element type   | length / NONE  |
 | leaves (IDENT, PATH, |                |                |                |
 | literals, TYPE_BASE, | the token      | NONE           | NONE           |
 | TYPE_NAME, ERROR_*)  |                |                |                |

 **Shape 2 - a child list.** `lhs` is the start index into `Ast.extra` and
 `rhs` is the count. Reach them only through `Ast.children`, never by indexing
 `extra`. Each kind has a fixed prefix, then a variadic tail where noted;
 absent slots are `NONE` so positions stay stable.

 | Kind                  | children                                      |
 |-----------------------|-----------------------------------------------|
 | BLOCK                 | statements...                                 |
 | CALL                  | callee, argument...                           |
 | INIT_LIST             | element...                                    |
 | IF                    | condition, then, else-or-NONE                 |
 | TERNARY               | condition, then, else                         |
 | FOR                   | init, condition, increment, body (NONE slots) |
 | FOREACH / FOREACH_R   | collection, body, variable...                 |
 | SWITCH / CT_SWITCH    | subject, case...                              |
 | SLICE                 | object, low-or-NONE, high-or-NONE             |
 | SIGNATURE             | return type, parameter...                     |
 | STRUCT_DECL / UNION_  | member...                                     |
 | DECL / BITSTRUCT_DECL |                                               |
 | ENUM_DECL             | constant...                                   |
 | INTERFACE_DECL        | member...                                     |
 | ENUM_CONST            | value...                                      |
 | ATTR                  | argument...                                   |
 | LAMBDA                | SIGNATURE, body                               |
 | TYPE_FN               | return type, parameter type...                |
 | TYPE_GENERIC          | base type, argument...                        |
 | ASM_BLOCK             | instruction...                                |
 | CT_IF                 | condition, then, else-or-NONE                 |
 | CT_FOR / CT_FOREACH   | as FOR / FOREACH                              |
 | ASSERT                | condition, message-or-NONE                    |
 | NEXTCASE              | label-or-NONE, value-or-NONE                  |

 `is_list_bearing` is the single source of truth for which shape a kind uses,
 and every kind added must appear in it and in one of the tables above, in the
 same commit.

 Every node carries `first_tok`/`last_tok` covering its whole subtree, so a
 diagnostic gets an exact range without recomputation and the span-coverage
 invariant (docs/DESIGN.md section 6) is checkable.
*>
module c3::parser;

import std::collections::list;

<* Index into `Ast.nodes`. Index 0 is the reserved NONE sentinel. *>
alias NodeId = uint;

<* The absent node. `Ast.nodes[0]` is always an INVALID-kind sentinel. *>
const NodeId NONE = 0;

<* Which of the four grammar families a kind belongs to. *>
enum NodeFamily : char
{
	INVALID,
	DECL,
	STMT,
	EXPR,
	TYPE,
}

<*
 Every syntactic form the parser can produce.

 The `family` association means `is_expr` and friends stay correct when kinds
 are reordered or inserted, which matters for an interface three lanes extend.
*>
enum NodeKind : ushort (NodeFamily family)
{
	// The nodes[0] sentinel. Never produced by the parser.
	NONE_NODE        { NodeFamily.INVALID },

	// --- Declarations ---------------------------------------------------
	MODULE           { NodeFamily.DECL },
	IMPORT           { NodeFamily.DECL },
	FN_DECL          { NodeFamily.DECL },
	MACRO_DECL       { NodeFamily.DECL },
	ATTRMACRO_DECL   { NodeFamily.DECL },
	STRUCT_DECL      { NodeFamily.DECL },
	UNION_DECL       { NodeFamily.DECL },
	BITSTRUCT_DECL   { NodeFamily.DECL },
	ENUM_DECL        { NodeFamily.DECL },
	INTERFACE_DECL   { NodeFamily.DECL },
	TYPEDEF_DECL     { NodeFamily.DECL },
	ALIAS_DECL       { NodeFamily.DECL },
	CONST_DECL       { NodeFamily.DECL },
	GLOBAL_DECL      { NodeFamily.DECL },
	FAULTDEF         { NodeFamily.DECL },
	ATTRDEF          { NodeFamily.DECL },
	CONSTDEF         { NodeFamily.DECL },
	CONSTSET         { NodeFamily.DECL },
	CT_INCLUDE       { NodeFamily.DECL },
	CT_ASSERT_DECL   { NodeFamily.DECL },
	CT_ECHO_DECL     { NodeFamily.DECL },
	CT_ERROR_DECL    { NodeFamily.DECL },
	CT_EXPAND        { NodeFamily.DECL },
	PARAM            { NodeFamily.DECL },
	MEMBER           { NodeFamily.DECL },
	ENUM_CONST       { NodeFamily.DECL },
	ATTR             { NodeFamily.DECL },
	SIGNATURE        { NodeFamily.DECL },
	ERROR_DECL       { NodeFamily.DECL },

	// --- Statements -----------------------------------------------------
	BLOCK            { NodeFamily.STMT },
	VAR_DECL         { NodeFamily.STMT },
	EXPR_STMT        { NodeFamily.STMT },
	RETURN           { NodeFamily.STMT },
	IF               { NodeFamily.STMT },
	WHILE            { NodeFamily.STMT },
	DO               { NodeFamily.STMT },
	FOR              { NodeFamily.STMT },
	FOREACH          { NodeFamily.STMT },
	FOREACH_R        { NodeFamily.STMT },
	SWITCH           { NodeFamily.STMT },
	CASE             { NodeFamily.STMT },
	DEFAULT          { NodeFamily.STMT },
	NEXTCASE         { NodeFamily.STMT },
	BREAK            { NodeFamily.STMT },
	CONTINUE         { NodeFamily.STMT },
	DEFER            { NodeFamily.STMT },
	ASSERT           { NodeFamily.STMT },
	ASM_BLOCK        { NodeFamily.STMT },
	EMPTY_STMT       { NodeFamily.STMT },
	CT_IF            { NodeFamily.STMT },
	CT_SWITCH        { NodeFamily.STMT },
	CT_FOR           { NodeFamily.STMT },
	CT_FOREACH       { NodeFamily.STMT },
	LABEL            { NodeFamily.STMT },
	ERROR_STMT       { NodeFamily.STMT },

	// --- Expressions ----------------------------------------------------
	BINARY           { NodeFamily.EXPR },
	UNARY            { NodeFamily.EXPR },
	POSTFIX          { NodeFamily.EXPR },
	ASSIGN           { NodeFamily.EXPR },
	TERNARY          { NodeFamily.EXPR },
	ELVIS            { NodeFamily.EXPR },
	OPTELSE          { NodeFamily.EXPR },
	CALL             { NodeFamily.EXPR },
	SUBSCRIPT        { NodeFamily.EXPR },
	SLICE            { NodeFamily.EXPR },
	MEMBER_ACCESS    { NodeFamily.EXPR },
	IDENT            { NodeFamily.EXPR },
	PATH             { NodeFamily.EXPR },
	PLACEHOLDER      { NodeFamily.EXPR },
	INT_LIT          { NodeFamily.EXPR },
	REAL_LIT         { NodeFamily.EXPR },
	STRING_LIT       { NodeFamily.EXPR },
	CHAR_LIT         { NodeFamily.EXPR },
	BYTES_LIT        { NodeFamily.EXPR },
	BOOL_LIT         { NodeFamily.EXPR },
	NULL_LIT         { NodeFamily.EXPR },
	INIT_LIST        { NodeFamily.EXPR },
	CAST             { NodeFamily.EXPR },
	LAMBDA           { NodeFamily.EXPR },
	TRY_EXPR         { NodeFamily.EXPR },
	CATCH_EXPR       { NodeFamily.EXPR },
	FORCE_UNWRAP     { NodeFamily.EXPR },
	RETHROW          { NodeFamily.EXPR },
	BUILTIN_EXPR     { NodeFamily.EXPR },
	SPLAT            { NodeFamily.EXPR },
	RANGE            { NodeFamily.EXPR },
	CT_CALL          { NodeFamily.EXPR },
	CT_IDENT_EXPR    { NodeFamily.EXPR },
	ARG              { NodeFamily.EXPR },
	ERROR_EXPR       { NodeFamily.EXPR },

	// --- Types ----------------------------------------------------------
	TYPE_BASE        { NodeFamily.TYPE },
	TYPE_NAME        { NodeFamily.TYPE },
	TYPE_PTR         { NodeFamily.TYPE },
	TYPE_ARRAY       { NodeFamily.TYPE },
	TYPE_SLICE       { NodeFamily.TYPE },
	TYPE_VEC         { NodeFamily.TYPE },
	TYPE_OPTIONAL    { NodeFamily.TYPE },
	TYPE_GENERIC     { NodeFamily.TYPE },
	TYPE_FN          { NodeFamily.TYPE },
	TYPE_INFERRED    { NodeFamily.TYPE },
	TYPE_EXPR        { NodeFamily.TYPE },
}

fn bool NodeKind.is_decl(self) @inline => self.family == DECL;
fn bool NodeKind.is_stmt(self) @inline => self.family == STMT;
fn bool NodeKind.is_expr(self) @inline => self.family == EXPR;
fn bool NodeKind.is_type(self) @inline => self.family == TYPE;

<* True for the three recovery kinds the parser emits on malformed input. *>
fn bool NodeKind.is_error(self) @inline
	=> self == ERROR_DECL || self == ERROR_STMT || self == ERROR_EXPR;

<*
 One syntactic form.

 `tok`, `first_tok` and `last_tok` are indices into `TokenList.code` (the
 non-trivia stream), never into `TokenList.all`.
*>
struct Node
{
	NodeKind kind;
	<* The node's principal token: its operator, keyword or name. *>
	uint     tok;
	<* Span start, inclusive: the first token of the whole subtree. *>
	uint     first_tok;
	<* Span end, inclusive: the last token of the whole subtree. *>
	uint     last_tok;
	NodeId   lhs;
	NodeId   rhs;
}

<* The arena for one source file. *>
struct Ast
{
	List{Node}   nodes;
	<* Child lists for list-bearing kinds. Reach them via `Ast.children`. *>
	List{NodeId} extra;
	<* The translation unit node; NONE until the parser finishes. *>
	NodeId       root;
}

<* Prepare an empty arena with the NONE sentinel installed at index 0. *>
fn void Ast.init(&self, Allocator a)
{
	self.nodes.init(a);
	self.extra.init(a);
	self.root = NONE;
	// Index 0 must be the NONE sentinel so that NodeId 0 reads as "absent".
	self.nodes.push({ .kind = NONE_NODE });
}

fn void Ast.free(&self)
{
	self.nodes.free();
	self.extra.free();
}

<* Append a node and return its id. *>
fn NodeId Ast.add(&self, NodeKind kind, uint tok, uint first_tok, uint last_tok,
                  NodeId lhs = NONE, NodeId rhs = NONE)
{
	NodeId id = (NodeId)self.nodes.len();
	self.nodes.push({ kind, tok, first_tok, last_tok, lhs, rhs });
	return id;
}

<*
 Append a child list to `extra` and return it as an (lhs, rhs) pair ready to
 store on a list-bearing node.
 @return "the start index and the count"
*>
fn NodeId[<2>] Ast.add_children(&self, NodeId[] ids)
{
	NodeId start = (NodeId)self.extra.len();
	foreach (id : ids) self.extra.push(id);
	return { start, (NodeId)ids.len };
}

<* The node for `id`. `NONE` yields the sentinel, never a bad pointer. *>
fn Node* Ast.node(&self, NodeId id)
{
	return &self.nodes.array_view()[id];
}

fn NodeKind Ast.kind(&self, NodeId id) @inline => self.node(id).kind;

<*
 True when `lhs`/`rhs` address a child list in `Ast.extra` rather than being
 two plain NodeIds.

 This is the single source of truth for a node's shape. Keep it in step with
 the field-contract tables at the top of this file.
*>
fn bool NodeKind.is_list_bearing(self)
{
	switch (self)
	{
		case BLOCK:
		case CALL:
		case INIT_LIST:
		case IF:
		case TERNARY:
		case FOR:
		case FOREACH:
		case FOREACH_R:
		case SWITCH:
		case CT_SWITCH:
		case SLICE:
		case SIGNATURE:
		case STRUCT_DECL:
		case UNION_DECL:
		case BITSTRUCT_DECL:
		case ENUM_DECL:
		case INTERFACE_DECL:
		case ENUM_CONST:
		case ATTR:
		case LAMBDA:
		case TYPE_FN:
		case TYPE_GENERIC:
		case ASM_BLOCK:
		case CT_IF:
		case CT_FOR:
		case CT_FOREACH:
		case ASSERT:
		case NEXTCASE:
			return true;
		default:
			return false;
	}
}

<*
 The children of a list-bearing node.

 Returns an empty slice for every other kind, so a visitor may call this
 unconditionally. Reading `lhs`/`rhs` as a range on a two-node-id kind would
 interpret a NodeId as a count, which is why the shape test comes first.
*>
fn NodeId[] Ast.children(&self, NodeId id)
{
	Node* n = self.node(id);
	if (!n.kind.is_list_bearing() || !n.rhs) return {};
	return self.extra.array_view()[n.lhs : n.rhs];
}

<* Total node count, including the NONE sentinel at index 0. *>
fn sz Ast.len(&self) @inline => self.nodes.len();
