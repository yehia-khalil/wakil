import Foundation
import WakilKit
import WebKit

/// The agent's page script (3c-ii): Wakil's own JavaScript, in its own content world.
///
/// **`wakil.agent` is a world of its own**, so the page's script can neither see, call nor spoof
/// it — nor reach the refs it keeps — as the find script's `wakil.find` is (`BrowserTabHost`). It is
/// added to every tab's configuration at document end, main frame only (`userScript`), and every call
/// also carries it (`body`), so a page whose script has not run yet gets it on first use.
///
/// **No agent string is ever in its source** (plan ruling 18). The source is constant; what the
/// agent sent — a ref, the text to type, an option, a key — reaches it only as
/// `callAsyncJavaScript` arguments, which WebKit passes as values, never as code.
///
/// What it does, per the plan's rulings 7, 15, 17 and 18 and the rulings carried from Tasks 4 and 7:
/// - `read(firstRef)`: the main frame's visible elements in document order, open shadow roots
///   walked, frames counted not read; each given `e<n>` from `firstRef` up, kept as a `WeakRef`, the
///   map replaced on each read. **A `firstRef` not above the refs this document already issued is
///   refused as stale**, so the script's map and the store's read can never name one ref twice.
/// - A label is `aria-label`, else `aria-labelledby`'s text, else its `<label>`, else `placeholder`,
///   `title`, `name`, its text, a button's value — whitespace collapsed — **with `aria-label` and
///   `title` folded in** when the label came from elsewhere, so the never-list sees them.
/// - A never-list field's value never leaves the page (`wakilYours`, generated from
///   `BrowserFieldRules`), nor its own text through the page's text.
/// - `describe(ref)`: the live element, as a read describes it.
/// - `act(spec)`: refuses a gone element (`stale`), one whose type, autocomplete, name or id is
///   not the read's (`expect`), and — for type, select and press — **a field that is the operator's
///   now (the never-list again, on the live element)**. A press never changes a field's value: it
///   focuses the element and sends the key's events; Return submits the form of a text input.
/// - A `failed` reason is Wakil's own fixed sentence, never page text.
enum BrowserAgentScript {
    @MainActor static let world = WKContentWorld.world(name: "wakil.agent")

    /// Added to each tab's configuration: the script installs itself as each main-frame document ends.
    @MainActor static func userScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    }

    /// A call's body: the script (installed once per document; a no-op when already there), then
    /// `call`, a fixed expression over the call's arguments, answered as JSON text.
    static func body(_ call: String) -> String {
        source + "\nreturn JSON.stringify(await (\(call)));"
    }

    /// The fixed sentences a failed act answers with. Wakil's words only: never the page's.
    static let yoursNowReason = "that field is the operator's to fill now (a password, card or one-time-code "
        + "field) — the agent never types into it (Invariant 6)."

    static let source: String = #"""
        globalThis.wakil ??= (() => {
          'use strict';
          \#(BrowserFieldRules.scriptSource)
          const SELECTOR = 'a[href], button, input, select, textarea, summary, [contenteditable=""], '
            + '[contenteditable="true"], [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], '
            + '[role=option], [role=menuitem]';
          const YOURS_NOW = \#(jsString(yoursNowReason));
          const KEYS = {
            Return: ['Enter', 'Enter', 13], Tab: ['Tab', 'Tab', 9], Escape: ['Escape', 'Escape', 27],
            ArrowUp: ['ArrowUp', 'ArrowUp', 38], ArrowDown: ['ArrowDown', 'ArrowDown', 40],
            ArrowLeft: ['ArrowLeft', 'ArrowLeft', 37], ArrowRight: ['ArrowRight', 'ArrowRight', 39],
          };
          const TEXT_TYPES = new Set(['', 'text', 'search', 'email', 'url', 'tel', 'number', 'password', 'date',
            'datetime-local', 'month', 'week', 'time']);
          const BUTTON_TYPES = new Set(['submit', 'button', 'reset', 'image']);
          let refs = new Map();
          let issued = 0;

          const collapse = s => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();

          function visible(el) {
            if (typeof el.checkVisibility === 'function') {
              if (!el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
            } else {
              const style = getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden') return false;
            }
            return el.getClientRects().length > 0;
          }

          function collect(root, out, frames) {
            for (const el of root.querySelectorAll('*')) {
              const tag = el.tagName;
              if (tag === 'IFRAME' || tag === 'FRAME') frames.count += 1;
              if (el.matches(SELECTOR) && !(tag === 'INPUT' && String(el.type).toLowerCase() === 'hidden')
                  && visible(el)) out.push(el);
              if (el.shadowRoot) collect(el.shadowRoot, out, frames);
            }
          }

          function roleOf(el) {
            const tag = el.tagName;
            if (tag === 'INPUT') {
              const type = String(el.type || '').toLowerCase();
              if (type === 'checkbox') return 'checkbox';
              if (type === 'radio') return 'radio';
              if (BUTTON_TYPES.has(type)) return 'button';
              return TEXT_TYPES.has(type) ? 'textbox' : 'other';
            }
            if (tag === 'TEXTAREA') return 'textarea';
            if (tag === 'SELECT') return 'select';
            if (tag === 'BUTTON' || tag === 'SUMMARY') return 'button';
            if (tag === 'A') return 'link';
            if (el.isContentEditable) return 'textbox';
            const role = collapse(el.getAttribute('role')).toLowerCase();
            if (role === 'button' || role === 'link' || role === 'checkbox' || role === 'radio') return role;
            return 'other';
          }

          const isField = el => el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT'
            || el.isContentEditable;

          function labelOf(el, role) {
            const aria = collapse(el.getAttribute('aria-label'));
            let labelledBy = '';
            const ids = collapse(el.getAttribute('aria-labelledby'));
            if (ids) {
              const root = el.getRootNode();
              labelledBy = collapse(ids.split(' ').map(id => {
                const node = (root.getElementById && root.getElementById(id)) || document.getElementById(id);
                return node ? node.textContent : '';
              }).join(' '));
            }
            const labels = el.labels ? collapse(Array.from(el.labels).map(l => l.textContent).join(' ')) : '';
            const placeholder = collapse(el.getAttribute('placeholder'));
            const title = collapse(el.getAttribute('title'));
            const name = collapse(el.getAttribute('name'));
            const text = isField(el) ? '' : collapse(el.innerText != null ? el.innerText : el.textContent);
            const value = el.tagName === 'INPUT' && role === 'button' ? collapse(el.value) : '';
            const label = [aria, labelledBy, labels, placeholder, title, name, text, value].find(s => s) || '';
            // aria-label and title are folded in where the label came from elsewhere: a field the
            // operator fills may say so only there, and the never-list must see it.
            const folded = [aria, title].filter(s => s && !label.toLowerCase().includes(s.toLowerCase()));
            return [label, ...folded].join(' · ');
          }

          function valueOf(el, role) {
            if (role === 'checkbox' || role === 'radio') {
              const checked = el.tagName === 'INPUT' ? el.checked : el.getAttribute('aria-checked') === 'true';
              return checked ? 'checked' : 'unchecked';
            }
            if (el.tagName === 'SELECT') {
              const option = el.options[el.selectedIndex];
              return option ? collapse(option.text) : '';
            }
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return String(el.value);
            if (el.isContentEditable) return String(el.innerText);
            return undefined;
          }

          function describeElement(el, ref) {
            const role = roleOf(el);
            const typed = el.tagName === 'INPUT' || el.tagName === 'BUTTON' || el.tagName === 'SELECT';
            const e = {
              ref, role, label: labelOf(el, role),
              type: typed ? String(el.type || '') : '',
              autocomplete: String(el.getAttribute('autocomplete') || ''),
              name: String(el.getAttribute('name') || ''), id: String(el.id || ''),
              placeholder: String(el.getAttribute('placeholder') || ''),
            };
            // The operator's field keeps its value in the page.
            if (wakilYours(e) === null) {
              const value = valueOf(el, role);
              if (value !== undefined) e.value = value;
            }
            if (el.tagName === 'SELECT') e.options = Array.from(el.options).map(o => collapse(o.text));
            if (el.tagName === 'A' && el.href) e.href = String(el.href);
            return e;
          }

          function live(ref) {
            const held = refs.get(String(ref));
            const el = held && held.deref();
            return el && el.isConnected ? el : null;
          }

          const SILENT = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'IFRAME', 'FRAME', 'OBJECT']);
          const INLINE = new Set(['inline', 'inline-block', 'inline-flex', 'inline-grid', 'contents', 'ruby']);

          // What the page shows as text, as innerText reads it in outline: the rendered text nodes in
          // document order, a line break around each block and at each <br>, and no text from an
          // element in `skip` (or anything under it).
          function pageText(skip) {
            const parts = [];
            function walk(node, shown) {
              for (const child of node.childNodes) {
                if (child.nodeType === Node.TEXT_NODE) { if (shown) parts.push(child.data); continue; }
                if (child.nodeType !== Node.ELEMENT_NODE || skip.has(child) || SILENT.has(child.tagName)) continue;
                if (child.tagName === 'BR') { parts.push('\n'); continue; }
                const style = getComputedStyle(child);
                if (style.display === 'none') continue;
                const block = !INLINE.has(style.display);
                if (block) parts.push('\n');
                // Computed visibility is inherited, and a child may show itself again.
                walk(child, style.visibility !== 'hidden');
                if (block) parts.push('\n');
              }
            }
            if (document.body) walk(document.body, getComputedStyle(document.body).visibility !== 'hidden');
            return parts.join('').split('\n').map(line => line.replace(/[ \t\u00a0]+/g, ' ').trim())
              .join('\n').replace(/\n{3,}/g, '\n\n').trim();
          }

          function read(firstRef) {
            // The store asks from the next ref it has not seen; a ref this document already gave out
            // would name two elements, so such a read is the page-changed refusal (it reads again).
            if (!Number.isInteger(firstRef) || firstRef <= issued) return { stale: true };
            const found = [];
            const frames = { count: 0 };
            collect(document, found, frames);
            const next = new Map();
            let n = firstRef;
            const elements = found.map(el => {
              const ref = 'e' + n;
              n += 1;
              next.set(ref, new WeakRef(el));
              return describeElement(el, ref);
            });
            if (elements.length) issued = n - 1;
            refs = next;
            // The operator's fields keep their text out of the page's text too. The text is built by
            // walking the page and skipping those fields where they stand — never by removing their
            // words from the whole text, which would tell their words by where they went missing.
            const theirs = new Set(found.filter((el, i) => wakilYours(elements[i]) !== null));
            const text = pageText(theirs);
            return {
              url: String(location.href), title: String(document.title), text,
              elements, framesSkipped: frames.count,
            };
          }

          function describe(ref) {
            const el = live(ref);
            return el ? { element: describeElement(el, String(ref)) } : { stale: true };
          }

          function nativeSet(el, value) {
            const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
            if (setter && setter.set) setter.set.call(el, value); else el.value = value;
          }

          function fire(el, type) { el.dispatchEvent(new Event(type, { bubbles: true })); }

          function typeInto(el, text) {
            el.focus({ preventScroll: false });
            if (el.isContentEditable) {
              const range = document.createRange();
              range.selectNodeContents(el);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              let done = false;
              try { done = document.execCommand('insertText', false, text); } catch (_) { done = false; }
              if (!done || String(el.innerText).replace(/\n$/, '') !== text) {
                el.textContent = text;
                fire(el, 'input');
              }
              return;
            }
            try { el.select(); } catch (_) {}
            let done = false;
            try { done = document.execCommand('insertText', false, text); } catch (_) { done = false; }
            if (!done || String(el.value) !== text) {
              nativeSet(el, text);
              fire(el, 'input');
            }
            fire(el, 'change');
          }

          function choose(el, option) {
            const wanted = collapse(option);
            const index = Array.from(el.options).findIndex(o => collapse(o.text) === wanted);
            if (index < 0) return false;
            el.focus({ preventScroll: false });
            nativeSet(el, el.options[index].value);
            el.selectedIndex = index;
            fire(el, 'input');
            fire(el, 'change');
            return true;
          }

          function nextFocusable(el) {
            const all = Array.from(document.querySelectorAll(
              'a[href], button, input, select, textarea, [tabindex], [contenteditable]'))
              .filter(e => e.tabIndex >= 0 && !e.disabled && visible(e));
            const at = all.indexOf(el);
            return at >= 0 ? all[at + 1] : null;
          }

          function press(el, key) {
            const [name, code, keyCode] = KEYS[key];
            el.focus({ preventScroll: false });
            const init = { key: name, code, keyCode, which: keyCode, bubbles: true, cancelable: true, composed: true };
            const down = new KeyboardEvent('keydown', init);
            el.dispatchEvent(down);
            el.dispatchEvent(new KeyboardEvent('keyup', init));
            if (down.defaultPrevented) return;
            // Synthetic keys change no field's value (a press never does); these two do what a
            // page's own Return and Tab do without touching one.
            // Return submits only from a text input in a form, as a page's own Return does there; on
            // a textarea, a button or a link it would do something else, so it does nothing more.
            if (key === 'Return' && el.tagName === 'INPUT' && roleOf(el) === 'textbox' && el.form
                && typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
            if (key === 'Tab') { const next = nextFocusable(el); if (next) next.focus(); }
          }

          function click(el) {
            el.scrollIntoView({ block: 'center', inline: 'nearest' });
            const init = { bubbles: true, cancelable: true, composed: true, view: window, button: 0 };
            for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
              const E = type.startsWith('pointer') && typeof PointerEvent === 'function' ? PointerEvent : MouseEvent;
              el.dispatchEvent(new E(type, init));
            }
            if (typeof el.focus === 'function') el.focus({ preventScroll: true });
            el.click();
          }

          function act(spec) {
            const el = live(spec.ref);
            if (!el) return { stale: true };
            const now = describeElement(el, String(spec.ref));
            const expect = spec.expect;
            if (expect && (now.type !== expect.type || now.autocomplete !== expect.autocomplete
                           || now.name !== expect.name || now.id !== expect.id)) return { stale: true };
            if ((spec.kind === 'type' || spec.kind === 'select' || spec.kind === 'press')
                && wakilYours(now) !== null) return { failed: YOURS_NOW };
            switch (spec.kind) {
              case 'click': click(el); break;
              case 'type': typeInto(el, String(spec.text)); break;
              case 'select': if (!choose(el, spec.option)) return { stale: true }; break;
              case 'press':
                if (!Object.prototype.hasOwnProperty.call(KEYS, spec.key)) return { stale: true };
                press(el, spec.key);
                break;
              case 'scroll': el.scrollIntoView({ block: 'center', inline: 'nearest' }); break;
              default: return { stale: true };
            }
            return { ok: true };
          }

          return { read, describe, act };
        })();
        """#

    /// A Swift string as a JavaScript string literal (JSON is one).
    private static func jsString(_ s: String) -> String {
        String(decoding: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
