<*
 The parser's own error type.

 FROZEN INTERFACE. See docs/DESIGN.md section 1.5 rule 2.

 Deliberately minimal: no severity, no check name, no file path, because the
 parser knows none of those. `c3vet` maps a ParseError onto its own Diagnostic
 and supplies the rest. The parser must never name `Diagnostic` — that is the
 coupling most likely to appear by accident and the reason this file is frozen.
*>
module c3::parser;

import std::collections::list;

struct ParseError
{
	<* Index into `TokenList.code` where the problem was found. *>
	uint   tok;
	<* What was wrong, phrased for a user: "expected ';'". *>
	String msg;
}

alias ParseErrorList = List{ParseError};
