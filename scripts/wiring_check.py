#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parameter/engine wiring checks that need no compiler.

Every one of these corresponds to a bug that passed the full test suite here, because
the suite asserts engine behaviour and parameter storage but not the *wiring*:

  * a field added to a parameters struct but missing from CodingKeys / decode /
    encode / knownKeys  -> "stored in UI, lost on save" or "our own key reported as
    unknown in the preset report"
  * a parameter group that no render path consumes -> the slider moves, nothing
    changes (this is the single most common defect shape in this repo's history)
  * an engine with `apply` but no call site        -> a dead asset ("哑资产"):
    implementation, tests and docs all green, feature does not exist
  * a `requires` prefix written but not filtered by the sync rules (or the reverse)
  * a missing-asset token (`[no_*]`, `[fallback:*]`) that never reached the docs,
    or a documented token that no longer exists in code
  * a model manifest `purpose` that claims a weight is (or is not) wired while the
    code says the opposite -- that field is printed verbatim in the Models panel, so
    a stale line there is the app telling the user a lie, not a stale comment
  * an engine/importer reachable only from `EditorModel.<something>()` while no panel
    calls that method -- the XMP shape: implementation, tests and model glue all
    green, the feature still does not exist for the user
  * a doc line that says a capability has *no* entry point when the code does have
    one (the shape that made device-check.md section 6 list shipped features as gaps)
  * a documented test-case count that no longer matches the tree

Run `python scripts/wiring_check.py --self-test` to check the checker itself: every
finding shape above gets a fixture that must fire, plus a good fixture that must not.
This matters because a checker that silently finds nothing is worse than no checker.

Exit code = number of findings. Output is ASCII so it survives the Windows console
codepage; the strings it reads are UTF-8.
"""
import io
import json
import os
import re
import shutil
import sys
import tempfile
from fnmatch import fnmatchcase

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from swift_lex_check import check_path, string_literals_of  # noqa: E402

DOMAIN = 'ImageCake/Domain'
IMAGING = 'ImageCake/Imaging'
UI = 'ImageCake/UI'
AI = 'ImageCake/AI'
SOURCES = ['ImageCake', 'Tests']
DOCS = ['README.md', 'docs']
MODELS = 'ImageCake/Resources/Models/models.json'
EDITOR = '%s/EditorModel.swift' % UI
TEST_DIR = 'Tests/ImageCakeTests'

PARAM_STRUCT_RE = re.compile(r'(?:public )?struct (\w+Parameters)\s*:')
# Stored properties only: `[ ^\n=]` must not cross newlines, otherwise
# `public var isSkinNeutral: Bool {` (a computed property) swallows the next `=`.
FIELD_RE = re.compile(r'^\s{4}public var (\w+)\s*:\s*([^\n={]+)\s*=\s*([^\n{]+)', re.M)
CLAMP_RE = re.compile(r'(\w+)\s*=\s*\1\.clamped')          # also matches `a = ...; b = ...`
APPLY_RE = re.compile(r'^\s{4}static func apply\(', re.M)
TOP_TYPE_RE = re.compile(r'^(?:public |final |fileprivate )*?(?:struct|enum|class|actor) (\w+)', re.M)
PREFIX_RE = re.compile(r'hasPrefix\("([a-z_]+:)"\)')
# A token is any bracketed lowercase slug, with an optional payload after a colon.
# The earlier, narrower pattern (`[no_*]` or `[a:b]`) silently ignored whole families
# the repo actually emits -- `[stack_mismatch]`, `[burst_capped]`, `[closed_eyes]`,
# `[spot-repair:none]` -- so a doc that invented `[stack_size_mismatch]` passed.
# Two or more characters after the leading letter keeps markdown checkboxes (`[x]`)
# and prose like `a-d` out of it. The leading `*` is allowed because an interpolated
# literal (`"[\(token)_too_large]"`) normalises to exactly that shape.
TOKEN_RE = re.compile(r'\[[a-z*][a-z0-9_.-]{2,}(?::[^\]]+)?\]')
# A Swift interpolation inside a literal ("[\(token)_too_large]") is a wildcard, not
# text: the literal never contains `tiff16_too_large`, so without this the doc that
# quotes a built token reads as stale.
INTERP_RE = re.compile(r'\\\((.*?)\)')
# Static entry points of an engine/importer/task type. A capability with no call site
# for one of these does not exist, no matter how many assertions cover its maths.
ENTRY_RE = re.compile(r'^\s{4}static func (apply|build|run|compose|suggest|detect|'
                      r'merge|review|import_|write)\(', re.M)
EDITOR_FUNC_RE = re.compile(r'^\s{4}func (\w+)', re.M)
BACKTICK_TYPE_RE = re.compile(r'`([A-Z][A-Za-z0-9]+)`')
# Phrases that assert a capability is unavailable. Checked against the code, because
# every one of these that goes stale reads as "we still have not built it" to a
# reader who then never tries the feature that shipped three batches ago.
NEGATIVE_DOC_RE = re.compile(u'(仍只有算子|没有入口|无入口|不提供入口|未实现|不在 v1|未接线|没有调用点|拿不到)')
# Same for the manifest: a purpose either claims a task consumes the weight or says
# it is a spare. Anything else is left alone so the rule cannot force churn.
CLAIM_WIRED_RE = re.compile(u'(已接线|接上|驱动)')
CLAIM_SPARE_RE = re.compile(u'(未接线|备用|没有任务引用)')
TEST_FUNC_RE = re.compile(r'^\s*func test', re.M)
COUNT_ANCHOR_RE = re.compile(r'(?:单元测试（|格 XCTest|全部 )(\d+) 格')
# Doc-side opt-out for past-tense negatives; see check_stale_doc_claims.
HISTORY_MARK = 'wiring-check:history'
RESOLVED_MARK = '✅'


def read(path):
    return io.open(path, encoding='utf-8', errors='replace').read()


def swift_files():
    for root, dirs, names in os.walk('ImageCake'):
        parts = set(root.split(os.sep))
        if {'.git', 'build'} & parts:
            continue
        for n in sorted(names):
            if n.endswith('.swift'):
                yield os.path.join(root, n).replace(os.sep, '/')


def doc_text():
    chunks = []
    if os.path.exists('README.md'):
        chunks.append(read('README.md'))
    for root, _, names in os.walk('docs'):
        for n in names:
            if n.endswith('.md'):
                chunks.append(read(os.path.join(root, n)))
    return '\n'.join(chunks)


def struct_blocks(src):
    """Yield (struct_name, body) for each *Parameters struct, brace-matched."""
    for m in struct_structures(src):
        yield m


def struct_structures(src):
    out = []
    for m in struct_structures_iter(src):
        out.append(m)
    return out


def struct_structures_iter(src):
    for m in PARAM_STRUCT_RE.finditer(src):
        name = m.group(1)
        brace = src.find('{', m.end())
        if brace < 0:
            continue
        depth = 0
        i = brace
        while i < len(src):
            if src[i] == '{':
                depth += 1
            elif src[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        yield name, src[brace + 1:i], brace


def coding_keys(*blocks):
    """name -> serialized key.

    Two shapes cost real rounds to get wrong here: `case a = "x", b, c = "y"`
    lists several per line, and `enum CodingKeys { case a }` fits on one line, so
    scanning line starts for `case` silently loses entries (and a missing entry
    looks exactly like a real bug in the Swift).
    """
    out = {}
    for block in blocks:
        start = block.find('enum CodingKeys')
        if start < 0:
            continue
        brace = block.find('{', start)
        end = block.find('}', brace)
        if brace < 0 or end < 0:
            continue
        inner = block[brace + 1:end]
        for piece in re.split(r'[\n;]', inner):
            piece = piece.strip()
            if not piece.startswith('case '):
                continue
            # Strip `case ` FIRST, then split: only the leading entry carries the
            # keyword, so splitting before stripping drops every name after the
            # first comma -- which reads exactly like a missing CodingKey.
            for entry in piece[5:].split(','):
                m = re.match(r'\s*(\w+)(?:\s*=\s*"([^"]+)"\s*)?$', entry)
                if m:
                    out[m.group(1)] = m.group(2) or m.group(1)
    return out


def check_parameter_contract(path, findings, seen_structs):
    """Fields of a parameters struct must appear in all of its serialisation sites."""
    src = read(path)
    for name, body, _ in struct_structures(src):
        seen_structs.add(name)
        fields = [(m.group(1), m.group(2).strip(), m.group(3).strip())
                  for m in FIELD_RE.finditer(body)]
        fields = [f for f in fields if 'static' not in f[2]]
        if not fields:
            continue
        # Codable may live in a later `extension X: Codable` OR inside the struct
        # itself; look in both places before claiming a key is missing.
        ext = src[src.find('extension %s: Codable' % name):]
        keys = coding_keys(ext, body)
        decoded = set(re.findall(r'forKey:\s*\.(\w+)',
                                 (ext[ext.find('init(from'):] if 'init(from' in ext else '')
                                  + body))
        encoded = set(re.findall(r'forKey:\s*\.(\w+)',
                                 (ext[ext.find('func encode'):] if 'func encode' in ext else '')
                                  + body))
        clamped = set(CLAMP_RE.findall(body[body.find('func clamp'):] if 'func clamp' in body else ''))
        where = os.path.basename(path)
        for fname, ftype, default in fields:
            if fname in DERIVED_KEYS:
                continue
            if fname not in keys:
                findings.append('%s: %s.%s missing from CodingKeys '
                                '(cannot be stored)' % (where, name, fname))
            elif name == 'EditParameters' and keys[fname] not in doc_known_keys(
                    read('%s/EditParameters.swift' % DOMAIN)):
                findings.append('EditParameters.%s serialises as "%s" which is not in '
                                'knownKeys (our own key would be reported as unknown)'
                                % (fname, keys[fname]))
            if fname not in decoded:
                findings.append('%s: %s.%s not decoded (a saved value would never come back)'
                                % (where, name, fname))
            if fname not in encoded:
                findings.append('%s: %s.%s not encoded (value is dropped on save)'
                                % (where, name, fname))
            if ftype == 'Double' and 'func clamp' in body and fname not in clamped:
                findings.append('%s: %s.%s not clamped (panel/preset can feed out-of-range values)'
                                % (where, name, fname))
    return


# Fields intentionally serialised through derived keys (a struct field with no
# matching CodingKey of its own). Listed here with the reason, so the checker does
# not shout about them and a human does not have to re-derive the answer.
DERIVED_KEYS = {
    'curves': 'stored as curve_x / curve_y (four channels, two parallel arrays)',
}


def doc_known_keys(src):
    # Anchor on the declaration: the word `knownKeys` also appears in comments about
    # keeping it in sync, and a comment match silently truncates the set.
    start = src.find('static let knownKeys')
    if start < 0:
        start = src.find('knownKeys')
    block = src[start:]
    opener = block.find('[')
    block = block[opener:]
    return set(re.findall(r'"([a-z0-9_]+)"', block[:block.find(']')]))


def check_render_wiring(findings):
    """Every parameter group with isNeutral must be consumed by the render path,
    and every group must have a UI entry point."""
    doc = read('%s/ImageDocument.swift' % DOMAIN)
    render = doc[doc.find('func render('):]
    render = render[:render.find('\n    /// ') if '\n    /// ' in render else render.find('\n    static ')]
    edit = read('%s/EditParameters.swift' % DOMAIN)
    groups = [m.group(1) for m in re.finditer(r'public var (\w+) = \w+Parameters\(\)', edit)]
    aliases = dict((m.group(1), m.group(2)) for m in
                   re.finditer(r'let (\w+) = params\.(\w+)', render))
    ui_files = {p: read(p) for p in swift_files() if p.startswith(UI)}
    for g in groups:
        consumed = ('params.%s' % g) in render or g in aliases.values()
        if not consumed:
            findings.append('ImageDocument.render() never reads params.%s '
                            '(parameter stored but nothing consumes it)' % g)
        in_ui = any(('params.%s' % g) in text or ('.%s.' % g) in text
                    for text in ui_files.values())
        if not in_ui:
            findings.append('no UI file references params.%s (a group with no entry point '
                            'is a dead feature)' % g)


def enclosing_type(src, offset):
    """The innermost top-level (column 0) type containing `offset`.

    Nested structs sit at indent 4; attributing a `static func apply` to whichever
    type name happened to appear last in the file points at the wrong owner and
    makes a wired-up engine look like a dead asset.
    """
    best = None
    for m in TOP_TYPE_RE.finditer(src):
        if m.start() >= offset:
            break
        best = m.group(1)
    return best


def check_engine_entries(findings):
    """`static func apply(` in Imaging must be called from outside its own file."""
    files = {p: read(p) for p in swift_files()}
    for path, src in files.items():
        if not path.startswith(IMAGING):
            continue
        for m in APPLY_RE.finditer(src):
            ty = enclosing_type(src, m.start())
            if not ty:
                continue
            needle = '%s.apply(' % ty
            callers = [p for p, s in files.items() if p != path and needle in s]
            if not callers:
                findings.append('%s: %s has apply() but no call site anywhere '
                                '(implementation + tests, no feature)'
                                % (os.path.basename(path), ty))


def check_tokens(findings):
    """Documented tokens must still exist in code.

    Only this direction is checked on purpose. The reverse ("every token the code
    emits must be written up") is noise: docs list a curated subset of the ~40
    tokens, and forcing parity would get the list padded rather than read. The
    direction that actually bit this repo is a doc claiming a token/panel/entry
    that no longer exists in code (a stale "provides the entry point" line).

    Two shapes make the naive comparison lie, both found while writing this:
      * the narrower inline copy of the pattern (`[no_*]` or `[a:b]`) ignored whole
        families the app emits -- `[stack_mismatch]`, `[burst_capped]`, `[closed_eyes]`
        -- so a doc that invented `[stack_size_mismatch]` passed;
      * markdown link labels (`[parity.md](parity.md)`) look exactly like a bracketed
        slug, so a match followed by `(` is a label, not a token.
    """
    code = set()
    for path in swift_files():
        for lit in string_literals_of(path):
            # Tokens sit mid-sentence ("... · [fallback:sky-colour-locus]"), so an
            # anchored match silently finds almost none and every doc token then
            # looks stale.
            code |= set(m.group(0) for m in TOKEN_RE.finditer(lit))
            code |= set(m.group(0) for m in TOKEN_RE.finditer(INTERP_RE.sub('*', lit)))
    docs = doc_text()
    documented = set()
    for m in TOKEN_RE.finditer(docs):
        if docs[m.end():m.end() + 1] == '(':
            continue                       # markdown link label, not a token
        documented.add(m.group(0))
    shapes = [tok[1:-1] for tok in code if '*' in tok]
    for tok in sorted(documented - code):
        body = tok[1:-1]
        if any(fnmatchcase(body, shape) for shape in shapes):
            continue                       # the app builds it by interpolation
        stem = body.split(':')[0]
        if not any(other[1:-1].startswith(stem) for other in code):
            findings.append('%s is documented but no code emits it any more' % tok)


def check_requires(findings):
    """`requires` prefixes written into params must be handled by the sync filter."""
    all_src = {p: read(p) for p in swift_files()}
    written = set()
    for src in all_src.values():
        for m in re.finditer(r'"([a-z_]+):\\\(', src):
            written.add(m.group(1) + ':')
    kept = set()
    for src in all_src.values():
        kept |= set(PREFIX_RE.findall(src))
    for pref in sorted(written - kept):
        findings.append('requires entry "%s…" is written but ParamSync never keeps it '
                        '(it would be dropped on the first sync)' % pref)
    for pref in sorted(kept - written):
        findings.append('ParamSync filters on "%s" but nothing writes that prefix' % pref)


# Where a capability can be reached from before a user can actually get it: either a
# panel touches it, or the render/export path does. Anything else is code that exists
# but never runs for anybody.
RENDER_HOSTS = ('ImageCake/Domain/ImageDocument.swift', 'ImageCake/Domain/ExportPipeline.swift')

# Known entries that are reachable from the model but from no panel yet. Kept here with
# the reason (same pattern as DERIVED_KEYS) so a *recorded* gap stays quiet -- and so
# the line cannot outlive the fix: wire the entry, delete the entry here, the checker
# then keeps it wired for good.
# (2026-11-03: the only tenant, XMPImporter.import_, is gone -- the entry now lives in
# the toolbar's Preset menu. Empty is the correct state; a non-empty map means somebody
# shipped a feature the user cannot reach and chose to write it down instead of fix it.)
DEAD_ENTRIES_OK = {}


def swift_texts():
    return {p: read(p) for p in swift_files()}


def editor_funcs(src):
    """[(name, body)] for every 4-indent `func` in EditorModel, in file order."""
    marks = list(EDITOR_FUNC_RE.finditer(src))
    out = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(src)
        out.append((m.group(1), src[m.end():end]))
    return out


def enclosing_editor_func(src, offset):
    """The `EditorModel` method containing `offset` (last 4-indent `func` before it)."""
    best = None
    for m in EDITOR_FUNC_RE.finditer(src):
        if m.start() >= offset:
            break
        best = m.group(1)
    return best


def host_reaches_panel(host, funcs, panels):
    """Whether some panel calls `host`, directly or through the model's own methods.

    One hop is not enough: the honest shape is a panel action that reads a file and
    then delegates (`importXMPFile(from:) -> applyXMP(_:) -> XMPImporter.import_`).
    Judging only the immediate host would call that a dead entry, which is how a
    checker gets switched off. Walking upward stops at the first panel reference, and
    a host nobody calls still reports -- the transitive case is pinned in --self-test.
    """
    frontier = [host]
    seen = set(frontier)
    while frontier:
        name = frontier.pop()
        if any(re.search(r'[.]%s\b' % re.escape(name), s) for s in panels.values()):
            return True
        needle = re.compile(r'\b%s\s*\(' % re.escape(name))
        for other, body in funcs:
            if other in seen or other == name or not needle.search(body):
                continue
            seen.add(other)
            frontier.append(other)
    return False


def entry_call_sites(texts):
    """(Type, verb) -> (own file, [other files calling it]) for every static entry point."""
    out = {}
    for path, src in texts.items():
        for m in ENTRY_RE.finditer(src):
            ty = enclosing_type(src, m.start())
            if not ty:
                continue
            verb = m.group(1)
            needle = '%s.%s(' % (ty, verb)
            callers = sorted(p for p, s in texts.items() if p != path and needle in s)
            out['%s.%s' % (ty, verb)] = (path, ty, verb, callers)
    return out


def check_manifest_claims(findings, texts):
    """A manifest `purpose` must agree with whether a task actually consumes that weight.

    `purpose` is rendered verbatim in the Models panel (`ModelsPanel`), so "v1 not
    wired" on a weight that drives the whole beauty chain is the app lying to the user.
    """
    if not os.path.exists(MODELS):
        findings.append('%s is missing (the manifest is the single source of truth)' % MODELS)
        return
    try:
        models = json.loads(read(MODELS)).get('models', [])
    except ValueError as exc:
        findings.append('%s does not parse: %s' % (MODELS, exc))
        return
    for entry in models:
        mid = entry.get('id', '')
        purpose = entry.get('purpose', '')
        literal = '"%s"' % mid
        holders = sorted(p for p, s in texts.items() if literal in s)
        # A weight is only in use when a task reads it *and* something outside that
        # task calls the task -- an unreferenced task is the dead-asset shape again.
        used_by = []
        for holder in holders:
            if not holder.startswith(AI) or not holder.endswith('Task.swift'):
                continue
            task = os.path.basename(holder)[:-len('.swift')]
            if any(p != holder and ('%s.' % task) in s for p, s in texts.items()):
                used_by.append(holder)
        if '已接线' in purpose and not used_by:
            findings.append('%s: purpose claims the weight is wired but no task that is '
                            'actually called reads it' % mid)
        if CLAIM_SPARE_RE.search(purpose) and used_by:
            findings.append('%s: purpose says spare/not wired but %s consumes it (the panel '
                            'tells the user this feature does not exist)' % (mid, used_by[0]))
        if CLAIM_SPARE_RE.search(purpose) and not used_by and mid in ''.join(
                s for p, s in texts.items() if p.startswith(AI)):
            findings.append('%s: purpose calls it a spare but an AI task still mentions it' % mid)


def check_dead_ui_entries(findings, texts):
    """An engine reachable only from `EditorModel`, whose method no panel calls."""
    editor = texts.get(EDITOR)
    if editor is None:
        return
    panels = {p: s for p, s in texts.items() if p.startswith(UI) and p != EDITOR}
    funcs = editor_funcs(editor)
    for key, (own, ty, verb, callers) in sorted(entry_call_sites(texts).items()):
        if key in DEAD_ENTRIES_OK or not callers:
            continue
        if set(callers) != {EDITOR}:
            continue
        host = enclosing_editor_func(editor, editor.find('%s.%s(' % (ty, verb)))
        if not host:
            continue
        if host_reaches_panel(host, funcs, panels):
            continue
        findings.append('%s.%s is reached only from EditorModel.%s(), and no panel calls '
                        '%s() (dead entry: implementation + tests, no feature). Record it '
                        'in DEAD_ENTRIES_OK only with a reason and a doc anchor'
                        % (own, ty, verb, host))


def check_stale_doc_claims(findings, texts):
    """A doc line denying an entry point for something the code does expose.

    Reachable means "a panel other than the model glue, or the render/export path"
    touches it -- EditorModel alone is precisely the dead-entry shape the other check
    reports, so counting it as reachable would silence the XMP finding forever.

    Historical narrative legitimately contains past-tense negatives ("these three were
   哑资产 until this batch"), so a line may opt out with the marker
    `<!-- wiring-check:history -->`; grep for it to see what is claimed away. The parity
    tables are also built as "本轮之前 → 本轮之后", so any row that still carries a check
    mark is describing a resolved state rather than a live gap.
    """
    reachable = set()
    for key, (own, ty, verb, callers) in entry_call_sites(texts).items():
        if any((p.startswith(UI) and p != EDITOR) or p in RENDER_HOSTS for p in callers):
            reachable.add(ty)
    doc_files = ['README.md'] if os.path.exists('README.md') else []
    if os.path.isdir('docs'):
        doc_files += sorted(os.path.join('docs', n) for n in os.listdir('docs')
                            if n.endswith('.md'))
    for path in doc_files:
        for line in read(path).splitlines():
            if HISTORY_MARK in line or RESOLVED_MARK in line:
                continue
            if not NEGATIVE_DOC_RE.search(line):
                continue
            for sym in BACKTICK_TYPE_RE.findall(line):
                if sym in reachable:
                    findings.append("%s: this line says %s has no entry point, but panels "
                                    "or the render path call it (stale gap claim)"
                                    % (path, sym))


def tree_test_count():
    if not os.path.isdir(TEST_DIR):
        return 0
    n = 0
    for name in sorted(os.listdir(TEST_DIR)):
        if name.endswith('.swift'):
            n += len(TEST_FUNC_RE.findall(read('%s/%s' % (TEST_DIR, name))))
    return n


def check_test_counts(findings):
    """Documented test-case counts must match the tree.

    Four different numbers for the same suite (320 / 342 / 344 / 352) were live in the
    docs at once, none of them wrong at the time it was written and all of them wrong
    now. A count is only worth printing if something re-checks it, so only the shapes
    matched by COUNT_ANCHOR_RE are treated as claims; dated historical rows stay.
    """
    actual = tree_test_count()
    docs = ['README.md'] if os.path.exists('README.md') else []
    if os.path.isdir('docs'):
        docs += sorted(os.path.join('docs', n) for n in os.listdir('docs') if n.endswith('.md'))
    for path in docs:
        for m in COUNT_ANCHOR_RE.finditer(read(path)):
            if int(m.group(1)) != actual:
                findings.append('%s: documented count %s 格 but the tree has %d '
                                '`func test` methods (fix the number, or say which sha '
                                'it was true for)' % (path, m.group(1), actual))


WRONG_COUNT = '3'
RIGHT_COUNT = '2'
SPARE_PURPOSE = '备用：仓里没有任何任务引用它'
WIRED_PURPOSE = 'FakeTask 已接线，驱动画面'


def _fixture_tree(good):
    """A miniature repo used to test the checker itself.

    good=False plants one instance of every finding shape the checker claims to catch;
    good=True is the same tree with each of them fixed. The self-test asserts the bad
    tree produces exactly the expected set (nothing missed, nothing extra) and the good
    tree produces nothing. Both halves matter: a checker that fires on everything gets
    deleted as noise, and a checker that fires on nothing gets trusted by mistake.
    """
    panel_body = '        model.runFake()\n        model.document = nil\n\n'
    if good:
        panel_body += ('        model.reachOrphan()\n        model.reachModelOnly()\n'
                       '        model.importSidecar()\n\n')
    stale_doc = '' if good else (
        '`LiveEngine`（假功能）仍只有算子没有入口\n'
        '`OrphanEngine` 不在 v1\n'
        '报 `[fake_never_emitted]` 时要点名\n')
    # The bad tree leaves OrphanEngine with no caller at all (the dead-asset shape) and
    # ModelOnlyEngine reachable from the model only (the dead-entry shape). The good
    # tree gives both a real path to the user.
    editor_extra = ('    func reachOrphan() {\n        OrphanEngine.apply(0)\n    }\n\n'
                    if good else '')
    files = {
        'ImageCake/AI/FakeTask.swift': (
            'import Foundation\n'
            'enum FakeTask {\n'
            '    static func run(store: Int) -> Int {\n'
            '        let a = "fake_wired"\n'
            '        let b = "fake_stale_says_not_wired"\n'
            '        return a.count + b.count\n'
            '    }\n}\n'),
        'ImageCake/UI/EditorModel.swift': (
            'import Foundation\n'
            'class EditorModel {\n'
            '    func runFake() {\n        FakeTask.run(store: 0)\n    }\n\n'
            '    func reachLive() {\n        LiveEngine.apply(0)\n    }\n\n'
            '    func reachModelOnly() {\n        ModelOnlyEngine.apply(0)\n    }\n\n'
            # The transitive shape: a panel action that delegates. Reading a file and
            # then applying it lives in two methods, so the checker must follow the
            # chain -- otherwise wiring XMP would still read as a dead entry.
            '    func importSidecar() {\n        applyExternal()\n    }\n\n'
            '    func applyExternal() {\n        ExternalEngine.apply(0)\n    }\n\n'
            + editor_extra + '}\n'),
        'ImageCake/UI/FakePanel.swift': (
            'import Foundation\n'
            'struct FakePanel {\n'
            '    func body(model: EditorModel) {\n' + panel_body + '    }\n}\n'),
        'ImageCake/Imaging/LiveEngine.swift': (
            'import Foundation\nenum LiveEngine {\n    static func apply(_ x: Int) {}\n}\n'),
        'ImageCake/Imaging/ModelOnlyEngine.swift': (
            'import Foundation\nenum ModelOnlyEngine {\n    static func apply(_ x: Int) {}\n}\n'),
        'ImageCake/Imaging/OrphanEngine.swift': (
            'import Foundation\nenum OrphanEngine {\n    static func apply(_ x: Int) {}\n}\n'),
        'ImageCake/Imaging/ExternalEngine.swift': (
            'import Foundation\nenum ExternalEngine {\n    static func apply(_ x: Int) {}\n}\n'),
        'ImageCake/Domain/ImageDocument.swift': (
            'import Foundation\nstruct ImageDocument {\n'
            '    func render() {\n        LiveEngine.apply(0)\n    }\n}\n'),
        'Tests/ImageCakeTests/FakeTests.swift': (
            'import XCTest\nfinal class FakeTests: XCTestCase {\n'
            '    func testOne() { XCTAssertEqual(1, 1) }\n\n'
            '    func testTwo() { XCTAssertTrue(true) }\n}\n'),
        'README.md': (
            '# fake\n\n'
            '| 单元测试（%s 格） | 假表 |\n\n'
            '- [x] 已完成的复选框，不能被当成令牌\n'
            '- 方向 a-d 四条都是方向断言\n'
            '`LiveEngine` 有算子**没有入口** → ✅ 入口已接通\n'
            '%s') % (RIGHT_COUNT if good else WRONG_COUNT, stale_doc),
    }
    entries = [
        {'id': 'fake_wired', 'purpose': '478 点关键点（%s）' % WIRED_PURPOSE},
        {'id': 'fake_spare', 'purpose': '106 点关键点（%s）' % SPARE_PURPOSE},
    ]
    if not good:
        entries += [
            {'id': 'fake_stale_says_not_wired', 'purpose': '身形关键点（%s）' % SPARE_PURPOSE},
            {'id': 'fake_claim_wired_nothing', 'purpose': '发丝分割（%s）' % WIRED_PURPOSE},
        ]
    files[MODELS] = json.dumps({'schema': 1, 'models': entries}, ensure_ascii=False) + '\n'
    return files


EXPECTED_BAD = (
    'OrphanEngine has apply() but no call site',
    'no panel calls reachModelOnly',
    'no panel calls applyExternal',
    'fake_stale_says_not_wired: purpose says spare/not wired',
    'fake_claim_wired_nothing: purpose claims the weight is wired',
    'documented count 3 格',
    'says LiveEngine has no entry point',
    '[fake_never_emitted] is documented but no code emits',
)


def _run_new_checks():
    findings = []
    texts = swift_texts()
    check_engine_entries(findings)
    check_tokens(findings)
    check_manifest_claims(findings, texts)
    check_dead_ui_entries(findings, texts)
    check_stale_doc_claims(findings, texts)
    check_test_counts(findings)
    return findings


def self_test():
    cwd = os.getcwd()
    root = tempfile.mkdtemp(prefix='wiring-selftest-')
    failures = []
    try:
        for good in (False, True):
            for path, content in _fixture_tree(good).items():
                full = os.path.join(root, *path.split('/'))
                parent = os.path.dirname(full)
                if not os.path.isdir(parent):
                    os.makedirs(parent)
                with io.open(full, 'w', encoding='utf-8', newline='\n') as handle:
                    handle.write(content)
            os.chdir(root)
            findings = _run_new_checks()
            if good:
                if findings:
                    failures.append('good fixture still reported %d finding(s):\n  %s'
                                    % (len(findings), '\n  '.join(findings)))
                continue
            for expected in EXPECTED_BAD:
                if not any(expected in f for f in findings):
                    failures.append('bad fixture did NOT trigger: %s' % expected)
            for f in findings:
                if not any(expected in f for expected in EXPECTED_BAD):
                    failures.append('unexpected finding (the checker shouts): %s' % f)
            print('self-test bad tree: %d findings, %d expected shapes'
                  % (len(findings), len(EXPECTED_BAD)))
    finally:
        os.chdir(cwd)
        shutil.rmtree(root, ignore_errors=True)
    for f in failures:
        print(f)
    if failures:
        print('self-test: FAILED (%d)' % len(failures))
        return len(failures)
    print('self-test: ok (%d shapes caught, good fixture silent)' % len(EXPECTED_BAD))
    return 0


def main(argv=()):
    findings = []
    lex_findings = []
    for path in sorted(swift_files()):
        lex_findings += check_path(path)
    findings += lex_findings

    seen = set()
    for name in ('BeautyParameters.swift', 'SceneParameters.swift', 'EditParameters.swift'):
        check_parameter_contract('%s/%s' % (DOMAIN, name), findings, seen)
    check_render_wiring(findings)
    check_engine_entries(findings)
    check_tokens(findings)
    check_requires(findings)

    texts = swift_texts()
    check_manifest_claims(findings, texts)
    check_dead_ui_entries(findings, texts)
    check_stale_doc_claims(findings, texts)
    check_test_counts(findings)

    for f in findings:
        print(f)
    print('wiring check: %d swift files, %d parameter structs, %d test methods, %d findings'
          % (len(texts), len(seen), tree_test_count(), len(findings)))
    return len(findings)


if __name__ == '__main__':
    if '--self-test' in sys.argv[1:]:
        sys.exit(self_test())
    sys.exit(1 if main(sys.argv[1:]) else 0)
