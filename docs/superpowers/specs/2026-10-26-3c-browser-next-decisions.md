# The browser after 3c-i: decisions so far (brainstorming notes, not yet a spec)

Brainstorming with the operator on 2026-10-26, after they used the 3c-i browser. This is not yet a spec.
These are the decisions to carry into the next browser spec, alongside 3c-ii (the agent's reach) and
3c-iii (history, bookmarks, links), which `2026-10-25-3c-browser-design.md` already plans. Where this
note overturns that spec, it says so.

Why: the operator browses in Dia today and wants Wakil's browser to replace it. They watch a lot of
video, they are a developer, and they keep work, local testing, study and home browsing in tab groups.

## Decided by the operator

1. **Picture-in-picture, automatic.** A playing video floats out on its own when you leave its tab,
   pane, place or organisation. It goes to a small window above Wakil that you can drag to a corner and
   resize, with play/pause, back to the tab, and close. Closing it pauses the video. A video you paused
   yourself does not float out. My call, not yet the operator's: one floating video at a time, the
   newest replacing the last. How it is built (WebKit's own PiP, or Wakil moving the page into its own
   floating window) is settled by a throwaway build first.
2. **Vertical tabs**, as a choice beside the horizontal strip.
3. **Tab groups**, which overturns the spec's "no tab groups":
   - Groups belong to the **organisation** and show in any browser pane of that organisation's places.
     Loose tabs stay with their place, as in 3c-i. That split is my recommendation; the operator
     accepted it implicitly when they turned to accounts.
   - Groups are named, coloured and collapsible. You make your own (work, local testing, studying,
     home), and each organisation can have its own: a personal organisation and each work organisation keep their own
     study groups.
   - **A pull-request group fills itself**, one per organisation, from that organisation's GitHub
     account. It holds the PRs you opened and the ones your review is requested on, adds and drops
     them as they open and close, and only reads from GitHub.
4. **Spaces are organisations.** Wakil keeps cookies and cache per organisation already, so no
   separate spaces are added.
5. **Identities inside an organisation**, like Firefox containers. Each identity is its own WebKit
   store inside the organisation, for example `admin` and `customer` signed into the same site at
   once, in tabs of the same pane.
   - Right-click a tab → **Identity ▸** `Default · admin · customer · New Identity…`. Changing a tab's
     identity reloads its page in that identity, which the operator accepted. New Identity… opens a
     name field in the menu, already focused, and is created when you leave the field, with no Enter.
   - ⌥-click ＋ or ⌘K *New Tab as admin* opens a tab in an identity. A link opened from a tab keeps the
     tab's identity. A group can have a default identity.
   - A tab in an identity has a coloured mark, and the footer or field names it. The default identity
     has no mark.
   - Settings → Browser → Identities lets you rename, recolour or delete one. Delete asks in place and
     clears the identity's cookies and passwords.
   - Identities never cross organisations. The agent can open a tab in one (`browser_open {identity}`,
     3c-ii) and is still asked per site.
6. **Passwords, option 3**, which overturns the spec's "no password manager of Wakil's own":
   - **Now:** Wakil keeps its own passwords in the macOS Keychain, per organisation (and per
     identity). It fills from a key next to the field, suggests a strong password on sign-up forms,
     and asks before saving or updating. It can import once from the Passwords app's CSV export,
     sorting each login into an organisation. It does not sync to the phone.
   - **Later:** a throwaway build with Wakil signed (a developer ID, and the browser passkey
     entitlement) to see whether the Passwords app's autofill and passkeys start working in Wakil's web
     view. If they do, Wakil switches to the Passwords app and drops its own store.
   - Found: on the unsigned 3c-i build, a login form shows no Passwords suggestion. The operator
     tested `github.com/login` on 2026-10-26.
   - Unchanged: the agent never sees or fills a password. Card and one-time-code fields stay the
     operator's.
7. **No forced dark mode.** Wakil runs in dark appearance, so sites with a dark theme already show it.
   Pages without one stay as they are.
8. **Address-bar suggestions** as 3c-iii plans them: open tabs, then bookmarks, then history, with the
   address completed inline. Suggestions from the search engine come as a setting, off by default,
   because they send every keystroke to the engine.

## From Dia, recommended but not yet confirmed by the operator

- Asking about open tabs from the composer ("@pricing page, compare it with the API docs"), in 3c-ii.
- A question typed in the address field goes to the conversation, not the search engine.
- Quick tasks that know the current page ("Summarise this page").
- Opt-in browsing history as the agent's context, per organisation (3c-iii's store).
- Pinned tabs, a peek window for a quick lookup, and focus mode.
- Left out on purpose: Dia's Slack, Notion and Gmail integrations, and its writing help in any text
  field (it would conflict with the never-list).

## Still open

- **Network view.** Web Inspector's Network tab works since 69a944b (developer extras on). Ask what
  is missing from it: a Wakil-native panel, or the agent reading requests.
- **Settings and developer settings.** Which controls? Candidates: disable the cache, the user agent,
  JavaScript on and off, the default identity, and PiP on or off.
- Vertical tabs: a setting, per pane, or both.
- The order the next phases ship in.
