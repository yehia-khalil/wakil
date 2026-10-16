# 2c-iv — API client pane: acceptance

**Spec:** [#179](https://github.com/yehia-khalil/rafiq/issues/179) ·
**Cover rung:** [#296](https://github.com/yehia-khalil/rafiq/issues/296),
[#310](https://github.com/yehia-khalil/rafiq/pull/310),
[#313](https://github.com/yehia-khalil/rafiq/pull/313),
[#314](https://github.com/yehia-khalil/rafiq/pull/314),
[#338](https://github.com/yehia-khalil/rafiq/pull/338) (the hand bind)

**This document is ready to walk.** Forty check files run green, and every one the
work added was seen to fail against its merge-base. *The coverage gate passes* was true
per PR and false for the phase: measured 2026-09-29 from `18f9762` (before 2c-iv), #310
added `api_bind`, `api_unbind` and `api_reopen`, and every later PR in the stack — #305's
family — gated against a merge-base that already had them (found by #317). This branch
closes `api_bind`, which now carries a drag parity; `api_unbind` and `api_reopen` stay in
`uncoverable.tsv` §1, excused — `api_unbind`'s parity can't run because after the `×` the
position is a hole and `api_unbind` refuses one, and `api_reopen`'s dispatch needs a row id
minted per send. `go run ./e2e/cmd/wakil-e2e-cover --trunk 18f9762` now reports: writes,
5 of 41 carry a parity check. §0 below is rendered from those records and nothing writes
it by hand.

## 0. The ten checks

**Ten, chosen for what a test cannot see.** Most of what this document listed as
residue in September is now covered by a check — the pane has identifiers, both
channels exist, and sending is exercised end to end. What is left is the two
things no assertion reaches: a **judgement** about how something reads, and a
**live provider**.

Walk these in order; 4 and 5 need a real API entry configured in a project you are
willing to send to. Amendment 9 re-walk: checks 4, 5, 6 and 10 — 5 is the look at the split
layout and the response's headers; the list after check 10 is what no check can see.

- [x] **1. The amber is caution, not failure.** Open an api pane, type a path with
      a named hole in it, and point the pane at an entry whose `baseUrl` does not
      resolve. Both draw `#e8b45a`. **Does it read as *this is not ready yet*
      rather than *something has gone wrong*?** Nothing has gone wrong in either
      case, and the pane says so in colour only. If it reads as an error, the hue
      is wrong and design-language.md §5 is what to argue with.

- [x] **2. The body is text, and looks like text.** Put a JSON body in the pane.
      It must not look like a grid — it cannot sort, filter or page, and §8's rule
      is that a surface which cannot do the thing must not look like it can.
      **Does it invite you to click into it as though it were a table?**

- [x] **3. An empty region reads as a place to put something.** A fresh `GET` has
      an empty query region, an empty header region beyond Wakil's own rows, and
      an empty body. Each draws `empty`, and the query and header regions each
      carry their own `+ query` / `+ header` row. **Is it obvious that this is
      where the first row goes, rather than chrome you cannot act on?** #158
      chose visible over hidden precisely for this; the walk is what says
      whether it worked.

- [x] **4. A request built entirely by hand reaches a real server.** Against a live
      entry: pick it from the chooser, type `/anything/customers/`, press `+ hole`, type
      `id` and press Return — the amber chip appears — then type `/confirm` after it.
      Click just after the chip, before `/confirm`, and press **Backspace** — **the hole
      goes, and the path is plain text again, `/anything/customers//confirm`, with the cursor
      where the chip was**: type `x` and it lands there (`/anything/customers/x/confirm`),
      never after `/confirm`. Put the hole back: delete `x/confirm`, press `+ hole`, type
      `id`, Return, and type `/confirm` again. `+ hole` lands at the cursor in every field,
      the path too. Later, once the drop has filled it, Backspace after
      the filled chip **unbinds it back to its hole, and a second Backspace removes that**.
      Select text that runs across the filled chip and type, or press ⌘X: it is refused, in
      amber, and the chip stays. Click the chip, ⌘C, click into the body, ⌘V: its **hole**
      arrives, not the binding. Drag the unfilled `id` chip from the path into the body: it
      moves. Each chip's `×` now sits
      **inside** the chip, at its right edge. **Does the `×` still read as part of the chip
      rather than a stray character?**
      **Nothing else here needs Return**: what you type is saved as you pause, and at once
      when you leave the field or press anything. Type `?expand=all` at the end of the
      path — within a moment the Query region shows `expand=all` as its own row. Press
      `+ query`, type `page`, press Return (a name box still takes Return), and type `2`
      into its value — the path line follows with `...&page=2`. Press `+ header`, type
      `X-Trace-Id`, press Return, and give it a value. Press `+ header` again, type
      `authorization` and press Return — it is refused, naming `wakil secrets set-api`.
      Press `+ header` once more and type `content-type` — it goes to Wakil's own row.
      **Is a typed value in the path, a query value or a header
      value left exactly as typed, not autocorrected?** Text replacement and spelling
      correction may still apply there (Ruling 13) — the walk is what judges it. **The
      caret stays where you left it across a pause** — type, wait past a moment, keep
      typing, in the path, a query value, a header value and the body: it never jumps to the
      end. (No check can see a caret.) Open a DB pane on a table whose column matches the
      hole's name and **drag a row's `⋮` grip onto the api pane** — the chip fills, and a
      drop is never refused for what you are typing. **Type into the text beside the
      filled chip — it stays editable; only the chip itself is locked** — and a second hole
      beside it can still be removed. Click into a field, type, and press
      Escape — **the field goes back to what it held when you clicked in**. Type a
      multi-line JSON body with two holes in it (Return is a newline, `+ HOLE` at the cursor
      each time), then press **Format**: **each chip sits in its line, after its key,
      exactly where text would.** Arrow up and down across the chips. Type on the line after
      one.
      Type a `"` into the body — **it must stay a straight quote**; only your
      own machine can show this, because every check here runs against a fixture that
      never substitutes a curly one. Press Send, or ⌘Return in the body. Then point
      the path at something that answers slowly (`/delay/10` on httpbin) and press Send:
      **the button reads `Cancel · 1.2 s` and counts up** (the label is not readable by the
      tree vocabulary, so only your eyes confirm it). Press it. A `GET` reads
      *"cancelled after N s"* in grey; send it again as a `POST` and cancel — it reads
      *"… — the server may already have it"* in amber. **Does the amber read as "this may
      have happened" rather than "this failed"?** Pausing mid-typing writes one journal
      entry per pause, not one per keystroke (no check can count entries; look at the
      journal once). Press Send once more, without cancelling — that is the reply check 5
      reads. A pane with no entry chosen refuses Send with "pick an entry first", before any
      plane. On a `GET` the body and content-type rows dim and send nothing, and no extra
      line is drawn. **Every step by hand, no agent.** That is
      the sub-phase's exit criterion, both clauses, and no check can prove it, because
      every check sends at an `.invalid` host and has never drawn a reply. While the row
      is being dragged, the api pane draws a thin drop outline. **Does it read as "drop
      here"?** Over the dimmed `⋮` grip the pointer is an open hand. **Does it read as
      "drag me", and does the hand go away after the drop?**

- [x] **5. A reply draws legibly, in its own half.** From 4: **the pane splits** — the
      request above, about 55% of the pane, the response below, each scrolling on its own;
      before anything is sent the response is one line and the request takes the rest. The
      status chip, timing, size and URL **stay pinned while a long body scrolls**, and a large
      reply never pushes the request under the window's toolbar. The status carries the only
      colour and the body carries none. **Is a 500's JSON visually identical to a 200's, apart
      from the status?** Press **Headers** on the response's head — the reply's headers as a
      `HEADER | VALUE` table, listed in **byte order** (the wire carries a map, so there is no
      order received), uncoloured; **Body** goes back.
      Recent sits at the foot of the response half, at most four rows tall, and a row shows
      the values sent (`GET /customers/<id:3>/confirm`); the Bound list reads
      `id = 3 · live · …`. Open a second api pane: **Recent is the same list there**, and
      Reopen loads into the pane you pressed it in. Point that second pane at another entry
      first: the row **names its entry** (`billing · GET …`), because it is not the pane's,
      and Reopen **re-points the pane at the row's entry** — the title, the origin and, if that
      entry has a credential, its `authorization` row come with it; never *no origin*. **Does the split read as one request and
      its reply, and is the pinned status findable without hunting?**

- [x] **6. Production costs a typed confirmation, and staging does not.** Send a
      mutation in a non-production environment — it goes on one press. Switch to an
      environment declaring `production: true` and send the same request. **Read the
      statement on the plane: does it name the whole URL that will leave (path and query)
      and the body by its SHAPE, e.g. `{test, customer_id}`, not part counts or bytes?** A large body must not make the plane unreadable.

- [x] **7. A `GET` in production costs nothing.** Same environment, a read method.
      It must not raise a plane at all. This is the inversion Decision 25 exists to
      prevent, and the reason the send is two actions.

- [x] **8. The one-author rule fires on screen.** Click into the path field and leave the
      cursor there — type nothing. Ask the agent to set the path. **The write must be
      refused, naming the field.** Click out of the field and ask again: **it lands.** The
      rule is now *the cursor is in it*, not *it holds unsaved text* (Decision 27, amended
      2026-10-03), because nothing is ever left unsaved.

- [x] **9. The past tense is usable.** Send two requests. Unfold `Recent`, reopen
      the older one — **the whole draft comes back** — and Copy as cURL, then paste
      it somewhere. **The line must say the credential is not included**, and must
      name no scheme and no ref.

- [x] **10. An environment switch clears the present and nothing else.** With a reply on
      screen and a draft you care about, switch environments. **The reply goes, the draft
      stays, nothing is re-sent**, and the chooser offers the new environment's entries.
      Switch back: **the pane's origin is its entry's own again** — never *no origin*.
      Switch to an environment that does not declare the pane's entry: the URL line reads
      "<env> declares no entry named <name> — pick one", and the chooser offers that
      environment's entries. Then choose the environment that is already active:
      **nothing happens, and no plane rises.**

- [x] **11. A cURL command pasted into the path is that request.** In a browser's devtools,
      copy a request to an entry of this environment as cURL (bash). Click into an api
      pane's path and paste: **the method, path, query, headers and body fill**, the line
      says *Filled from cURL · <entry>* and names what it dropped (an `Authorization`, a
      cookie), and the caret sits at the end of the path. Press Send — it goes. Press
      **Undo** on a fresh fill — the previous draft comes back, a filled chip included.
      Paste a cURL for another entry: the pane switches to it. Paste one for a host no
      entry has: refused in amber, naming the host, and nothing changes. Paste `curl` into
      a header value or the body: it stays text.

### Also look at, while walking (no check can see these)

One line each; none is a pass/fail of its own.

- **Split proportions.** Request about 55%, response below; resize the pane with a 200 KB
  reply on screen — is it smooth, and does the request never slide under the toolbar
  (`Open…` / `Actions…`)?
- **The cursor survives** the first reply, a cancel and an environment switch (and body focus
  with it); ⌘Return from the body still sends.
- **The body with holes** reads as JSON with values missing, never as boxes beside text.
  Lines align, a chip takes one character's place, and wrapping moves it like a word.
- **Undo** (⌘Z) after removing a hole brings the hole back, in place. After an unbind it does
  nothing to the binding.
- **An input method** (accent menu, or Japanese) right after a chip composes normally, and
  Backspace while composing never removes the chip.
- **Paste from another app** of `<id>` stays the text `<id>`, never a hole.
- **A chip at the path's wrap edge**: narrow the pane until the path wraps right at a chip.
  The chip moves to the next line whole, like a word, and arrows and Backspace treat it as one
  character.
- **A query row's ×** while another row with the same name holds typing you haven't sent: the
  row goes, and the other row keeps its typing.
- **The Bound line** reads `id = 3 · live · …`; the region is shown only when two holes share
  a name; close the source grid and it reads `… · no value now`, dimmer.
- **Recent is shared** across api panes in the same project and environment (a send in one
  appears in the other, Reopen changes only the pane pressed), is separate per project, shows
  `<id:3>` values (long ones end in `…`), and at most four rows then scrolls.
- **Body · Headers** choice survives the next replies; a 204 with no headers reads "no
  headers"; a refusal or transport failure draws no choice; long values wrap.
- **`+ query` / `+ header`** (and the `+ add a parameter` line) put the caret in the new name
  box; the value field takes it after the name; refusal lines span the full width.
- **`BODY · JSON` / `BODY · TEXT`** follows the content type as you type `text/plain`; an
  empty content type shows the `application/json` placeholder.
- **The title follows the entry** — on picking one, on Reopen, on an environment switch, and
  at launch.
- **Escape** after typing beside a chip restores the text and keeps the chip; after unbinding
  with `×` it restores the text and the hole, not the binding.

## What this walk CANNOT establish

**No check has ever drawn a reply.** The fixture's entries point at `.invalid`
hosts on purpose, so every check's send fails at DNS. Checks 4 and 5 are the only
evidence that a successful response renders at all. The Body · Headers choice and its
table are drawn only over a reply, so check 5 is their only evidence (`uncoverable.tsv` §3).

## 0. What the machine walked

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green:** every check ran against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks.

Walked by `make e2e` against c446bc7c00ed, rendered 2026-10-06 07:18 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

| Check | `make e2e` | Red against the base | Assertions | Evidence |
|---|---|---|---|---|
| `org-plane.jsonl` | ✓ exit 0 | not new on this branch | 3 | — |
| `2c-iii-1-bundle-path.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2c-iii-2-block.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2c-iii-3-live-prompt.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2c-iii-4-interrupt.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2c-iii-5-full-screen.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2c-iii-6-no-orphan.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `2c-iii-7-org-switch.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2e-settings-databases-dispatch.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `2e-settings-databases.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `2e-settings-doors.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `2e-settings-organisation.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `2e-settings-pane.jsonl` | ✓ exit 0 | not new on this branch | 10 | — |
| `2e-settings-unlink.jsonl` | ✓ exit 0 | not new on this branch | 11 | — |
| `agent-pane-is-drawn.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
| `api-bind.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `api-body-editor.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |
| `api-body-hole-cursor.jsonl` | ✓ exit 0 | not new on this branch | 3 | — |
| `api-bound-locks.jsonl` | ✓ exit 0 | not new on this branch | 16 | — |
| `api-cancel.jsonl` | ✓ exit 0 | not new on this branch | 15 | — |
| `api-chip-keys-second-chip.jsonl` | ✓ exit 0 | not new on this branch | 11 | — |
| `api-chip-keys-text-after.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-chip-keys.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `api-editor-copy-bound.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `api-editor-json-holes.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-editor-wrap.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `api-env-roundtrip.jsonl` | ✓ exit 0 | not new on this branch | 11 | — |
| `api-hole.jsonl` | ✓ exit 0 | not new on this branch | 12 | — |
| `api-one-author-focus.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `api-open.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `api-paste-curl-hotkey.jsonl` | ✓ exit 0 | ✓ red vs 42c75ce | 7 | — |
| `api-paste-curl-refused.jsonl` | ✓ exit 0 | ✓ red vs 42c75ce | 4 | — |
| `api-paste-curl.jsonl` | ✓ exit 0 | ✓ red vs 42c75ce | 20 | — |
| `api-query-sync.jsonl` | ✓ exit 0 | not new on this branch | 15 | — |
| `api-recent-shared.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-recent.jsonl` | ✓ exit 0 | not new on this branch | 9 | — |
| `api-reopen-cross-entry.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-rows.jsonl` | ✓ exit 0 | not new on this branch | 30 | — |
| `api-saved-as-typed.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `api-send-what-it-shows.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-send.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-set-request.jsonl` | ✓ exit 0 | not new on this branch | 25 | — |
| `api-surface.jsonl` | ✓ exit 0 | not new on this branch | 20 | — |
| `api-the-rest.jsonl` | ✓ exit 0 | not new on this branch | 8 | — |
| `api-unbind.jsonl` | ✓ exit 0 | not new on this branch | 7 | — |
| `landing.jsonl` | ✓ exit 0 | not new on this branch | 5 | — |
| `vocabulary.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `both-surfaces.jsonl` | ✓ exit 0 | not new on this branch | 6 | — |
| `two-enter.jsonl` | ✓ exit 0 | not new on this branch | 13 | — |

**`make e2e-new` saw every check this branch added go red against 42c75ce.**

**Every action and control this branch added carries a check.** 2 action(s) and 1 control(s) are new on this branch.

- actions:  25 of 68 dispatched by a check
- writes:   5 of 43 carry a parity check
- controls: 63 of 103 exercised by a check

**19 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `api.recent.<…>.curl` — Its whole effect is a string on the SYSTEM PASTEBOARD, which no check can read — the act is real and its result leaves the window, so a check could press it and assert nothing, which is the check-that-cannot-fail this file exists to prevent rather than permit. `TerminalPane`'s own Copy is silent for the same reason and carries no indicator. The line it copies is `apiRenderCurl`'s, covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses. If this pane ever draws a "copied" acknowledgement, the act becomes observable and this line should go.
- `api.response.<…>` — the Body · Headers choice (W20) is drawn only over a reply, and no fixture host ever replies — every entry is `.invalid` or the never-answering `slow`, and wakil-http refuses http://. apiResponseOffersHeaders and apiResponseHeaderRows are pinned in ApiPaneLayoutTests; the drawn table is the runbook's check 5.
- `settings.login.cancel` — #254. Only exists while a browser trip is in flight.
- `settings.login.dismiss` — #254. Drawn only by the states a finished trip reaches — added, refused, cancelled, timedOut, uncertain, failed.
- `settings.login.someoneElse` — #254. Starts a fresh trip, and only appears when the config dir is already signed in, which itself needs a real credential.
- `settings.login.start` — #254. The control that does the above.
- `settings.mint.stopWaiting` — #254. Only exists while waiting on a live mint.
- `settings.row.<…>.reauthenticate` — #254. Goes straight to the browser by design — no confirmation step — so pressing it IS starting a real trip.

**This section knows nothing about what a machine cannot see.** The visual rulings and the live-provider question stay the operator's, permanently; they are the human section below.

<!-- /machine-walk -->

## 1. The residue — what no check reaches, and why

**Everything below was written on 2026-09-25, against a pane that drew `Text`
and nothing else.** It is left standing as the dated record it is, and most of
it is now discharged: `ApiPane.swift` carries identifiers and is in
`AuditedSources`; the GUI channel exists, so `api_set_request` and `api_send`
both have one; the chooser's disabled state is asserted; and requests are sent
by check down both channels. What survives it is in *"What this walk cannot
establish"* above — the absence of a live reply *(the drop gesture was discharged
2026-09-29 by the hand bind)*.

The only part of the Cover rung's output the operator is expected to read.
One line per item.

**Identifiers, all of them.** `ApiPane.swift` carries zero
`.accessibilityIdentifier`s, and the audit did not add any. Every element the
pane draws — the entry chooser, the query rows, the header rows, the
content-type row, the body, the response line — is a `Text`. None has an
accessibility action, so none can be pressed, and an identifier on an element
`AXPress` cannot reach would enter the control denominator owing a press no
check can make. **The pane is therefore invisible to the control half of the
coverage gate**, and it is read today only through `read_pane` and through
tree text. This is the ticket's second acceptance criterion and it is
deliberately unmet — see §2.

**`api_open` parity — no check drives it down both channels.** Invariant 2 is
*"UI controls and the agent dispatch the same actions"*, and the gate asks a
writing action for a parity check. Nothing in the window dispatches `api_open`:
`WakilWindow` has `window.openPane` (hardcoded `kind: "db"`) and
`window.openTerminal`, and no third button. Its own comment anticipates this —
*"a third pane kind gets the same treatment until §6.1's param-collecting
palette actually lands"* — so the control is three lines and was left out as
product surface this ticket was not asked to add.

**`api_set_request` parity — the GUI channel does not exist at all.** Not an
omission of the same kind: there is no in-place editor to click, because the
editors are [#191](https://github.com/yehia-khalil/rafiq/issues/191)'s and
after. This gap closes when they land and not before, and neither is an
`uncoverable.tsv` entry — that file's bar is *no check can reach it*, a claim
about the harness, and this is ordinary work the gate is right to keep asking
for.

**The chooser's disabled state is asserted nowhere.**
`apiChooserIsEnabled(entryCount:)` has a true branch that nothing in the app
can reach — `ApiPane.entryCount` is `snapshot.entry.isEmpty ? 0 : 1`, so it is
never above one — and a check cannot tell a disabled chooser from an enabled
one without an identifier to address. `WakilKit`'s own tests cover the
function; what is uncovered is that the view is drawn from it.

**Nothing is sent, so nothing about sending is covered.** No request leaves the
window in any check here: `api_send`, `api_request`, `api_bind`, `api_unbind`,
`api_reopen` and Copy as cURL are the remaining tickets, and the fixture's two
entries point at `.invalid` hosts precisely so that nothing can leave by
accident.

**Visual rulings stay the operator's, permanently.** The amber is
`#e8b45a` on two elements — an unresolved origin and an unfilled hole — and
whether it reads as *caution* rather than *failure* is a judgement no
assertion makes. Likewise that the body refuses the grid, and that a region
drawn `empty` reads as a place to put the first row rather than as chrome.

### #191 — one pane, one draft, one author

Added 2026-09-25, on `yehia-khalil/2c-iv-191-one-author`. **The ticket added no
check, and why it could not is the whole of its residue.**

**Nothing in the shipped app can put the pane into the state the rule reads.**
The refusal is keyed on an operator's unsaved edit, one field at a time, and a
mark is set by `PaneStore.noteApiEdit` — which has no caller outside
`WakilKitTests`. `ApiPane.swift` draws every region with `Text` and carries no
editor, so no `do` step can type into a field and no `dispatch` step can claim
to have. Both halves of the vocabulary are blind to it: a check may dispatch
`api_set_request` all day and never meet a collision.

**And this is not an `uncoverable.tsv` line.** That file's bar is *no check can
reach it* — a claim about the harness — and the harness is not what is missing.
The editors are. Nor is the gate asking yet: the branch adds no action and no
identifier, `api_set_request` already carries a check, and the pane still has
no control.

**What a run on this branch does prove is the half that could have broken.**
`api_set_request` now consults a policy function before it decodes a region, so
the ordinary agent write — the one no edit contends — passes through a guard
that did not exist. `api-set-request.jsonl`'s twenty-five assertions are that
regression's only witness.

**§2's expectation is not met, and it now has no owner.** That section hands
the identifier obligation to *"the first ticket that gives the pane a
control"*, naming `#191` as the one that *"adds the first editor"*. It does
not: #191 is policy, and it refuses new surface in as many words. None of the
four tickets left in the sub-phase adds an editor either — #192 is binding,
#193 and #194 are sending, #195 is the past tense — so `ApiPane.swift` stays
out of `AuditedSources`, and the rule shipped here cannot fire on screen until
somebody cuts the ticket that gives the operator a field to type in.

## 2. The one criterion this audit did not meet, and why

[#296](https://github.com/yehia-khalil/rafiq/issues/296)'s second acceptance
criterion asks that *"`ApiPane.swift`'s actionable controls carry identifiers
— the entry chooser, the region rows, the content-type row"*.

**The pane has no actionable controls.** Measured rather than argued:
`driver.controlKinds` matches `Button`, `TextField`, `SecureField`, `Toggle`,
`Picker`, `Stepper`, `Slider`, `DatePicker`, `ColorPicker`, `Menu` and
`.onTapGesture`, and `ApiPane.swift` contains none of them. The chooser is the
closest thing to one and it is a `Text` plus a `▾` glyph with `.disabled()`
applied, which changes a foreground opacity and nothing else.

Every one of the app's existing identifiers sits on an element with an
accessibility action behind it — `Landing.swift:265` pairs
`landing.row.<…>` with `.accessibilityAction(.default, action)` and says why
in its own comment: *"a tap gesture is not an accessibility action, so
VoiceOver would announce a button that does nothing when activated."* An
identifier added to this pane today would be that announcement.

**So the obligation is real and it belongs to the tickets that add the
controls.** `#191` adds the first editor, and the identifier arrives with it —
which is also `identifiers.go`'s own rule for `AuditedSources`: *"Adding a
file here is the deliberate act that puts it under the gate, and it belongs in
the change that names its controls — never in a change that merely touches
it."* `ApiPane.swift` is therefore **not** added to `AuditedSources` by this
ticket, and the first ticket that gives the pane a control should add it.

## 3. Do the sending tickets inherit an extension point?

**Yes, and it is `api-set-request.jsonl`.** The draft it builds — a `POST` to
`/invoices/{invoiceId}` with one query row, one authored header, a
`merge-patch+json` content type and a JSON body — is the draft a send has to
carry, and it already holds an unfilled slot for
[#192](https://github.com/yehia-khalil/rafiq/issues/192) to bind. A send check
extends that file's tail rather than rebuilding the draft.

**`api-open.jsonl` does not extend; it is finished.** It asserts what the pane
is pointed at and nothing about a request, and the one thing it would still
want — the chooser — is behind the identifier work above.

**The fixture is the shared part.** `fixtureAPIEntries()` in
`e2e/driver/seed.go` gives every seeded launch two entries, one credentialed
and one not. A send check needs a third that points somewhere a request can
actually reach; both of these are `.invalid` on purpose.
