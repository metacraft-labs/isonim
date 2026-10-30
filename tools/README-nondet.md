Run `just lint-nondet` to check the framework and nim-everywhere, including the
scanner's real-file negative controls and real Nim compiler escape probes. Run `just test-strict-nondet` for the
native and JS compiler controls.

A site can reuse the same checker with all source roots in one invocation:

```sh
python3 ../isonim/tools/lint_nondet.py \
  --allowlist ../isonim/tools/nondet_allowlist.json \
  ../isonim/src ../nim-everywhere/src src
```

The allowlist uses exact `repository/src/path`, API, count and reason entries.
Adding a use, deleting an obsolete allowance's use, or omitting a reason fails.
Warnings for Worker, WebAssembly, BroadcastChannel and indexedDB remain visible
and cannot be suppressed by a fatal-API allowance. New site exceptions belong in
the same supplied allowlist and must identify their boundary and justification.

The scanner checks literal importjs/importc/emit payloads, emit fragment arrays,
and JavaScript lexical tokens, ignoring comments and ordinary strings. Git
ownership excludes ignored generated outputs and submodule trees; untracked
source is included. Without Git, it scans all files in the source roots. It
recognizes literal bracket members, but does not infer aliases, computed member
names, generated code or ordinary Nim variables later evaluated as JavaScript.

Ordinary Nim string escapes are decoded using Nim's literal grammar before
scanning JavaScript, including named/control, hexadecimal/decimal byte and
Unicode escapes. Raw/triple/generalized literals keep literal backslashes.
Diagnostics identify physical Nim source lines, even when escapes insert JS
line breaks or emit arrays splice multiple literals. The standalone checker
needs only Python and Git; the recipe's compiler controls also need Nim and Node.

The existing native editor/iframe/preview adapter allowances are a bounded
inventory, not a claim that those adapters can be recorded and replayed. They
include computed-style and scroll geometry beyond the present rectangle seam.
New application code uses `isonim/core/nondet` instead.

Strict mode makes the legacy raw platform entry points compiler errors. The
Real backend and platform implementation explicitly delegate with
`RawBackendAccess`; this opt-in documents trust, rather than acting as a security
capability. Raw effect tags cannot prove effects through closure fields. Source
lint remains the enforcement for foreign calls.

The same CLI also checks raw `value`/`textContent` bindings on directly identified
free-text DOM elements in JavaScript and literal foreign JavaScript payloads.
It recognizes local `document.createElement` allocations, simple local aliases,
literal input type/editable/autocomplete assignments and literal HTML attribute
setters. Input types default to text; textarea and explicitly enabled editable
elements are free-text. Credential autocomplete tokens use ASCII whitespace.
JavaScript property names remain case-sensitive; HTML attribute names fold ASCII
case. Raw public/sensitive marker attributes do not authorize a raw binding.

This is bounded source analysis, not whole-program privacy certification. A
tracked DOM receiver whose metadata becomes uncertain through a call, computed
member or unsupported control flow reports an unresolved privacy binding instead
of keeping an earlier checkbox exemption. Ordinary ViewModel `.value` writes,
button labels and text nodes are not inferred to be free-text fields. Function
parameters, lexical declarations and `var` hoisting shadow the global document;
opaque Nim splices do not provide JavaScript receiver identity.

Visiting a deferred function body does not apply its assignments to captured
bindings in the caller's present state. Captured bindings and allocation
metadata have separate function-local analysis views; an unknown invocation
still invalidates classification. Replacing a tracked DOM local with an
unknown expression retains an unresolved binding obligation on that local,
without changing an existing alias's identity. A whole object-literal model
replacement and a known direct DOM replacement remain distinct controls.
Recognized branch, loop and exception bodies (including braceless if/while/for)
cannot certify a replacement of an outer binding from only the visited arm.
The post-boundary binding stays unresolved; fresh branch-local declarations and
later unconditional known replacements retain their separate identity.

Ordinary Nim has a separate bounded local frontend for direct calls to the
shipped `isonim/web/dom_api` module. Exact imports (including aliases and bracket
imports), qualified calls, and unambiguous imported UFCS calls establish identity.
It recognizes `document` allocations, aliases, resolved Node/Element upcasts,
metadata setters/removal (including named/reordered owning formal arguments),
dynamic-property getters/setters, attribute value
bindings and inherited `.textContent` access. It shares the JavaScript field
classifier. Known text nodes and button labels remain controls. Local declarations
and parameters shadow imports sequentially; Nim symbol matching preserves the
first character and ignores later ASCII case/underscores. Literal metadata retains its token kind; the boolean enum names true/false count only with no visible lexical binding or unresolved competing import. A local cstring named false, including a backtick/style-equivalent name, is unknown metadata rather than a false literal. Constructor tags, member names and values use this same provenance check; strings keep their existing literal decoding. No local constant folding is performed. Backtick-quoted ordinary
identifiers retain identity without becoming control keywords. Other imports disable
unqualified API inference because they may supply competing overloads; qualified
owning-module calls remain analyzable. `from`/`except` forms are unanalysed.

Local `let`/`var`/`const` declaration identities come only from structural
binder positions. Comma groups, optional type annotations, export markers and
binder pragmas retain the same Nim name; type names, initializer identifiers and
pragma payloads do not introduce bindings. Each comma initializer runs before its
own binding becomes visible, in source order. Repeated constructor initializers
have distinct finite binder sites; actual aliases retain the same receiver.
Diagnostics identify authored receiver spans: repeated evaluation of one grouped
initializer reports its access once, while separate accesses on the same physical
line remain separate. All initializer effects still run in source order. If one
site has both known free-text and unresolved observations, its single diagnostic
retains the unresolved obligation. Speculative loop observations are discarded
before authored-site aggregation.

Tuple declaration binders become visible after the initializer. Direct authored
tuple positions preserve receiver references and their evaluation order, including
a saved reference read before a later component rebinds its source cell. Other
tuple expressions do not gain positional or type inference: already tracked DOM
obligations remain uncertain possible receivers. Unknown local values still
shadow builtin booleans, with the existing lexical restoration and capture rules.
Plain parenthesized statement lists retain their declarations in the enclosing
lexical scope, including captured mutable cells. An explicit `block:` retains its
normal scope restoration.
This adds declaration ownership, not general destructuring assignment analysis.

Nim branches, loops and exception paths retain possible allocation identities;
relevant mutations through an uncertain alias invalidate its possible objects.
Harmless id/title writes preserve known checkbox classification. Loops join the
zero-iteration path and reachable back edges to a finite allocation-site fixed
point before checking body bindings. Different metadata coordinates widen
individually, so an unconditional literal type assignment before a binding can
recover that type within the same iteration; unknown-call/receiver obligations
remain unresolved. Fresh loop-local allocations retain their own initialization.
While-condition effects occur before the body on each reachable iteration.
Normal and abrupt completions are separate: break/continue/return/raise stop
unreachable suffixes, and lexical loop/block targets own their exit/backedge
states. Handler entry conservatively joins protected reachable prefixes, not
just the state before the try or its normal final state; a later normal reset
cannot erase an earlier potentially exceptional mutation or alias replacement.
Snapshots preserve outer roots and aliases across inner same-named declarations;
expression-internal effect boundaries are included. Implicit exceptional prefixes
also reach finally cleanup, which keeps incoming completion ownership unless it
completes abruptly.
These are bounded source-flow checks, not thrown-type or call-graph inference.
Semicolon sequences following an inline control/routine header stay inside its
body, including later statements on the same physical line. Literal semicolon
contents and delimiter-enclosed parameter lists do not create sibling statements.
Routine bodies
have separate allocation views; actual calls to a locally analyzed routine
invalidate captured metadata that its body may change. Unknown calls invalidate
passed tracked receivers. Unknown reassignment retains an unresolved obligation
on an already tracked receiver; later unconditional known allocation can recover
that binding. Whole literals alone establish metadata: arbitrary generalized
string macros (including unproved `cstring"..."`) are unknown, not constants.
Physical receiver lines and distinct same-line accesses remain visible.

This does not resolve arbitrary typed Nim/importcpp, generic renderer identities,
macro expansion, helper-return/cross-module flow, generated source or inherited
editable state. A zero result on those forms is no privacy guarantee. Use
the DSL's explicit field policy rather than treating a raw marker or a missing
lint finding as an authorization. Invalid literal metadata and uncertain tracked
DOM bindings remain unsupported. Existing platform-API allowances and the exact
trusted backend platform exclusion never suppress privacy findings; privacy
allowlist entries are rejected. No entire file or site path is exempted.

This recognizer does not certify arbitrary destructuring assignments or
expression-bodied callbacks, nor infer invocation order through helper calls.
Those unsupported JavaScript forms need further owning analysis; they must not
be treated as a whole-program privacy result.

Metadata property writes use the complete ordinary JavaScript assignment family
(`=`, arithmetic, exponentiation, shift, bitwise, logical and nullish compound
assignments) and prefix/postfix `++`/`--`. Only a whole literal RHS of plain
assignment establishes literal metadata. Every other such write loses the old
metadata certification, including through a local alias or literal bracket
member. Read-only equality/comparison operators remain distinct tokens and do
not change that state. Raw `value`/`textContent` findings are independent of the
operator used on that raw access. This is bounded lexical analysis, not runtime
proof of JavaScript coercion or a complete language parser.

Receiver-local writes use that same complete assignment/update family. Plain
`=` can establish a known replacement allocation. Other writes retain an
unresolved DOM obligation when either the old receiver or a direct known RHS
alias has DOM provenance. Possible old/RHS identities stay distinct: merely
rebinding does not mutate either object's metadata, but a later mutation through
the uncertain receiver invalidates its possible aliases. Deferred function views
isolate these changes until an unknown invocation invalidates present metadata.
Ordinary unknown models acquire no DOM provenance from an operator alone. This
is conservative local flow analysis, not general expression or browser execution.

An uncertain plain replacement preserves possible local receiver identities too,
including conditional choices passed through another local. Subsequent metadata,
attribute, computed-write or method mutation invalidates those possible aliases;
merely selecting a receiver does not mutate the old objects. Bare local result references and recognized conditional result arms supply
edges for an already tracked receiver; comparisons, conditions, containers,
property-derived values and closure captures do not prove result identity.
Unknown declaration expressions gain no inferred receiver origin. An opaque replacement of an
already tracked DOM receiver conservatively retains visible DOM candidates.
Unknown models without tracked DOM inputs receive no invented DOM authority.
Alias invalidation and deferred-view construction visit allocation identities
iteratively, retaining sharing without recursive graph traversal.

A conditional result set is precise only when every result arm is a recognized
known local allocation. An uninspectable arm discards the partial set and uses
the already tracked receiver's conservative visible-DOM fallback. One known arm
cannot certify that an unknown intermediate choice excludes other DOM locals.

Receiver writes normalize possible RHS identities before selecting plain, logical,
compound or update behavior. Direct locals and complete conditional result arms
retain their identities; any uninspectable result on a tracked receiver falls
back to visible tracked DOM locals, including a partial unknown arm. This shared
normalization does not infer DOM origins for unknown model declarations. Merely
rebinding a receiver changes no old object metadata; later mutations propagate
through its possible allocation edges within the current function view.

The bounded local flow recognizes ordinary semicolon-free JavaScript statements
using token positions and actual JS line terminators, including decoded foreign
JS payloads and line breaks in comments. Whole initializers, aliases, replacement
RHS expressions, literal metadata and braceless control bodies use the same
boundary rule. Newlines within groups/calls or around expression operators, member
accesses, calls and tagged templates remain continuations; template prose stays
elided and executable interpolations remain checked. Prefix versus restricted
postfix updates do not grant a metadata exemption. This remains a bounded lexical
analysis, not a general JavaScript parser or whole-program privacy certification.
# Lexical loop and exception ownership

Within the bounded local JavaScript analysis, `let`/`const` declarations in a
`for` header shadow only the header and body, including their TDZ. Ordinary
for-of, for-in and classic for bodies may be braced, braceless, nested or labelled;
for-await uses the same lexical ownership. `var` still hoists to the containing
real function, including through a catch block. Catch parameters shadow only
their catch body and do not create a function boundary. Possible writes to outer
DOM locals remain unresolved across controls; a fresh unconditional allocation
can recover local classification. Deferred bodies retain isolated captured views.
These are lexical checks; they do not simulate loop execution or thrown values.

An authored template delimiter still proves tagged-template continuation when
an opaque Nim emit splice lies inside its interpolation. Its prose supplies no
syntax, its executable interpolation remains checked, and the opaque data never
supplies DOM identity. A tag result is not inferred to be its receiver's DOM
allocation. This does not broaden ordinary Nim/importcpp or cross-module coverage.


Routine scopes follow syntax ownership: object/class methods (including keyword,
quoted and computed names and ordinary async/generator/accessor forms) own their
parameters and var declarations. Genuine catch clauses keep block-local
parameters while var declarations hoist to the surrounding routine. A call
followed by a newline and ordinary block is not a routine declaration. Class
static blocks own var bindings without a deferred execution view: their direct
metadata updates remain in the current state. This is bounded lexical ownership,
not proof of method invocation order, computed-key effects or class inheritance.

Unknown calls use callee syntax, including named and bracket members, grouped
callees, immediate block-bodied function/arrow expressions, and tagged templates.
Visiting a routine declaration, grouping a name, or an untagged template does not
execute that routine. Unknown calls invalidate visible captured DOM metadata,
including calls on a different known DOM receiver; recognized literal
setAttribute/removeAttribute metadata operations retain their local semantics.
This conservative call effect is not a general call graph or browser execution
model. Only actual control syntax introduces control-flow uncertainty; a method
named after a control keyword does not execute merely by being declared.

JavaScript identifier identities use Unicode `ID_Start`/`ID_Continue`, with
`$`, `_`, ZWNJ and ZWJ as ECMAScript specifies, and decode fixed-width and
braced Unicode escapes only inside identifier tokens. Binding and dot-member
identity is case-sensitive; physical source offsets retain authored escape
widths. Escaped contextual names remain ordinary identifiers rather than being
reinterpreted as grammar keywords. Opaque Nim spans never acquire identity from
escape decoding. The character-category database is the running Python's
`unicodedata.unidata_version` (qualification:15.1.0); Node qualification uses
Unicode16.0. Newly assigned characters beyond the Python database, malformed
identifier escapes, invalid syntax and unhandled syntax are unanalysed, never
a privacy refusal or a whole-program safety certificate.

Named function expressions (normal, async and generator forms) and named class
expressions retain private expression self-bindings: those names shadow within
the expression and do not hide an outer global `document` or an unrelated DOM
local. Actual function/class declarations retain enclosing-scope shadowing and
TDZ handling. Plain/escaped names share identity. This ownership distinction is
lexical; class heritage/computed-key effects, default-parameter evaluation and
interprocedural/call-graph execution remain unanalysed, not certified safe.

Conditional-expression colons are paired within their delimiter owner before
case/default/statement labels are recognized. A named function or class in a
conditional arm keeps its private self-name, including within a switch case;
real declarations after case/default labels keep their enclosing lexical scope.
This remains a bounded source recognizer, not a complete JavaScript parser.

Class member names are not lexical writes to same-named captured locals. Each
ordinary instance field initializer is analyzed in its own deferred allocation
and binding view, as with a method body; merely declaring the class cannot
change the current outer field metadata. Static fields and static blocks execute
in the present class evaluation. The contextual static modifier differs from an
instance field named static. A subsequent unknown construction invalidates
visible captured metadata, including construction without parentheses; this does
not infer constructor/callback call graphs or field execution order. Class
heritage and computed-key effects remain unanalysed, as do default parameters,
expression-only callback bodies and the other documented full-parser limits.

Conditional arms and short-circuit right operands (`&&`, `||`, `??`, including
logical assignments) retain bounded guarded-execution ranges. A metadata or
receiver write in such an operand cannot certify a later non-free exemption;
tracked outer obligations become unresolved. Read-only conditions and operands
do not invalidate allocations, and a mutation in the condition/left operand
retains its unconditional timing. Argument commas, balanced groups, statement
boundaries and ASI bound these effects; fresh local allocations and deferred
routine/instance-initializer views retain their separate ownership. This is
conservative branch joining, not evaluation of conditions or a full parser.

Guarded initializations of the same hoisted var binding retain possible allocation
alternatives from different control paths. Straight-line redeclarations on one
path replace that path's earlier alternatives; an unconditional replacement
recovers a definite binding. Plain nested blocks do not invent another branch,
and classic for initializers retain their unconditional timing. Ordinary writes
keep their existing conservative joins; declaration history uses the same actual
lexical binding owner and deferred-routine view. This does not infer branch
conditions or claim complete statement/reachability analysis.

Actual break/continue/return/throw statements retain conservative uncertainty for
later metadata and receiver replacements within their enclosing jump target.
Nested loops, switch bodies and statement labels bound break/continue effects;
method/property names do not introduce jumps. Return/throw operands remain
checked. A locally caught throw ends its suffix at the handler boundary, so
fresh unconditional replacement after a complete try/catch can recover normally.
Classic for updates are optional; the initializer and first condition evaluation
retain their distinct timing. This is bounded uncertainty, not a complete
reachability or exception/call-graph interpreter.

Whole expression statements and return/throw operands retain their complete comma
sequence through the statement terminator or supported ASI boundary. This does
not merge separate declaration initializers or call arguments. Braceless control
bodies retain uncertainty through every executed comma operand.

Whole no-op parenthesized local primaries preserve identity in declarations,
receiver writes and member access, including grouped direct DOM constructors and
grouped global document receivers. Literal-bracket reads also accept optional
member syntax. Call arguments/results, formal parameters, control headers, comma
sequences and conditional results do not become bare aliases by losing their
parentheses. Member property names never identify a same-named lexical DOM local.
Grouping retains the inner receiver identifier's physical source location and
opaque foreign fragments retain their independent provenance. Ordinary grouped
model replacements remain models; grouped metadata updates/deletes share the
existing conservative mutation rules. These are bounded primary compositions,
not inferred helper returns, complete optional-chain interpretation or a full
JavaScript parser.

Whole grouped local-member references share the same metadata assignment,
compound/update, delete and literal setter/removal rules as ungrouped members.
Grouping preserves the authored receiver location; actual call results, formal
parameters and control headers do not establish receiver identity. This remains
a bounded lexical check rather than full JavaScript analysis.
Direct document allocation method references can likewise be grouped before
their literal call; arbitrary helper-returned or model method results still
supply no DOM origin.
Known unrelated property deletion, like its assignment/update counterparts,
does not change the local privacy classification; relevant or computed-unknown
member deletion retains the conservative unresolved obligation.

Possible-alias metadata updates first check relevance to field privacy. Known
unrelated property/attribute writes (including grouped/bracket members and
compound/update operators) retain each original checkbox's classification.
Unknown/computed names and potentially relevant metadata on an unknown-tag
receiver remain conservative; this does not certify arbitrary method effects.

Local Nim routine defaults and bodies are analyzed for authored raw bindings
without executing their effects in the enclosing scope. A possible actual call
conservatively invalidates possibly affected captured DOM objects, including intermediate
metadata before a later normal reset. Formal parameters and parenthesized
statement-list locals retain lexical shadowing. Same-scope overload summaries
are combined conservatively; nested declarations start their own lexical owner.
This does not infer argument types, helper returns or a cross-module call graph.
A statement list preserves its already-evaluated final tracked value in its
enclosing lexical frame. Deferred defaults own a separate scope; their declarations
remain isolated from the caller. Free or unknown DOM tails retain conservative
possible provenance; proven non-free tails keep their shared allocation identity
so a later alias metadata write still reaches the original field. Ordinary
model tails stay ordinary. This does not evaluate an expression twice.

Captured local Nim variables have lexical binding identity distinct from their
DOM objects. Actual calls resolve the current binding after replacement and
respect both routine-local and caller-local shadowing. Metadata summaries retain
the authored member and test its relevance on the current receiver, including a
mutable receiver whose former tag made that member irrelevant. Binding writes
replace the abstract receiver without mutating discarded objects still held by
immutable aliases; optional replacements retain possible old receivers. Local
alias dependencies travel with the same copied/joined allocation graph. This
remains a finite local direct-call check, without general escaping-closure,
helper-return, arbitrary typed-wrapper or cross-module inference.

Copied local references snapshot the invocation's object graph before later cell
replacement; they keep object identity independently of their source variable.
Authored operation sites keep ordered metadata writes distinct across replacement.
Same-scope overloads execute in separate abstract graph views, with nested choices
retained in deferred observations. Loop widening preserves known possible RHS
reference edges without a guessed iteration bound. These remain local lexical
operations and do not certify arbitrary typed or cross-module code.

Local deferred routine operations retain their authored invocation context: two
caller statements around a captured-cell replacement remain distinct, including
nested wrappers and copied-reference witnesses. Repeated analysis of one authored
call inside a loop reuses that finite context. Retained witness alternatives are
kept separately from the current snapshot, so earlier copied objects cannot move
with a later cell replacement. A snapshot of the actual current loop-widened cell
retains that cell's possible known RHS receivers. These local flow summaries add
no runtime counters, general call graph, escaping-closure or type inference.
