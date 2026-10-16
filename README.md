# Wakil

A native macOS workspace where your organization, project and environment are ambient:
every tool, and the agent, already knows which one you mean.

You never tell Wakil *which* Jira, *which* database or *which* Claude account. You tell it
what you want.

## What it is

Wakil holds one active context, an **(organization, project, environment)**, and every
pane inside it resolves against that context: a database client, an API client, a
terminal, an editor, git, Jira and a conversation with an agent. Switch the context and
everything follows.

Two ideas carry it:

- **Ambient context.** The active org, project and environment are implicit state, not an
  argument you repeat on every call. Each organization is a credential boundary, so one
  org's secrets can never answer another org's request.
- **Dual-driven panes.** Your clicks and the agent dispatch the same actions, so speaking
  and clicking are one operation on one state. The agent can read what is on screen, so
  "this table" means the table you are looking at.

The test every feature has to pass:

> A feature earns its place in Wakil only when its absence forces you to leave.

It is deliberately **not** a VS Code replacement and **not** multi-user.

## Status

Pre-release and in active development, built for a single operator. Expect sharp edges
and breaking changes. Writes are off by default and earn their way in one adapter at a
time; the charter lists which ones have.

## Requirements

- macOS 14.4 or later
- Xcode command-line tools with Swift 6 and the Metal compiler (`xcrun metal`)
- Go 1.27
- The [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI, for the agent

## Build and run

```sh
make build        # the Go tools, into bin/
make app-bundle   # bin/ plus the Swift app, into app/Wakil.app (unsigned)
open app/Wakil.app
```

Tests:

```sh
make test         # Go suite and the charter's word-limit check
make build app-test   # Swift suite; it runs against whatever bin/ holds, so build first
make test-live    # engine-backed tests against MySQL and Mongo in Docker
```

## How it's built

```
app/                 Swift app: WakilKit (testable logic) and WakilApp (drawing)
cmd/                 one MCP server per capability: wakil-db, wakil-git, wakil-http, ...
internal/wakilcore/  the headless capability layer those servers share
```

The Go capability layer is headless and usable without the app; the Swift app owns pane
state and actions. The agent is the `claude` CLI behind a harness adapter, and nothing
outside that adapter knows which agent it is.

## Docs

| Read | For |
|---|---|
| [`docs/wakil/north-star.md`](docs/wakil/north-star.md) | The charter: what Wakil is, its binding invariants, its non-goals |
| [`docs/architecture/README.md`](docs/architecture/README.md) | The map of the code, Swift and Go |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Where code goes, recipes, and the tests each change needs |
| [`PRODUCT.md`](PRODUCT.md) | Users, brand and the interaction rules every control follows |
| [`docs/agents/workflow.md`](docs/agents/workflow.md) | How work moves from design to a merged change |

## License

[MIT](LICENSE). Bundled third-party code keeps its own license, such as Monaco in `app/Resources/monaco/`.
