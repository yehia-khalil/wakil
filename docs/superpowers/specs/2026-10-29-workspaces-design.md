# Workspaces: where a piece of work happens, who works in it, and the home screen that shows it

**Date:** 2026-10-29
**Status:** umbrella design. Every user-facing call was walked with the operator on 2026-10-29 and is
recorded under *Decided by the operator* (1–29); what remains the designer's is under *Calls made
for the operator*. Each numbered piece gets its own design before it is planned. Mockups (not
committed): `.scratch/workspaces/home.html` (home screen, views, ⌘N, the first change) and
`.scratch/workspaces/settings.html` (a project's Running settings).
**Sub-phase:** the piece after ticket work 1–3 (main fcd2825d), before ticket work 4–6. Lifts the
ticket-noticing non-goal "a worktree or branch of its own for a handed agent", and replaces the
conversations design's call 2b (a canvas per conversation).

---

## Problem

Wakil runs several conversations at once (Decision 41 amended) and hands tickets to agents
(Decision 51), but every conversation in a project writes in the same folders. Two agents edit the
same files, stage each other's hunks, and one's branch switch moves the tree under the other. An
app cannot be run twice side by side, and panes can only be opened once a conversation exists.

The operator's work comes in three shapes, and all three must work:

| Shape | Example | What it needs |
|---|---|---|
| **One repo, many tasks at once** | A monorepo; three agents on three tickets | One isolated copy per task |
| **One ticket across many repos** | An estate of 15 repos; one change made in 7 of them, a ticket per repo, base `staging` in one repo and `main` in the rest | A copy only of the repos touched, each on its own base, all in one place |
| **One ticket, agents working together** | A backend and a frontend repo; one agent per repo; the frontend needs the backend's answer shape and the backend running locally | Agents that share a ticket, write different repos, talk to each other, and run servers without port clashes |

The home screen does not help either. It lists *Running* conversations, *Tickets in flight* and
*Continue* side by side, for one project, with no branch, no repo, and nothing saying which
conversation belongs to which ticket or what a conversation is.

## Decided by the operator

1. **(2026-10-29, earlier)** A worktree is made at a conversation's first edit or branch switch, not
   before. If the checkout it needs is held by an **idle** conversation, it **takes it over**; if the
   holder is **working**, it **branches off**.
2. **(2026-10-29, earlier)** Messages between conversations are **information only, never approval**.
3. **(2026-10-29)** Plan for all three shapes above: monorepos, tickets spanning many repos, and
   agents working together across a frontend and a backend.
4. **(2026-10-29)** A workspace is one piece of work, usually one ticket: it may carry no ticket, or
   several (a change with a key per repo is one workspace carrying every key).
5. **(2026-10-29)** Revisit the home screen: it must say what a conversation is, which worktree it
   works in, how to switch, and where tickets in flight stand.
6. **(2026-10-29)** The operator can move a conversation to another workspace (**Move to
   workspace…**, `conversation_move {workspace}`) while it holds no checkout; one that holds a checkout
   branches off instead, so no change is stranded.
7. **(2026-10-29)** **Main is for asking and reading; real work is a workspace.** Any number of
   conversations can read in Main, but no agent writes there: a conversation's first change moves
   it into a new workspace with a worktree. The operator's own folders change only by the
   operator's hand or **Bring to Main**.
8. **(2026-10-29)** Starting a ticket whose branch is checked out in Main **takes the branch from
   Main**: Main's folder goes back to its base, its uncommitted changes carried into the worktree
   (*Where a conversation starts*).
9. **(2026-10-29)** A branch-off is a **child workspace** linked to its parent: it carries the same
   ticket(s), so the Ticket view, ⌘P `#` and the needs-you count cover both; the home screen draws
   it under its parent. Its branch, checkouts, ports, PRs and Archive are its own; archiving the
   parent leaves the child, then drawn on its own.
10. **(2026-10-29)** Branch names follow the operator's **branch instructions**, a fourth text beside
   General, Commits and Pull requests in the agent instructions settings (organization, then
   project; Decision 45). *Refined 2026-10-30:* they also say which base to branch from, and the
   agent starts its copy from it with `workspace_start` (amendment below).
11. **(2026-10-29)** **Archive is offered, never automatic.** It snapshots uncommitted work, removes
   the worktrees and keeps the branches; Restore brings all of it back. The card offers Archive once
   every PR of the workspace is merged. No count cap, no age sweep.
12. **(2026-10-29)** **The app runs in its worktree.** Each repo declares a **run** command; the card
   and the agent start and stop it there on the workspace's ports. The agent runs only that
   declared command (any other stays a proposal for the operator's Enter). **Bring to Main** stays
   as an escape hatch in the card's ⋯ menu for apps tied to one folder.
13. **(2026-10-29)** **Wakil helps write how a repo runs**: setup, docker services, serving,
   building, for frontends and backends in any stack. It detects what it can from the repo's files,
   a conversation drafts the rest from the repo's docs, and **Try** proves it in a throwaway
   workspace before the operator saves it.
14. **(2026-10-29)** **Recipes are shared across repos**, with per-repo overrides; **shared services**
   run once per workspace for the repos that need them; **ports are per checkout**, with
   `WAKIL_PORT_<REPO>` to reach another repo of the same workspace; **Draft all** proposes the
   recipes for a whole project at once.
15. **(2026-10-29)** **Env variables per recipe or per repo**, secrets in the Keychain, with an
   opt-in to write them into the worktree's `.env`.
16. **(2026-10-29)** Message-woken turns: **8 per operator message per workspace by default**, a
   setting per organization with a project override; 0 turns waking off.
17. **(2026-10-29)** **Start one agent; it proposes teammates.** An agent can propose a teammate for a
   repo; the operator starts it with one click. **One per repo** stays in the Start box for when the
   split is known; an agent with nothing to do says so and ends.
18. **(2026-10-29)** **The home screen is per organization**, grouped by project, the current one
   first; pills filter to one project instead of a separate project page; cards that need the
   operator, then working ones, then the rest.
19. **(2026-10-29)** **⌘N is the only new-conversation shortcut.** It starts in Main of the project
   the composer names; with several projects the composer is a picker, pre-set to the current one,
   to choose before sending.
20. **(2026-10-29)** **A card shows everything**: every repo with its branch and every
   conversation, wrapping onto more lines; no cap, no "+N more", no scroll inside a card. The home
   screen scrolls as a whole; the order keeps what needs the operator on top.
21. **(2026-10-29)** The help line ("A conversation is one agent and its thread…") shows in full while
   the home screen has three cards or fewer, and as an **ⓘ** beside "Work in …" once it is busier.
22. **(2026-10-29)** **Every workspace has a view, Main included; a conversation is optional in it.**
   A view is the workspace's canvas of panes over its checkouts (Main's: the operator's own folders
   in the project + environment). The operator opens a view from its card, a project's **Open**, or
   ⌘P, and uses panes with no agent; typing in its composer starts a conversation there. **Panes
   belong to the workspace, not the conversation**: its conversations share them, and switching
   between them swaps only the thread. Main stays the operator's own folder (git's main worktree),
   never a copy Wakil keeps. This replaces the conversations design's call 2b (a canvas per
   conversation). When a conversation's first change moves it out of Main, the new workspace's view
   starts as a copy of the layout it was in: the editor reopens the same files in the copy, data
   panes come along, and terminals stay in Main's view (the new view opens its own in the copy).
23. **(2026-10-29)** **Sending from the home screen goes straight to work**: the screen switches to
   the chosen project and environment, into Main's view (its panes as the operator left them), with
   the new conversation's thread in it. No agent is needed to open panes there.
24. **(2026-10-29)** **Tickets not started here**: a short section after the cards, tickets in flight
   in the organization with no workspace yet (a review requested, a ticket assigned), needs-you
   first, each with **Start**; nothing capped.
25. **(2026-10-29)** **Earlier** replaces Continue: one folded line at the bottom; unfolded, archived
   workspaces (each with **Restore**) and past conversations grouped by workspace, newest first.
   ⌘P searches it too.
26. **(2026-10-29)** **The Open column is dropped** from the home screen: panes open in a workspace's
   view. The empty first-run screen keeps one line, *"Open a pane: Database · Terminal · Browser"*,
   which opens Main's view with that pane.
27. **(2026-10-29)** **⌘P groups Running by workspace** (Main included); workspaces are rows of their
   own (Return opens the view); Earlier follows, searchable; `#` lists tickets in flight, and a
   ticket with a workspace opens that workspace's view.
28. **(2026-10-29)** **A workspace belongs to one environment**: the one it started in, kept in its
   record and shown on its card (red when production). The view's header can change it, which moves
   its data panes, Run's price and new conversations; running conversations keep the environment
   they started in (Decision 41's pin). Switching the screen's environment never moves a workspace.
   Main has one view per environment, as places do today.
29. **(2026-10-29)** **A slot for ticket work's steps row.** A ticketed workspace's card keeps room on
   its PRs line for the current step in words (`7 PRs open · checks 5/7 · Build 4/9`), and its
   view's Ticket header for the full row. Nothing fills them until ticket work piece 4.


## The model

Four words, added to the glossary (north-star §9):

- **Workspace.** Where one piece of work happens inside a project, in one environment: a name, zero or more tickets, a
  **checkout** of each repo it has changed, a **view** (its panes), and the conversations working in
  it. Made by Wakil, except Main.
- **Main.** The project's own folders, as registered (git's main worktree of each repo), in the
  place's environment. It is a workspace for viewing, asking and reading, and where the operator
  works by hand. **No agent writes in Main** (decision 7).
- **Checkout.** One repo's working folder inside a workspace other than Main: a git worktree Wakil
  made. **Held** by at most one conversation at a time, for writing. One per repo per workspace;
  any number of workspaces per repo.
- **View.** A workspace's canvas of panes over its checkouts (Main's: over the operator's folders).
  Panes belong to the workspace; its conversations share them; a conversation is optional
  (decision 22).

```
Organization
 └─ Project  (N repos — Invariant 7's roots)
     ├─ Main                     your folders · its view · conversations that have changed nothing
     ├─ Workspace "INI-142 Login rate limit"
     │    ├─ tickets INI-142 (+ more)
     │    ├─ checkouts  api → worktree on INI-142-login-rate-limit   ports 41200–41209
     │    │             web → worktree on INI-142-login-rate-limit   ports 41210–41219
     │    ├─ view (panes)
     │    ├─ conversations "backend" (holds api) · "frontend" (holds web)
     │    └─ child "Try a token bucket" (branched off; same tickets)
     └─ Workspace "Fix OTP guard order" (no ticket)
```

**Shapes, mapped:** a monorepo task is a workspace with one checkout; two tasks on one repo are two
workspaces. An estate ticket is one workspace with checkouts in the 7 repos it changed and none in
the other 8. A frontend/backend ticket is one workspace whose two conversations each hold a
different repo, talk through messages, and run servers on their own ports.

### How a write finds its checkout

A conversation C writes in repo R — any file write, create, move or Move to Trash; stage, unstage,
discard, commit, amend, undo; stash, merge, rebase, resolve; branch switch or create:

0. **C is in Main** → Wakil makes a new workspace for it (named after its ticket, else its title),
   moves C into it, and goes on at 2. The worktree starts **from the commit Main's folder of R is
   on**, on the workspace's own branch, so the agent sees what the operator sees; uncommitted
   changes in Main's folder are not carried. The thread says: *"Started workspace ‘Fix OTP guard
   order’ — a copy of core on `fix-otp-guard-order`, from the commit your folder is on. Your folder
   is untouched; your 2 uncommitted changes there are not in the copy."*
1. **C's workspace W has a checkout of R.** Free, held by C, or held by an **idle** conversation → C
   takes it (*"Took over api from ‘backend’ (idle)."*). Held by a **working** conversation → C
   **branches off**: a child workspace of W (decision 9) with a checkout of R on a new branch off
   that branch's tip; C moves into it, and its thread says so.
2. **W has no checkout of R** → Wakil makes one in W: a worktree of R on the workspace's branch,
   from R's base (or, from step 0, from Main's commit), and C takes it.
3. **Reads** use W's checkout of a repo when it has one, and Main's folder when it has not.

**Idle** is the states *idle*, *done* and *failed*; *working* and *waiting* are working. A branch
switch to a branch checked out in another checkout follows the same rule (taken over or branched
off; git's "already checked out" never reaches anyone).

### Where a conversation starts, and where the screen goes

- **⌘N** (the only shortcut) brings the operator to the home screen with the composer focused,
  naming the current project and environment; with several projects it is a picker (decision 19).
  **Sending** switches the screen to that project and environment, into **Main's view**, with the
  new conversation's thread (decision 23).
- **Start on a ticket** (the home screen's ticket row, Hand to agent, ⌘P `#`): in that ticket's
  workspace, made if missing (a record only; checkouts come at the first write), from each repo's
  base. If the ticket's branch is checked out in Main's folder, the first write **takes it from
  Main** (decision 8): Main's folder is switched to its base, its uncommitted changes carried into
  the worktree (the existing switch's `carry: bring`), and the thread says so. If Main's folder
  cannot switch (a conflict), the write is not made and the reason is shown whole. Start does not
  move the screen.
- **New conversation here** (a card's hover, or a view's composer): in that workspace.
- **Move to workspace…** (decision 6, `conversation_move {workspace}`): while the conversation holds
  no checkout.

## The pieces, in build order

### 1. Workspaces, checkouts and views

- The model and the write rule above; `workspace_*` and `conversation_move` actions; child
  workspaces from branch-offs.
- **The agent sees real paths.** Its instructions and `session_list` give its workspace's map —
  each repo, the checkout's path (or Main's folder for repos it has not changed), its branch, its
  ports — and the other conversations of the workspace with their repos and states. A path in
  Main's folder of a repo the workspace has a checkout of is translated to that checkout, both
  ways; the answer names the real path. Built-in tools are refused (`permissionDecision`), so every
  write is a Wakil action and passes the rule.
- **Where:** `~/.wakil/orgs/<org>/workspaces/<project>/<workspace slug>/<repo folder>` (Invariant 4);
  `git worktree add`, so git and terminals know them.
- **Branch and base** (decision 10). A workspace has one branch name, drafted when it is made by a
  quick task (the ✨ commit draft's path, Decision 42) from the **Branches** instructions
  (organization, then project), the ticket's key and title or the conversation's first message,
  and the repo's recent branch names. Fallback when there are no instructions or the draft fails or
  is slow: `<KEY>-<slug of title>` or a slug of the title. The agent also gets the Branches text, so
  it can rename once it knows the work (`editor_changes_branch_rename`). A child adds
  `--<2 characters of its conversation id>`, lengthened until unused. Each repo has a **base** in
  `project.json` (default: the remote's default branch, fetched first). Within one workspace, a
  second branch of a repo (another base, a backport) is the existing switch / branch create in its
  one checkout.
- **The record:** `~/.wakil/orgs/<org>/workspaces.json` — each workspace: name, environment, tickets, parent,
  checkouts (repo, path, branch, base, port block, last holder's lineage root), view layout,
  archived state, snapshots. Only worktrees in this record are ever touched. An unreadable file is
  never written over; the failure is shown whole.
- **Views** (decision 22). Each workspace's canvas is filed under the workspace (replacing the
  per-conversation `LayoutScope` of the conversations design, call 2b). Files, Search, Changes,
  Ticket, Ghost text and new terminals read the view's checkouts. The view's top line names the
  place and workspace (*initech · estate · staging › Fix OTP guard order*); the editor and each
  terminal carry a tag, **Main · your folder** or **workspace copy**; a strip lists the
  workspace's conversations. Switching conversations within a workspace swaps only the thread.
  When step 0 moves a conversation out of Main, the new view starts as a copy of the layout it was
  in: the editor reopens the same files in the copy, data panes come along, terminals stay in
  Main's view and the new view opens its own in the copy.
- **Archive** (decision 11, `workspace_archive`): refused while a conversation in it is working,
  with the reason; asks only when one is waiting on the operator (Rule 1). Runs the recipe's
  `teardown`, stops its processes. Each checkout with nothing uncommitted is removed; one with
  changes is **snapshotted first** (`git stash create`, kept as `refs/wakil/snapshots/<workspace>/<repo>`)
  and then removed. Branches stay. **Restore** brings the workspace back; a checkout is re-made at
  its next write, its snapshot re-applied. Offered on the card when every PR of the workspace is
  merged; never automatic; no count cap, no age sweep. A child outlives its archived parent.
- **Bring to Main** (`workspace_bring_home {repo}`), in the card's **⋯** menu: for an app tied to one
  folder, switches Main's folder of a repo to the workspace's branch; the worktree is snapshotted
  and removed first, its uncommitted changes carried by `carry: bring`. Refused while a conversation
  of the workspace is working on that repo, with the reason. The repo then shows **in Main** on the
  card; an agent's next change to it makes a fresh worktree and takes the branch back (decision 8's
  rule).

### 2. Running the app

**Recipes, shared** (decisions 13–15; mockup `settings.html`). A project's **Running** settings list
every repo grouped by the **recipe** it uses. A recipe is written once in `project.json`
(`"recipes": {"laravel-sail": {…}}`); a repo names its recipe and stores only what it overrides. A
repo can be marked **doesn't run**. With one repo the list collapses to the one form. Shared fields
show grey, a repo's own in violet; each field says where it came from.

| Field | What it is | Example |
|---|---|---|
| `needs` | Other repos or **shared services** started first (a shared service is a recipe with only `services`, run once per workspace for every repo that needs it) | `core-db`, `api` |
| `ports` | Map the repo's own port variables to Wakil's, so a compose file that already reads a variable is not rewritten | `APP_PORT → $WAKIL_PORT`, `VITE_API_URL → http://localhost:$WAKIL_PORT_API` |
| `env` | Variables for every command of the repo, in every workspace; values may use `$WAKIL_*`. A **secret** is stored in the Keychain (`wakil:<org>:<ref>`), never in `project.json` or a log, filled in at run time. **Also write to .env** adds the lines to the worktree's `.env` (ignored by git); Main's `.env` is never touched | `QUEUE_CONNECTION=rabbitmq`, `STRIPE_SECRET` 🔒 |
| `copy` | Ignored files copied from Main's folder (gitignore globs; default `.env*`; `.worktreeinclude` read too) | `.env`, `config/local.php` |
| `clone` | Heavy ignored folders cloned copy-on-write (APFS `clonefile`; never symlinks) | `node_modules`, `vendor` |
| `services` | Started once per workspace before the app | `docker compose up -d mysql redis` |
| `setup` | Run once in a new worktree | `composer install && php artisan migrate` |
| `processes` | The app: named long-running commands, each in its own terminal | `api: php artisan serve --port=$WAKIL_PORT` · `queue: php artisan queue:work` |
| `build` | A one-shot build | `pnpm build` |
| `ready` | How Wakil knows it is up: a URL that answers, or a line in the output | `http://localhost:$WAKIL_PORT/up` |
| `teardown` | Run when services stop or the workspace is archived | `docker compose down` |

**Ports.** Each checkout gets a block of ten: `WAKIL_PORT`, `WAKIL_PORT_1` … `WAKIL_PORT_9` are its
own; `WAKIL_PORT_<REPO>` (upper-cased folder name) is another repo's first port in the same
workspace. `WAKIL_WORKSPACE`, `WAKIL_REPO` and each checkout's path are exported too. Blocks are
handed out from 41200 upward, skipping any port already listening, and kept in `workspaces.json`.
Main gets none.

**Docker.** Compose runs with `COMPOSE_PROJECT_NAME=<workspace slug>-<repo>`, separating containers,
networks and volumes. Fixed published host ports are remapped into the block by a generated
override (`.wakil/compose.ports.yml` in the worktree, ignored by git, using compose's `!override`).
A compose file with fixed `container_name`s cannot run twice: the recipe says so and points to
Bring to Main for that repo.

**Wakil drafts the recipe.**

0. **Draft all** (many repos): reads every repo, groups alike ones under one recipe, finds shared
   services (a database several repos' `.env.example` point at), and lists what it could not
   decide as questions.
1. **Detect** without a model, from the repo's files:

   | Found | Means |
   |---|---|
   | `package.json` + `pnpm-lock.yaml` / `yarn.lock` / `bun.lockb` / `package-lock.json` | that package manager; `dev`, `start`, `build`, `serve` scripts become processes and build; `node_modules` cloned |
   | `vite.config.*`, `next.config.*`, `nuxt.config.*`, `angular.json`, `svelte.config.*` | the framework's dev server and its port flag |
   | `composer.json` + `artisan` | Laravel: `composer install`, `artisan serve --port`, `queue:work` if queues are configured, `vendor` cloned; Sail's port variables |
   | `composer.json` + `yii` | Yii: `composer install`, `yii serve --port` |
   | `Gemfile` + `bin/rails` | Rails: `bundle install`, `bin/rails server -p` |
   | `pyproject.toml` / `uv.lock` / `poetry.lock` / `requirements.txt`; `manage.py`; FastAPI/Flask entry | uv/poetry/pip; Django `runserver`, `uvicorn --port` |
   | `go.mod`; `Cargo.toml`; `mix.exs`; `pom.xml` / `build.gradle`; `*.csproj` | `go run`, `cargo run`, `mix phx.server`, `./mvnw spring-boot:run` / `./gradlew bootRun`, `dotnet run` |
   | `docker-compose.yml` / `compose.yaml`, `Dockerfile` | services vs the app's own container; port variables, fixed ports and `container_name`s noted |
   | `Makefile`, `justfile`, `Taskfile.yml`, `Procfile`, `bin/dev`, `scripts/*` | the repo's own entry points, preferred over guesses |
   | `.nvmrc`, `.tool-versions`, `mise.toml`, `.python-version`, `.ruby-version` | the runtime version, through the manager the operator has (mise, asdf, nvm) |
   | `.env.example` / `.env.dist` | `copy`, and keys a `.env` lacks (offered as `env`) |
   | `README`, `CONTRIBUTING`, `docs/` | read in step 2 |

2. **Draft:** a conversation in Main (reading only) gets the detected facts, the docs and the rules
   (every port through `$WAKIL_PORT…`, the repo's own scripts first, databases and queues in
   `services`) and returns the recipe as a draft in the form. Nothing is saved until the operator
   saves it (Rule 9).
3. **Try:** a throwaway workspace runs services, setup and processes, waits for `ready`, and reports
   each step, passed or failed with its output whole; on a failure the drafting conversation
   proposes a fix. Try's workspace is archived when the form closes. Cancel stops it (Rule 4).

**Run, Stop, Build** (`workspace_run {repo, process?}`, `workspace_stop`, `workspace_build`): the
card's **▶ Run** starts `needs` and services once, then the processes, in the view's terminals; the
card shows `api running on :41200 · queue running` with **Stop**. Output is a terminal pane the
operator and the agent read (`read_pane`).

**The agent runs only the saved recipe** (decision 12). The three actions are agent-reachable: on
"run it", or to check its work. Any other command stays a `term_propose` for the operator's Enter.
Price: *control* outside production, *gate* in a production place (Invariant 8). This is a new
earned write under Invariant 6, recorded in Decision 94: *run the operator's saved recipe in a Wakil
worktree*; refused: any command not in the recipe, and editing the recipe.

**A recipe that fails in use** (setup, a process, `ready` timing out) shows the error whole on the
card and in the thread of the conversation that started it, so it fixes what is in its reach or
says why it cannot. It never blocks the write that made the worktree (Rule 8).

#### Amendment 2026-10-29: piece 2's Go core

What building the Go side settled (plan `docs/superpowers/plans/2026-10-29-workspaces-2-running.md`):

- **Shape in `project.json`.** `recipes` by name; each root carries `recipe`, `overrides` (a recipe
  whose absent fields inherit) and `doesntRun` beside its `path`. `processes` is an ordered list of
  `{name, command}`; `services`, `setup`, `teardown` are lists of commands; `build` one command;
  `ready` is `{url}` or `{output}` (a substring or `/regexp/`) with `timeoutSeconds` (default 120).
  An env value is a string or `{"secret": "<ref>"}` (Keychain `wakil:<org>:<ref>`). A shared
  service names the repo its commands run in with `in`. `notes` keep, per field, where a value came
  from. A repo's name is its folder's.
- **Merge.** Lists and single values replace; `ports`, `env` and `notes` merge per variable;
  processes merge by name, and an override's empty command removes a shared one. Validation lists
  every problem whole; a name Wakil exports (`WAKIL_*`, `COMPOSE_*`) cannot be set by a recipe.
- **Env.** Besides the ports, `WAKIL_DIR` and `WAKIL_DIR_<REPO>` (each repo's folder: its checkout,
  or Main's), and `COMPOSE_PROJECT_NAME`. Two folders that sanitise to one `<REPO>` are refused.
- **Compose.** The override is attached by `COMPOSE_FILE` (the repo's file, its own override file,
  then `.wakil/compose.ports.yml`), so `sail` and `docker compose` in the recipe pick it up as
  written. Fixed ports take the block offsets the recipe's `ports` leave free.
- **Draft all.** A shared service is proposed when two or more repos' example env files point at a
  host another repo's compose file defines; it is named `<repo>-services` and runs there. A host no
  compose file defines becomes a question.
- **Runtime versions.** With mise (or asdf for `.tool-versions`, nvm for `.nvmrc`) on the machine,
  the draft's setup starts with its install; without one, a question.
- **Where.** The tools are on `wakil-ctx` (window-owned, not agent-facing); the agent reaches running
  only through piece 2's Swift actions. `recipe_ready_wait` polls loopback URLs only.

#### Amendment 2026-10-30: piece 2's Swift half

What building Run, Stop, Build, Try and the Running settings settled (plan, part two):

- **One-shot steps run headless, processes in terminals.** Services, setup, build and teardown run
  in Go (`recipe_run_steps`: the operator's login shell, output whole, cancellable) so a failure is
  shown whole (Rule 8); each process gets a terminal pane `<repo> · <process>` in the workspace's own
  view, opened unfocused wherever the screen is (Rule 6), with the plan's env and secrets. Files,
  copy, clone and `.env` are Go's (`recipe_prepare`).
- **Once-ness.** Needs and services run once per workspace per app session (kept in memory: a compose
  `up -d` is safe to repeat); copy, clone and setup once per checkout, recorded as the checkout's
  `setUp` in `workspaces.json`. Ports are allocated at the first Run or Build, not at the checkout's
  making.
- **A repo with no copy is not run** (decision 12): Run is refused naming the decision, and from Main
  the agent's call is refused (Main has no ports). A need on a repo without a copy is refused the same
  way.
- **Stop with no repo** closes every process and runs each started repo's and shared service's
  teardown; Archive calls it first (the router's run hook).
- **Agent reach.** `workspace_run`, `workspace_stop`, `workspace_build` and the read
  `workspace_running` are agent-reachable in the agent's own workspace only; the run three are
  `.mutate` priced *allow* outside production, *gate* in it. The `running_*` actions are operator-only.
- **Secrets** are typed in the Env row and kept by `recipe_secret_set` under
  `run:<project>:<owner>:<VAR>`; a step's output has their values masked.
- **Try's workspace** is a record named *Try <repo>* on a `wakil-try/<slug>` branch; ending it (the
  form closing, another Try) archives and forgets the record. The branch stays, as Archive keeps
  branches. *(Superseded by the amendment of 2026-11-01: the Try itself removes it, branch too.)*
- **Not built here:** the card's ▶ Run / Stop and its run line (piece 3 draws `runStatusLine` and
  calls the actions). The drafting conversation and Try's fix: the next amendment.

#### Amendment 2026-10-30: piece 2's drafting conversation and Try's fix

- **When a conversation drafts.** Detect's draft is incomplete when the repo runs and the draft asks
  a question or starts no process. Then Wakil starts a conversation in Main of the project — off
  screen, so the operator stays in the settings (Rule 6), with its chip — titled *Draft how
  `<repo>` runs*. Its first message carries Detect's facts whole (Go's `Draft`), the docs to read,
  the rules (ports through `$WAKIL_PORT…`, the repo's own scripts first, databases and queues in
  `services`, change nothing) and how to answer. Detect's own draft shows meanwhile. Main's place is
  the screen's when the project is on screen, otherwise the project's first non-production
  environment. One conversation per repo per app session; Detect again drafts in the same thread.
- **How it answers.** `running_draft_propose {repo, recipe, recipeName?, questions?, doesntRun?,
  why?}`: agent-reachable, `.control`, pre-approved — it writes nothing; the recipe lands in the
  form under the repo as *Drafted in ‘…’* with Save / Discard (Rule 9). Only the conversation Wakil
  started for that repo may call it; anyone else is refused naming decision 13. A turn that ends
  without a proposal is said whole in the form (Rule 8); **Stop** ends the conversation (Rule 4).
- **Try's fix.** A Try that fails (not cancelled, not refused) sends that conversation — started
  first when there is none — every step, the failing one's output whole, and the recipe as tried.
  Its answer shows as *Fix proposed by ‘…’*. A repo on a shared recipe saves a draft or a fix as its
  own overrides (only what differs), so one repo's fix never changes the others; a repo with no
  recipe gets a new one, as Detect's draft does.

### 3. The home screen and ⌘P

Replaces the Landing's columns (Running, Tickets in flight, Continue, Open). Mockup: `home.html`.

- **One home per organization**, *"Work in <organization>"* (decision 18), grouped by **project**: the
  current project first (marked *you are here*), then others by latest activity; a project with
  nothing going on is not drawn. Within a project: Main while a conversation is in it (its repos'
  branches only where the operator has changes), then cards that need the operator, then cards
  with an agent working, then the rest by latest activity.
- **Pills** (*All projects* · each project with its needs-you count) filter the same screen; they
  never choose where work starts. **A project's header**: its name makes it the current project (a
  place switch; the composer follows); **Open** opens Main's view.
- **A card** (decision 20): name (ticket key and title, or its first conversation's title); every repo
  with its branch, or **in Main** after Bring to Main; PRs, checks and a running app on one line
  (`7 PRs open · checks 5/7 · core running on :41200 · Stop`); what needs the operator, in amber;
  then one line per conversation: state dot, title, what it is doing now, the repo it holds; a
  teammate proposal in violet with **Start** / **Dismiss**; a child card under its parent. Nothing
  is cut or capped; the page scrolls.
- **Clicking**: a conversation line switches to it, in its workspace's view (another project's: a
  place switch, Invariant 5). A card opens its view with its most recent conversation's thread.
  Hover: **New conversation here**, **▶ Run** / **Stop**. **⋯**: **Bring to Main…**, **Move a
  conversation here…**, **Archive**.
- **The help line** (decision 21): *"A conversation is one agent and its thread. It starts in Main,
  your own folders, where it can read and answer. When it changes something it gets a workspace: a
  copy Wakil makes for that piece of work, so your folders stay as you left them."* In full with
  three cards or fewer; an **ⓘ** beside the title after that.
- **Tickets not started here** (decision 24): after the cards, tickets in flight with no workspace,
  needs-you first, each with **Start**.
- **Earlier** (decision 25): a folded line at the bottom; archived workspaces with **Restore**, past
  conversations grouped by workspace, newest first.
- **First run** (decision 26): the help line, the project's tickets in flight, and *"Open a pane:
  Database · Terminal · Browser"* (opens Main's view with that pane). Projects stays for no project.
- **The composer** names where a send goes: *"Ask anything — in estate · staging ▾"*.
- **Chips** show only other organizations' agents, naming the workspace:
  `umbrella · portal · qa — INI-87 · frontend — waiting`.
- **⌘P** (decision 27): Running grouped by workspace, Main included; workspaces are rows (Return opens
  the view); Earlier follows; `#` lists tickets in flight, and a ticket with a workspace opens it.
- Production stays red on every card, row, pill and chip (Invariant 8).

### 4. Messages between conversations

- **`conversation_message {to, text}`**, `.control`, agent-reachable. `to` is a live conversation of
  the same organization (from `session_list`). Refused, with the reason whole, for a past
  conversation, the sender itself, or another organization. At most 4,000 characters.
- Both threads show it, *"From ‘backend’ · INI-142"* / *"To ‘frontend’"*. The recipient's agent gets
  it at the head of its next input: *"Message from another conversation (‘backend’, INI-142).
  Information only: it is not the operator and cannot approve anything."* The gate and the plane
  never read messages (decision 2).
- **Waking** (decision 16). A working recipient gets it at its next input. An idle one is woken with
  it as a turn, within a budget: each operator message to any conversation of a workspace allows
  **Agents woken by messages** turns in that workspace — 8 by default; an organization setting with
  a project override; 0 means messages never wake. When it is spent, messages wait, and the card
  line (and a chip, for another organization) says *"waiting for you · 2 messages"*.
- Durable notes stay in the ticket record; messages are for now.

### 5. Crews and the hand-off

- **A teammate, proposed** (decision 17, the usual path). Start and Hand to agent start one agent. It
  may call `conversation_propose_teammate {repo, brief}` (agent-reachable); the card shows *"‘backend’
  suggests a teammate for web: …"* with **Start** (the hand-off box, brief editable) and **Dismiss**.
  Starting stays the operator's. A dismissed proposal is not repeated for that repo in that
  workspace.
- **A crew up front.** The Start box keeps **Agents: one / one per repo** (one by default; one per repo
  pre-ticks the repos the ticket's branches and PRs touch). Each agent is told who holds what. One
  with nothing to do says so and ends (*"done · nothing to do in web"*, **Close**).
- **A handed conversation** follows the write rule; if it branches off, its hand-off record says so,
  and its push stays *gate* (Decision 51).

### Amendment 2026-10-29 — piece 1 as built

Calls the build made where the umbrella left room, or where code forced a refinement:

- **The decision number is 106**, not 94: `decisions.md` already runs to 105 on `main`.
- **The record is Go's** (`internal/wakilcore/workspaces.go`), reached through wakil-git's
  `workspaces_read` / `workspaces_write` (the window's copy only), because Go's confinement
  (`AllowedRootPaths`, in `wakil-git` and `wakil-files`) must admit a recorded checkout and nothing
  else. Each workspace also records an `id`, a `slug` and its `conversations` (lineage roots), so a
  resumed conversation goes back to its workspace and pieces 3–5 can name a past one's.
- **Snapshots never touch the shared stash list**: a stash-shaped commit (`git stash create`, plus an
  untracked parent built in a temporary index) under `refs/wakil/snapshots/<slug>/<repo>`, put back
  with `git stash apply <sha>`. Take-from-Main carries Main's work the same way
  (`refs/wakil/carry/…`), and puts it back in Main's folder on any failure.
- **A switch to a branch another folder holds**: an idle or absent holder lets go of it (a checkout
  detaches, keeping its files; Main's folder goes back to its default branch with its changes); a
  working holder makes the switch a new branch `<branch>--<id>` off its tip in the switcher's own
  checkout. The thread says so. No child workspace for a switch: the switcher already has a checkout.
- **Move to workspace…** is refused, naming decision 6, for a conversation holding a checkout,
  rather than branching it off: a branch-off needs a write to branch from.
- **An agent's replace across files** (`editor_replace` with no `file`) covers only its workspace's
  copies; with none yet it is refused naming decision 7, and a named file starts the workspace.
- **Views, as far as built**: a conversation in a workspace has the workspace's view (filed as
  `workspace-<view key>`), shared by the workspace's conversations; step 0 carries the canvas the
  conversation was on into it when it is on screen, terminals excepted (amendment 2026-10-30, the
  three items). **Main's view is still per
  conversation** (the conversations design's call 2b) until piece 3 gives Main's view a door with no
  conversation; an off-screen conversation moved by step 0 opens its new view empty.
- **Environment** (decision 28): the workspace records the environment it started in;
  `workspace_set_environment` (operator-only) changes it; its data panes follow (amendment
  2026-10-30, the three items).
- **Branch name draft** waits 4 s for the ✨ quick task, only when Branches instructions exist and
  commit drafts are on; otherwise the fallback name.

### Amendment 2026-10-30 — piece 1's e2e run

- **The rule applies to a conversation whose agent runs** (a harness, or a session start in flight).
  A place's conversation minted by a pane or a row, with no agent ever started, holds nothing and
  made no write: a dispatch naming it lands where it was aimed, as the operator's does. The seeded
  e2e checks dispatch as exactly such a conversation, so their parity halves still meet in Main's
  folder; `e2e/checks/agent/` checks, whose scripted agent runs, see the rule.
- **A root that is not a git repository has no copy**, and no agent writes in Main (decision 7): an
  agent's write there is refused whole, naming decision 7 and asking for the operator's hand or a
  `git init`, before any workspace is made. The operator's own writes there are unchanged.

### Amendment 2026-10-30 — piece 1's three remaining items

- **Terminals at step 0** (decision 22, call 9). The terminals on the canvas step 0 carries do not
  go with it: each one — its shell, history and frame — stays in **Main's view**, which in piece 1
  is the canvas the place's Landing draws over (the id it reserves for its next conversation, so
  the next conversation started there takes them; piece 3's Main view adopts that same canvas). In
  each one's place the workspace's view opens its own terminal in the copy: same frame, links and
  focus, a new id, at the old path translated into the copy, else the view's first copy. New
  terminals in the view open in the copy (already built). An off-screen conversation's view opens
  empty, as before.
- **Data panes follow the environment** (decision 28). `workspace_set_environment` (which now takes
  the workspace's id or its slug) tells the window once the record is saved. The view's database and
  api panes leave the view in the old environment for the view in the new one, frame and subject
  kept; their rows and replies, which describe the old environment, are dropped, and each subject
  re-runs when the new view is shown (at once if it is on screen). A running conversation keeps its
  environment (Decision 41's pin) and so its view there, editors and terminals included.
- **The map in the instructions** ("The agent sees real paths"). Every conversation's turn carries
  its map — on its session's first turn and whenever the map changed — as a block marked
  *[Wakil: where you work. …]* **after** the operator's words, as the identifier note is, so the
  words stay what a session is listed by (`firstPrompt` drops the block) and what the e2e stub
  matches. A resumed thread's operator rows drop it too (`session_read`'s user entries): the
  operator's rows show only the operator's words. A workspace's map: each repo's copy (path, branch, ports, holder) or Main's folder, and
  the workspace's other conversations with their states and repos. **Main's map**: Main's folders
  with their branches, the other conversations in Main, and the project's workspaces — each one's
  copies, branches, ports and conversations — which it reads but never writes. Sent only by a window
  the write rule is wired into; the launch prompt is unchanged (it is per project, the map per
  conversation).
### Amendment 2026-10-30 — piece 3 as built

- **A view with no agent is a conversation slot with no turn.** Opening a pane over the Landing already
  minted a conversation with no process; opening a view does the same with no pane. Main's view is the
  project + environment canvas (the seed the Landing drew over); a workspace's is the slot moved into
  the workspace, so its canvas is the workspace's view. **Open** goes back to the place's slot while one
  is live, so Main keeps one view per environment. A slot draws no line on the home: it is a view.
- **`workspace_open {workspace, project?, environment?}`** (`main` or an id) and
  **`workspace_new_conversation {workspace}`**, operator-only `.control`, parked on the conversation
  broker as `session_switch` is. The card, a project's Open, ⌘P's workspace and Main rows dispatch them.
- **The current project is always drawn**, even with nothing going on: its header holds Main's Open and
  *Open a pane: Database · Terminal · Browser* (each opens Main's view with that pane). Decision 26's line
  therefore stands on every day, not only the first run; the Open column stays dropped.
- **Start on a ticket not started here opens the ticket** (`ticket_open`), where Hand to agent starts it;
  a record-only workspace for a ticket comes with crews (piece 5).
- **A card's PRs** are the in-flight rows of its tickets or branches (`2 PRs open · 1 failing`); Archive is
  always in ⋯ (asking only with a conversation waiting, Rule 1). The merged-PRs offer, Main's
  "changed by you" branches and a line's "doing now" wait for reads that carry them (a line says its
  state and the repos it holds).
- **Earlier** lists the current project's past conversations (`session_list` is per project) and every
  archived workspace of the organisation.
- **Identifiers** stay under the `landing` surface (`landing.card.<id>`, `landing.project.<p>.open`, …);
  a conversation line keeps `landing.row.running:<n>`, numbered in drawing order.
- **Not built in piece 3:** chips limited to other organisations' agents, ⌘P `#` opening a ticket's
  workspace, and moving data panes when a workspace's environment changes.

### Amendment 2026-10-30 — piece 3 finished

- **Chips are another organisation's only** (`WindowModel.chips` filters `chipCandidates`). The screen's
  own organisation's conversations, a backgrounded one included, are lines on its home. A chip names the
  workspace by its first ticket key, else its name: `umbrella · portal · qa — INI-87 · frontend`; one in
  Main names none. Its identifier is unchanged (`window.agentChip.<org>/<project>/<env>`).
- **⌘P: a ticket row whose ticket has a workspace opens it** (`workspace_open`), under `#` and under a
  typed key alike, so a row means one thing; its verb says *open workspace*. Its PR rows still open the
  ticket, and ⌘↩ still hands it to an agent. The workspace is the open one carrying the key or working
  on one of the ticket's branches (the card's own rule), a parent before its child, then the newest; an
  archived one is Earlier's, and the ticket opens. A workspace starting reads In flight again, since its
  branch may carry a key (`INI-142-…`): the ticket is then that workspace's, here and on the home.
- **The merged offer** (decision 11): the home reads each open workspace's branch PRs with
  `ticket_branch {root, branch}` (Main's root, the checkout's branch), not waited for, each at most every
  60 s. A card offers *"2 PRs merged — this work is done"* with **Archive** (the ⋯ one: it asks only with a
  conversation waiting) when every branch is read, there is at least one PR, and every one is merged; a
  closed PR is not merged, and a repo with no PR is not one of its PRs. The offer's Archive is numbered in
  drawing order (`landing.archive.offer:<n>`), as a card's id is generated.
- Still not built: moving data panes when a workspace's environment changes (not piece 3's finish list).

### Amendment 2026-10-30 — piece 3 on pieces 1 and 2's finish

- **▶ Run on the card** (piece 2's Run, Stop, Build). A card's hover offers **▶ Run…**: a menu of the
  repos with a copy on disk, each running its saved recipe (`workspace_run {workspace, repo}`, as the
  operator); with no copy it says the app runs in a copy made at the first change. What runs joins the
  PRs line (`1 PR open · api web running on :41200`) with **Stop** after it (`workspace_stop
  {workspace}`: every process, then the teardown). The line follows the runner as it changes,
  whoever ran it — the agent included. The card is disabled while its Run or Stop is in flight (Rule 5);
  a refusal or failure is drawn on the card whole until its next Run or Stop (Rule 8).
- **Main's view takes step 0's terminals** (piece 1's amendment): the canvas of Main's live view slot
  — what the project's **Open** goes back to — else the canvas the home reserves for the place's next
  conversation, which Open adopts.
- Moving data panes when a workspace's environment changes is built (piece 1's three remaining items).

### Amendment 2026-10-30 — the home is the organisation's

Approved by the operator on 2026-10-30; the calls below are the build's.

- **No project and no environment are selected on the home.** It shows every workspace and open
  conversation of the organisation, grouped by project; a project is drawn while something goes on in
  it, by latest activity, and none is pinned first or marked *you are here*. With nothing going on
  anywhere, every project's header is drawn, each with Main's **Open**. A project and an environment
  become selected only by starting a conversation (in Main, or as a new change in a workspace) through
  the composer's **Start in**, or by opening a workspace or a conversation.
- **The context line on the home names the organisation only** — no project, environment, branch or
  workspace, at rest or promoted. *Call:* the environment still reaches the screen on the home through
  **Start in** (red for production), which keeps Invariant 8 where a send would go.
- **What needs a place on the home uses Start in's** (*call*): the window keeps the place Start in
  points at — the last one worked in, pre-set as Rule 9 says — and the rail, ⌘P's sources (files,
  tables, the api entries), the fast path and *Open a pane* read it, exactly as before. A project's
  name on the home points Start in at that project (it no longer reads as *becoming the current
  project*: nothing is current on the home).
- ***Open a pane: Database · Terminal · Browser*** moves under the home's title, drawn every day; it
  opens Main's view of Start in's place with that pane. The header's *⌘N new conversation in Main of
  <project>* is dropped: it named a project.
- **A Home button**: a house at the far left of the context line, before the organisation's name, at
  rest and promoted, on every screen (`window.contextLine.home`). It and **⇧⌘H** (`window.home`, the
  Window menu's *Home*, in the one keymap of Decision 50; no other command holds ⇧⌘H anywhere, and it
  is taken before a browser page) run ⌘N's path, `session_new`: the home, every conversation left
  running where it was. Rules: 6 — it is the operator's own move of the screen, the one thing it does;
  3 — the composer is focused on arrival; 1 — nothing is closed, so nothing asks.
- **The composer on the home**: the placeholder is *Ask, or name what to open* (Start in already shows
  where); the hints keep only *Hold ⌥ to speak* — ⌘P and ⌘K stay in a conversation's hints. Both wrap
  or show whole; nothing is cut.
- Checks: `seeded/workspaces-home-organisation.jsonl` (the line, the hints, Home and ⇧⌘H);
  `seeded/landing.jsonl`, `seeded/2e-ii-rename-active-environment.jsonl` read Start in's place where they
  read the line's environment chip; `seeded/workspaces-home.jsonl` reads no *you are here*. The 2d-ii
  voice checks read *TO SPEAK*, which the home's hint still carries, so they stand unchanged.

### Amendment 2026-10-30 — the home's walk

Approved by the operator's walk on 2026-10-30; the calls below are the build's.

- **Start in moves nothing.** Choosing a row (or a project's name on the home) only sets where the next
  send goes (`WindowModel.homeStartIn`, read by the picker's label): the screen stays on the home and no
  project or environment is selected. The send goes there — the window switches, onto Main's Landing
  (a conversation on screen there goes to the background untouched, as ⌘N puts it) — and the choice is
  spent; a switch refused gives the line back (Rule 2) with its reason in the status line (Rule 8). Any
  other change of screen pre-sets it again (Rule 9). *Call:* the rail and ⌘P keep reading the window's
  place, which Start in no longer moves; *Open a pane* opens Main's view of Start in's place.
- **Every line opens its conversation** (`openHomeLine`): `session_switch` while it is live, else its
  thread through `session_resume`, as Earlier's Continue. A conversation started with no environment
  chosen is reached again: the switch goes to its place exactly, and `set_environment ""` leaves none
  chosen, as a project switch to a project lacking the environment already did.
- **The composer's row never cuts.** The field shrinks to 160 pt first; narrower, Start in and the hint go
  on a line under it, each wrapping whole. **On the home the status line has its own space**: the page
  ends above it, and it stands 4 pt clear of the bar.
- Checks: `seeded/workspaces-home-start-in.jsonl`; WakilKit `HomeStartInTests`.
- **What the home lists.** A conversation is on the home once it has had a turn (a message, a hand-off's
  brief, or a resumed thread) — a session started with none drew an idle *New conversation* in Main.
  Main's lines drop *· read only* (its header says *asking and reading*). A ticket leaves *Tickets not
  started here* once a live conversation carries it: its key in the title as a word, or a hand-off on
  its key or branch. Repeated *Hand to agent* presses each start a conversation of the same title; the
  home lists each (the walk's two "AQ247-141 · Work toward Next." rows were two hand-offs, not a fork).

### Amendment 2026-10-30 — the home, as the comp draws it

The operator confirmed the home brief and approved the comp (impeccable, Operate mode, a refinement
inside `design-language.md`); this is what was built from it.

- **Needs first.** *NEEDS YOU* (drawn only when non-empty) lists one row per workspace, or per
  conversation in Main, that needs the operator: every why it has, strongest first — waiting on you ›
  failed › checks failing *n* › review requested › *n* comments › done, unseen — in its strongest
  why's hue, with that why's one action (Review, Open, checks ↗, review ↗). The row opens what it is
  about. A pill counts its project's rows; the filter narrows NEEDS YOU too (`HomeNeeds.swift`).
- **The organisation's line only.** No *Work in …* title, no help line, no *Open a pane*: a pane opens
  inside a project's view. **A project's name is the door to its Main view** (`workspace_open`); no
  separate Open. Projects with nothing going on fold into one line that names them (`2 quiet projects —
  web · portal`), each name the same door.
- **Compact cards that expand in place.** One line: state dot · key and title · the environment tag
  only when it differs from the project's default (production always, red) · `● n` · `:41200 ■` while
  something runs · ▶ while nothing does and a copy exists · ⌄. Expanded (lifted, not a new slab): the
  repos and their whole branches (`main · not copied` for one never copied), the PRs with checks ↗ and
  what runs, every conversation, the child as a ↳ line, then New conversation here · ▶ Run… · ⋯. A
  child is its own ↳ row under a closed parent. Expansion is the operator's, kept per workspace
  across relaunch (`HomeExpansionStore`, Rule 6). Decision 11's merged offer and a Run error stand
  under the compact row, open or not.
- **Start in is Wakil's own plane**, not an NSMenu: rows grouped by project, *now* and *production*
  tags, production red (Invariant 8); ↑ ↓ Return, Escape closes; a choice sets the target only and
  gives the composer the keyboard back with the draft kept.
- **The explainer shows on the first run only** (an organisation with no project), with *Add a
  project* (`settings_open`).
- **The colours read are asserted**: `HomePalette`, each over the void, a slab and an expanded card's
  lift, ≥ 4.5:1 (`HomePaletteTests`). The working dot holds still under Reduce Motion (`ChipDot`).
- *Calls:* checks failing reads `checks failing 2`, not the comp's `2/7`: the in-flight read carries
  the failing checks' names, not the total. A ticket key in *Tickets* is not a ↗ link: the read
  carries the PR's page, not the ticket's. ▶ shows for a copy on disk, not "a saved recipe": the home
  reads no recipe, and Run on a repo with none says why, whole. *All tickets in ⌘P* left the home
  (⌘P's `#` still lists them).

## Calls made for the operator

1. **"Workspace"** is the name (Conductor and Orca use it too).
2. **The agent sees real paths, and Main's are translated**, so old habits land in the right copy.
3. **A workspace record is made eagerly, its checkouts lazily**: a 15-repo ticket costs nothing
   until a repo is changed.
4. **Step 0 starts from Main's commit**, not the base: the agent keeps what it was reading.
5. **Snapshots instead of keeping dirty worktrees** (Codex's pattern); only Wakil's own worktrees are
   ever removed (Cursor's sweep is the failure to avoid).
6. **APFS clone, not symlink**, for heavy folders (no write-through to Main).
7. **Ports per checkout from 41200**, ten each, stable across runs.
8. **Compose isolation** by project name plus a generated port override.
9. **Terminals stay with the view they were opened in**; editors and data panes follow a conversation
   out of Main.
10. **Invariant 6** — "inside the project's roots" includes their Wakil worktrees (a dated note); the
    one new earned write is running the saved recipe (piece 2).
11. **What gets planned next** is piece 1's own design (the Design rung), then its plan; this umbrella
    is not planned whole.
12. **The operator's hand in a view.** The operator is never a holder: an edit, commit or a terminal
    Enter (including on an agent's proposal) in a view goes to that view's checkout of the repo, even
    one a working agent holds, as two hands in one folder do today; for a repo the workspace has no
    checkout of, it goes to Main's folder, which the editor tags **Main · your folder**. Only an
    agent's write runs the write rule.
13. **An agent writes only in its own workspace.** Its file and git actions are confined to its
    workspace's checkouts (and read Main's folders); a path inside another workspace's checkout is
    refused, naming that workspace — never translated. Confinement becomes per conversation: the
    roots handed to `ConfineFilePath` and the Go clients come from the caller's workspace, not the
    project.
14. **Upgrade.** Every conversation is past after a relaunch, so nothing is held at upgrade. The most
    recently used canvas of each project and environment becomes Main's view; other per-conversation
    canvases are dropped. Uncommitted changes an agent left in Main's folder before the upgrade are
    the operator's folder state now; a resumed conversation's next write follows step 0 (from Main's
    commit, not carried), and its thread says so.
15. **The wake budget resets, it does not add up.** Each operator message sets that workspace's
    remaining message-woken turns back to the setting's value; a child workspace has its own budget.

## What it does not do

- No worktree for a conversation that only reads, nor for the operator, whose hand edits in Main go
  to Main's folders as today.
- No sandboxed agents, containers of Wakil's own, remote machines or cloud runs; docker is only the
  repo's own compose.
- No cross-organization workspace or message; no message that starts a conversation.
- No automatic archive, merge or PR.
- No dependency install of Wakil's invention: `setup` is the repo's own command.
- No free command run by an agent.

## Anti-goals

- A sidebar of workspaces always on screen.
- Losing uncommitted work to any cleanup.
- A home screen longer than today's when only one thing is going on.
- Agents that keep each other running without the operator.

### Amendment 2026-10-31 — entering a project chooses an environment

From the operator's walk: the home selects no environment, and its doors landed in the project with
none chosen — the badge read UNKNOWN and no picker drew, though the project declares `staging` and
`production` (Invariant 8). Calls:

- **Every door from the home into a project lands on one of its environments** when it declares any:
  the one the operator last used in that project this launch, else the one Start in names, else the
  first declared that is not production (Rule 9: defaults suggest); a project declaring only production
  lands on it, red. A Start in row or a workspace naming an environment goes there.
- **A live conversation started with none chosen still opens where it lives** (piece 3 walk): moving a
  live agent's place would change the caller its socket answers for (Invariant 4), which renames refuse
  for the same reason. On its screen the Environment segment offers the project's environments.
- **The Environment segment always offers the declared environments while none is chosen**, its badge
  reading *none chosen*; *unknown* stays only for a project declaring none. The resting badge opens the
  picker too.

### Amendment 2026-10-31 — an environment switch stays in the view

From the operator's walk: in a project's view, choosing another environment on the context line
took the operator to the home. A conversation lives in one place, so the new environment is a place
with nothing on screen, and the home is drawn wherever no work has begun. Calls (Rule 6):

- **The operator's environment switch stays in the view it was made in** — the context line's picker,
  ⌘P's row and the fast path alike. In Main's view, Main's view of the new environment opens as its
  **Open** does (its newest view slot, else one over that environment's canvas); Main keeps one view
  per environment, so its data panes are that environment's and the terminals stay in the view left.
  In a workspace's view, the workspace's view opens there (its newest live conversation in that
  place, else a view slot); the workspace keeps its environment (decision 28: switching the screen's
  environment never moves a workspace; `workspace_set_environment` does). On the home it stays on
  the home. A switch on the way somewhere else (a door, a chip, a line) lands where that goes.

### Amendment 2026-10-30 — piece 1's walk: names and orphan copies

- **The key once** (decision 10's fallback). `<KEY>-<slug of title>` drops the slug's leading copy of
  the key (any case): a ticket conversation titled *AQ247-141 · Work toward Next.* gets
  `AQ247-141-work-toward-next`, not `AQ247-141-aq247-141-work-toward-next`.
- **No name fails a copy** (Errors and edges). A new workspace's slug and branch (step 0, a
  branch-off) step past any that is taken — a slug the record uses or whose folder exists, a branch
  the record names, the repo has, or any worktree has checked out — to the next free `-2`, `-3`;
  wakil-git picks them (`git_worktree_add` with `newName`) and the record keeps the ones used. Two
  conversations with the same title get two workspaces. A checkout made later in a workspace
  (step 2) asks for the workspace's branch and checks it out as it is when it exists (a ticket's
  branch), stepping past it only when another folder holds it (`freeBranch`); the checkout records
  the branch it got.
- **No orphan copies.** The call: **make the copy, then save; when the save fails, take the copy
  back** — not save first. wakil-git's confinement admits only checkouts the saved record holds and
  only Go knows the copy's path, so saving first would record a folder that may never exist. When
  step 0, a branch-off or a step-2 checkout cannot save the record, the record in memory goes back
  as it was and `git_worktree_discard` removes the folder (and the workspace's folder, when empty)
  and the branch when the add made it. Nothing was written in the copy yet, so nothing is lost; a
  copy git will not remove (something is in it) is left and named. The thread and the refusal say
  so whole (Rule 8). **A copy taken from Main** carries Main's work, so it is never taken back: the
  write is refused naming where the copy is, and the record in memory keeps it for the next save.

### Amendment 2026-10-30 — decision 10 refined: the agent chooses its copy's base (`workspace_start`)

Operator-approved. Real projects branch from different bases per repo (staging, main, master,
production), and a hotfix branches from production; the write rule always started from the default
branch (step 2) or Main's commit (step 0).

- **`workspace_start {repo, base, branch?}`** (agent-reachable, `.mutate`, priced allow): the agent
  calls it before its first change in a repo, choosing the base and branch from its **branch
  instructions** (decision 10's fourth text, organisation then project) and the operator's message.
  `repo` is a project root's folder name or path. In Main it runs step 0 with that base; in a
  workspace with no checkout of the repo, step 2 with it. `branch` omitted is drafted as today.
- **Refused whole** (nothing made, no thread line) when the conversation's workspace already has a
  checkout of the repo — made or recorded — naming it and pointing at switch / branch create in it;
  for the operator's dispatch; for a repo outside the project; for a name git will not take.
- **Fallback:** without the call, the first change behaves as before.
- **The base:** `origin/<base>` when the remote has it, else the local branch (the remote is the
  shared truth for staging and production; a branch only the repo has still works). Neither is
  refused whole by wakil-git (`git_worktree_add`'s `base`) and nothing is made; no fetch is run.
- **Names:** the branch is minted like a new workspace's (`-2` past a taken one) and keeps the
  ticket's key once (`INI-1637-ini-1637-…` → `INI-1637-…`). In a workspace the slug is its own.
- **The thread names the base:** *"Made a copy of web from `production` on
  `from-production/INI-1637-full-jwt`."*; in Main, *"Started workspace ‘…’ — a copy of web from
  `production` on `…`. Your folder is untouched."* The checkout's `base` records it.
- **Agent-facing text:** the tool's description and Wakil's rule 8 tell the agent to read its branch
  instructions for the base and call the tool first; the Branches box's placeholder gives an
  example (*from staging; a hotfix from production*). No separate Settings field.

### Amendment 2026-10-31 — piece 2's walk: Try in steps, a process after ready

- **Try shows its steps as they run.** Go runs Try as a job the window follows
  (`recipe_try_start`, `recipe_try_status`, `recipe_try_cancel`): every step is listed before it
  runs — copy made, prepared, each services, setup and build command, each process started, ready,
  teardown — and is ✓ done with its time, ● running with its time and last line, ○ to come, or ✗
  failed with its output whole. Show output opens the running or failed step's output; Cancel stops
  the running step, teardown still run. A card's Run runs each services and setup step on its own and
  reads `<step> · <command> · <time>` until ready, then `running on :<port>`.
- **A process may start after ready.** A recipe's process takes `afterReady: true` when it needs
  the app up (a Sail queue failed because laravel.test was not up yet); Run and Try start it once the
  ready check passed, and never when it fails. The Processes box marks it `(after ready)`. Detect marks
  a Sail queue so, and a first run's image build (`sail build`, `docker compose build`) goes in setup,
  never under the ready timeout; the drafting and fix briefs say both.
- **The drafting line's conversation opens.** Its name in "Drafting … in ‘…’", "‘…’ is proposing a
  fix…", "‘…’ ended its turn without proposing …" and "Drafted in ‘…’" is a control that opens it in
  Main of the project (the operator asked for the jump, Rule 6), and a turn that ended without a
  proposal offers **Ask again**, which sends the same request once more.

### Amendment 2026-11-01 — piece 2's walk: a Try's workspace goes when the Try ends

The walk found two *Try parkour-warriors* workspaces in `workspaces.json` a day later, the first
drawn on the home as a card with its stale failure. The cleanup hung on the Running form: it ran
only when the form closed or another Try started, and only for a Try whose result had come back.
A Try still running when the form closed (its result never reached the form), a Try that threw
part-way (no workspace id came back) and the app quitting mid-Try all left the record, the copy and
the branch; the set of open Tries lived in memory, so after a relaunch `running_try_end` refused
the leftover as "not a Try workspace", and nothing swept it. The operator then opened the leftover
card, so a conversation joined it.

- **The Try removes its own workspace when it ends**, however it ends — passed, failed, Cancel,
  refused part-way — before `running_try` answers or throws (`WorkspaceRunner.tryRecipe`): what it
  runs is stopped, teardown run when Go's job did not reach it, each copy taken back with its
  `wakil-try/` branch (`git_worktree_discard`), and the record entry forgotten. The answer still
  carries the Try's port, read before the record went. `running_try_end` (the form closing) only
  cleans one that is still recorded.
- **Whenever an organisation becomes active** — at launch once its context is read, and on every
  switch to it — once per organisation per launch and never before the runner is wired, every
  record entry that is a Try's (`try-` id on a `wakil-try/` branch) and is not running in this
  session is cleaned the same way, its teardown run first (`cleanLeftoverTries`). An organisation
  whose record could not be read is swept at its next context read. An operator's workspace is
  never touched. *(The first build swept only on one branch of the context read, which a window
  opened with no organisation never reached, so a relaunch kept both leftovers.)*
- **Ignored files are not changes.** A copy whose only extra files are ignored ones the Try's own
  prepare wrote — `.env`, `vendor/` and `node_modules/` clones — shows nothing in `git status`, and
  `git_worktree_discard` removes it with them; only tracked changes or untracked, unignored files
  keep a copy.
- **A copy with changes is kept**: git refuses to remove it, so the copy, its branch and the record
  stay, and Wakil says so whole — the copy's path, its branch and git's words — in the Try's result
  in the form, or on the window's status line at launch (Rule 8). The next launch tries again.
- **The call: a Try waiting on a fix proposal does not keep its workspace.** The fix conversation
  lives in Main of the project and is sent every step, the failing one's output whole, and the
  recipe as tried; it reads the repo from Main's folder and proposes a recipe, writing nothing. It
  never needs the throwaway copy, and keeping the workspace until the proposal is saved or
  discarded would leave a card on the home and a copy on disk for as long as the operator leaves the
  proposal open — the defect itself. The next ▶ Try proves the fixed recipe in a fresh workspace.

## Errors and edges

- `git worktree add` fails: the write is not made; git's message whole in the thread (Rule 8).
- A worktree deleted outside Wakil: pruned at the next start; re-made at the next write with its
  snapshot.
- The holder turns idle between check and write: check and take are one step on the main actor.
- Main's folder on a detached HEAD: step 0 starts from that commit.
- A base branch missing on the remote: the checkout starts from the remote's default branch; the
  thread says so.
- No free port block: the card says which ports are taken; Run is refused with that sentence.
- Removing a repo from the project while a workspace has a checkout of it: refused while its holder
  works; otherwise snapshotted and removed.
- A root that holds several repos: each must be registered as its own root; Wakil does not look
  inside a root for more repos.
- Org switch: workspaces, holds and running apps stay; the home screen shows the new organization's.

## Interaction Rules

| Rule | Where it bites | How this meets it |
|---|---|---|
| 1 Confirm only what destroys or gates | Take-over, branch-off, Archive, Bring to Main, Run in production | Nothing asks but Archive with a conversation waiting on the operator, and Run in production (*gate*). Archive snapshots first. |
| 2 Enter never required | Workspace rename, recipe fields, env | Kept on blur. |
| 3 New input focused | ⌘N, New conversation here, Start | The composer or brief is focused. |
| 4 Waiting can be cancelled | Worktree add, setup, Try, Run | Each can be stopped. |
| 5 Work in flight shows | Setup, Try, Run, Archive, a woken agent | The card says *setting up* / *trying* / *running* / *archiving*; controls disabled meanwhile. |
| 6 Stay where the operator was | The first change, Start, Archive | The view stays; Start does not move the screen. |
| 7 Override or ignore | A branch held elsewhere | Taken over or branched off, never refused. |
| 8 Errors whole | Worktree, recipe, `workspaces.json` | Untruncated, on the card and in the thread. |
| 9 Defaults suggest | Branch name, recipe draft, Agents: one, project in the composer | Pre-filled, changed in one click; nothing saved unasked. |

## Invariants

| Invariant | How this keeps it |
|---|---|
| 1 Agent-agnostic | The map, message block and briefs are plain text; nothing uses a harness's own worktree support. |
| 2 Actions only | Every workspace, recipe and message change is an action; holds change only inside write actions. |
| 3 Panes observable | `session_list` and `read_pane` give workspaces, checkouts, holders and running processes. |
| 4 Credential boundary | Worktrees, `workspaces.json` and secrets under the organization; no cross-org messages. |
| 5 One place on screen | A workspace lives in one project; opening another project's work is a place switch. |
| 6 Earned writes | One new write: running the saved recipe (call 10). |
| 7 N roots | Checkouts per repo; a ticket touches only what it changes. |
| 8 Environment visible | Production red everywhere a workspace or conversation is drawn; Run there is *gate*. |

## Testing (each piece's own design refines it)

- **WakilKit:** the write rule as a pure function (one case per step, the detached HEAD, take-from-Main);
  path translation both ways; port blocks; the wake budget; the home list's grouping and order;
  view layout copy on step 0.
- **Go (`wakil-git`):** worktree add / remove / list / prune; snapshot create and apply; a branch
  checked out elsewhere; a dirty worktree.
- **Recipe detection:** one fixture repo per row of the Detect table → the expected draft.
- **e2e (scripted agent):** the three shapes — two tasks in one repo; one ticket across three repos
  changing two; a crew of two exchanging a message; plus Main's view with panes and no agent, and
  Run on the workspace's port.
- **Runbook:** the three shapes on real repos, with real setup, a real compose file and a local
  server on `WAKIL_PORT`.

## Open questions

None.

## Charter changes

- Glossary: *workspace*, *Main*, *checkout*, *view*. **Decision 94** (this design), including the earned
  write. Decision 41: "each conversation in a workspace". The conversations design's call 2b is
  replaced by decision 22.
- Settings: the **Branches** instructions text; **Agents woken by messages**; a project's **Running**.
- `docs/architecture/state.md`: `workspaces/`, `workspaces.json`, snapshot refs.
- PRODUCT.md: the home screen, workspaces and messages.
