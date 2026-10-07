import { EditorState, RangeSetBuilder, StateField, StateEffect } from "@codemirror/state"
import { EditorView, Decoration, WidgetType, keymap, drawSelection,
         rectangularSelection } from "@codemirror/view"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import { Prec } from "@codemirror/state"
import { markdown, markdownLanguage } from "@codemirror/lang-markdown"
import { syntaxHighlighting, HighlightStyle, syntaxTree } from "@codemirror/language"
import { searchKeymap, highlightSelectionMatches, search, openSearchPanel } from "@codemirror/search"
import { tags as t } from "@lezer/highlight"

// S3: every colour is a CSS variable, so HostThemeTokens maps in without JS.
const highlight = HighlightStyle.define([
  { tag: t.heading1, fontSize: "1.8em", fontWeight: "600" },
  { tag: t.heading2, fontSize: "1.6em", fontWeight: "600" },
  { tag: t.heading3, fontSize: "1.4em", fontWeight: "600" },
  // 5B.F1: h4–h6 were never sized — the stylesheet's `.tok-heading<N>` rules
  // matched nothing. Ratios and weights are `MarkdownTheme.headingSize` /
  // `headingWeight`: semibold at the top, bold at the bottom.
  { tag: t.heading4, fontSize: "1.25em", fontWeight: "700" },
  { tag: t.heading5, fontSize: "1.125em", fontWeight: "700" },
  { tag: t.heading6, fontSize: "1.05em", fontWeight: "700" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: [t.link, t.url], color: "var(--accent-primary)" },
  { tag: t.monospace, fontFamily: "var(--font-mono)" },
  { tag: t.meta, color: "var(--text-faint)" },
])

// ---------------------------------------------------- inline live preview
//
// E2T0. Without this the editor shows `## Heading` and `**bold**` with their
// syntax on screen at all times, which is not Live Preview — it is a source
// editor with colours, and it is what the first screenshot of a real note
// showed.
//
// The rule is Obsidian's and the same one the native renderer already
// implements (`MarkdownReveal`): syntax is hidden unless the CARET IS ON ITS
// LINE, so the marker you need to edit is the one you are standing in. Line
// scope, not block scope — a five-item list must not show all five bullets
// because the caret is in one of them.

/// Marker node types whose text is notation and nothing else.
///
/// Names come from lezer-markdown. `CodeMark` covers both inline backticks and
/// a fence's ```; `HeaderMark` covers the `#` run and a setext underline.
const MARKER_NODES = new Set([
  "HeaderMark", "EmphasisMark", "StrikethroughMark", "CodeMark",
  "QuoteMark", "LinkMark", "CodeInfo",
])

/// A drawn horizontal rule, standing in for `---`.
class RuleWidget extends WidgetType {
  toDOM() {
    const hr = document.createElement("hr")
    hr.className = "cm-lore-rule"
    return hr
  }
  eq() { return true }
  ignoreEvent() { return true }
}

/// The bullet a collapsed list marker is replaced by.
///
/// Depth cycles disc, circle, square — the same decision M9 measured against
/// Obsidian. An ordered item keeps its own number, because a number is already
/// its own distinguishing mark.
class BulletWidget extends WidgetType {
  constructor(text, depth) { super(); this.text = text; this.depth = depth }
  eq(other) { return other.text === this.text && other.depth === this.depth }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-lore-bullet"
    const ordered = /\d/.test(this.text)
    span.textContent = ordered ? this.text.trim()
                               : ["•", "◦", "▪"][this.depth % 3]
    return span
  }
  ignoreEvent() { return true }
}

/// A rendered `[[wikilink]]`.
///
/// E2T1b. Resolution stays in Swift — this widget knows the raw target and
/// nothing else, and a click hands that target over the bridge exactly as the
/// native editor hands it to `onOpenLink`. Keeping vault knowledge on the Swift
/// side is what stops the editor surface from needing its own index.
/// The DOM for a rendered wikilink, wherever it appears.
///
/// Shared by `WikilinkWidget` and by a table cell's `renderInline`, because a
/// link inside a cell that merely LOOKS like a link — or worse, stays as
/// `[[Design Doc]]` while every other link on the page is rendered — is the
/// half-rendered table the first real-note screenshot showed.
function wikilinkSpan(target, display) {
  const a = document.createElement("span")
  a.className = "cm-lore-wikilink"
  a.textContent = display
  a.dataset.target = target
  // `mousedown`, not `click`: CM6 moves the caret on mousedown, and by the time
  // a click lands the selection has already changed — which reveals the line
  // and destroys the very widget being clicked.
  a.addEventListener("mousedown", event => {
    event.preventDefault()
    event.stopPropagation()
    window.webkit?.messageHandlers?.lore?.postMessage({
      kind: "openLink", target, beside: event.metaKey,
    })
  })
  return a
}

/// Split `target|display` — one place, so a cell and a widget cannot disagree
/// about which half is which.
function splitWikilink(inner) {
  const bar = inner.indexOf("|")
  const target = (bar === -1 ? inner : inner.slice(0, bar)).trim()
  const display = bar === -1 ? target : inner.slice(bar + 1).trim()
  return { target, display: display || target }
}

class WikilinkWidget extends WidgetType {
  constructor(target, display) { super(); this.target = target; this.display = display }
  eq(other) { return other.target === this.target && other.display === this.display }
  toDOM() { return wikilinkSpan(this.target, this.display) }
  // The widget handles its own mousedown; CM6 must not also treat it as a
  // click in the text.
  ignoreEvent() { return true }
}

/// The ranges in which `[[…]]` is documentation about a link, not a link.
///
/// The same exclusion `LinkParser` applies on the Swift side, and for the same
/// reason: a `[[Design]]` written inside a fenced block is prose. Rendering it
/// as a link here — while Swift's link graph excludes it — would give the
/// reader something clickable that no backlink, and no rename, knows about.
function codeRanges(state) {
  const ranges = []
  syntaxTree(state).iterate({
    enter: node => {
      if (node.name === "InlineCode" || node.name === "FencedCode" ||
          node.name === "CodeBlock" || node.name === "CodeText") {
        ranges.push({ from: node.from, to: node.to })
      }
    },
  })
  return ranges
}

/// Every `[[target]]` / `[[target|display]]` outside code.
///
/// An `![[embed]]` is deliberately SKIPPED: it is a different construct with a
/// different rendering (E2T1c), and treating it as a plain link here would
/// leave a stray `!` in front of the rendered result.
function wikilinkRanges(state) {
  const text = state.doc.toString()
  const code = codeRanges(state)
  const inCode = (from, to) => code.some(r => from < r.to && to > r.from)
  const found = []
  const pattern = /\[\[([^\[\]\n]+)\]\]/g
  let match
  while ((match = pattern.exec(text)) !== null) {
    const from = match.index
    if (from > 0 && text[from - 1] === "!") continue
    const to = from + match[0].length
    if (inCode(from, to)) continue
    const { target, display } = splitWikilink(match[1])
    if (!target) continue
    found.push({ from, to, target, display })
  }
  return found
}

/// Where `![[…]]` sits — the ranges in which NO marker may be hidden yet.
///
/// Found by the screenshot, not by a test. lezer parses `![[x]]` as an image,
/// so its `!` and brackets are `LinkMark` nodes and E2T0's marker-hiding
/// collapsed the whole thing to a bare `x` styled as a link. An embed that
/// renders as a link to a file is worse than an embed that renders as its own
/// source: the reader is shown a construct that does not exist. Until E2T1c
/// renders embeds properly, their syntax stays on screen — visibly unfinished
/// rather than quietly wrong.
///
/// The earlier test asserted `wikilinkTargets() === []` for an embed, which was
/// true and proved nothing: the rendering came from a different code path.
function embedRanges(state) {
  const text = state.doc.toString()
  const code = codeRanges(state)
  const found = []
  const pattern = /!\[\[([^\[\]\n]+)\]\]/g
  let match
  while ((match = pattern.exec(text)) !== null) {
    const from = match.index, to = from + match[0].length
    if (code.some(r => from < r.to && to > r.from)) continue
    found.push({ from, to })
  }
  return found
}

/// Ranges in which a `#` is part of a LINK, not a tag.
///
/// `[text](https://x.test/page#anchor)` and `[[Target#Heading]]` both contain a
/// `#` that means something else. The native scanner excludes both, from two
/// different sources for the same reason lezer gives here: `[[…]]` is not
/// CommonMark, so the tree knows nothing about it.
function linkRanges(state) {
  const ranges = []
  syntaxTree(state).iterate({
    enter: node => {
      if (node.name === "Link" || node.name === "Image" || node.name === "URL") {
        ranges.push({ from: node.from, to: node.to })
      }
    },
  })
  for (const w of wikilinkRanges(state)) ranges.push({ from: w.from, to: w.to })
  for (const e of embedRanges(state)) ranges.push({ from: e.from, to: e.to })
  return ranges
}

/// `#tag`, `#nested/tag`.
///
/// A deliberate transcription of `MarkdownExtensions.scanTags`, disqualification
/// for disqualification, because the tags this surface shows must be exactly the
/// tags the index holds — a tag rendered here that the sidebar does not list is
/// a tag the reader cannot click through to anything.
///
/// The `#` STAYS in the span. Obsidian keeps it, and a chip without it is
/// indistinguishable from a link chip.
function tagRanges(state) {
  const text = state.doc.toString()
  const excluded = codeRanges(state).concat(linkRanges(state))
  const isExcluded = at => excluded.some(r => at >= r.from && at < r.to)
  const found = []
  let i = 0
  while (i < text.length) {
    if (text[i] !== "#" || isExcluded(i)) { i++; continue }
    // A heading: `#`(s) at line start, then a space. The AST owns it.
    const atLineStart = i === 0 || text[i - 1] === "\n"
    if (atLineStart) {
      let h = i
      while (h < text.length && text[h] === "#") h++
      if (text[h] === " ") { i = h; continue }
    }
    let j = i + 1
    let hasNonDigit = false
    while (j < text.length) {
      const ch = text[j]
      const code = text.charCodeAt(j)
      const isDigit = ch >= "0" && ch <= "9"
      const isLetter = /[A-Za-z]/.test(ch) || code > 0x7f
      const isJoiner = ch === "_" || ch === "-" || ch === "/"
      if (!(isDigit || isLetter || isJoiner)) break
      if (isLetter || isJoiner) hasNonDigit = true
      j++
    }
    const name = text.slice(i + 1, j)
    // At least one non-digit, or `#1234` — an issue reference — becomes a tag
    // and every changelog in the vault fills with them.
    if (!hasNonDigit || !name) { i++; continue }
    // A trailing `/` is notation the author is mid-typing. It is trimmed from
    // the NAME but stays inside the span, so the chip does not visibly clip
    // under the caret.
    const trimmed = name.endsWith("/") ? name.slice(0, -1) : name
    if (!trimmed) { i++; continue }
    found.push({ from: i, to: j, name: trimmed })
    i = j
  }
  return found
}

/// A tag chip. Clicking it filters the vault, exactly as the sidebar's chip
/// row does — the same `onTagClick` the native editor is handed.
class TagWidget extends WidgetType {
  constructor(text, name) { super(); this.text = text; this.name = name }
  eq(other) { return other.text === this.text && other.name === this.name }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-lore-tag"
    span.textContent = this.text
    span.dataset.tag = this.name
    span.addEventListener("mousedown", event => {
      event.preventDefault()
      event.stopPropagation()
      window.webkit?.messageHandlers?.lore?.postMessage(
        { kind: "openTag", tag: this.name })
    })
    return span
  }
  ignoreEvent() { return true }
}

// ------------------------------------------------------- editor settings
//
// These two are STATE, not module variables.
//
// They were module-level `let`s with a `view.dispatch({})` to redraw, and that
// silently did nothing: the decoration facet is computed from `["doc",
// "selection"]`, an empty transaction changes neither, so CM6 correctly reused
// its cached decorations. Turning chips off left every chip on screen. Putting
// the settings in a StateField and naming that field as a dependency is what
// makes "redraw when this changes" true rather than intended.

/// `{ tagsAsChips, tasksToggleable }`.
const settingsEffect = StateEffect.define()

// ------------------------------------------------------- transclusions
//
// E2T1c. `![[Note.md]]` shows the note. The CONTENT comes from Swift — the
// slicing of `![[note#Heading]]` and `![[note#^block-id]]`, the frontmatter
// strip, the cycle and depth caps are all `TransclusionResolver`'s, which
// already knows all of it. This side only asks and draws.
//
// Content arrives asynchronously, so it is state for the same reason the
// settings are: the decoration facet recomputes when the field changes, and a
// module-level cache would leave the placeholder on screen forever.

/// `{ target, kind, text }` for one resolved embed.
const transclusionEffect = StateEffect.define()

const transclusionField = StateField.define({
  create: () => ({}),
  update(value, tr) {
    for (const effect of tr.effects) {
      if (!effect.is(transclusionEffect)) continue
      value = { ...value, [effect.value.target]: effect.value }
    }
    return value
  },
})

/// Targets already asked for, so a redraw does not re-ask on every keystroke.
///
/// Deliberately NOT in the state field: it is a record of messages sent, not of
/// document content, and putting it in the field would make every request part
/// of the undo history.
const requested = new Set()

const settingsField = StateField.define({
  create: () => ({ tagsAsChips: true, tasksToggleable: true }),
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(settingsEffect)) return { ...value, ...effect.value }
    }
    return value
  },
})

/// A task checkbox that can actually be clicked.
///
/// E2T4, and the clearest single case for this whole milestone: the native
/// editor draws a checkbox and routes a click back through
/// `MarkdownEditorClicks` to edit the text underneath a picture. Here the
/// checkbox IS an input, and toggling it dispatches a one-character change to
/// the document — no drawn stand-in, no hit-testing against a painted rect.
class CheckboxWidget extends WidgetType {
  constructor(checked, from, toggleable) {
    super(); this.checked = checked; this.from = from; this.toggleable = toggleable
  }
  // `toggleable` is part of identity: without it, turning the session
  // read-only leaves every already-drawn checkbox enabled, because CM6 keeps a
  // widget whose `eq` says nothing changed.
  eq(other) {
    return other.checked === this.checked && other.from === this.from &&
           other.toggleable === this.toggleable
  }
  toDOM(view) {
    const box = document.createElement("input")
    box.type = "checkbox"
    box.className = "cm-lore-checkbox"
    box.checked = this.checked
    // A read-only session can never persist this, so it must not offer to —
    // the same reasoning as the native `allowsTaskToggle`.
    box.disabled = !this.toggleable
    box.addEventListener("mousedown", event => {
      // The caret must not move to this line: that would reveal the source and
      // replace the box mid-click.
      event.preventDefault()
      event.stopPropagation()
      if (!this.toggleable) return
      // One character. `[ ]` -> `[x]` is a single-unit change, which keeps the
      // undo grain at "toggled one task" and leaves every other offset in the
      // document exactly where it was.
      view.dispatch({ changes: { from: this.from + 1, to: this.from + 2,
                                 insert: this.checked ? " " : "x" } })
    })
    return box
  }
  ignoreEvent() { return true }
}

/// `- [ ] thing` / `* [x] done`, with the marker's own range.
///
/// Scanned by line rather than taken from the tree: `markdown()` here is
/// CommonMark, which has no task-list node — the same reason the tables in this
/// file are hand-rolled.
function taskLines(state) {
  const found = []
  const doc = state.doc
  for (let n = 1; n <= doc.lines; n++) {
    const line = doc.line(n)
    const match = /^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]($|\s)/.exec(line.text)
    if (!match) continue
    const from = line.from + match[1].length
    found.push({ from, to: from + 3, checked: match[2] !== " ", line: n })
  }
  return found
}

// ------------------------------------------------------------- callouts
//
// E2T3. `> [!note] An optional title` — a block quote whose first line opens
// with `[!type]`. Not CommonMark, so lezer gives us the quote and this gives us
// what the quote MEANS, exactly as `MarkdownCallout` does on the Swift side.

/// Every spelling Obsidian accepts, mapped to a kind. Transcribed from
/// `MarkdownCallout.Kind.named` — a vault written against Obsidian contains
/// `[!tldr]` and `[!caution]` interchangeably with `[!abstract]` and
/// `[!warning]`, and an unrecognised type must fall back to a plain quote
/// rather than render as stray punctuation.
const CALLOUT_ALIASES = {
  note: "note",
  abstract: "abstract", summary: "abstract", tldr: "abstract",
  info: "info",
  todo: "todo",
  tip: "tip", hint: "tip", important: "tip",
  success: "success", check: "success", done: "success",
  question: "question", help: "question", faq: "question",
  warning: "warning", caution: "warning", attention: "warning",
  failure: "failure", fail: "failure", missing: "failure",
  danger: "danger", error: "danger",
  bug: "bug",
  example: "example",
  quote: "quote", cite: "quote",
}

/// What Obsidian shows when the author gave no title.
///
/// DRAWN, never inserted: putting it in the text would change the document and
/// every offset the index and the link graph hold with it.
const CALLOUT_TITLES = {
  note: "Note", abstract: "Abstract", info: "Info", todo: "Todo", tip: "Tip",
  success: "Success", question: "Question", warning: "Warning",
  failure: "Failure", danger: "Danger", bug: "Bug", example: "Example",
  quote: "Quote",
}

/// The glyph beside the title.
///
/// Unicode, not SF Symbols: those are an AppKit facility and this surface is a
/// web view, so the native renderer's `pencil`/`flame`/`ant` cannot be reached
/// from here. Bundling an icon font or inlining thirteen SVG paths buys a
/// closer match than the parity gap justifies, so these are chosen to read as
/// the same SIGNAL — a warning triangle is a warning triangle.
const CALLOUT_ICONS = {
  note: "\u270E", abstract: "\u2261", info: "\u24D8", todo: "\u2611",
  tip: "\u25C6", success: "\u2713", question: "?", warning: "\u26A0",
  failure: "\u2715", danger: "\u26A1", bug: "\u2691", example: "\u2263",
  quote: "\u275D",
}

/// The header a callout's opening line declares, or null for a plain quote.
function calloutHeader(text) {
  const match = /^(\s*>\s*)(\[!([A-Za-z]+)\]([+-]?))(\s*)(.*)$/.exec(text)
  if (!match) return null
  const kind = CALLOUT_ALIASES[match[3].toLowerCase()]
  if (!kind) return null
  return {
    kind,
    markerStart: match[1].length,
    markerEnd: match[1].length + match[2].length,
    // The author's own title is real document text and stays as text; only
    // the `[!type]` notation is replaced.
    title: match[6].trim(),
  }
}

/// The icon, and — when the author wrote no title of their own — the default
/// one, standing in for the `[!type]` notation.
class CalloutMarkerWidget extends WidgetType {
  constructor(kind, needsTitle) { super(); this.kind = kind; this.needsTitle = needsTitle }
  eq(other) { return other.kind === this.kind && other.needsTitle === this.needsTitle }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-lore-callout-marker"
    const icon = document.createElement("span")
    icon.className = "cm-lore-callout-icon"
    icon.textContent = CALLOUT_ICONS[this.kind]
    span.appendChild(icon)
    if (this.needsTitle) {
      const title = document.createElement("span")
      title.className = "cm-lore-callout-default-title"
      title.textContent = CALLOUT_TITLES[this.kind]
      span.appendChild(title)
    }
    return span
  }
  ignoreEvent() { return true }
}

/// Every callout in the document, as line spans.
///
/// A callout runs from its `> [!type]` line for as long as the quote does —
/// consecutive lines beginning with `>`. Found by line scan for the same reason
/// the header is: the construct is not in the tree.
function calloutBlocks(state) {
  const doc = state.doc
  const blocks = []
  let n = 1
  while (n <= doc.lines) {
    const header = calloutHeader(doc.line(n).text)
    if (!header) { n++; continue }
    let last = n
    while (last + 1 <= doc.lines && /^\s*>/.test(doc.line(last + 1).text)) last++
    blocks.push({ first: n, last, header })
    n = last + 1
  }
  return blocks
}

// ------------------------------------------------------------ footnotes
//
// `[^1]` and, at line start, `[^1]:`. Not CommonMark, so the tree does not have
// them — the same reason wikilinks and callouts are scanned by hand.
//
// Found by the E4T2 parity shots: the native editor draws a reference as a
// small superscript and CM6 was showing `^1`, because `LinkMark` hid the
// brackets and left the caret and the label sitting in the prose.

/// A superscript reference, standing in for `[^label]`.
class FootnoteRefWidget extends WidgetType {
  constructor(label) { super(); this.label = label }
  eq(other) { return other.label === this.label }
  toDOM() {
    const sup = document.createElement("sup")
    sup.className = "cm-lore-footnote-ref"
    sup.textContent = this.label
    return sup
  }
  ignoreEvent() { return true }
}

/// The label of a definition, standing in for `[^label]:`.
class FootnoteDefWidget extends WidgetType {
  constructor(label) { super(); this.label = label }
  eq(other) { return other.label === this.label }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-lore-footnote-def"
    span.textContent = this.label + "."
    return span
  }
  ignoreEvent() { return true }
}

/// Every `[^label]` outside code, and whether it is a definition.
///
/// A definition is checked by POSITION: `[^1]:` at line start is a definition
/// and the same characters mid-line are a reference. One scan decides both,
/// rather than two scans racing — the same shape as
/// `MarkdownExtensions.scanFootnotes`.
function footnoteRanges(state) {
  const text = state.doc.toString()
  const code = codeRanges(state)
  const found = []
  const pattern = /\[\^([^\]\s]+)\](:?)/g
  let match
  while ((match = pattern.exec(text)) !== null) {
    const from = match.index
    const to = from + match[0].length
    if (code.some(r => from < r.to && to > r.from)) continue
    const atLineStart = from === 0 || text[from - 1] === "\n"
    const isDefinition = match[2] === ":" && atLineStart
    // A mid-line `[^1]:` is a reference followed by a colon, so the colon is
    // not part of the span.
    const end = match[2] === ":" && !isDefinition ? to - 1 : to
    found.push({ from, to: end, label: match[1], isDefinition })
  }
  return found
}

// ----------------------------------------------------------------- math
//
// E2T6. `$inline$` and `$$block$$`, rendered by KaTeX.
//
// ## Why KaTeX, measured rather than assumed
//
// The plan required the bundle cost to be measured before choosing. Built and
// weighed, both minified:
//
//     KaTeX ....... 261 KB JS + 24 KB CSS + 296 KB woff2 = 581 KB
//     MathJax ..... 1777 KB JS, no font files (SVG paths)
//
// KaTeX at a third the total. MathJax's one real advantage — no font files, so
// no missing-glyph boxes while fonts load — is not worth 1.2 MB in a plugin
// bundle, and the fonts here are local files in the same directory as the page
// rather than a network fetch, so the race it avoids barely exists.
//
// ## What the native renderer could not do
//
// `MarkdownMath` draws maths with a hand-written parser and layout engine
// because AppKit has no TeX renderer that does not drag in a web view. It is
// all-or-nothing per expression: anything its parser refuses is left as tinted
// source. This surface IS a web view, so that constraint is gone — but the rule
// it produced is kept, because it is a good rule. An expression KaTeX cannot
// parse stays as source and stays tinted, rather than half-rendering.

/// `$inline$` and `$$block$$`, outside code.
///
/// The scan mirrors `MarkdownMath.spans`: a `$` opens, two `$` open a block,
/// and the closing delimiter must be the same width. Suppressed inside code for
/// the same reason a wikilink is — `$5 and $10` in prose is not mathematics,
/// and neither is a `$` in a shell snippet.
function mathRanges(state) {
  const text = state.doc.toString()
  const code = codeRanges(state)
  const inCode = at => code.some(r => at >= r.from && at < r.to)
  const found = []
  const isSpace = ch => ch === " " || ch === "\t" || ch === "\n" || ch === "\r"
  let i = 0
  while (i < text.length) {
    if (text[i] !== "$" || inCode(i)) { i++; continue }
    const isBlock = text[i + 1] === "$"
    const width = isBlock ? 2 : 1
    const delimiter = isBlock ? "$$" : "$"
    // An inline opener followed by whitespace is not an opener. `$ x$` is
    // prose; so is the first `$` of "costs $ 5".
    if (!isBlock && isSpace(text[i + 1])) { i += 1; continue }
    let close = -1
    let j = i + width
    while (j < text.length) {
      if (text[j] === "\\") { j += 2; continue }
      // An inline expression never crosses a line, which is `MarkdownMath`'s
      // rule and what stops a lone `$` from swallowing the rest of the note.
      if (!isBlock && (text[j] === "\n" || text[j] === "\r")) break
      if (text.startsWith(delimiter, j)) {
        // An inline `$…$` must not be the opening half of a `$$`.
        if (!isBlock && text[j + 1] === "$") { j += 2; continue }
        // THE rule that stops "$5 and then $10 more" from being an
        // expression: a closing delimiter is never preceded by whitespace.
        // Transcribed from `MarkdownMath.closingDelimiter`, where it is the
        // reason a vault full of prices does not fill with rendered maths.
        //
        // Applied to inline only. A block may span lines —
        //
        //     $$
        //     x = y
        //     $$
        //
        // — which is how Obsidian is written and used, and which the native
        // renderer's shared whitespace rule rejects. A deliberate divergence:
        // this surface can render it, and the parity goal is Obsidian's
        // behaviour rather than the native renderer's limits.
        if (!isBlock && isSpace(text[j - 1])) { j += 1; continue }
        close = j
        break
      }
      j++
    }
    if (close === -1) { i += 1; continue }
    const body = text.slice(i + width, close)
    if (!body.trim()) { i += width; continue }
    found.push({ from: i, to: close + width, body, isBlock })
    i = close + width
  }
  return found
}

/// KaTeX, once it has arrived. See `src/katex-entry.js` for why it is not
/// simply imported: it costs ~29.5 MB of resident memory PER SURFACE, and most
/// notes contain no mathematics at all.
let katex = null
let katexLoading = false

/// Signals that KaTeX is available, so the decoration facet recomputes.
const katexEffect = StateEffect.define()

const katexField = StateField.define({
  create: () => false,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(katexEffect)) return true
    return value
  },
})

/// Fetch KaTeX, once, and redraw when it lands.
///
/// Until it does, expressions stay as source — which is already what an
/// unparseable expression does, so there is no third state to design.
function loadKatex(view) {
  if (katex || katexLoading) return
  katexLoading = true
  const script = document.createElement("script")
  script.src = "katex.js"
  script.onload = () => {
    katex = window.__loreKatex || null
    // A transaction, not a direct redraw: the facet depends on this field, and
    // that dependency is what makes the redraw happen at all.
    if (katex) view.dispatch({ effects: katexEffect.of(true) })
  }
  script.onerror = () => {
    // Left unloaded rather than retried on every keystroke. Maths stays source,
    // which is readable — a retry loop against a missing file would not be.
    katexLoading = false
    console.error("[Lore] katex.js failed to load; maths stays as source")
  }
  document.head.appendChild(script)
}

/// One rendered expression.
///
/// KaTeX is given `throwOnError: false`, and the result is checked: an
/// expression it cannot parse renders as KaTeX's own error markup, which is a
/// red version of the source. That is not what this surface wants — the native
/// renderer's rule is that unparseable maths stays SOURCE, tinted, so the
/// reader can still tell notation from prose. So a failure is caught and the
/// widget reports it, and the decoration is skipped entirely.
class MathWidget extends WidgetType {
  constructor(body, isBlock) { super(); this.body = body; this.isBlock = isBlock }
  eq(other) { return other.body === this.body && other.isBlock === this.isBlock }
  toDOM() {
    const host = document.createElement(this.isBlock ? "div" : "span")
    host.className = this.isBlock ? "cm-lore-math-block" : "cm-lore-math"
    host.dataset.tex = this.body
    katex.render(this.body, host, {
      displayMode: this.isBlock,
      throwOnError: false,
      output: "html",
    })
    return host
  }
  ignoreEvent() { return true }
}

/// Whether KaTeX can render this at all.
///
/// Asked BEFORE deciding to decorate, so an expression it refuses is left as
/// source rather than replaced by red error text. `renderToString` is used for
/// the check because it throws where `render` into a node would not.
function mathParses(body, isBlock) {
  if (!katex) return false
  try {
    katex.renderToString(body, { displayMode: isBlock, throwOnError: true })
    return true
  } catch {
    return false
  }
}

// --------------------------------------------------------------- embeds
//
// E2T5. `![[picture.png]]` and `![](picture.png)` become real images; anything
// else attached becomes the same chip the native renderer draws; a markdown
// target keeps its syntax, because rendering a note inside a note is E2T1c.

/// Case-insensitive, and the same set as `EmbedRendering.imageExtensions`: a
/// target is written by hand and Obsidian vaults are full of screenshots saved
/// with an upper-case extension.
const IMAGE_EXTENSIONS = new Set([
  "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg",
])
/// `EmbedRendering.markdownExtensions`.
const MARKDOWN_EXTENSIONS = new Set(["md", "markdown", "mdown"])

function lastExtension(name) {
  const dot = name.lastIndexOf(".")
  return dot === -1 ? "" : name.slice(dot + 1).toLowerCase()
}

/// The extension that decides what an embed becomes.
///
/// `#` is BOTH a fragment separator and a legal filename character, so the
/// whole target is tried first and the pre-fragment part only as a fallback.
/// Splitting on `#` first — which is what this did — turned
/// `![[Screen Shot #2 (v1).png]]` into a target with no extension at all, and
/// an image silently became a note embed. `![[note.md#Heading]]` still resolves
/// through the fallback, because `md#heading` is not a known extension.
function extensionOf(target) {
  const whole = lastExtension(target)
  if (IMAGE_EXTENSIONS.has(whole) || MARKDOWN_EXTENSIONS.has(whole)) return whole
  return lastExtension(target.split("#")[0])
}

/// What an embed of `target` should become. Mirrors `EmbedRendering.kind`.
function embedKind(target) {
  const ext = extensionOf(target)
  if (IMAGE_EXTENSIONS.has(ext)) return "image"
  if (MARKDOWN_EXTENSIONS.has(ext)) return "transclusion"
  if (!ext) return "transclusion"   // a bare note name is a note
  return "chip"
}

/// The URL the page asks for. Must match `CM6AssetSchemeHandler.url(forTarget:)`
/// exactly, including the encoding: a target may contain spaces, `#`, `?` and
/// `&`, every one of which would otherwise truncate or re-route the request.
function assetURL(target) {
  return "lore-asset:///" + target.replace(/[^A-Za-z0-9]/g, ch =>
    Array.from(new TextEncoder().encode(ch))
         .map(b => "%" + b.toString(16).toUpperCase().padStart(2, "0")).join(""))
}

/// An inline image.
///
/// `alt` carries the raw target, so a broken embed says WHICH file is missing
/// rather than showing a generic broken-image glyph.
class EmbedImageWidget extends WidgetType {
  constructor(target) { super(); this.target = target }
  eq(other) { return other.target === this.target }
  toDOM() {
    // A wrapper, because a failed image has to be REPLACED rather than styled:
    // `alt` text is not shown in place of a broken image in WebKit — a
    // grey box with a `?` glyph is, which is what the screenshot showed for a
    // missing attachment. `EmbedRendering` leaves an unresolved embed looking
    // like an unresolved link, and so does this.
    const wrap = document.createElement("span")
    wrap.className = "cm-lore-embed"
    const img = document.createElement("img")
    img.className = "cm-lore-embed-image"
    img.src = assetURL(this.target)
    img.alt = this.target
    img.dataset.target = this.target
    img.addEventListener("error", () => {
      const missing = document.createElement("span")
      missing.className = "cm-lore-embed-missing"
      missing.textContent = this.target
      missing.dataset.target = this.target
      missing.title = "Not found"
      wrap.replaceChildren(missing)
    })
    wrap.appendChild(img)
    return wrap
  }
  ignoreEvent() { return true }
}

/// A non-image, non-markdown attachment: a PDF, a Word file, a zip.
///
/// A chip, not an inline rendering — the native renderer's reasoning holds here
/// too: putting a second document's renderer inside the editor is a different
/// project. Clicking it opens the file through the same path a link does.
class EmbedChipWidget extends WidgetType {
  constructor(target) { super(); this.target = target }
  eq(other) { return other.target === this.target }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-lore-embed-chip"
    span.textContent = this.target
    span.dataset.target = this.target
    span.addEventListener("mousedown", event => {
      event.preventDefault()
      event.stopPropagation()
      window.webkit?.messageHandlers?.lore?.postMessage(
        { kind: "openLink", target: this.target, beside: event.metaKey })
    })
    return span
  }
  ignoreEvent() { return true }
}

/// A transcluded note.
///
/// The content is rendered by a NESTED, read-only CodeMirror rather than by a
/// second markdown renderer written for this widget. One engine, one set of
/// decorations, so a heading inside an embed looks exactly like a heading
/// outside it — and a second renderer is precisely the thing that made the
/// native surface and its PDF export drift apart.
///
/// Nested embeds inside the slice are NOT expanded: the inner editor gets the
/// rendering extensions without the transclusion one. That is the same "one
/// flat slice" the native renderer draws, and it makes a cycle impossible here
/// rather than merely capped.
class TransclusionWidget extends WidgetType {
  constructor(target, entry) { super(); this.target = target; this.entry = entry }
  eq(other) {
    return other.target === this.target &&
           other.entry?.kind === this.entry?.kind &&
           other.entry?.text === this.entry?.text
  }
  toDOM() {
    const box = document.createElement("div")
    box.className = "cm-lore-transclusion"
    box.dataset.target = this.target

    const title = document.createElement("div")
    title.className = "cm-lore-transclusion-title"
    title.textContent = this.target
    box.appendChild(title)

    if (!this.entry) {
      const waiting = document.createElement("div")
      waiting.className = "cm-lore-transclusion-waiting"
      waiting.textContent = "…"
      box.appendChild(waiting)
      return box
    }
    if (this.entry.kind === "error" || this.entry.kind === "missingFragment") {
      const problem = document.createElement("div")
      problem.className = "cm-lore-transclusion-problem"
      problem.textContent = this.entry.text
      box.appendChild(problem)
      return box
    }

    const body = document.createElement("div")
    body.className = "cm-lore-transclusion-body"
    box.appendChild(body)
    this.nested = new EditorView({
      state: EditorState.create({
        doc: this.entry.text,
        extensions: [
          markdown({ base: markdownLanguage }), syntaxHighlighting(highlight),
          nestedLivePreview, tablePlugin, EditorView.lineWrapping,
          EditorView.editable.of(false),
          settingsField, transclusionField, katexField,
        ],
      }),
      parent: body,
    })
    if (this.entry.kind === "truncated") {
      const notice = document.createElement("div")
      notice.className = "cm-lore-transclusion-problem"
      notice.textContent = "Content truncated."
      box.appendChild(notice)
    }
    return box
  }
  /// CM6 calls this when the widget leaves the document. Without it the nested
  /// view outlives the embed — a whole EditorView per transclusion ever drawn,
  /// still holding its DOM and its listeners.
  destroy() {
    this.nested?.destroy()
    this.nested = null
  }
  ignoreEvent() { return true }
}

/// Markdown image syntax, `![alt](path)`, which lezer DOES give us a node for —
/// but only as `Image`, so the target still has to be sliced out.
function markdownImages(state) {
  const found = []
  const doc = state.doc
  syntaxTree(state).iterate({
    enter: node => {
      if (node.name !== "Image") return
      const text = doc.sliceString(node.from, node.to)
      const match = /^!\[([^\]]*)\]\(([^)]*)\)$/.exec(text)
      if (!match) return
      // A remote image is not ours to serve: the scheme handler resolves vault
      // targets, and an `https://` target must be left to the page.
      if (/^[a-z][a-z0-9+.-]*:/i.test(match[2])) return
      found.push({ from: node.from, to: node.to, target: match[2].trim() })
    },
  })
  return found
}

function livePreviewDecorations(state, options = {}) {
  const builder = new RangeSetBuilder()
  const doc = state.doc
  // The lines the caret (or selection) touches. Their syntax stays visible.
  //
  // Inside a transclusion, NOTHING is revealed. The nested editor has a
  // selection whether or not anyone put it there — it defaults to offset 0 —
  // so an embedded note showed `## Heading` on its first line while every
  // other line rendered. There is no caret in somebody else's text, so there
  // is nothing to reveal for.
  const revealed = new Set()
  if (options.revealCaretLine !== false) {
    for (const range of state.selection.ranges) {
      const from = doc.lineAt(range.from).number
      const to = doc.lineAt(range.to).number
      for (let n = from; n <= to; n++) revealed.add(n)
    }
  }

  const hidden = []
  const lineClasses = []
  // Marks are collected separately from replacements: they may overlap a
  // replacement legally (a pill spans the backticks that are hidden inside it),
  // so they must not go through the overlap guard that protects replacements
  // from each other.
  const marks = []

  // RESERVED RANGES — the ranges this file replaces with a widget of its own.
  //
  // Every one of them also contains lezer marker nodes: `[x]` and `[!note]`
  // both look like the start of a link, so `LinkMark` covers their brackets.
  // The builder's overlap guard takes whichever decoration comes FIRST at a
  // position and drops the rest, so the bracket-hiding won and the widget was
  // silently discarded — a checked task rendered as a bare `x`, and a callout
  // header as `!note`. Found in a screenshot; nothing in the tests could see
  // it, because each construct's own scanner was working perfectly.
  //
  // So: collect the ranges first, and suppress lezer's markers inside them.
  const settings = state.field(settingsField)
  const tasks = taskLines(state)
  const callouts = calloutBlocks(state)
  const embeds = embedRanges(state)
  const tags = settings.tagsAsChips ? tagRanges(state) : []
  const reserved = embeds.slice()
  for (const t of tasks) reserved.push({ from: t.from, to: t.to })
  for (const tag of tags) reserved.push({ from: tag.from, to: tag.to })
  for (const c of callouts) {
    const line = doc.line(c.first)
    reserved.push({ from: line.from + c.header.markerStart,
                    to: line.from + c.header.markerEnd })
  }
  for (const w of wikilinkRanges(state)) reserved.push({ from: w.from, to: w.to })
  const images = markdownImages(state)
  for (const i of images) reserved.push({ from: i.from, to: i.to })
  const maths = mathRanges(state)
  for (const m of maths) reserved.push({ from: m.from, to: m.to })
  const footnotes = footnoteRanges(state)
  for (const f of footnotes) reserved.push({ from: f.from, to: f.to })
  const isReserved = (from, to) => reserved.some(r => from < r.to && to > r.from)
  const taskLineNumbers = new Set(tasks.map(t => t.line))
  syntaxTree(state).iterate({
    enter: node => {
      const line = doc.lineAt(node.from).number
      if (node.name === "HorizontalRule") {
        if (!revealed.has(line)) {
          // `block: true`, so the rule REPLACES the line rather than sitting
          // inside its text box.
          //
          // Measured before and after, ordinary line 23px:
          //     inline widget ....  70px for the rule's line
          //     block widget .....  25px
          // Three times a text line, for a 1px rule — the `hr` is a block
          // element and was being laid out inside a line box that still
          // reserved its own full line height around it. The gap between the
          // paragraphs either side was 116px against 23px for a plain
          // paragraph break.
          hidden.push({ from: node.from, to: node.to,
                        deco: Decoration.replace({ widget: new RuleWidget(),
                                                   block: true }) })
        }
        return
      }
      // The inline-code pill. A MARK, not a replace: the text stays real and
      // the backticks inside it are hidden separately, so the pill sits exactly
      // where the code is. M9.9 drew this natively and CM6 had only the
      // monospace face — a regression against the Lore that ships.
      if (node.name === "InlineCode") {
        marks.push({ from: node.from, to: node.to,
                     deco: Decoration.mark({ class: "cm-lore-inline-code" }) })
        return
      }
      // Heading rhythm. M9.4 measured this natively — space before a heading
      // scales with its size, space after is smaller — and CM6 had none, so
      // headings sat as tight as body text.
      const heading = /^ATXHeading([1-6])$/.exec(node.name)
      if (heading) {
        lineClasses.push({ from: doc.lineAt(node.from).from,
                           cls: "cm-lore-h" + heading[1] })
        return
      }
      if (node.name === "FencedCode" || node.name === "CodeBlock") {
        // A panel behind the whole fence. Marked as LINE decorations rather
        // than one range: a `Decoration.mark` over a multi-line span paints a
        // ragged staircase — the same reason the native renderer draws a panel
        // instead of using a per-glyph background.
        const first = doc.lineAt(node.from).number
        const last = doc.lineAt(node.to).number
        for (let n = first; n <= last; n++) {
          const line = doc.line(n)
          lineClasses.push({ from: line.from, cls: n === first ? "cm-lore-code-first"
                                                : n === last ? "cm-lore-code-last"
                                                : "cm-lore-code" })
        }
        return
      }
      if (node.name === "ListMark") {
        if (revealed.has(line)) return
        // A task item shows its checkbox, not a bullet AND a checkbox.
        if (taskLineNumbers.has(line)) {
          hidden.push({ from: node.from, to: node.to, deco: Decoration.replace({}) })
          return
        }
        const text = doc.sliceString(node.from, node.to)
        // Indentation before the marker is the nesting depth. Four spaces or a
        // tab per level, which is what the markdown itself uses.
        const before = doc.sliceString(doc.lineAt(node.from).from, node.from)
        const depth = Math.floor(before.replace(/\t/g, "    ").length / 4)
        hidden.push({ from: node.from, to: node.to,
                      deco: Decoration.replace({
                        widget: new BulletWidget(text, depth) }) })
        return
      }
      // A markdown link's target is notation too. Without this, `[a
      // link](https://x.test/p)` renders as `a linkhttps://x.test/p` — the
      // brackets hidden and the URL left sitting against the label, which the
      // screenshot showed and which no marker rule would ever have caught,
      // because `URL` is content as far as lezer is concerned.
      //
      // Only a PARENTHESISED target: an autolink's URL is the visible text,
      // and hiding it would leave the reader nothing at all.
      if (node.name === "URL") {
        if (revealed.has(line)) return
        if (doc.sliceString(Math.max(0, node.from - 1), node.from) !== "(") return
        hidden.push({ from: node.from, to: node.to, deco: Decoration.replace({}) })
        return
      }
      if (!MARKER_NODES.has(node.name)) return
      if (revealed.has(line)) return
      if (isReserved(node.from, node.to)) return
      hidden.push({ from: node.from, to: node.to, deco: Decoration.replace({}) })
    },
  })

  // Wikilinks go through the SAME builder as every other replacement so that
  // one overlap guard covers them all. A `[[link]]` sits inside a LinkMark run
  // as far as lezer is concerned, and two facets each replacing part of that
  // run is how CM6 is made to throw.
  for (const link of wikilinkRanges(state)) {
    if (revealed.has(doc.lineAt(link.from).number)) continue
    hidden.push({ from: link.from, to: link.to,
                  deco: Decoration.replace({
                    widget: new WikilinkWidget(link.target, link.display) }) })
  }

  // Footnotes.
  for (const note of footnotes) {
    if (revealed.has(doc.lineAt(note.from).number)) continue
    hidden.push({ from: note.from, to: note.to,
                  deco: Decoration.replace({
                    widget: note.isDefinition ? new FootnoteDefWidget(note.label)
                                              : new FootnoteRefWidget(note.label) }) })
  }

  // Maths. An expression KaTeX refuses is left as source and merely tinted —
  // `MarkdownMath`'s all-or-nothing rule, kept: half-rendering would leave the
  // reader unable to tell which parts are notation and which are content.
  for (const math of maths) {
    // No line decoration here. One was added at the block's own start position,
    // and a `Decoration.replace({block: true})` sorts BEFORE a
    // `Decoration.line` at the same position — `RangeSetBuilder` threw
    // "Ranges must be added sorted by `from` position and `startSide`" and took
    // the whole surface down. It was also unused: nothing styled that class.
    // EVERY line the expression spans, not just its first and last. A block
    // written across three lines has a middle one, and the caret sitting on it
    // left the maths rendered with no way to edit the source it was standing
    // in.
    const first = doc.lineAt(math.from).number
    const last = doc.lineAt(math.to).number
    let caretInside = false
    for (let n = first; n <= last && !caretInside; n++) {
      if (revealed.has(n)) caretInside = true
    }
    if (caretInside) continue
    if (!mathParses(math.body, math.isBlock)) continue
    hidden.push({ from: math.from, to: math.to,
                  deco: Decoration.replace({
                    widget: new MathWidget(math.body, math.isBlock),
                    block: math.isBlock }) })
  }

  // Embeds. An `![[…]]` whose target is an image or an attachment is replaced;
  // a markdown target is left as source, because rendering a note inside a note
  // is E2T1c and a half-rendered transclusion is worse than a visible `![[…]]`.
  const expandTransclusions = options.expandTransclusions !== false
  const provided = state.field(transclusionField, false) || {}
  for (const embed of embeds) {
    if (revealed.has(doc.lineAt(embed.from).number)) continue
    const target = splitWikilink(
      doc.sliceString(embed.from + 3, embed.to - 2)).target
    if (!target) continue
    const kind = embedKind(target)
    if (kind === "transclusion") {
      if (!expandTransclusions) continue
      if (!requested.has(target)) {
        requested.add(target)
        // Asked for OUTSIDE this synchronous pass: posting from inside a
        // decoration computation means a reply can arrive mid-compute and
        // dispatch a transaction into a view that is still building one.
        Promise.resolve().then(() => {
          window.webkit?.messageHandlers?.lore?.postMessage(
            { kind: "transclude", target })
        })
      }
      hidden.push({ from: embed.from, to: embed.to,
                    deco: Decoration.replace({
                      widget: new TransclusionWidget(target, provided[target]),
                      block: true }) })
      continue
    }
    hidden.push({ from: embed.from, to: embed.to,
                  deco: Decoration.replace({
                    widget: kind === "image" ? new EmbedImageWidget(target)
                                             : new EmbedChipWidget(target) }) })
  }
  for (const image of images) {
    if (revealed.has(doc.lineAt(image.from).number)) continue
    if (!image.target) continue
    hidden.push({ from: image.from, to: image.to,
                  deco: Decoration.replace({
                    widget: new EmbedImageWidget(image.target) }) })
  }

  // Callouts: a tinted panel per line, plus the header's notation replaced by
  // an icon and, when the author wrote none, the default title.
  for (const block of callouts) {
    for (let n = block.first; n <= block.last; n++) {
      const cls = ["cm-lore-callout", "cm-lore-callout-" + block.header.kind,
                   n === block.first ? "cm-lore-callout-head" : "cm-lore-callout-body",
                   n === block.last ? "cm-lore-callout-last" : ""].join(" ").trim()
      lineClasses.push({ from: doc.line(n).from, cls })
    }
    if (revealed.has(block.first)) continue
    const line = doc.line(block.first)
    hidden.push({
      from: line.from + block.header.markerStart,
      to: line.from + block.header.markerEnd,
      deco: Decoration.replace({
        widget: new CalloutMarkerWidget(block.header.kind, !block.header.title) }),
    })
  }

  // Task checkboxes, and the strike-through on a completed one. The line
  // class goes on whether or not the caret is present: a done task reads as
  // done in Obsidian even while you are editing it.
  for (const task of tasks) {
    if (task.checked) lineClasses.push({ from: doc.line(task.line).from,
                                         cls: "cm-lore-task-done" })
    if (revealed.has(task.line)) continue
    hidden.push({ from: task.from, to: task.to,
                  deco: Decoration.replace({
                    widget: new CheckboxWidget(task.checked, task.from,
                                               settings.tasksToggleable) }) })
  }

  // Tags. Replaced rather than MARKED because the chip needs its own click
  // target and its own box; a `Decoration.mark` would give the pill a ragged
  // edge wherever it wrapped.
  if (settings.tagsAsChips) {
    for (const tag of tags) {
      if (revealed.has(doc.lineAt(tag.from).number)) continue
      hidden.push({ from: tag.from, to: tag.to,
                    deco: Decoration.replace({
                      widget: new TagWidget(doc.sliceString(tag.from, tag.to),
                                            tag.name) }) })
    }
  }

  // RangeSetBuilder demands ascending order and the tree walk does not
  // guarantee it across node kinds.
  // Line decorations must be added in document order along with the rest, and
  // RangeSetBuilder takes everything at a position together — so they are
  // merged into one sorted stream rather than added in a second pass.
  for (const l of lineClasses) {
    hidden.push({ from: l.from, to: l.from, line: l.cls })
  }
  for (const m of marks) hidden.push({ from: m.from, to: m.to, mark: m.deco })
  hidden.sort((a, b) => a.from - b.from || a.to - b.to)
  let lastTo = -1
  for (const h of hidden) {
    // Overlapping replacements throw. A `CodeMark` inside a `HeaderMark`'s line
    // is legal markdown and would otherwise take the editor down.
    if (h.line) {
      builder.add(h.from, h.from, Decoration.line({ class: h.line }))
      continue
    }
    if (h.mark) {
      builder.add(h.from, h.to, h.mark)
      continue
    }
    if (h.from < lastTo) continue
    builder.add(h.from, h.to, h.deco)
    lastTo = h.to
  }
  return builder.finish()
}

const livePreview = EditorView.decorations.compute(
  ["doc", "selection", settingsField, transclusionField, katexField],
  state => livePreviewDecorations(state))

/// The same decorations, with transclusions left as source. Used INSIDE a
/// transclusion, which is what makes a cycle impossible rather than capped.
const nestedLivePreview = EditorView.decorations.compute(
  ["doc", "selection", settingsField, katexField],
  state => livePreviewDecorations(state, { expandTransclusions: false,
                                          revealCaretLine: false }))

/// Render a cell's inline markdown into `parent`.
///
/// E2T1a. The cell used to be set with `textContent`, so `**Web**` appeared
/// with its asterisks INSIDE a rendered table — visible in the first real-note
/// screenshot, and wrong in a way that reads as the table being half-rendered.
///
/// A deliberate SUBSET: bold, italic, inline code. Not a markdown parser — a
/// cell is one line of inline content, and the alternative (running CodeMirror
/// inside a widget inside CodeMirror) is not something to reach for to make
/// three delimiters work. Anything unrecognised is left as literal text, which
/// is the honest failure: the reader sees what they typed.
///
/// Nested emphasis (`**a *b* c**`) renders the outer level only. Recorded
/// rather than hidden; it is rare in a table cell and the fix is a real parser.
function renderInline(text, parent) {
  // `[[…]]` is first in the alternation so a link is never mistaken for
  // emphasis. Its own brackets contain no `*` or `_`, but a DISPLAY half may.
  const pattern = /(\[\[[^\[\]\n]+\]\]|\*\*[^*]+\*\*|__[^_]+__|\*[^*]+\*|_[^_]+_|`[^`]+`)/g
  let index = 0
  let match
  while ((match = pattern.exec(text)) !== null) {
    if (match.index > index) {
      parent.appendChild(document.createTextNode(text.slice(index, match.index)))
    }
    const token = match[0]
    let node
    if (token.startsWith("[[")) {
      const { target, display } = splitWikilink(token.slice(2, -2))
      node = wikilinkSpan(target, display)
    } else if (token.startsWith("**") || token.startsWith("__")) {
      node = document.createElement("strong")
      node.textContent = token.slice(2, -2)
    } else if (token.startsWith("`")) {
      node = document.createElement("code")
      node.textContent = token.slice(1, -1)
    } else {
      node = document.createElement("em")
      node.textContent = token.slice(1, -1)
    }
    parent.appendChild(node)
    index = pattern.lastIndex
  }
  if (index < text.length) {
    parent.appendChild(document.createTextNode(text.slice(index)))
  }
}

// S2, the question this spike exists for. A table's source range is REPLACED
// by a real <table> with contenteditable cells. Typing dispatches a change to
// the underlying document range; the grid never reverts to `| a | b |`, which
// is exactly what a painted grid cannot do.
class TableWidget extends WidgetType {
  constructor(rows, from, cellRanges) {
    super(); this.rows = rows; this.from = from; this.cellRanges = cellRanges
  }
  eq(other) {
    return other.from === this.from &&
           JSON.stringify(other.rows) === JSON.stringify(this.rows)
  }
  toDOM(view) {
    const table = document.createElement("table")
    table.className = "cm-lore-table"
    this.rows.forEach((row, r) => {
      const tr = document.createElement("tr")
      row.forEach((cell, c) => {
        const td = document.createElement(r === 0 ? "th" : "td")
        renderInline(cell, td)
        td.contentEditable = "true"
        td.dataset.r = String(r); td.dataset.c = String(c)
        // The cell's source text, so `updateDOM` can tell which cells actually
        // changed and leave the rest — and the caret — alone.
        td.dataset.raw = cell
        // `input` rather than `beforeinput`: the cell's text is read AFTER
        // the browser has applied the edit, so `textContent` is what the user
        // now sees. Reading it before would write the previous value.
        td.addEventListener("input", () => {
          // Re-derived, never the ranges captured at build time: those are
          // stale after the first keystroke, so the second character would be
          // written over the wrong span.
          const range = tableCellRangeAt(view, view.posAtDOM(table), r, c)
          if (!range) return
          const text = " " + td.textContent.trim() + " "
          td.dataset.raw = text
          view.dispatch({ changes: { from: range.from, to: range.to, insert: text } })
        })
        tr.appendChild(td)
      })
      table.appendChild(tr)
    })
    return table
  }

  /// Update the EXISTING table in place rather than letting CodeMirror replace
  /// it.
  ///
  /// This is what makes typing in a cell work at all. Without it the dispatch
  /// from the first keystroke changed the document, `eq` reported the rows
  /// different, CodeMirror destroyed the widget and built a new one — and the
  /// contentEditable cell holding the caret was thrown away with it. The
  /// symptom was exactly one character accepted and the caret jumping below the
  /// table.
  ///
  /// The cell being typed in is deliberately NOT rewritten: its DOM already
  /// shows what the reader typed, and replacing its children would destroy the
  /// caret a second time.
  updateDOM(dom, view) {
    const rows = dom.querySelectorAll("tr")
    // A different SHAPE is a different table — let CodeMirror rebuild it.
    if (rows.length !== this.rows.length) return false
    const active = document.activeElement
    for (let r = 0; r < this.rows.length; r++) {
      const cells = rows[r].children
      if (cells.length !== this.rows[r].length) return false
      for (let c = 0; c < this.rows[r].length; c++) {
        const cell = cells[c]
        const want = this.rows[r][c]
        if (cell === active) { cell.dataset.raw = want; continue }
        if (cell.dataset.raw === want) continue
        cell.dataset.raw = want
        cell.replaceChildren()
        renderInline(want, cell)
      }
    }
    return true
  }

  ignoreEvent() { return true }
}

/// A cell's range in the CURRENT document, re-derived from the table's live
/// position.
///
/// The ranges captured when a widget is built are stale the moment anything
/// before the table changes — including the previous keystroke in the same
/// cell. `posAtDOM` gives the replaced range's current start, and the rows are
/// re-read from there, so every keystroke computes against the document as it
/// is now.
///
/// The delimiter line is skipped when the widget's rows are built, so row 0 is
/// the header and row r > 0 is r + 1 lines below it.
function tableCellRangeAt(view, tableStart, r, c) {
  const doc = view.state.doc
  const first = doc.lineAt(tableStart).number
  const lineNumber = first + (r === 0 ? 0 : r + 1)
  if (lineNumber < 1 || lineNumber > doc.lines) return null
  return parsePipeRow(doc.line(lineNumber)).ranges[c] || null
}

function parsePipeRow(line) {
  const cells = [], ranges = []
  let start = null, buf = ""
  for (let i = 0; i < line.text.length; i++) {
    const ch = line.text[i]
    if (ch === "|" && (i === 0 || line.text[i - 1] !== "\\")) {
      if (start !== null) {
        cells.push(buf.trim())
        ranges.push({ from: line.from + start, to: line.from + i })
      }
      start = i + 1; buf = ""
    } else if (start !== null) { buf += ch }
  }
  return { cells, ranges }
}

const isDelimiterLine = text =>
  /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/.test(text)

function buildDecorations(state) {
  const builder = new RangeSetBuilder()
  const doc = state.doc
  let line = 1
  while (line <= doc.lines) {
    const l = doc.line(line)
    if (l.text.includes("|") && line + 1 <= doc.lines &&
        isDelimiterLine(doc.line(line + 1).text)) {
      let last = line + 1
      while (last + 1 <= doc.lines && doc.line(last + 1).text.includes("|")) last++
      const rows = [], cellRanges = []
      for (let r = line; r <= last; r++) {
        if (r === line + 1) continue
        const parsed = parsePipeRow(doc.line(r))
        rows.push(parsed.cells); cellRanges.push(parsed.ranges)
      }
      if (rows.length) {
        builder.add(l.from, doc.line(last).to, Decoration.replace({
          widget: new TableWidget(rows, l.from, cellRanges), block: true,
        }))
        line = last + 1
        continue
      }
    }
    line++
  }
  return builder.finish()
}

const tablePlugin = EditorView.decorations.compute(["doc", "selection"],
                                                   state => buildDecorations(state))

// ------------------------------------------------------ hover preview
//
// A pointer RESTING over a link means "show me what is in there". Rendered in
// the page, for the same two reasons the completion list is: a popover that
// follows the pointer cannot afford a round trip for its position, and it must
// dismiss on the pointer leaving — which is a DOM event, here.
//
// The rules are the native editor's (`MarkdownEditorHover`), including the one
// that makes it feel considered rather than twitchy: 450ms of STILLNESS, not of
// presence. Movement within a single link restarts the wait, so crossing a link
// on the way somewhere else shows nothing — otherwise a document full of links
// becomes a flicker.

const HOVER_DELAY_MS = 450

let hoverTarget = null
let hoverTimer = null
let hoverElement = null
let previewDOM = null

function hidePreview() {
  if (previewDOM) { previewDOM.remove(); previewDOM = null }
}

function cancelHover() {
  if (hoverTimer) { clearTimeout(hoverTimer); hoverTimer = null }
  hoverTarget = null
  hoverElement = null
  hidePreview()
}

/// Every pointer move inside the editor.
function hoverMoved(event) {
  const element = event.target?.closest?.(
    ".cm-lore-wikilink, .cm-lore-embed-chip, .cm-lore-embed-missing")
  if (!element) {
    if (hoverTarget) cancelHover()
    return
  }
  const target = element.dataset.target
  if (!target) return
  // A DIFFERENT link: drop whatever was showing before waiting again.
  if (target !== hoverTarget) hidePreview()
  hoverTarget = target
  hoverElement = element
  // Movement restarts the wait even within the same link — the delay measures
  // stillness, not presence. That is the whole difference between a considered
  // preview and a twitchy one.
  if (hoverTimer) clearTimeout(hoverTimer)
  hoverTimer = setTimeout(() => {
    hoverTimer = null
    window.webkit?.messageHandlers?.lore?.postMessage(
      { kind: "preview", target })
  }, HOVER_DELAY_MS)
}

/// Draw the popover under the hovered link.
function renderPreview(view, title, excerpt) {
  if (!hoverElement || !hoverElement.isConnected) return
  hidePreview()
  previewDOM = document.createElement("div")
  previewDOM.className = "cm-lore-preview"
  previewDOM.dataset.target = hoverTarget || ""
  const heading = document.createElement("div")
  heading.className = "cm-lore-preview-title"
  heading.textContent = title
  previewDOM.appendChild(heading)
  if (excerpt) {
    const body = document.createElement("div")
    body.className = "cm-lore-preview-body"
    body.textContent = excerpt
    previewDOM.appendChild(body)
  }
  view.dom.appendChild(previewDOM)

  const link = hoverElement.getBoundingClientRect()
  const editor = view.dom.getBoundingClientRect()
  previewDOM.style.left = Math.round(link.left - editor.left) + "px"
  previewDOM.style.top = Math.round(link.bottom - editor.top + 6) + "px"
  const box = previewDOM.getBoundingClientRect()
  if (link.bottom + box.height > editor.bottom) {
    previewDOM.style.top = Math.round(link.top - editor.top - box.height - 6) + "px"
  }
  if (box.right > editor.right) {
    previewDOM.style.left =
      Math.round(Math.max(0, editor.width - box.width - 8)) + "px"
  }
}

// -------------------------------------------------------- completion
//
// The `[[` and `#` popup, rendered IN THE PAGE.
//
// The design doc recommended a native popup, reusing `LinkCompletionPanel`.
// Overridden with the owner's word, for two reasons that are properties of the
// arrangement rather than preferences:
//
//  1. A native panel has to be anchored in SCREEN coordinates reported from
//     this page, per keystroke. Any lag and the popup points at where the caret
//     used to be — and there is no way to make that lag zero across a process
//     boundary.
//  2. Arrow keys, Return and Escape belong to whoever has focus, and that is
//     the web view. Routing them out to Swift and back means every one of them
//     is a round trip, and a dropped one leaves the reader typing into a list
//     that is not listening.
//
// Rendered here, both problems are absent by construction: CodeMirror already
// knows where the caret is and already owns the keys.
//
// What did NOT move to JavaScript is the part that matters: Swift decides what
// is being completed, which rows to offer and what each row inserts. This side
// draws a list and reports which row was chosen.

/// `{ from, to, items, index }`, or null when nothing is being completed.
let completion = null
let completionDOM = null

function completionVisible() { return !!completion && completion.items.length > 0 }

/// Ask Swift what the caret is completing. Debounced to a microtask so a burst
/// of transactions (a keystroke is often several) asks once.
let completionAsked = false
function askForCompletions(view) {
  if (completionAsked) return
  completionAsked = true
  Promise.resolve().then(() => {
    completionAsked = false
    if (!view.state.selection.main.empty) { hideCompletions(); return }
    window.webkit?.messageHandlers?.lore?.postMessage(
      { kind: "completion", caret: view.state.selection.main.head })
  })
}

function hideCompletions() {
  completion = null
  if (completionDOM) { completionDOM.remove(); completionDOM = null }
}

/// Draw (or redraw) the list under the caret.
function renderCompletions(view) {
  if (!completionVisible()) { hideCompletions(); return }
  if (!completionDOM) {
    completionDOM = document.createElement("div")
    completionDOM.className = "cm-lore-completion"
    view.dom.appendChild(completionDOM)
  }
  completionDOM.replaceChildren()
  completion.items.forEach((item, i) => {
    const row = document.createElement("div")
    row.className = "cm-lore-completion-row" + (i === completion.index ? " is-selected" : "")
    const label = document.createElement("span")
    label.className = "cm-lore-completion-label"
    label.textContent = item.label
    row.appendChild(label)
    if (item.detail) {
      const detail = document.createElement("span")
      detail.className = "cm-lore-completion-detail"
      detail.textContent = item.detail
      row.appendChild(detail)
    }
    // `mousedown`, not `click`: a click moves the caret first, which changes
    // the query and destroys the list mid-gesture.
    row.addEventListener("mousedown", event => {
      event.preventDefault()
      event.stopPropagation()
      completion.index = i
      acceptCompletion(view)
    })
    completionDOM.appendChild(row)
  })

  // Anchored to the START of the replaced range, which is where the reader is
  // looking — not to the caret, which drifts right as they type.
  const coords = view.coordsAtPos(Math.min(completion.from, view.state.doc.length))
  const editor = view.dom.getBoundingClientRect()
  if (!coords) { hideCompletions(); return }
  completionDOM.style.left = Math.round(coords.left - editor.left) + "px"
  completionDOM.style.top = Math.round(coords.bottom - editor.top + 4) + "px"
  // Keep it on screen: flip above the line when there is no room below.
  const box = completionDOM.getBoundingClientRect()
  if (coords.bottom + box.height > editor.bottom) {
    completionDOM.style.top =
      Math.round(coords.top - editor.top - box.height - 4) + "px"
  }
}

function moveCompletion(view, delta) {
  if (!completionVisible()) return false
  const count = completion.items.length
  completion.index = (completion.index + delta + count) % count
  renderCompletions(view)
  return true
}

function acceptCompletion(view) {
  if (!completionVisible()) return false
  const item = completion.items[completion.index]
  const { from, to } = completion
  if (item.create) {
    // The note is made in SWIFT first: a refused create must leave the document
    // untouched rather than write a link to a note that was never made. Swift
    // calls `applyCompletion` back if and only if it succeeded.
    window.webkit?.messageHandlers?.lore?.postMessage(
      { kind: "completionCreate", name: item.create,
        from, to, insert: item.insert })
    hideCompletions()
    return true
  }
  applyCompletionRange(view, from, to, item.insert)
  hideCompletions()
  return true
}

function applyCompletionRange(view, from, to, insert) {
  const end = Math.min(to, view.state.doc.length)
  view.dispatch({
    changes: { from, to: end, insert },
    selection: { anchor: from + insert.length },
  })
}

/// The keys the list owns while it is open, and nobody else's.
///
/// `Prec.highest` so these beat the default keymap — otherwise Return inserts a
/// newline and the list is left open under a caret that has moved.
const completionKeymap = Prec.highest(keymap.of([
  { key: "ArrowDown", run: view => moveCompletion(view, 1) },
  { key: "ArrowUp", run: view => moveCompletion(view, -1) },
  { key: "Enter", run: view => acceptCompletion(view) },
  { key: "Tab", run: view => acceptCompletion(view) },
  { key: "Escape", run: () => {
      if (!completionVisible()) return false
      hideCompletions()
      return true
    } },
]))

let view = null

// Is a change arriving FROM Swift right now?
//
// The edit loop this guards is the classic one: Swift pushes a document, CM6
// reports it as a change, Swift treats that as user input and pushes again.
// Under a fast typist the two chase each other and keystrokes are dropped —
// silently, and only under load, which is the worst way to find out. So a
// change Swift asked for is never reported back to Swift.
let applyingFromSwift = false

window.loreEditor = {
  init(text) {
    const state = EditorState.create({
      doc: text,
      extensions: [
        history(), drawSelection(), rectangularSelection(),
        // `highlightActiveLine()` is deliberately ABSENT. It paints a
        // full-width grey band behind the caret's line, which Obsidian does
        // not do and which the first wikilink screenshot showed as the loudest
        // thing on the page — a bar wider than the text measure, drawn under
        // the one line the reader is already looking at.

        search(), highlightSelectionMatches(),
        keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap]),
        settingsField, transclusionField,
        // GFM, not bare CommonMark.
        //
        // `markdown()` defaults to CommonMark, which has NO strikethrough node
        // — so `StrikethroughMark` sat in MARKER_NODES matching nothing, and
        // `~~struck~~` rendered with its tildes on screen and no line through
        // it. The native editor strikes it, so this was a regression against
        // the Lore that ships, found by the E4T2 parity shots.
        //
        // GFM also brings tables, task markers and autolinks. The tables and
        // tasks here are hand-rolled and scan lines independently, and neither
        // of their node types is hidden as a marker, so the new nodes are
        // inert rather than conflicting.
        markdown({ base: markdownLanguage }), syntaxHighlighting(highlight),
        livePreview, tablePlugin, EditorView.lineWrapping,
        // CM6 turns the browser's own spellchecking OFF by default. On macOS
        // that also means NSSpellChecker never inspects the text, so a
        // misspelling is never underlined — S7b measured `spellcheck=false`.
        // Opting back in is what hands the surface to the system.
        EditorView.contentAttributes.of({ spellcheck: "true",
                                          autocorrect: "on",
                                          autocapitalize: "off" }),
        katexField, completionKeymap,
        // Hover, and everything that ends a hover. `mouseleave` on the editor
        // itself rather than on each link: the widgets are rebuilt on every
        // decoration pass, so per-element listeners would be attached and lost
        // constantly.
        EditorView.domEventHandlers({
          mousemove: hoverMoved,
          mouseleave: () => { cancelHover(); return false },
          // A keystroke means the reader is writing, not reading.
          keydown: () => { cancelHover(); return false },
          scroll: () => { cancelHover(); return false },
        }),
        // Ask Swift what the caret is completing, whenever it could have
        // changed. Swift answers with rows or with nothing.
        EditorView.updateListener.of(u => {
          if (u.docChanged) cancelHover()
          if (applyingFromSwift) return
          if (u.docChanged || u.selectionSet) askForCompletions(u.view)
        }),
        // Load KaTeX the first time a document that could contain maths is
        // seen. The gate is `includes("$")` rather than a real scan: the scan
        // walks the whole document, and this runs on every update.
        EditorView.updateListener.of(u => {
          if (katex || katexLoading) return
          if (u.state.doc.toString().includes("$")) loadKatex(u.view)
        }),
        EditorView.updateListener.of(u => {
          if (!u.docChanged || applyingFromSwift) return
          window.webkit?.messageHandlers?.lore?.postMessage(
            { kind: "doc", text: u.state.doc.toString() })
        }),
      ],
    })
    view = new EditorView({ state, parent: document.getElementById("root") })
    return view.state.doc.length
  },
  text() { return view.state.doc.toString() },

  /// Test hooks. `insertAtEnd` is what a keystroke amounts to, and
  /// `__setDocumentCalls` counts pushes that actually reached the editor —
  /// which is how the "Swift must not echo" rule is asserted rather than
  /// assumed.
  /// Put the caret at an offset — how a test says "the reader clicked here".
  selectAt(offset) {
    if (offset < 0) return false
    view.dispatch({ selection: { anchor: Math.min(offset, view.state.doc.length) } })
    return true
  },
  insertAtEnd(ch) {
    view.dispatch({ changes: { from: view.state.doc.length, insert: ch } })
    return view.state.doc.length
  },
  __setDocumentCalls: 0,

  /// Replace the whole document because SWIFT says so — a note being opened,
  /// or an external change on disk.
  ///
  /// Returns false and does nothing when the text already matches, so an
  /// echo costs no transaction and, more importantly, cannot move the caret.
  setDocument(text) {
    if (!view) return false
    if (view.state.doc.toString() === text) return false
    window.loreEditor.__setDocumentCalls++
    applyingFromSwift = true
    try {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
        // The caret is clamped rather than preserved at its offset: the new
        // document is a DIFFERENT document, so an offset from the old one
        // means nothing in it.
        selection: { anchor: Math.min(view.state.selection.main.anchor, text.length) },
      })
    } finally {
      applyingFromSwift = false
    }
    return true
  },

  /// Swift's answer to a `preview` request.
  ///
  /// Ignored when the pointer has moved on — the read happens off the main
  /// actor and can land after the reader has left the link, and presenting then
  /// would show a preview for a link nobody is pointing at. The native path
  /// guards the same case for the same reason.
  showPreview(target, title, excerpt) {
    if (!view) return false
    if (target !== hoverTarget) return false
    renderPreview(view, title, excerpt)
    return true
  },
  previewTitle() {
    const node = document.querySelector(".cm-lore-preview-title")
    return node ? node.textContent : null
  },
  previewBody() {
    const node = document.querySelector(".cm-lore-preview-body")
    return node ? node.textContent : null
  },
  previewIsOpen() { return !!document.querySelector(".cm-lore-preview") },
  /// Test hooks: the pointer, without a pointer. `hoverAt` names a link by its
  /// index among the rendered links, and `hoverAway` is the pointer leaving.
  hoverAt(index) {
    const links = document.querySelectorAll(
      ".cm-lore-wikilink, .cm-lore-embed-chip, .cm-lore-embed-missing")
    const element = links[index || 0]
    if (!element) return false
    hoverMoved({ target: element })
    return true
  },
  hoverAway() { cancelHover(); return true },
  hoverPendingTarget() { return hoverTarget },
  /// Fire the pending stillness timer now, rather than waiting 450ms in a test.
  flushHover() {
    if (!hoverTimer) return false
    clearTimeout(hoverTimer)
    hoverTimer = null
    window.webkit?.messageHandlers?.lore?.postMessage(
      { kind: "preview", target: hoverTarget })
    return true
  },

  /// Swift's answer to a `completion` request: `{from, to, items}` or null.
  showCompletions(payload) {
    if (!view) return false
    if (!payload || !payload.items || !payload.items.length) {
      hideCompletions()
      return false
    }
    completion = { from: payload.from, to: payload.to, items: payload.items, index: 0 }
    renderCompletions(view)
    return true
  },
  /// Swift's answer to `completionCreate`, once the note exists.
  applyCompletion(from, to, insert) {
    if (!view) return false
    applyCompletionRange(view, from, to, insert)
    return true
  },

  /// Test hooks.
  completionLabels() {
    return Array.from(document.querySelectorAll(".cm-lore-completion-label"))
                .map(n => n.textContent)
  },
  completionSelectedIndex() {
    const rows = Array.from(document.querySelectorAll(".cm-lore-completion-row"))
    return rows.findIndex(r => r.classList.contains("is-selected"))
  },
  completionIsOpen() { return completionVisible() },
  /// Drive the list by the keys a reader would use, through CodeMirror's own
  /// keymap rather than by calling the commands directly — which is what
  /// asserts that `Prec.highest` actually beat the default keymap.
  completionKey(key) {
    const handlers = {
      ArrowDown: v => moveCompletion(v, 1),
      ArrowUp: v => moveCompletion(v, -1),
      Enter: v => acceptCompletion(v),
      Escape: () => { if (!completionVisible()) return false; hideCompletions(); return true },
    }
    return handlers[key] ? !!handlers[key](view) : false
  },

  /// Round-trip every line through the geometry: for each line start, the
  /// coordinates CodeMirror DRAWS it at, mapped back to a position.
  ///
  /// Returns the line numbers where the two disagree. Non-empty means a click
  /// lands on a different line than the one under the pointer — which is what
  /// `margin` on a `.cm-line` caused: CodeMirror's height oracle does not
  /// account for margins, and adjacent margins collapse, so the error
  /// accumulates down the document.
  geometryMismatchedLines() {
    const bad = []
    const box = pos => {
      const c = view.coordsAtPos(pos)
      return c ? Math.round(c.top) + ":" + Math.round(c.bottom) : null
    }
    for (let n = 1; n <= view.state.doc.lines; n++) {
      const line = view.state.doc.line(n)
      const coords = view.coordsAtPos(line.from)
      if (!coords) continue
      // The vertical MIDDLE of the drawn line, a little inside its left edge —
      // where a click on that line would actually land.
      const back = view.posAtCoords({ x: coords.left + 2,
                                      y: (coords.top + coords.bottom) / 2 })
      if (back === null) continue
      const landed = view.state.doc.lineAt(back).number
      if (landed === n) continue
      // A block widget REPLACES several lines with one element — a table, a
      // multi-line maths block, a transclusion. The interior lines have no
      // drawn position of their own, so mapping one of them to the widget's
      // first line is correct, not a mis-aimed click. They are told apart by
      // being drawn in the SAME box: a genuine geometry error moves the click
      // to a line drawn somewhere else.
      if (box(line.from) !== null && box(line.from) === box(view.state.doc.line(landed).from)) {
        continue
      }
      bad.push(n)
    }
    return bad
  },
  /// A real selection, so the drawn selection layer exists to be measured.
  selectRangeForTesting(from, to) {
    if (!view) return false
    view.focus()
    view.dispatch({ selection: { anchor: from, head: Math.min(to, view.state.doc.length) } })
    return true
  },
  /// The computed colour of the caret CodeMirror draws, and of the background
  /// behind it — so "the caret is invisible" is a measurement, not an opinion.
  caretAndBackgroundColours() {
    const cursor = document.querySelector(".cm-cursor")
    const content = document.querySelector(".cm-content")
    if (!cursor || !content) return null
    return JSON.stringify({
      caret: getComputedStyle(cursor).borderLeftColor,
      background: getComputedStyle(document.body).backgroundColor,
    })
  },

  lines() { return view.state.doc.lines },

  /// `EditorSettings.renderTagsAsChips`. Redraws, because a setting that
  /// only takes effect on the next document is a setting that looks broken.
  setTagsAsChips(on) {
    if (!view) return false
    view.dispatch({ effects: settingsEffect.of({ tagsAsChips: !!on }) })
    return view.state.field(settingsField).tagsAsChips
  },
  /// `EditorContext.isReadOnly`, inverted, pushed from Swift.
  setTasksToggleable(on) {
    if (!view) return false
    view.dispatch({ effects: settingsEffect.of({ tasksToggleable: !!on }) })
    return view.state.field(settingsField).tasksToggleable
  },
  checkboxStates() {
    return Array.from(document.querySelectorAll(".cm-lore-checkbox"))
                .map(n => n.checked)
  },
  checkboxDisabled() {
    return Array.from(document.querySelectorAll(".cm-lore-checkbox"))
                .map(n => n.disabled)
  },
  clickCheckbox(index) {
    const node = document.querySelectorAll(".cm-lore-checkbox")[index || 0]
    if (!node) return false
    node.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }))
    return true
  },
  doneLineCount() { return document.querySelectorAll(".cm-lore-task-done").length },
  calloutKinds() {
    return Array.from(document.querySelectorAll(".cm-lore-callout-head"))
                .map(n => (/cm-lore-callout-([a-z]+)/.exec(
                  Array.from(n.classList).find(c =>
                    c.startsWith("cm-lore-callout-") &&
                    !["cm-lore-callout-head", "cm-lore-callout-body",
                      "cm-lore-callout-last"].includes(c)) || "") || [])[1])
  },
  calloutTitles() {
    return Array.from(document.querySelectorAll(".cm-lore-callout-head"))
                .map(n => n.innerText.trim())
  },
  calloutLineCount() { return document.querySelectorAll(".cm-lore-callout").length },
  embedImageSources() {
    return Array.from(document.querySelectorAll(".cm-lore-embed-image"))
                .map(n => n.getAttribute("src"))
  },
  embedImageTargets() {
    return Array.from(document.querySelectorAll(".cm-lore-embed-image"))
                .map(n => n.dataset.target)
  },
  /// Whether each image actually DECODED. `naturalWidth` is 0 for an image
  /// that failed to load, which is the only way to tell a served asset from a
  /// broken one — an `<img>` with a bad src still exists in the DOM.
  embedImageWidths() {
    return Array.from(document.querySelectorAll(".cm-lore-embed-image"))
                .map(n => n.naturalWidth)
  },
  /// Swift's answer to a `transclude` request.
  provideTransclusion(target, kind, text) {
    if (!view) return false
    view.dispatch({ effects: transclusionEffect.of({ target, kind, text }) })
    return true
  },
  transclusionTargets() {
    return Array.from(document.querySelectorAll(".cm-lore-transclusion"))
                .map(n => n.dataset.target)
  },
  transclusionText(index) {
    const box = document.querySelectorAll(".cm-lore-transclusion")[index || 0]
    return box ? box.innerText : null
  },
  transclusionRequests() { return Array.from(requested) },
  /// Whether KaTeX has been fetched. The POINT of the split bundle is that
  /// this stays false for a note with no mathematics in it.
  mathEngineLoaded() { return !!katex },
  mathCount() { return document.querySelectorAll(".cm-lore-math, .cm-lore-math-block").length },
  mathBlockCount() { return document.querySelectorAll(".cm-lore-math-block").length },
  mathSources() {
    return Array.from(document.querySelectorAll(".cm-lore-math, .cm-lore-math-block"))
                .map(n => n.dataset.tex)
  },
  /// Whether KaTeX produced real markup rather than its error rendering. The
  /// `.katex-error` class is what an unparseable expression becomes, and it must
  /// never appear on this surface.
  mathErrorCount() { return document.querySelectorAll(".katex-error").length },
  mathRendersTo(index) {
    const node = document.querySelectorAll(".cm-lore-math, .cm-lore-math-block")[index || 0]
    return node ? node.innerHTML.includes("katex") : null
  },
  /// Test hook: forget what has been asked for, so one test's requests cannot
  /// decide another's assertions.
  __resetTransclusionRequests() { requested.clear(); return true },
  embedMissingTargets() {
    return Array.from(document.querySelectorAll(".cm-lore-embed-missing"))
                .map(n => n.dataset.target)
  },
  embedChipTargets() {
    return Array.from(document.querySelectorAll(".cm-lore-embed-chip"))
                .map(n => n.dataset.target)
  },
  tagNames() {
    return Array.from(document.querySelectorAll(".cm-lore-tag"))
                .map(n => n.dataset.tag)
  },
  tagTexts() {
    return Array.from(document.querySelectorAll(".cm-lore-tag"))
                .map(n => n.textContent)
  },
  clickTag(index) {
    const node = document.querySelectorAll(".cm-lore-tag")[index || 0]
    if (!node) return false
    node.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }))
    return true
  },

  /// E2T1b hooks. `wikilinkTargets` is what a test asserts the RENDERING
  /// against; `clickWikilink` is what asserts the bridge message, because a
  /// link that renders and does not open is the more likely of the two bugs.
  wikilinkTexts() {
    return Array.from(document.querySelectorAll(".cm-lore-wikilink"))
                .map(n => n.textContent)
  },
  wikilinkTargets() {
    return Array.from(document.querySelectorAll(".cm-lore-wikilink"))
                .map(n => n.dataset.target)
  },
  clickWikilink(index, meta) {
    const nodes = document.querySelectorAll(".cm-lore-wikilink")
    const node = nodes[index || 0]
    if (!node) return false
    node.dispatchEvent(new MouseEvent("mousedown",
                                      { bubbles: true, metaKey: !!meta }))
    return true
  },
  tableCount() { return document.querySelectorAll(".cm-lore-table").length },
  focusFirstCell() {
    const cell = document.querySelector(".cm-lore-table td")
    if (!cell) return false
    cell.focus()
    return document.activeElement === cell
  },
  typeInFirstCell(s) {
    const cell = document.querySelector(".cm-lore-table td")
    if (!cell) return false
    cell.textContent = s
    cell.dispatchEvent(new Event("input", { bubbles: true }))
    return true
  },
  // S4: one character at a time, timed end to end — the same shape as the
  // native MarkdownTypingLagBenchmark.
  openFind() { openSearchPanel(view); return true },
  countMatches(needle) {
    const doc = view.state.doc.toString()
    let n = 0, i = 0
    while ((i = doc.indexOf(needle, i)) !== -1) { n++; i += needle.length }
    return n
  },
  focusEnd() {
    view.focus()
    view.dispatch({ selection: { anchor: view.state.doc.length } })
    return true
  },
  benchTyping(n) {
    const pos = Math.floor(view.state.doc.length / 2)
    const t0 = performance.now()
    for (let i = 0; i < n; i++) view.dispatch({ changes: { from: pos + i, insert: "x" } })
    return (performance.now() - t0) / n
  },
}
