<*
 The Phase 1 gate: run the parser over the real C3 corpus.

 See docs/DESIGN.md section 3 ("the corpus is two corpora, not one") and
 docs/ROADMAP.md section 3. Two separate requirements, not one:

   - CONFORMANCE corpus (642 files: c3c/lib + c3c/test/unit, all valid C3):
     every file must parse with ZERO ERROR_* nodes and all four structural
     invariants held. This is the bar lexer.c3l's own test.sh set, and
     c3f met, over the same stdlib.
   - RESILIENCE corpus (816 files: c3c/test/test_suite, most of them
     DELIBERATELY invalid -- 662 carry "// #error" annotations by design):
     the parser must never crash or hang, and invariants 1/2 (span nesting,
     edge validity) must still hold even on garbage. Zero ERROR_* nodes is
     NOT expected here and is not asserted.

 The corpus lives in a sibling checkout, found via the C3C_CHECKOUT
 environment variable (default: /home/km/Documents/c3c). If that directory
 is not present, these tests report it and return without asserting
 anything, rather than failing on a machine that doesn't have the sibling
 repo -- but on the orchestrator's own machine, where it always exists,
 this IS the gate.
*>
module c3::parser::conformance;

import c3::parser;
import c3::lexer;
import c3::parser::invariants;
import std::io;
import std::io::path;
import std::os::env;
import std::collections::list;

fn String checkout_dir()
{
	String? v = env::tget_var("C3C_CHECKOUT");
	if (try v) return v;
	return "/home/km/Documents/c3c";
}

<* Every *.c3 and *.c3i file under `dir`, recursively. Result in temp memory. *>
fn String[] find_c3_files(String dir)
{
	List{String} out;
	out.tinit();
	walk(&out, dir);
	return out.to_tarray();
}

fn void walk(List{String}* out, String dir) @local
{
	Path? p = path::tnew(dir);
	if (catch p) return;
	PathList? entries = path::ls(tmem, p);
	if (catch entries) return;
	foreach (e : entries)
	{
		String name = e.basename();
		if (name == "." || name == "..") continue;
		String full = string::tformat("%s/%s", dir, name);
		if (file::is_dir(full))
		{
			walk(out, full);
			continue;
		}
		if (name.ends_with(".c3") || name.ends_with(".c3i")) out.push(full);
	}
}

struct Summary
{
	sz files;
	sz with_errors;
	sz invariant_failures;
	sz crashed;
	<* First few failing paths, so a failure is diagnosable without rerunning. *>
	String[16] detail;
	sz detail_n;
}

<*
 `why` and `path` may be backed by the caller's temp arena (e.g. inside the
 per-file @pool() in `run_over`), which is reclaimed before this report is
 read back. Copy with `mem` so the detail survives past that scope.
*>
fn void Summary.note(&self, String path, String why)
{
	if (self.detail_n < self.detail.len) self.detail[self.detail_n] = string::format(mem, "%s: %s", path, why);
	self.detail_n++;
}

fn Summary run_over(String[] files, bool require_no_errors)
{
	Summary s;
	foreach (f : files)
	{
		s.files++;
		@pool()
		{
			char[]? bytes = file::load(tmem, f);
			if (catch bytes)
			{
				s.crashed++;
				s.note(f, "could not read file");
			}
			else
			{
				ParseResult r = parser::parse(tmem, (String)bytes);
				if (r.has_errors())
				{
					s.with_errors++;
				}
				Report rep = invariants::check(&r);
				if (!rep.edges_valid || !rep.spans_nest)
				{
					s.invariant_failures++;
					s.note(f, rep.detail);
				}
				else if (r.has_errors() && require_no_errors)
				{
					s.note(f, r.errors.len() > 0 ? r.errors[0].msg : "lex failed");
				}
			}
		};
	}
	return s;
}

fn void Summary.report(&self, String label)
{
	io::printfn("%s: %d files, %d with parse errors, %d invariant failures, %d unreadable",
		label, self.files, self.with_errors, self.invariant_failures, self.crashed);
	for (sz i = 0; i < self.detail_n && i < self.detail.len; i++) io::printfn("  %s", self.detail[i]);
	if (self.detail_n > self.detail.len)
	{
		io::printfn("  ... and %d more", self.detail_n - self.detail.len);
	}
}

<*
 The Phase 1 gate. Fails the test unless every conformance-corpus file
 parses with zero errors and intact invariants.
*>
fn void conformance_corpus_is_clean() @test
{
	String base = checkout_dir();
	String lib_dir = string::tformat("%s/lib", base);
	String unit_dir = string::tformat("%s/test/unit", base);

	if (!path::exists(path::tnew(base) ?? (Path){}))
	{
		io::printfn("C3C_CHECKOUT '%s' not found; skipping the Phase 1 gate on this machine", base);
		return;
	}

	String[] files = find_c3_files(lib_dir);
	String[] unit_files = find_c3_files(unit_dir);
	List{String} all;
	all.tinit();
	foreach (f : files) all.push(f);
	foreach (f : unit_files) all.push(f);

	Summary s = run_over(all.to_tarray(), true);
	s.report("conformance corpus");

	assert(s.files > 0, "found no corpus files under '%s' -- is C3C_CHECKOUT right?", base);
	assert(s.crashed == 0, "the parser could not read %d file(s)", s.crashed);
	assert(s.invariant_failures == 0,
		"%d file(s) violate span/edge invariants -- see the detail above", s.invariant_failures);
	assert(s.with_errors == 0,
		"%d conformance file(s) produced parse errors on VALID C3 -- see the detail above", s.with_errors);
}

<*
 The resilience half: the deliberately-broken test_suite must never crash
 the parser and must never violate span nesting or edge validity, but is
 NOT required to parse error-free -- most of it is error-free by accident
 of being a semantic (not syntactic) test, not by this test's design.
*>
fn void resilience_corpus_does_not_crash() @test
{
	String base = checkout_dir();
	String dir = string::tformat("%s/test/test_suite", base);

	if (!path::exists(path::tnew(base) ?? (Path){}))
	{
		io::printfn("C3C_CHECKOUT '%s' not found; skipping the resilience check on this machine", base);
		return;
	}

	String[] files = find_c3_files(dir);
	Summary s = run_over(files, false);
	s.report("resilience corpus (test_suite, mostly deliberately invalid)");

	assert(s.files > 0, "found no files under '%s' -- is C3C_CHECKOUT right?", dir);
	assert(s.crashed == 0, "the parser could not read %d file(s)", s.crashed);
	assert(s.invariant_failures == 0,
		"%d file(s) violate span/edge invariants even though those invariants must hold on ANY input",
		s.invariant_failures);
}


