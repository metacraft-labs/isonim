"""Bounded lexical DOM-origin analysis for the source lint.

Only direct HTML document allocations and local aliases have identity here.
This deliberately does not infer Nim types, execute JavaScript, follow helper
returns, or certify unknown objects. Uncertainty on a tracked DOM allocation
cannot retain an exemption established by its former input type.
"""
from dataclasses import dataclass, field
from copy import copy
import re
import unicodedata

RAW = 'free-text binding'
UNRESOLVED = 'unresolved DOM privacy binding'
PRIVACY_APIS = frozenset({RAW, UNRESOLVED})
TEXT_TYPES = frozenset({'text', 'search', 'email', 'tel', 'url', 'password'})
OTHER_TYPES = frozenset({'hidden', 'date', 'month', 'week', 'time', 'datetime-local',
                         'number', 'range', 'color', 'checkbox', 'radio', 'file',
                         'submit', 'image', 'reset', 'button'})
ASCII_SPACE = re.compile('[ \t\n\r\f]+')
# One lexical family supplies both longest-token recognition and write dispatch.
# Comparisons must remain whole tokens so == cannot masquerade as assignment.
ASSIGNMENT_OPERATORS = frozenset({'=', '+=', '-=', '*=', '/=', '%=', '**=',
                                 '<<=', '>>=', '>>>=', '&=', '^=', '|=',
                                 '&&=', '||=', '??='})
UPDATE_OPERATORS = frozenset({'++', '--'})
LEXICAL_OPERATORS = ASSIGNMENT_OPERATORS | UPDATE_OPERATORS | frozenset({
    '===', '!==', '==', '!=', '<=', '>=', '=>', '?.', '&&', '||', '??',
    '<<', '>>', '>>>', '**'})
OPERATOR_PATTERN = '|'.join(re.escape(op) for op in
                            sorted(LEXICAL_OPERATORS, key=lambda op: (-len(op), op)))



def ascii_lower(value):
    return value.translate(str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                                        'abcdefghijklmnopqrstuvwxyz'))


def string_value(raw):
    """Decode a JS quoted literal without evaluating source or using Python codecs.

    The supported JS escape forms have explicit lengths; invalid/unsupported
    forms return unknown. In particular Python's unicode_escape is not JS.
    """
    if len(raw) < 2 or raw[-1] != raw[0]: return None
    out, i, end = [], 1, len(raw) - 1
    simple = {'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v',
              '0': '\0', '"': '"', "'": "'", '\\': '\\'}
    while i < end:
        ch = raw[i]; i += 1
        if ch != '\\':
            if ch in '\r\n\u2028\u2029': return None
            out.append(ch); continue
        if i == end: return None
        ch = raw[i]; i += 1
        if ch in '\r\n\u2028\u2029':
            if ch == '\r' and raw[i:i+1] == '\n': i += 1
            continue
        if ch in simple:
            if ch == '0' and raw[i:i+1].isdigit(): return None
            out.append(simple[ch]); continue
        if ch in 'xu':
            braced = ch == 'u' and raw[i:i+1] == '{'
            if braced:
                close = raw.find('}', i + 1, end)
                if close < 0: return None
                digits = raw[i+1:close]; i = close + 1
            else:
                width = 2 if ch == 'x' else 4
                digits = raw[i:i+width]; i += width
                if len(digits) != width: return None
            if not digits or not re.fullmatch('[0-9a-fA-F]+', digits): return None
            value = int(digits, 16)
            if value > 0x10ffff: return None
            out.append(chr(value)); continue
        # Identity escapes are legal in ordinary non-strict JS strings. Avoid
        # guessing legacy octal semantics: those metadata values are unknown.
        if ch.isdigit(): return None
        out.append(ch)
    return ''.join(out)


@dataclass(frozen=True)
class Token:
    kind: str
    value: str | None
    start: int
    end: int


# ECMAScript IdentifierStart/IdentifierPart use Unicode ID_Start/ID_Continue,
# not Python's XID-normalized identifiers or a case-insensitive word regex.
# https://tc39.es/ecma262/#sec-names-and-keywords
OTHER_ID_START = frozenset('\u1885\u1886\u2118\u212e\u309b\u309c')
OTHER_ID_CONTINUE = frozenset('\u00b7\u0387\u1369\u136a\u136b\u136c\u136d\u136e\u136f\u1370\u1371\u19da\u200c\u200d\u30fb\uff65')


def identifier_start(ch):
    # U+2E2F is the one letter-category Pattern_Syntax exclusion in Unicode15.1.
    return ch in '_$' or ch in OTHER_ID_START or (ch != '\u2e2f' and unicodedata.category(ch) in {'Lu', 'Ll', 'Lt', 'Lm', 'Lo', 'Nl'})


def identifier_part(ch):
    return identifier_start(ch) or ch in OTHER_ID_CONTINUE or unicodedata.category(ch) in {'Mn', 'Mc', 'Nd', 'Pc'}


def identifier_at(source, start):
    """Return IdentifierValue and physical extent, never decode surrounding JS.

    Invalid escapes/identifier characters are unsupported syntax. They do not
    become a DOM finding or evidence of privacy refusal. Fixed-width surrogate
    escapes are not combined: ECMAScript identifiers require a code point in
    ID_Start/Continue, unlike string literal UTF-16 escape semantics.
    """
    cursor, value = start, []
    while cursor < len(source):
        end = cursor + 1
        ch = source[cursor]
        if ch == '\\':
            if source[cursor:cursor+2] != '\\u': break
            if source[cursor+2:cursor+3] == '{':
                close = source.find('}', cursor+3)
                if close < 0: break
                digits = source[cursor+3:close]; end = close+1
            else:
                digits = source[cursor+2:cursor+6]; end = cursor+6
                if len(digits) != 4: break
            if not digits or not re.fullmatch('[0-9a-fA-F]+', digits): break
            # Bound conversion as well as code point range for malformed input.
            if len(digits.lstrip('0')) > 6: break
            point = int(digits, 16)
            if point > 0x10ffff: break
            ch = chr(point)
        if not (identifier_part(ch) if value else identifier_start(ch)): break
        value.append(ch); cursor = end
    return (''.join(value), cursor) if value else (None, start)


def tokens(text, mask, literals, opaque):
    result = []
    symbol = re.compile(r'\d+(?:\.\d+)?|' + OPERATOR_PATTERN + r'|[^\s]')
    cursor = 0
    while cursor < len(mask):
        if mask[cursor].isspace(): cursor += 1; continue
        value, end = identifier_at(mask, cursor)
        if value is None:
            match = symbol.match(mask, cursor)
            value, end = match[0], match.end()
            kind = 'symbol'
        else: kind = 'id'
        if not any(a < end and b > cursor for a, b in opaque):
            result.append(Token(kind, value, cursor, end))
        cursor = end
    for a, b in literals:
        # A template's interior may contain an opaque Nim interpolation while
        # its authored opening delimiter still proves continuation syntax.
        # Keep that structural extent without giving the interpolation identity.
        template = text[a:a+1] == '`'
        if not any(x <= a < y if template else x < b and y > a for x, y in opaque):
            result.append(Token('template' if text[a:a+1] == '`' else 'string',
                                None if text[a:a+1] == '`' else string_value(text[a:b]), a, b))
    for a, b in opaque: result.append(Token('opaque', None, a, b))
    return sorted(result, key=lambda t: t.start)


@dataclass(eq=False)
class Scope:
    parent: 'Scope | None' = None
    function: bool = False
    uncertain: bool = False
    bindings: dict = field(default_factory=dict)
    # Static initialization blocks own var bindings but execute immediately.
    # Only actual routines create deferred allocation/binding views.
    var_owner: bool = False

    def lookup(self, name):
        scope = self
        while scope:
            if name in scope.bindings: return scope, scope.bindings[name]
            scope = scope.parent
        return None, None


@dataclass(eq=False)
class Allocation:
    tag: str | None
    scope: Scope
    text_node: bool = False
    input_type: str | None = 'text'
    editable: bool | None = False
    credential: bool | None = False
    uncertain: bool = False
    # An uncertain receiver can still denote these distinct allocations.
    # Keep the edges, rather than merging their metadata or losing old aliases.
    possible_aliases: tuple = ()

    def finding(self):
        if self.text_node: return None
        if self.uncertain or self.tag is None: return UNRESOLVED
        if self.editable is None or self.credential is None: return UNRESOLVED
        if self.editable or self.credential or self.tag == 'textarea': return RAW
        if self.tag == 'input':
            if self.input_type is None: return UNRESOLVED
            if self.input_type in TEXT_TYPES or self.input_type == '<dynamic>': return RAW
        return None


def invalidate(allocation):
    """Lose metadata certainty, including all possible receiver identities."""
    pending, visited = [allocation], set()
    while pending:
        current = pending.pop()
        if current in visited: continue
        visited.add(current)
        current.uncertain = True
        pending.extend(current.possible_aliases)


def metadata_relevant(allocation, name, *, attribute=False):
    """Whether this local member can change the field's privacy classification.

    A synthetic possible-alias receiver has an unknown tag. It can still name
    an input/form field, so its type/autocomplete cannot be declared irrelevant.
    """
    if attribute: name = ascii_lower(name) if name is not None else None
    editable_name = 'contenteditable' if attribute else 'contentEditable'
    return (name is None or name == editable_name or
            name == 'type' and allocation.tag in {None, 'input'} or
            name == 'autocomplete' and allocation.tag in {None, 'input', 'textarea', 'select'})


def metadata(allocation, name, value, *, attribute=False, guarded=False):
    """Update the allocation shared by aliases; names are JS-case-sensitive.

    HTML setAttribute names alone fold ASCII. A div's type is never input.type.
    Invalid/inherited states are unknown here, not new HTML privacy policy.
    """
    if allocation.text_node: return
    # An uncertain receiver retains distinct possible objects. Only metadata
    # relevant to its privacy classification can invalidate those objects;
    # literal id/title writes are harmless even through such an alias.
    relevant = metadata_relevant(allocation, name, attribute=attribute)
    if not relevant: return
    for possible in allocation.possible_aliases:
        invalidate(possible)
    if attribute: name = ascii_lower(name) if name is not None else None
    editable_name = 'contenteditable' if attribute else 'contentEditable'
    # Guarded execution changes certainty only when this supported metadata
    # operation can change the privacy classification. A literal id/data write
    # cannot turn a known checkbox or button into a free-text field.
    if guarded and relevant: invalidate(allocation)
    if name is None:
        allocation.uncertain = True
    elif name == 'type' and allocation.tag == 'input':
        lowered = ascii_lower(value) if value is not None else '<dynamic>'
        allocation.input_type = lowered if lowered in TEXT_TYPES | OTHER_TYPES or lowered == '<dynamic>' else None
    elif name == editable_name:
        lowered = ascii_lower(value) if value is not None else None
        allocation.editable = False if lowered == 'false' else True if lowered in {'', 'true', 'plaintext-only'} else None
    elif name == 'autocomplete' and allocation.tag in {'input', 'textarea', 'select'}:
        allocation.credential = None if value is None else any(
            token.startswith('cc-') or token in {'current-password', 'new-password', 'one-time-code'}
            for token in ASCII_SPACE.split(ascii_lower(value)))


def privacy_bindings(text, mask, literals, opaque):
    """Return (source offset, API) for bounded local DOM property bindings.

    Scope predeclaration prevents parameter/var/TDZ document shadowing from
    manufacturing a global DOM origin. Token metadata, never marker spelling,
    identifies opaque Nim splices. Unknown calls/control flow invalidate tracked
    metadata; unrelated model objects receive no invented DOM provenance.
    """
    ts = tokens(text, mask, literals, opaque)
    n = len(ts)
    if not n: return []
    def v(i):
        # Literal contents never become syntax. Escaped IdentifierNames retain
        # their authored spelling for grammar comparisons; binding/member lookup
        # below uses their decoded IdentifierValue, without case normalization.
        if not 0 <= i < n or ts[i].kind not in {'id', 'symbol'}: return None
        token = ts[i]
        return text[token.start:token.end] if token.kind == 'id' and '\\' in text[token.start:token.end] else token.value
    pairs, stack = {}, []
    for i, t in enumerate(ts):
        if v(i) in {'(', '[', '{'}: stack.append(i)
        elif v(i) in {')', ']', '}'}:
            if stack and v(stack[-1]) == {')': '(', ']': '[', '}': '{'}[v(i)]:
                other = stack.pop(); pairs[i] = other; pairs[other] = i
    def line_break(before, after):
        # Offsets refer to decoded executable JS, including actual newlines in
        # block comments. Comment prose never supplies continuation tokens.
        return bool(re.search(r'[\r\n\u2028\u2029]', text[ts[before].end:ts[after].start]))

    def can_end_expression(index):
        if ts[index].kind in {'string', 'template', 'opaque'}: return True
        value = v(index)
        if value in UPDATE_OPERATORS:
            # Only a postfix update ends an expression. A prefix operator may
            # have a line break before its operand (unlike restricted postfix).
            return index > 0 and not line_break(index-1, index) and can_end_expression(index-1)
        if value in {')', ']', '}'}: return True
        if ts[index].kind == 'id':
            return value not in {'new', 'delete', 'typeof', 'void', 'await', 'yield',
                                 'in', 'instanceof', 'return', 'throw', 'case',
                                 'let', 'const', 'var', 'else', 'do'}
        return bool(value and re.fullmatch(r'\d+(?:\.\d+)?', value))

    continuation = ASSIGNMENT_OPERATORS | frozenset({
        '.', '?.', '(', '[', ',', '?', ':', '+', '-', '*', '/', '%', '**',
        '&', '|', '^', '&&', '||', '??', '<', '>', '<=', '>=', '==', '!=',
        '===', '!==', '<<', '>>', '>>>', 'in', 'instanceof'})

    def asi_boundary(before, after):
        """Recognize supported ASI boundaries, never every physical newline.

        A completed primary can continue through member/call/template syntax or
        a binary/conditional operator. Conversely ++/-- after a line terminator
        cannot be postfix. Nesting is handled by expression_end, so line breaks
        within a call/bracket/group cannot split its outer expression.
        """
        if not line_break(before, after): return False
        if v(before) in {'return', 'break', 'continue', 'yield'}: return True
        if not can_end_expression(before): return False
        if ts[after].kind == 'template' or v(after) in continuation: return False
        return True

    def expression_end(start, *, sequence=False):
        # Shared by declarations, whole-RHS identities/metadata and braceless
        # statements. Template spans skip prose AND nested interpolation tokens
        # here, while the main analysis still visits that executable code.
        cursor, previous = start, None
        while cursor < n:
            if v(cursor) in {';', ')', ']', '}'} or (v(cursor) == ',' and not sequence): break
            if previous is not None and asi_boundary(previous, cursor): break
            if ts[cursor].kind == 'template':
                previous = cursor
                end = ts[cursor].end
                cursor += 1
                while cursor < n and ts[cursor].start < end: cursor += 1
            elif cursor in pairs and v(cursor) in {'(', '[', '{'}:
                previous = pairs[cursor]; cursor = previous + 1
            else:
                previous = cursor; cursor += 1
        return cursor

    def whole_primary(start, end):
        return expression_end(start) == end

    def postfix(index):
        return (v(index) in UPDATE_OPERATORS and index > 0 and
                not line_break(index-1, index) and can_end_expression(index-1))

    def write_after(after):
        return v(after) in ASSIGNMENT_OPERATORS or postfix(after)

    def prefix_before(index):
        return v(index-1) in UPDATE_OPERATORS and not postfix(index-1)

    def split_items(start, end):
        result, first, cursor = [], start, start
        while cursor < end:
            if v(cursor) == ',': result.append((first, cursor)); first = cursor+1
            elif cursor in pairs and v(cursor) in {'(', '[', '{'}: cursor = pairs[cursor]
            cursor += 1
        if first < end: result.append((first, end))
        return result

    def binding_names(start, end):
        # Binding patterns and their default *expressions* are different syntax.
        # In {document: unused}, document is a property key, not a declaration.
        while start < end and v(start) == '.': start += 1  # rest binding
        if start >= end: return []
        if ts[start].kind == 'id': return [ts[start].value]
        if v(start) == '[' and start in pairs:
            return [name for a, b in split_items(start+1, pairs[start])
                    for name in binding_names(a, b)]
        if v(start) == '{' and start in pairs:
            result = []
            for a, b in split_items(start+1, pairs[start]):
                cursor = a
                while cursor < b and v(cursor) not in {':', '='}:
                    if cursor in pairs and v(cursor) in {'[', '(', '{'}: cursor = pairs[cursor]
                    cursor += 1
                result.extend(binding_names(cursor+1, b) if v(cursor) == ':' else binding_names(a, b))
            return result
        return []

    def control_header(index):
        start = index + 2 if v(index) == 'for' and v(index+1) == 'await' else index+1
        return start if v(start) == '(' and start in pairs else None

    def statement_end(start):
        # A control body may itself be a labelled or braceless control. Include
        # an if's else arm in its extent; neither arm is execution proof.
        if start >= n: return n
        if v(start) == '{' and start in pairs: return pairs[start] + 1
        if ts[start].kind == 'id' and v(start+1) == ':':
            return statement_end(start+2)
        if v(start) in {'if', 'for', 'while', 'switch', 'with'}:
            header = control_header(start)
            if header is not None:
                end = statement_end(pairs[header]+1)
                if v(start) == 'if' and v(end) == 'else': end = statement_end(end+1)
                return end
        # Statements own the complete comma sequence; declarations and call
        # arguments still use component expression bounds. Return/throw operands
        # execute in order through every comma before the abrupt suffix begins.
        end = expression_end(start, sequence=True)
        return end+1 if v(end) == ';' else end

    # let/const in a for header belong to the loop, including its RHS/condition
    # (TDZ), update and body, never to the surrounding block. This scope is not
    # itself an uncertain body: control_ranges below retain the actual outside
    # owner, so fresh local allocations and outer possible writes stay distinct.
    loop_extents = {}
    for index in range(n):
        if v(index) != 'for': continue
        header = control_header(index)
        if header is not None and v(header+1) in {'let', 'const'}:
            loop_extents[header] = statement_end(pairs[header]+1)

    # Syntax role, rather than a keyword's spelling, owns a routine body.
    # In a member slot `catch(){}` is a method, whereas after a try body it is
    # a catch clause. An arbitrary `call()\n{}` is an ordinary block. Track
    # delimiter ownership so names/parameters inside nested expressions never
    # become a member header of the surrounding object or class.
    parents, delimiters = {}, []
    for index in range(n):
        parents[index] = delimiters[-1] if delimiters else None
        if v(index) in {'(', '[', '{'}: delimiters.append(index)
        elif v(index) in {')', ']', '}'} and delimiters: delimiters.pop()

    brace_roles, routine_headers, catch_headers = {}, set(), set()

    def class_body(index):
        cursor = index-1
        while cursor >= 0:
            if v(cursor) == 'class': return v(cursor-1) not in {'.', '?.'}
            if v(cursor) in {';', '{', '}', '=', '=>', ','}: return False
            if v(cursor) in {')', ']'} and cursor in pairs:
                cursor = pairs[cursor]-1
            else: cursor -= 1
        return False

    def explicit_function(start):
        cursor = start-1
        if ts[cursor].kind == 'id' and v(cursor) != 'function': cursor -= 1
        if v(cursor) == '*': cursor -= 1
        return v(cursor) == 'function' and v(cursor-1) not in {'.', '?.'}

    def method_header(start, parent):
        if brace_roles.get(parent) not in {'object', 'class'}: return False
        cursor = start-1
        if v(cursor) == ']' and cursor in pairs: cursor = pairs[cursor]-1
        elif cursor >= 0:
            # The token stream does not attach numeric type semantics. Retain
            # an actual numeric property-name lexeme (including radix, exponent,
            # separators and bigint), rather than hoisting its method's locals.
            first = cursor
            while (first > 0 and ts[first-1].end == ts[first].start and
                   re.fullmatch(r'[\w.+-]+', text[ts[first-1].start:ts[first-1].end])):
                first -= 1
            raw_name = text[ts[first].start:ts[cursor].end].replace('_', '')
            numeric = re.fullmatch(r'(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)n?', raw_name)
            if numeric: cursor = first-1
            elif ts[cursor].kind in {'id', 'string'}:
                cursor -= 1
                if v(cursor) == '#' and brace_roles.get(parent) == 'class': cursor -= 1
            else: return False
        else: return False
        # Contextual modifiers are recognized only in the member slot. The
        # property name itself may be any IdentifierName, string or computed key.
        if v(cursor) == '*': cursor -= 1
        if v(cursor) in {'get', 'set', 'async'}: cursor -= 1
        if brace_roles.get(parent) == 'class' and v(cursor) == 'static': cursor -= 1
        return (cursor == parent or v(cursor) in {',', ';', '}'} or
                (brace_roles.get(parent) == 'class' and cursor >= 0 and
                 line_break(cursor, cursor+1) and can_end_expression(cursor)))

    # Resolve brace roles in source order; the enclosing object's/class's role
    # is known before its members. Function/class body syntax is retained even
    # when the declaration is anonymous, async or a generator.
    for index in range(n):
        if v(index) != '{': continue
        parent = parents[index]
        arrow = v(index-1) == '=>'
        end = index-2 if arrow else index-1
        start = pairs[end] if v(end) == ')' and end in pairs else None
        method = start is not None and method_header(start, parent)
        function = arrow or (start is not None and (explicit_function(start) or method))
        catch = (not function and start is not None and v(start-1) == 'catch' and
                 v(start-2) == '}' and brace_roles.get(pairs.get(start-2)) == 'control')
        # Genuine catch remains a block; its var declarations hoist through it.
        if catch: catch_headers.add(start)
        if function:
            brace_roles[index] = 'function'
            if start is not None: routine_headers.add(start)
        elif brace_roles.get(parent) == 'class' and v(index-1) == 'static':
            brace_roles[index] = 'static'
        elif class_body(index): brace_roles[index] = 'class'
        elif (v(index-1) in {'else', 'try', 'finally', 'do'} or catch or
              (v(index-1) == 'catch' and v(index-2) == '}' and
               brace_roles.get(pairs.get(index-2)) == 'control') or
              (start is not None and v(start-1) in {'if', 'for', 'while', 'switch', 'with'})):
            brace_roles[index] = 'control'
        elif v(index-1) in {'=', '(', '[', ',', ':', '?', '||', '&&', '??', 'return', 'yield'}:
            brace_roles[index] = 'object'
        else: brace_roles[index] = 'block'

    # Class property names are member slots, never assignments to a captured
    # lexical local with the same spelling. Instance initializer expressions
    # execute only on construction, so analyze each in an independent deferred
    # view. Static fields/blocks execute in the current class evaluation. Skip
    # balanced method bodies and initializer expressions to avoid interpreting
    # their nested tokens as additional class members.
    field_heads, initializer_extents = set(), {}
    for body, role in brace_roles.items():
        if role != 'class': continue
        cursor, end = body+1, pairs.get(body, n)
        while cursor < end:
            if v(cursor) == ';': cursor += 1; continue
            first, static = cursor, False
            if v(cursor) == 'static' and v(cursor+1) == '{':
                field_heads.add(cursor)
                cursor = pairs.get(cursor+1, cursor+1)+1
                continue
            if v(cursor) == 'static' and v(cursor+1) not in {'=', ';', '}', '('}:
                static = True; cursor += 1
            # Contextual method modifiers precede a separate property name;
            # a field named get/set/async instead ends or has its own '='.
            if (v(cursor) in {'get', 'set', 'async'} and
                    v(cursor+1) not in {'=', ';', '}', '('} and
                    not (v(cursor) == 'async' and line_break(cursor, cursor+1))):
                cursor += 1
            if v(cursor) == '*': cursor += 1
            if v(cursor) == '#': cursor += 1
            if v(cursor) == '[' and cursor in pairs:
                cursor = pairs[cursor]+1
            else:
                # Quoted/IdentifierName/private and numeric literal keys all
                # end before '=', a parameter list, or an ASI field boundary.
                cursor += 1
                while (cursor < end and ts[cursor-1].end == ts[cursor].start and
                       v(cursor) not in {'=', ';', '('} and
                       re.fullmatch(r'[\w.+-]+', text[ts[cursor].start:ts[cursor].end])):
                    cursor += 1
            field_heads.update(range(first, cursor))
            if v(cursor) == '(' and cursor in pairs:
                cursor = pairs[cursor]+1
                if v(cursor) == '{': cursor = pairs.get(cursor, cursor)+1
            elif v(cursor) == '=':
                start = cursor+1
                cursor = expression_end(start)
                if not static and start < cursor:
                    initializer_extents[start] = cursor
            elif cursor < end and v(cursor) != ';' and not line_break(cursor-1, cursor):
                # Unsupported member syntax must still advance without letting
                # its interior masquerade as another recognized field head.
                cursor += 1

    # Actual statement headers alone are exempt from unknown-call effects.
    # `obj.catch()` and a method declaration named `catch` have different roles
    # from an exception clause despite sharing its token spelling.
    statement_headers = set()
    for index in range(n):
        if v(index) not in {'if', 'for', 'while', 'switch', 'with', 'catch'}: continue
        header = control_header(index)
        if (header is not None and header not in routine_headers and
                v(index-1) not in {'.', '?.'}): statement_headers.add(header)

    # Pair conditional operators in their own delimiter owner before assigning
    # statement-label roles. A colon in a conditional arm cannot be borrowed
    # by an earlier case label, even when both live directly in a switch body.
    # Nested groups/objects have independent stacks; nested conditionals pair
    # inside-out according to the grammar's right associativity.
    conditional_colons, questions, conditional_pairs = set(), {}, {}
    for index in range(n):
        owner = parents[index]
        if v(index) == '?': questions.setdefault(owner, []).append(index)
        elif v(index) == ':' and questions.get(owner):
            conditional_pairs[questions[owner].pop()] = index
            conditional_colons.add(index)

    switch_bodies = {body for body, role in brace_roles.items()
                     if role == 'control' and v(body-1) == ')' and
                     v(pairs.get(body-1, -1)-1) == 'switch'}
    statement_colons, pending_cases = set(), set()
    for index in range(n):
        owner = parents[index]
        if (owner in switch_bodies and v(index) in {'case', 'default'} and
                v(index-1) not in {'.', '?.'}):
            pending_cases.add(owner)
        if v(index) != ':' or index in conditional_colons: continue
        if brace_roles.get(owner) == 'object' and owner-1 in statement_colons:
            brace_roles[owner] = 'block'
        if brace_roles.get(owner) == 'object': continue
        if owner in pending_cases:
            statement_colons.add(index)
            pending_cases.remove(owner)
        elif (index > 0 and ts[index-1].kind == 'id' and
              (index < 2 or v(index-2) in {';', '{', '}'} or
               index-2 in statement_colons)):
            statement_colons.add(index)

    # A brace after a statement-label colon is a plain block, not an object.
    for body, role in brace_roles.items():
        if role == 'object' and body-1 in statement_colons: brace_roles[body] = 'block'

    # Only a syntactic declaration exports its name to the enclosing lexical
    # scope. A named expression owns a private self-binding (also visible to
    # its parameters/class body); neither a following global document read nor
    # a captured same-named DOM local can resolve to that private name.
    def declaration_position(keyword):
        first = keyword
        if v(first-1) == 'async' and not line_break(first-1, first): first -= 1
        before = first-1
        if before < 0 or v(before) == ';': return True
        if v(before) == '{': return brace_roles.get(before) != 'object'
        if v(before) == '}': return True
        if v(before) in {'export', 'default', 'else'}: return True
        if v(before) in {'return', 'yield'}: return line_break(before, first)
        if v(before) == ')' and pairs.get(before) in statement_headers: return True
        # A labelled declaration is a statement; an object value or conditional
        # arm after ':' remains an expression. Switch/default labels similarly
        # introduce statements, rather than expression names in their owner.
        if v(before) == ':': return before in statement_colons
        # ASI separates an ordinary completed statement from a declaration.
        return line_break(before, first) and can_end_expression(before)

    named_constructs, expression_extents = {}, {}
    for body, role in brace_roles.items():
        keyword = None
        if role == 'function' and v(body-1) == ')':
            start = pairs.get(body-1)
            if start is not None and explicit_function(start):
                cursor = start-1
                if ts[cursor].kind == 'id' and v(cursor) != 'function': cursor -= 1
                if v(cursor) == '*': cursor -= 1
                keyword = cursor
        elif role == 'class':
            cursor = body-1
            while cursor >= 0:
                if v(cursor) == 'class': keyword = cursor; break
                if v(cursor) in {')', ']'} and cursor in pairs: cursor = pairs[cursor]-1
                else: cursor -= 1
        if keyword is None: continue
        name = keyword+1
        if v(name) == '*': name += 1
        if name >= n or ts[name].kind != 'id' or v(name) == 'extends': continue
        named_constructs[keyword] = name
        if not declaration_position(keyword):
            expression_extents[keyword] = pairs.get(body, n-1)+1

    root = Scope(var_owner=True)
    scopes, opened, stack, formal_parens = [], {}, [(root, n)], set()
    for i, token in enumerate(ts):
        while len(stack) > 1 and i >= stack[-1][1]: stack.pop()
        if i in initializer_extents:
            stack.append((Scope(stack[-1][0], function=True, var_owner=True), initializer_extents[i]))
        if i in loop_extents: stack.append((Scope(stack[-1][0]), loop_extents[i]))
        if i in expression_extents:
            stack.append((Scope(stack[-1][0]), expression_extents[i]))
        scopes.append(stack[-1][0])
        if v(i) == '{':
            params = []
            function = brace_roles[i] == 'function'
            end = i - 2 if v(i-1) == '=>' else i - 1
            if v(end) == ')' and end in pairs:
                start = pairs[end]
                if start in routine_headers or start in catch_headers:
                    formal_parens.add(start)
                    params = [name for a, b in split_items(start+1, end)
                              for name in binding_names(a, b)]
            elif function and ts[end].kind == 'id': params = [ts[end].value]
            controlled = brace_roles[i] == 'control'
            child = Scope(stack[-1][0], function, controlled,
                          var_owner=function or brace_roles[i] == 'static')
            for name in params: child.bindings[name] = None
            opened[i] = child; stack.append((child, pairs.get(i, n-1)+1))
    # All lexical declarations shadow for the entire scope; var declarations
    # hoist to the nearest function. This pass does not initialize their values.
    declarations = {}
    for i, token in enumerate(ts):
        if i in field_heads or v(i) not in {'let', 'const', 'var'}: continue
        target = scopes[i]
        if token.value == 'var':
            while target.parent and not target.var_owner: target = target.parent
        cursor = i + 1
        while cursor < n:
            if ts[cursor].kind != 'id':
                # Recognize actual binding positions, never property keys or
                # names that appear only in a default initializer expression.
                end = pairs.get(cursor, cursor)
                for name in binding_names(cursor, end+1): target.bindings[name] = None
                break
            target.bindings[ts[cursor].value] = None; declarations[cursor] = target
            cursor += 1
            cursor = expression_end(cursor)
            if v(cursor) != ',': break
            cursor += 1
    # Declaration TDZ/hoisting and expression self-bindings use their actual
    # owner, independent of plain/escaped spelling or async/generator modifiers.
    for keyword, name in named_constructs.items():
        scopes[keyword].bindings[ts[name].value] = None

    def grouped_reference(first, end):
        # A complete local or member reference retains its identity through
        # no-op grouping. Grow both ends together: merely skipping closing
        # parentheses could turn a call argument or a partial expression into
        # a write target. Calls, formals and control headers own distinct roles.
        while (v(first-1) == '(' and pairs.get(first-1) == end and
               first-1 not in formal_parens | statement_headers | routine_headers and
               not callee_before(first-1)):
            first -= 1; end += 1
        return first, end

    def primary_span(i):
        return grouped_reference(i, i+1)

    def member(i):
        if i < n and ts[i].kind in {'id', 'opaque'}:
            _first, after = primary_span(i)
            if v(after) in {'.', '?.'} and after+1 < n and ts[after+1].kind == 'id':
                return ts[after+1].value, after+2
            if v(after) == '?.' and v(after+1) == '[': after += 1
            if v(after) == '[' and after in pairs:
                end = pairs[after]
                name = ts[after+1].value if end == after+2 and ts[after+1].kind == 'string' else None
                return name, end+1
        return None

    def primary_expression(start):
        # The complete component extent owns grouping, so a comma/conditional
        # or an argument mention cannot become a bare local allocation/alias.
        end = expression_end(start)
        while v(start) == '(' and pairs.get(start) == end-1:
            start += 1; end -= 1
        return start, end

    def local_identity(start, scope):
        first, end = primary_expression(start)
        return lookup(scope, ts[first].value)[1] if end == first+1 and ts[first].kind == 'id' else None

    def argument_list(start):
        if v(start) != '(' or start not in pairs: return [], start
        end = pairs[start]; args, first, i = [], start+1, start+1
        while i < end:
            if v(i) == ',': args.append((first, i)); first = i+1
            elif i in pairs and v(i) in {'(', '[', '{'}: i = pairs[i]
            i += 1
        if first < end: args.append((first, end))
        return args, end

    def literal(arg):
        a, b = arg
        return ts[a].value if b == a+1 and ts[a].kind == 'string' else None

    def origin(i, scope):
        first, extent = primary_expression(i)
        # The document receiver can itself have no-op groups. Identify its
        # inner identifier without stripping any argument or other expression.
        receiver = first
        while v(receiver) == '(' and receiver in pairs: receiver += 1
        if receiver >= n or ts[receiver].kind != 'id' or ts[receiver].value != 'document' or scope.lookup('document')[0] is not None: return None
        start, _after = primary_span(receiver)
        m = member(receiver)
        if not m or m[0] not in {'createElement', 'createTextNode'}: return None
        # Grouping a direct document method preserves the same reference;
        # this still requires that method call to be the entire initializer.
        method_left, call = grouped_reference(start, m[1])
        if method_left != first: return None
        args, end = argument_list(call)
        if v(call) != '(' or call not in pairs: return None
        covered.add(call)
        # The allocation must be the whole initializer, not one subexpression.
        if end+1 != extent: return None
        tag = literal(args[0]) if args else None
        return Allocation(ascii_lower(tag) if tag is not None else None, scope,
                          text_node=m[0] == 'createTextNode')

    allocations, findings, covered, views = [], [], set(), {}
    binding_views = {}

    def function_scope(scope):
        while scope.parent and not scope.function: scope = scope.parent
        return scope

    control_ranges = []
    for index in range(n):
        name = v(index)
        header = control_header(index)
        if name in {'if', 'for', 'while', 'switch', 'with', 'catch'} and header in statement_headers:
            body = pairs[header]+1
        elif name in {'else', 'try', 'finally', 'do', 'catch'} and brace_roles.get(index+1) == 'control':
            body = index+1
        else: continue
        control_ranges.append((index, statement_end(body), scopes[index]))

    # Conditional arms and short-circuit right operands are not unconditional
    # source-order proof. Retain bounded expression ranges, rather than losing
    # every visible allocation just because an expression reads a condition.
    # Pair ownership above prevents object/label colons from becoming arms;
    # expression_end respects groups, argument commas, delimiters and ASI.
    expression_controls = []
    for question, colon in conditional_pairs.items():
        expression_controls.append((question+1, colon, scopes[question]))
        expression_controls.append((colon+1, expression_end(colon+1), scopes[question]))
    for index in range(n):
        if v(index) in {'&&', '||', '??', '&&=', '||=', '??='}:
            expression_controls.append((index+1, expression_end(index+1), scopes[index]))
    # A classic for update is optional, unlike its initializer and first
    # condition evaluation. Visiting its tokens before the body cannot certify
    # a checkbox for the zero-iteration path. Skip nested delimiter semicolons.
    for header in statement_headers:
        if v(header-1) != 'for': continue
        cursor, separators = header+1, []
        while cursor < pairs[header]:
            if v(cursor) == ';': separators.append(cursor)
            elif cursor in pairs and v(cursor) in {'(', '[', '{'}: cursor = pairs[cursor]
            cursor += 1
        if len(separators) == 2 and separators[1]+1 < pairs[header]:
            expression_controls.append((separators[1]+1, pairs[header], scopes[header]))

    # Abrupt statements end an execution path, not the lexical token stream.
    # Keep later accesses visible, but never use metadata/rebindings after a
    # possible jump as unconditional proof. Resolve the actual enclosing jump
    # target; a nested function, method, object key or member spelling cannot
    # introduce a jump into its caller. This is conservative uncertainty rather
    # than a reachability interpreter (including conditional jumps/finally).
    jump_targets = []
    for index in range(n):
        header = control_header(index)
        if header in statement_headers and v(index) in {'for', 'while', 'switch'}:
            jump_targets.append((index, statement_end(pairs[header]+1), v(index), None))
        elif v(index) == 'do' and declaration_position(index):
            jump_targets.append((index, statement_end(index+1), 'do', None))
        elif index+1 in statement_colons and ts[index].kind == 'id':
            jump_targets.append((index, statement_end(index+2), 'label', ts[index].value))

    abrupt_ranges = []
    for index in range(n):
        keyword = v(index)
        if keyword not in {'break', 'continue', 'return', 'throw'}: continue
        if (index in field_heads or v(index-1) in {'.', '?.'} or
                v(index+1) == ':' or index+1 in routine_headers): continue
        owner = parents[index]
        if owner is not None and (v(owner) in {'(', '['} or
                                  brace_roles.get(owner) in {'object', 'class'}): continue
        routine = function_scope(scopes[index])
        # Only statement positions supply an abrupt keyword. A braceless
        # control body and ASI after an expression are statements too.
        if not declaration_position(index): continue
        end = None
        if keyword in {'break', 'continue'}:
            label = (ts[index+1].value if index+1 < n and
                     ts[index+1].kind == 'id' and not line_break(index, index+1) else None)
            choices = [(a, b) for a, b, kind, name in jump_targets
                       if a < index < b and function_scope(scopes[a]) is routine and
                       (name == label if label is not None else
                        kind in ({'for', 'while', 'do'} if keyword == 'continue' else
                                 {'for', 'while', 'do', 'switch'}))]
            if choices: end = max(choices)[1]
        else:
            bodies = [body for body, role in brace_roles.items()
                      if role == 'function' and body < index < pairs.get(body, n) and
                      function_scope(opened[body]) is routine]
            if bodies: end = pairs[max(bodies)]+1
            elif keyword == 'throw': end = n
            if keyword == 'throw':
                # A throw caught in this lexical try does not exit the routine.
                # Stop its unreachable suffix before entering the handler; the
                # catch's own optional effects retain their existing range.
                handlers = [body for body, role in brace_roles.items()
                            if role == 'control' and v(body-1) == 'try' and
                            body < index < pairs.get(body, n) and
                            v(pairs.get(body, n-1)+1) == 'catch' and
                            function_scope(scopes[body]) is routine]
                if handlers: end = pairs[max(handlers)]+1
        if end is not None:
            # Return/throw operands execute before leaving; don't hide their
            # raw value bindings or guard their immediate metadata operations.
            after = statement_end(index)
            if after < end: abrupt_ranges.append((after, end, routine))

    control_ranges.extend(expression_controls)
    expression_control_set = set(expression_controls)

    control_tokens = {index for index in range(n)
                      if control_header(index) in statement_headers or
                      (v(index) in {'try', 'with'} and brace_roles.get(index+1) == 'control')}

    def callee_before(index):
        # Only an expression-ending callee supplies invocation syntax. Formal
        # and statement-header parens are classified separately above; grouping
        # itself, return/await/unary operands and template data are not calls.
        before = index-1
        if v(before) == '?.': before -= 1
        if before < 0: return False
        if ts[before].kind == 'id':
            return (v(before-1) in {'.', '?.'} or v(before) not in {
                'return', 'throw', 'yield', 'await', 'new', 'delete', 'typeof',
                'void', 'in', 'instanceof', 'else', 'do', 'case', 'extends',
                'function', 'class', 'if', 'for', 'while', 'switch', 'catch', 'with'})
        if v(before) == ')':
            return pairs.get(before) not in statement_headers | routine_headers
        if v(before) == ']': return True
        if v(before) == '}': return brace_roles.get(pairs.get(before)) == 'function'
        # A primitive quoted literal is not callable: its call/tag continuation
        # cannot execute a hidden routine. A tagged-template result may itself
        # be callable, whereas an ordinary template evaluates to a string.
        if ts[before].kind == 'template': return callee_before(before)
        return ts[before].kind == 'opaque'

    def crosses_control(index, target, *, expression_only=False):
        if any(start <= index < end and function_scope(scopes[index]) is routine
               for start, end, routine in abrupt_ranges): return True
        for start, end, outside in control_ranges:
            if expression_only and (start, end, outside) not in expression_control_set: continue
            if not start <= index < end: continue
            current = outside
            while current is not None:
                if current is target: return True
                current = current.parent
        return False

    binding_origins = {}

    def binding_path(index, target):
        path = []
        for start, end, outside in control_ranges:
            if not start <= index < end: continue
            # A classic for initializer executes before its conditional loop;
            # declarations there are not optional body writes.
            header = control_header(start)
            if v(start) == 'for' and header is not None and index <= pairs[header]: continue
            current = outside
            while current is not None:
                if current is target:
                    path.append((start, end)); break
                current = current.parent
        path.extend((start, end) for start, end, routine in abrupt_ranges
                    if start <= index < end and function_scope(scopes[index]) is routine)
        return tuple(sorted(path))

    def join_binding(index, target, name, allocation, old):
        # Hoisted var declarations can initialize one binding in different
        # arms. Visiting the last arm cannot erase another possible allocation.
        # Replacements on the same straight-line path supersede that path's
        # earlier alternatives, including its nested conditional writes.
        key = (function_scope(scopes[index]), target, name)
        path = binding_path(index, target)
        if not path:
            binding_origins[key] = {(): allocation}
            return allocation
        origins = binding_origins.get(key, {(): old} if old is not None else {})
        origins = {prior: value for prior, value in origins.items()
                   if prior[:len(path)] != path}
        origins[path] = allocation
        binding_origins[key] = origins
        possible = tuple(dict.fromkeys(value for value in origins.values() if value is not None))
        if len(origins) > 1 and possible:
            return Allocation(None, scopes[index], uncertain=True, possible_aliases=possible)
        return allocation

    def lookup(scope, name):
        target, allocation = scope.lookup(name)
        if target is None: return None, None
        # A deferred body has its own writes to captured bindings, just as it
        # has its own view of captured allocation metadata. Search enclosing
        # function views too, so nested callbacks retain lexical identity.
        current = scope
        while current is not target and current is not None:
            if current.function:
                key = (current, target, name)
                if key in binding_views: return target, binding_views[key]
            current = current.parent
        return target, allocation

    def assign(scope, target, name, allocation):
        if function_scope(scope) is function_scope(target):
            target.bindings[name] = allocation
        else:
            binding_views[function_scope(scope), target, name] = allocation

    def view(allocation, scope):
        target = function_scope(scope)
        def shell(source):
            if target is function_scope(source.scope): return source
            key = (target, source)
            if key not in views:
                child = copy(source); child.scope = target
                child.uncertain = not child.text_node
                child.possible_aliases = ()
                views[key] = child
                pending.append(source)
            return views[key]
        # Cache shells before edges: shared/deep graphs must neither recurse
        # nor copy an identity twice. Deferred writes stay in this function.
        pending = []
        result = shell(allocation)
        while pending:
            source = pending.pop()
            views[target, source].possible_aliases = tuple(shell(x) for x in source.possible_aliases)
        return result

    def expression_aliases(start, scope):
        # Only a bare local result or the result arms of a bounded conditional
        # supplies identity. Mentions in conditions, comparisons, properties,
        # containers and call arguments cannot prove the expression's result.
        end = expression_end(start)
        pending, possible = [(start, end)], []
        while pending:
            first, last = pending.pop()
            while v(first) == '(' and pairs.get(first) == last-1:
                first += 1; last -= 1
            if last == first+1 and ts[first].kind == 'id':
                allocation = lookup(scope, ts[first].value)[1]
                if allocation is None: return ()
                possible.append(view(allocation, scope))
                continue
            cursor, question, depth, split = first, None, 0, False
            while cursor < last:
                if cursor in pairs and v(cursor) in {'(', '[', '{'}:
                    cursor = pairs[cursor]+1; continue
                if v(cursor) == '?':
                    if question is None: question = cursor
                    depth += 1
                elif v(cursor) == ':' and question is not None:
                    depth -= 1
                    if depth == 0:
                        pending.extend([(question+1, cursor), (cursor+1, last)])
                        split = True
                        break
                cursor += 1
            # A partial set is not exhaustive. Any unrecognized result arm
            # triggers the tracked receiver's conservative visible fallback.
            if not split: return ()
        return tuple(dict.fromkeys(possible))

    def visible_aliases(scope):
        # An opaque replacement of an already tracked receiver could select
        # any visible DOM local. This does not grant DOM origin to models.
        result, names, current = [], set(), scope
        while current:
            for name in current.bindings:
                if name in names: continue
                names.add(name)
                allocation = lookup(scope, name)[1]
                if allocation is not None: result.append(view(allocation, scope))
            current = current.parent
        return tuple(dict.fromkeys(result))

    def invalidate_visible(scope):
        visible, current = {}, scope
        while current:
            for name in current.bindings:
                if name not in visible: visible[name] = lookup(scope, name)[1]
            current = current.parent
        for allocation in visible.values():
            if allocation is not None and not allocation.text_node:
                invalidate(view(allocation, scope))

    def metadata_literal(after):
        # Only an entire literal RHS with plain assignment establishes a
        # constant. A leading literal in a concatenation/compound write does
        # not prove the HTML value that will actually be assigned.
        if v(after) == '=' and after+1 < n and ts[after+1].kind == 'string' and whole_primary(after+1, after+2):
            return ts[after+1].value
        return None

    for i, token in enumerate(ts):
        scope = scopes[i]
        if i in field_heads: continue
        # Construction may run deferred field initializers/constructors. Their
        # order is not inferred; even a no-parentheses construction loses the
        # current captured metadata exemption.
        if (v(i) == 'new' and v(i-1) not in {'.', '?.'} and
                v(i+1) not in {':', '.', '?.'} and i+1 not in routine_headers):
            invalidate_visible(scope)
        # Unsupported control flow must not preserve stale metadata. A later
        # fresh allocation within its own branch can still be analyzed locally.
        if i in control_tokens:
            invalidate_visible(scope)
        if token.kind == 'opaque':
            invalidate_visible(scope)
        left, after_primary = primary_span(i) if token.kind == 'id' else (i, i+1)
        write = after_primary
        if i in declarations and v(i+1) == '=':
            allocation = origin(i+2, scope)
            if allocation is None: allocation = local_identity(i+2, scope)
            target = declarations[i]
            old = target.bindings.get(token.value)
            allocation = join_binding(i, target, token.value, allocation, old)
            declarations[i].bindings[token.value] = allocation
            if allocation is not None and allocation not in allocations: allocations.append(allocation)
        elif token.kind == 'id' and (v(write) in ASSIGNMENT_OPERATORS | UPDATE_OPERATORS or (v(left-1) in UPDATE_OPERATORS and not member(i))) and (left == 0 or v(left-1) not in {'.', '?.'}):
            target, old = lookup(scope, token.value)
            if target is not None and (write_after(write) or prefix_before(left)):
                allocation = origin(write+1, scope)
                if allocation is None: allocation = local_identity(write+1, scope)
                # Normalize RHS identities before distinguishing write operators.
                # A partial conditional result set is never exhaustive. An opaque
                # result on an already tracked receiver can select any visible DOM
                # local, while an untracked model gains no invented provenance.
                rhs_aliases = ((view(allocation, scope),) if allocation is not None else
                               expression_aliases(write+1, scope) or
                               (visible_aliases(scope) if old is not None else ()))
                # Only plain assignment proves a replacement identity. Other
                # writes retain an obligation if either operand can denote DOM.
                # Logical writes may retain the old allocation or select the RHS;
                # later metadata writes must reach either possible alias without
                # changing either allocation merely because the binding changed.
                if v(write) != '=':
                    possible = tuple(dict.fromkeys(([view(old, scope)] if old is not None else []) + list(rhs_aliases)))
                    allocation = Allocation(None, scope, uncertain=True, possible_aliases=possible) if possible else None
                # Replacing a known DOM local with an unknown expression loses
                # its classification, not its provenance obligation. This is a
                # new receiver state: existing aliases still name the old DOM
                # allocation. An entire object literal is a known model value.
                model_first, model_extent = primary_expression(write+1)
                model_end = pairs.get(model_first) if v(model_first) == '{' else None
                model = model_end is not None and model_end+1 == model_extent
                if allocation is None and old is not None and not model and v(write) == '=':
                    allocation = Allocation(None, scope, uncertain=True)
                    # Preserve possible old/RHS identities without mutating
                    # them merely because this local was rebound.
                    if allocation is not None:
                        allocation.possible_aliases = rhs_aliases
                # A possible branch/loop/exception write cannot replace the
                # post-boundary state with its one visited arm. The obligation
                # belongs to the outer binding; branch-local declarations and
                # a later unconditional fresh replacement retain their meaning.
                if crosses_control(i, target) and (old is not None or allocation is not None):
                    allocation = Allocation(tag=None, scope=scope, uncertain=True, possible_aliases=tuple(dict.fromkeys(view(x, scope) for x in (old, allocation) if x is not None)))
                # Keep declaration history coherent with ordinary writes; the
                # existing assignment join above owns their diagnostic state.
                join_binding(i, target, token.value, allocation, old)
                assign(scope, target, token.value, allocation)
                if allocation is not None and allocation not in allocations: allocations.append(allocation)
        # A DOM allocation may escape its creation block through an outer
        # binding. Guarded writes belong to that current binding owner, not
        # the exited allocation scope; fresh routine locals remain separate.
        binding_scope, allocation = lookup(scope, token.value) if token.kind == 'id' and v(left-1) not in {'.', '?.'} else (None, None)
        if allocation is not None: allocation = view(allocation, scope)
        m = member(i)
        if allocation is not None and m:
            # Crossing a callback/control-flow scope is not source-order proof
            # of the captured allocation's metadata at the later execution.
            # An allocation can leave a plain nested block through a hoisted
            # binding. Stop at the shared lexical ancestor, rather than treating
            # that harmless scope exit as crossing its enclosing branch again.
            owners, owner = set(), allocation.scope
            while owner is not None:
                owners.add(owner); owner = owner.parent
            current = scope
            while current is not None and current not in owners:
                if current.function or current.uncertain: allocation.uncertain = True
                current = current.parent
            name, after = m
            member_left, after = grouped_reference(left, after)
            if (v(member_left-1) == 'delete' and metadata_relevant(allocation, name)) or (name is None and (write_after(after) or prefix_before(member_left))):
                invalidate(allocation)
            if name in {'value', 'textContent'} or name is None:
                api = allocation.finding()
                if name is None and not allocation.text_node: api = UNRESOLVED
                if api: findings.append((token.start, api))
            elif v(after) in ASSIGNMENT_OPERATORS | UPDATE_OPERATORS or v(member_left-1) in UPDATE_OPERATORS:
                if write_after(after) or prefix_before(member_left):
                    value = metadata_literal(after)
                    metadata(allocation, name, value, guarded=crosses_control(i, binding_scope, expression_only=True))
            elif v(after) == '(':
                args, end = argument_list(after); covered.add(after)
                if name == 'setAttribute' and len(args) == 2:
                    attr, value = literal(args[0]), literal(args[1])
                    if attr is not None and ascii_lower(attr) in {'value', 'textcontent'}:
                        api = allocation.finding()
                        if api: findings.append((token.start, api))
                    else:
                        metadata(allocation, attr, value, attribute=True, guarded=crosses_control(i, binding_scope, expression_only=True))
                elif name == 'removeAttribute' and len(args) == 1:
                    attr = literal(args[0])
                    guarded = crosses_control(i, binding_scope, expression_only=True)
                    if attr is not None and ascii_lower(attr) == 'type': metadata(allocation, 'type', 'text', attribute=True, guarded=guarded)
                    elif attr is not None and ascii_lower(attr) == 'autocomplete': metadata(allocation, 'autocomplete', '', attribute=True, guarded=guarded)
                    else: invalidate(allocation)
                else:
                    # An unknown receiver method can also mutate another
                    # captured DOM local; covering this call's arguments does
                    # not certify the rest of the visible allocation state.
                    invalidate_visible(scope)
        # Passing a known DOM allocation to an unknown call loses metadata
        # certainty; passing its primitive .value is handled by the binding
        # rule above and does not manufacture another receiver alias.
        if v(i) == '(' and i not in covered and i not in formal_parens and i not in statement_headers and callee_before(i):
            invalidate_visible(scope)
            args, _end = argument_list(i)
            for a, b in args:
                if b == a+1 and ts[a].kind == 'id':
                    passed = lookup(scope, ts[a].value)[1]
                    if passed is not None and not passed.text_node: invalidate(view(passed, scope))
        if token.kind == 'template' and callee_before(i):
            invalidate_visible(scope)
    # One diagnostic per authored member access. Ordinary platform findings
    # are accumulated separately by the owning scanner.
    return sorted(set(findings))
