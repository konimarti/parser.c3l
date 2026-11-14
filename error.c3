<*
 The parser's own error type.

 FROZEN INTERFACE.

 Deliberately minimal: no severity, no check name, no file path, because the
 parser knows none of those. A consumer maps a ParseError onto its own richer
 diagnostic type and supplies the rest; the parser itself must never name one.
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
