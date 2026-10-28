import Foundation
import WakilKit
import WebKit

/// 3d-iv: the passwords' page script — Wakil's own JavaScript, in its own content world.
///
/// **`wakil.passwords` is a world of its own**, as `wakil.agent` and `wakil.find` are: the page's
/// script can neither see, call nor spoof it, and the messages handler (`BrowserPasswordMessages`)
/// is added in this world only, so `window.webkit.messageHandlers.wakilPasswords` does not exist in
/// the page's own world. It is added at document end, main frame only (ruling 11: a login form in an
/// iframe gets no key).
///
/// **What it tells Wakil**, through `wakilPasswords`:
/// - `{kind: "field", role, rect}` when a login field takes focus, and again as it moves (scroll,
///   resize): `username` (`autocomplete="username"`, or the nearest text or email input before a
///   password field in its form), `password`, or `new` (`autocomplete="new-password"`). The rect is
///   in CSS pixels from the viewport's top left. Never a value.
/// - `{kind: "blur"}` when that field loses focus.
/// - `{kind: "submit", username, password, isNew}` when a form with a filled password field is sent
///   (ruling 14): a `submit` caught on the document in the capture phase — so it still fires when the
///   page cancels it — or Enter in a password field with no form. **The only message that carries a
///   password.**
///
/// **What Wakil asks of it** (`BrowserPasswordAgent`), through `callAsyncJavaScript`'s arguments —
/// values, never code: `fill(origin, username, password)` and `suggest(origin, password)`. Each refuses
/// with `moved` when `location.origin` is not the origin captured when the key was pressed (ruling 13),
/// and with `nofield` when it finds no field; it answers `ok` otherwise, and nothing more. A value is
/// set with the element's native setter, then `input` and `change` follow, as the agent's script does.
/// The field pressed in is focused again after, so it keeps the keyboard (Rule 6).
enum BrowserPasswordScript {
    @MainActor static let world = WKContentWorld.world(name: "wakil.passwords")
    static let handlerName = "wakilPasswords"

    /// Added to each tab's configuration: the script installs itself as each main-frame document ends.
    @MainActor static func userScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    }

    /// A call's body: the script (a no-op when already installed), then `call`, a fixed expression
    /// over the call's arguments.
    static func body(_ call: String) -> String {
        source + "\nreturn \(call);"
    }

    static let fillCall = "globalThis.wakilPasswords.fill(origin, username, password)"
    static let suggestCall = "globalThis.wakilPasswords.suggest(origin, password)"

    static let source: String = #"""
        globalThis.wakilPasswords ??= (() => {
          'use strict';
          const TEXTY = new Set(['text', 'email']);
          let lastField = null;
          let frame = 0;

          function post(message) {
            const handlers = globalThis.webkit && globalThis.webkit.messageHandlers;
            const handler = handlers && handlers.\#(handlerName);
            if (handler) handler.postMessage(message);
          }

          const tokens = el => String(el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
          const usable = el => el instanceof HTMLInputElement && !el.disabled && el.type !== 'hidden';
          const inputsOf = scope => Array.from(scope.querySelectorAll('input')).filter(usable);
          const scopeOf = el => el.form || document;
          const isNew = el => tokens(el).includes('new-password');
          const target = e => (e.composedPath ? e.composedPath()[0] : e.target);

          // The username field of a form (or of the page, for inputs with no form).
          function usernameIn(scope) {
            const inputs = inputsOf(scope);
            const named = inputs.find(i => TEXTY.has(i.type) && tokens(i).includes('username'));
            if (named) return named;
            const pw = inputs.findIndex(i => i.type === 'password');
            for (let k = pw - 1; k >= 0; k--) if (TEXTY.has(inputs[k].type)) return inputs[k];
            return null;
          }

          function roleOf(el) {
            if (!usable(el)) return null;
            if (el.type === 'password') return isNew(el) ? 'new' : 'password';
            if (TEXTY.has(el.type) && usernameIn(scopeOf(el)) === el) return 'username';
            return null;
          }

          function focused() {
            let at = document.activeElement;
            while (at && at.shadowRoot && at.shadowRoot.activeElement) at = at.shadowRoot.activeElement;
            return at;
          }

          const current = () => {
            const el = lastField && lastField.deref();
            return el && el.isConnected ? el : null;
          };

          function reportField() {
            const el = current();
            if (!el || focused() !== el) return;
            const role = roleOf(el);
            if (!role) return;
            const r = el.getBoundingClientRect();
            post({ kind: 'field', role, rect: { x: r.left, y: r.top, w: r.width, h: r.height } });
          }

          function onFocus(e) {
            const el = target(e);
            if (!(el instanceof HTMLInputElement) || !roleOf(el)) return;
            lastField = new WeakRef(el);
            reportField();
          }

          function onBlur(e) {
            const el = current();
            if (el && target(e) === el) post({ kind: 'blur' });
          }

          function moved() {
            if (frame) return;
            frame = requestAnimationFrame(() => { frame = 0; reportField(); });
          }

          // A sent form: the password it carries, and its username. A new-password field wins; a form
          // with several password fields is a change of password, whose new one is sent.
          function sent(scope) {
            const passwords = inputsOf(scope).filter(i => i.type === 'password' && i.value);
            if (!passwords.length) return;
            const fresh = passwords.filter(isNew);
            let field = passwords[0], isNewPassword = false;
            if (fresh.length) { field = fresh[0]; isNewPassword = true; }
            else if (passwords.length >= 3) { field = passwords[1]; isNewPassword = true; }
            else if (passwords.length === 2) {
              isNewPassword = true;
              field = passwords[0].value === passwords[1].value ? passwords[0] : passwords[1];
            }
            const user = usernameIn(scope);
            post({ kind: 'submit', username: user ? String(user.value).trim() : '', password: String(field.value),
                   isNew: isNewPassword });
          }

          document.addEventListener('focusin', onFocus, true);
          document.addEventListener('focus', onFocus, true);
          document.addEventListener('focusout', onBlur, true);
          document.addEventListener('blur', onBlur, true);
          document.addEventListener('scroll', moved, { capture: true, passive: true });
          window.addEventListener('resize', moved, { passive: true });
          document.addEventListener('submit', e => {
            const form = target(e);
            if (form instanceof HTMLFormElement) sent(form);
          }, true);
          document.addEventListener('keydown', e => {
            if (e.key !== 'Enter' || e.isComposing) return;
            const el = target(e);
            if (el instanceof HTMLInputElement && el.type === 'password' && !el.form) sent(document);
          }, true);

          // A field focused before this script ran (`autofocus`) gets its key without a second focus.
          { const el = focused(); if (el instanceof HTMLInputElement && roleOf(el)) { lastField = new WeakRef(el); reportField(); } }

          function set(el, value) {
            const descriptor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
            if (descriptor && descriptor.set) descriptor.set.call(el, value); else el.value = value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }

          function refocus() {
            const el = current();
            if (el && focused() !== el) el.focus({ preventScroll: true });
          }

          const scopeNow = () => { const el = current(); return el ? scopeOf(el) : document; };

          function fill(origin, username, password) {
            if (location.origin !== origin) return 'moved';
            const inputs = inputsOf(scopeNow());
            const pw = inputs.find(i => i.type === 'password' && !isNew(i)) || inputs.find(i => i.type === 'password');
            const user = usernameIn(scopeNow());
            if (!pw && !(user && username)) return 'nofield';
            if (user && username) set(user, username);
            if (pw) set(pw, password);
            refocus();
            return 'ok';
          }

          function suggest(origin, password) {
            if (location.origin !== origin) return 'moved';
            const fresh = inputsOf(scopeNow()).filter(i => i.type === 'password' && isNew(i));
            if (!fresh.length) return 'nofield';
            fresh.forEach(i => set(i, password));
            refocus();
            return 'ok';
          }

          return { fill, suggest };
        })();
        """#
}
