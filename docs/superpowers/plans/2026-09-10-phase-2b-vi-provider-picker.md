# Phase 2b-vi — Provider Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The session's Claude account is chosen in the window and read from the org's provider record, so `WAKIL_PROVIDER`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN` and `WAKIL_CLAUDE_PATH` stop being launch-time environment variables.

**Architecture:** Go keeps sole ownership of the Keychain — a new `wakil provider credentials` command reads the token via the existing `security` CLI path, and Swift shells out to it exactly as it already shells out to the Phase 1 binaries. The mid-session switch is a new `.control` action that reuses `WindowModel.resume(sessionId:)`'s start-then-swap ordering verbatim.

**Tech Stack:** Go 1.x (`cmd/wakil`, `internal/wakilcore`), Swift 6 / SwiftUI (`app/Sources/WakilKit`, `app/Sources/WakilApp`), swift-testing (`@Test`, `#expect`), `make build`, `make app-test`.

**Spec:** `docs/superpowers/specs/2026-09-10-phase-2b-vi-provider-picker-design.md`

## Global Constraints

- **Run `make build` before `make app-test`.** 16 Swift tests shell out to `bin/wakil-ctx` and `bin/` is per-worktree. Without it they fail for want of a binary, not for a real reason. Baseline on this branch: **380 tests passing**.
- **No test may touch the real Keychain.** The real round trip stays behind the existing `WAKIL_KEYCHAIN_TEST=1` gate (`TestKeychainRoundTrip`), excluded from every agent run.
- **The Keychain service name is `wakil:<org>:<ref>`** and the account attribute is the constant `"wakil"`. Never re-spell either; always go through `keychainService`.
- **The provider's token ref is `provider:<id>`**, derived from the provider id — never a stored field.
- **The token appears only in the success JSON on stdout.** No refusal path, no diagnostic, no log line may contain it.
- **`wakil provider credentials` must never be registered as an MCP tool.** It is a launch-time lookup for the app, not an agent capability.
- **`WAKIL_ORG` remains an environment variable.** Deliberate, dates to 2026-09-06. This plan does not touch it.
- **Never change `resume()`'s ordering** — start-then-swap, and the `eventPumpGeneration` bump before `stop()`. Its doc comment says "Do not 'fix' this back to stop-then-start."
- Go exit codes: `0` success, `2` user error. Every subcommand in `cmd/wakil` follows this.

---

## File Structure

**Go — created:**
- `cmd/wakil/providercredentials.go` — the new verb, its JSON shape and its refusals.
- `cmd/wakil/providercredentials_test.go` — its tests.

**Go — modified:**
- `internal/wakilcore/provider.go` — `ClaudePath` field; `ProviderTokenRef` helper.
- `internal/wakilcore/provider_test.go` — round-trip and ref-derivation tests.
- `cmd/wakil/main.go` — `secretReader` seam threaded through `run`.
- `cmd/wakil/providercmd.go` — dispatch the new verb; `--claude-path` on `add`.

**Swift — created:**
- `app/Sources/WakilKit/App/ProviderCredentialsLookup.swift` — the lookup protocol, its shell-out implementation, and its errors.
- `app/Tests/WakilKitTests/ProviderCredentialsLookupTests.swift`
- `app/Tests/WakilKitTests/ProviderSwitchTests.swift`

**Swift — modified:**
- `app/Sources/WakilKit/App/WindowModel.swift` — delete `providerCredentials(from:)`; `providerId` becomes `var`; add `setProvider(_:)`; register `session_set_provider`.
- `app/Sources/WakilKit/App/AppWiring.swift` — `childProcessEnvironment` takes the provider as a parameter.
- `app/Sources/WakilApp/WindowSession.swift` — build the factory from the lookup, not the environment.
- `app/Sources/WakilApp/WakilWindow.swift` — the indicator.

**Docs — modified:** `docs/wakil/design-language.md` (§14), `docs/wakil/operator-todo.md` (§3), `docs/wakil/phase-2a-acceptance.md` (launch commands), `docs/wakil/north-star.md` (2b-vi row).
**Docs — created:** `docs/wakil/phase-2b-vi-acceptance.md` (three checks).

---

## Task 1: `ClaudePath` on the provider record

**Files:**
- Modify: `internal/wakilcore/provider.go`
- Modify: `cmd/wakil/providercmd.go` (add the `--claude-path` flag to `provider add`)
- Test: `internal/wakilcore/provider_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `Provider.ClaudePath string`; `func ProviderTokenRef(id string) string`.

- [ ] **Step 1: Write the failing test**

In `internal/wakilcore/provider_test.go`:

```go
func TestProviderClaudePathRoundTrips(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", ""); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	configDir := t.TempDir()
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode,
		ConfigDir: configDir, ClaudePath: "/opt/bin/claude",
	}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}
	got, err := LoadProvider("acme", "main")
	if err != nil {
		t.Fatalf("LoadProvider: %v", err)
	}
	if got.ClaudePath != "/opt/bin/claude" {
		t.Fatalf("ClaudePath = %q, want /opt/bin/claude", got.ClaudePath)
	}
}

func TestProviderTokenRefIsDerivedFromID(t *testing.T) {
	if got := ProviderTokenRef("main"); got != "provider:main" {
		t.Fatalf("ProviderTokenRef = %q, want provider:main", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run 'TestProviderClaudePath|TestProviderTokenRef' -v`
Expected: FAIL — `unknown field ClaudePath`, `undefined: ProviderTokenRef`.

> If `CreateOrg` or `LoadProvider` have different names in this tree, read `provider.go` and `org.go` and use the real ones — do not add shims.

- [ ] **Step 3: Write minimal implementation**

In `internal/wakilcore/provider.go`, add to the `Provider` struct:

```go
	// ClaudePath is the agent binary this provider launches, formerly the
	// WAKIL_CLAUDE_PATH environment variable. It is a record field and not
	// a Keychain item because a path is not a credential: putting it in the
	// Keychain would mean a Keychain read to answer "which binary", which is
	// both slower and misleading about what is sensitive. It is genuinely
	// per-provider — a codex or local provider is a different binary
	// entirely, not a different account for the same one.
	ClaudePath string `json:"claudePath,omitempty"`
```

And below the kind constants:

```go
// ProviderTokenRef is the secrets ref a provider's OAuth token lives
// under: "provider:<id>", resolving to the Keychain service name
// "wakil:<org>:provider:<id>" through keychainService.
//
// DERIVED, NOT STORED. validateProviderToken already constrains a
// provider id to exactly the character set a Keychain ref needs — it
// reuses orgFileTokenPattern for that reason — so nothing has to be
// validated here that AddProvider has not already refused. A stored
// tokenRef field would add a second string that can disagree with the
// filename, which is the failure Provider.ID's own `json:"-"` was
// written to prevent.
//
// The consequence, and it is intended: two providers cannot share one
// token. Two providers on one account are one provider with two names,
// and AddProvider already refuses two providers sharing a config dir.
func ProviderTokenRef(id string) string { return "provider:" + id }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/wakilcore/ -run 'TestProviderClaudePath|TestProviderTokenRef' -v`
Expected: PASS.

- [ ] **Step 5: Wire the flag on `provider add`**

In `cmd/wakil/providercmd.go`'s `runProviderAdd`, beside the existing `--config-dir`:

```go
	fs.StringVar(&p.ClaudePath, "claude-path", "", "the agent binary this provider launches (--kind claude-code only)")
```

- [ ] **Step 6: Run the whole Go suite**

Run: `go test ./...`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/wakilcore/provider.go internal/wakilcore/provider_test.go cmd/wakil/providercmd.go
git commit -m "2b-vi: providers record their claude binary, and derive their token ref"
```

---

## Task 2: A read seam for secrets

**Files:**
- Modify: `cmd/wakil/main.go:139`, `:169`
- Test: `cmd/wakil/main_test.go`

**Why this task exists:** `secretStore` is `func(ref, value string) error` — write-only. The new verb *reads*, and the suite must never reach the real Keychain. Without a read seam, Task 3's tests either touch your login keychain or do not exist.

**Interfaces:**
- Consumes: Task 1's `ProviderTokenRef`.
- Produces: `type secretReader func(ref string) (string, error)`; `run` gains a trailing `read secretReader` parameter.

- [ ] **Step 1: Write the failing test**

In `cmd/wakil/main_test.go`:

```go
// failingReader is the read-side counterpart of failingStore: any test
// whose subcommand must not read a secret passes this, so an accidental
// Keychain read fails the test instead of prompting the operator.
func failingReader(t *testing.T) secretReader {
	t.Helper()
	return func(ref string) (string, error) {
		t.Fatalf("unexpected keychain read for ref %q", ref)
		return "", nil
	}
}

func TestRunThreadsTheSecretReader(t *testing.T) {
	var stderr bytes.Buffer
	called := ""
	read := func(ref string) (string, error) { called = ref; return "tok", nil }
	_ = run([]string{"--org", "acme", "provider", "list"},
		strings.NewReader(""), io.Discard, &stderr, failingStore(t), read)
	if called != "" {
		t.Fatalf("provider list read ref %q; it must read no secret", called)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./cmd/wakil/ -run TestRunThreadsTheSecretReader -v`
Expected: FAIL — `undefined: secretReader`, and `run` takes 5 arguments.

- [ ] **Step 3: Write minimal implementation**

In `cmd/wakil/main.go`, beside `secretStore`:

```go
// secretReader is the read-side seam, mirroring secretStore. It exists
// so `provider credentials` can be tested without a Keychain: the real
// binary passes wakilcore.SecretGet, and every test passes a fake or
// failingReader. Reads are seamed separately from writes because most
// subcommands need neither, and a subcommand that reads a secret when it
// should not is a leak rather than a mistake.
type secretReader func(ref string) (string, error)
```

Change `run`'s signature and thread it to `runProvider`:

```go
func run(args []string, stdin io.Reader, stdout, stderr io.Writer, store secretStore, read secretReader) int {
```

Update `main()` to pass `wakilcore.SecretGet`, and update `runProvider`'s signature to accept and forward `read`.

- [ ] **Step 4: Fix every existing `run(...)` call site**

Run: `go build ./... 2>&1 | head -40`
Add `failingReader(t)` as the trailing argument to every `run(` call in `cmd/wakil/*_test.go`. There are call sites in `orgcmd_test.go` at least at lines 66, 193 and 274; compile errors list the rest.

- [ ] **Step 5: Run the whole Go suite**

Run: `go test ./...`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add cmd/wakil/
git commit -m "2b-vi: seam Keychain reads the way writes were already seamed"
```

---

## Task 3: `wakil provider credentials` — the success path

**Files:**
- Create: `cmd/wakil/providercredentials.go`
- Create: `cmd/wakil/providercredentials_test.go`
- Modify: `cmd/wakil/providercmd.go` (dispatch)

**Interfaces:**
- Consumes: Task 1's `ProviderTokenRef`, `Provider.ClaudePath`; Task 2's `secretReader`.
- Produces: `func runProviderCredentials(args []string, stdout, stderr io.Writer, read secretReader) int`, emitting `{"configDir":…,"claudePath":…,"oauthToken":…}`.

- [ ] **Step 1: Write the failing test**

```go
func TestProviderCredentialsEmitsJSON(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	configDir := t.TempDir()
	mustOrgWithProvider(t, "acme", "main", configDir, "/opt/bin/claude")

	var stdout, stderr bytes.Buffer
	read := func(ref string) (string, error) {
		if ref != "provider:main" {
			t.Fatalf("read ref = %q, want provider:main", ref)
		}
		return "sk-tok", nil
	}
	code := run([]string{"--org", "acme", "provider", "credentials", "main"},
		strings.NewReader(""), &stdout, &stderr, failingStore(t), read)
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, stderr.String())
	}
	var got struct {
		ConfigDir, ClaudePath, OAuthToken string
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("stdout is not JSON: %v (%q)", err, stdout.String())
	}
	if got.ConfigDir != configDir || got.ClaudePath != "/opt/bin/claude" || got.OAuthToken != "sk-tok" {
		t.Fatalf("got %+v", got)
	}
}
```

Write `mustOrgWithProvider` as a helper in the same file — create the org, then `AddProvider` with the given config dir and claude path, failing the test on any error.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./cmd/wakil/ -run TestProviderCredentialsEmitsJSON -v`
Expected: FAIL — `unknown provider command "credentials"`, exit 2.

- [ ] **Step 3: Write minimal implementation**

Create `cmd/wakil/providercredentials.go`:

```go
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// providerCredentialsJSON is the launch-time answer Wakil.app asks for:
// everything one `claude` invocation needs that used to arrive as four
// environment variables.
//
// WHY THIS IS A SEPARATE VERB FROM `provider list`. It is the only
// command in this binary that prints a secret. Keeping it separate means
// the token has exactly one exit from this process, which is what makes
// "the token appears only in the success JSON" a property that can be
// tested rather than a convention that can be eroded. It is also why this
// verb is not, and must never be, registered as an MCP tool: an agent
// that could read the token could launch sessions outside the write gate.
type providerCredentialsJSON struct {
	ConfigDir  string `json:"configDir"`
	ClaudePath string `json:"claudePath"`
	OAuthToken string `json:"oauthToken"`
}

func runProviderCredentials(args []string, stdout, stderr io.Writer, read secretReader) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <id>\n\n"+usage)))
		return 2
	}
	id := args[0]
	fs := flag.NewFlagSet("provider credentials", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args[1:]); err != nil {
		fmt.Fprintln(stderr, message(wakilcore.UserError("bad flags for `wakil provider credentials`: "+err.Error()+"\n\n"+usage)))
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(fs.Arg(0))+"\n\n"+usage)))
		return 2
	}

	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	p, err := wakilcore.LoadProvider(org, id)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	if p.Kind != wakilcore.ProviderKindClaudeCode {
		fmt.Fprintln(stderr, message(wakilcore.UserError("provider "+strconv.Quote(id)+" in org "+org+
			" is kind "+p.Kind+"; launching a session is only automated for "+wakilcore.ProviderKindClaudeCode)))
		return 2
	}
	if _, err := os.Stat(p.ConfigDir); err != nil {
		// Checked rather than trusted: a config dir deleted after
		// registration would send `claude` into a fresh, unauthenticated
		// account, which looks like a login prompt rather than like a
		// missing directory.
		fmt.Fprintln(stderr, message(wakilcore.UserError("provider "+strconv.Quote(id)+" in org "+org+
			" names config dir "+p.ConfigDir+", which does not exist")))
		return 2
	}
	token, err := read(wakilcore.ProviderTokenRef(id))
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}

	out, err := json.Marshal(providerCredentialsJSON{
		ConfigDir: p.ConfigDir, ClaudePath: p.ClaudePath, OAuthToken: token,
	})
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	fmt.Fprintln(stdout, string(out))
	return 0
}
```

In `providercmd.go`'s switch, add:

```go
	case "credentials":
		return runProviderCredentials(args[1:], stdout, stderr, read)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./cmd/wakil/ -run TestProviderCredentialsEmitsJSON -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/wakil/providercredentials.go cmd/wakil/providercredentials_test.go cmd/wakil/providercmd.go
git commit -m "2b-vi: wakil provider credentials, the app's launch-time lookup"
```

---

## Task 4: Its refusals, and the token-leak test

**Files:**
- Modify: `cmd/wakil/providercredentials_test.go`

**Why the leak test matters most:** every other refusal fails loudly when wrong. A token printed into a diagnostic fails silently, and lands in whatever captured that output.

**Interfaces:**
- Consumes: Task 3's `runProviderCredentials`.
- Produces: nothing new.

- [ ] **Step 1: Write the failing tests**

```go
func TestProviderCredentialsRefusals(t *testing.T) {
	configDir := t.TempDir()
	cases := []struct {
		name, provider, wantSubstring string
		setup                         func(t *testing.T)
		read                          secretReader
	}{
		{
			name: "unregistered id", provider: "ghost",
			wantSubstring: "provider list",
			setup:         func(t *testing.T) { mustOrgWithProvider(t, "acme", "main", configDir, "/c") },
			read:          func(string) (string, error) { return "", nil },
		},
		{
			name: "no token stored", provider: "main",
			wantSubstring: "wakil secrets set provider:main",
			setup:         func(t *testing.T) { mustOrgWithProvider(t, "acme", "main", configDir, "/c") },
			read: func(string) (string, error) {
				return "", wakilcore.UserError("no credential stored for ref provider:main in org acme" +
					" — store it with: WAKIL_ORG=acme wakil secrets set provider:main")
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			tc.setup(t)
			var stdout, stderr bytes.Buffer
			code := run([]string{"--org", "acme", "provider", "credentials", tc.provider},
				strings.NewReader(""), &stdout, &stderr, failingStore(t), tc.read)
			if code != 2 {
				t.Fatalf("exit = %d, want 2", code)
			}
			if !strings.Contains(stderr.String(), tc.wantSubstring) {
				t.Fatalf("stderr = %q, want it to name %q", stderr.String(), tc.wantSubstring)
			}
			if stdout.Len() != 0 {
				t.Fatalf("stdout = %q, want empty on refusal", stdout.String())
			}
		})
	}
}

// TestProviderCredentialsNeverPrintsTheTokenOnFailure is the one test in
// this file whose failure is a leak rather than a bug.
func TestProviderCredentialsNeverPrintsTheTokenOnFailure(t *testing.T) {
	const token = "sk-do-not-print-me"
	t.Setenv("HOME", t.TempDir())
	// A config dir that exists at registration and is gone by lookup time
	// is the refusal most likely to be built by interpolating everything
	// the command knows, token included.
	configDir := t.TempDir()
	mustOrgWithProvider(t, "acme", "main", configDir, "/c")
	if err := os.RemoveAll(configDir); err != nil {
		t.Fatalf("RemoveAll: %v", err)
	}
	var stdout, stderr bytes.Buffer
	read := func(string) (string, error) { return token, nil }
	code := run([]string{"--org", "acme", "provider", "credentials", "main"},
		strings.NewReader(""), &stdout, &stderr, failingStore(t), read)
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if strings.Contains(stderr.String()+stdout.String(), token) {
		t.Fatalf("the token reached output: stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
}
```

- [ ] **Step 2: Run tests**

Run: `go test ./cmd/wakil/ -run TestProviderCredentials -v`
Expected: the refusal cases PASS if Task 3 ordered its checks as written (config-dir check *before* the read). If the leak test fails, move the `read` call to after every validation — do not filter the message.

- [ ] **Step 3: Run the whole Go suite**

Run: `go test ./...`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add cmd/wakil/providercredentials_test.go
git commit -m "2b-vi: pin every credentials refusal, and that no refusal carries the token"
```

---

## Task 5: The Swift lookup, replacing the environment read

**Files:**
- Create: `app/Sources/WakilKit/App/ProviderCredentialsLookup.swift`
- Create: `app/Tests/WakilKitTests/ProviderCredentialsLookupTests.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:295-308` (delete `providerCredentials(from:)`)

**Interfaces:**
- Consumes: Task 3's command and JSON shape.
- Produces: `protocol ProviderCredentialsLookup { func credentials(forProvider: String) async throws -> ProviderCredentials }`; `struct WakilCLICredentialsLookup: ProviderCredentialsLookup`; `enum ProviderCredentialsLookupError: Error, Equatable { case refused(String) }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import WakilKit

@Test func decodesTheCredentialsJSON() throws {
    let json = #"{"configDir":"/tmp/cfg","claudePath":"/opt/claude","oauthToken":"sk-x"}"#
    let got = try decodeProviderCredentials(Data(json.utf8))
    #expect(got.configDir == "/tmp/cfg")
    #expect(got.claudePath == "/opt/claude")
    #expect(got.oauthToken == "sk-x")
}

@Test func refusesCredentialsWithAnEmptyField() {
    let json = #"{"configDir":"/tmp/cfg","claudePath":"","oauthToken":"sk-x"}"#
    #expect(throws: ProviderCredentialsLookupError.refused(
        "the provider record is missing claudePath")) {
        try decodeProviderCredentials(Data(json.utf8))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build && make app-test 2>&1 | tail -20`
Expected: FAIL — `cannot find 'decodeProviderCredentials' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/WakilKit/App/ProviderCredentialsLookup.swift`:

```swift
import Foundation

/// What one `claude` invocation needs, formerly four environment
/// variables.
///
/// WHY SWIFT DOES NOT READ THE KEYCHAIN. `internal/wakilcore/secrets.go`
/// does not use Security.framework — it shells out to the `security` CLI,
/// and it encodes measured knowledge a second implementation would have to
/// re-derive: exit 44 for a missing item, the `wakil:<org>:<ref>` service
/// name as the ONLY place org scoping can live, and a deliberate refusal
/// to fall back to unscoped names. A Swift copy that drifted from that
/// scheme would not fail loudly; it would return the wrong org's
/// credential, which is the cross-org sharing the 2026-09-06 decoupling
/// ended. So Go reads, and this asks Go.
public enum ProviderCredentialsLookupError: Error, Equatable {
    case refused(String)
}

public protocol ProviderCredentialsLookup: Sendable {
    func credentials(forProvider id: String) async throws -> ProviderCredentials
}

/// Decodes the command's stdout, refusing an empty field rather than
/// passing it on. An empty config dir or token would launch `claude` into
/// whatever default account it finds — the cross-account confusion
/// Invariant 4 exists to prevent — and an empty claude path would resolve
/// through `PATH` instead of naming one pinned binary.
public func decodeProviderCredentials(_ data: Data) throws -> ProviderCredentials {
    struct Wire: Decodable { let configDir: String; let claudePath: String; let oauthToken: String }
    let wire: Wire
    do {
        wire = try JSONDecoder().decode(Wire.self, from: data)
    } catch {
        throw ProviderCredentialsLookupError.refused(
            "could not read the provider credentials response: \(error)")
    }
    for (name, value) in [
        ("configDir", wire.configDir), ("claudePath", wire.claudePath), ("oauthToken", wire.oauthToken),
    ] where value.isEmpty {
        throw ProviderCredentialsLookupError.refused("the provider record is missing \(name)")
    }
    return ProviderCredentials(
        claudePath: wire.claudePath, configDir: wire.configDir, oauthToken: wire.oauthToken)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make build && make app-test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Add the shell-out implementation**

Append to the same file:

```swift
/// Runs `wakil provider credentials <id> --org <org>` and decodes it.
///
/// The token is on this process's stdout pipe and nowhere else: it is
/// never logged, never journalled and never put in an error. On a refusal
/// the command's own stderr is surfaced verbatim, because it names the fix
/// (the exact `wakil secrets set` to run) and rewording it here would lose
/// that.
public struct WakilCLICredentialsLookup: ProviderCredentialsLookup {
    let executable: URL
    let organization: String

    public init(executable: URL, organization: String) {
        self.executable = executable
        self.organization = organization
    }

    public func credentials(forProvider id: String) async throws -> ProviderCredentials {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--org", organization, "provider", "credentials", id]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderCredentialsLookupError.refused(
                text.isEmpty ? "wakil provider credentials \(id) failed" : text)
        }
        return try decodeProviderCredentials(data)
    }
}
```

- [ ] **Step 6: Delete `providerCredentials(from:)`**

Remove the function at `WindowModel.swift:300-308` and its doc comment. Delete `WindowModelTests.swift`'s tests of it (around lines 961-981) — they test a function that no longer exists.

**Do not leave an environment-reading fallback.** A fallback that still reads `CLAUDE_CODE_OAUTH_TOKEN` means the variables never stop being launch-time, which is this sub-phase's entire point.

- [ ] **Step 7: Run the suite**

Run: `make build && make app-test 2>&1 | tail -5`
Expected: PASS. Compile errors at former call sites are Task 6's subject — if `WindowSession.swift` no longer builds, go straight to Task 6 and commit them together.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/App/ProviderCredentialsLookup.swift app/Tests/WakilKitTests/ProviderCredentialsLookupTests.swift app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "2b-vi: credentials come from the provider record, not the environment"
```

---

## Task 6: The factory takes a provider

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:621` (`harnessFactory`), `:629` (`providerId`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift:313-321`
- Modify: `app/Sources/WakilApp/WindowSession.swift:99-125`

**Why `mcpConfigJSON` must be rebuilt, not reused:** `WindowSession` computes `configJSON` once and captures it in the closure, and that JSON embeds `WAKIL_PROVIDER` for every MCP server (`agentMCPConfigJSON`'s `provider:` argument). A switch that reused the captured JSON would start the new account's session with the *old* provider id on every server — the servers would resolve the wrong provider record while the harness ran the right account. That mismatch would not throw; it would quietly answer questions about the wrong account.

**Interfaces:**
- Consumes: Task 5's `ProviderCredentialsLookup`.
- Produces: `struct ProviderSelection: Sendable { let id: String; let credentials: ProviderCredentials }`; `harnessFactory: @Sendable (ProviderSelection) -> AgentHarness?`; `WindowModel.providerId` is `var`; `AppWiring.childProcessEnvironment(from:provider:)`.

- [ ] **Step 1: Write the failing test**

In `app/Tests/WakilKitTests/AppWiringTests.swift`:

```swift
@Test func childEnvironmentTakesTheProviderAsAParameterNotFromTheEnvironment() {
    let child = AppWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_ORG": "acme", "WAKIL_PROVIDER": "stale"],
        provider: "current")
    #expect(child["WAKIL_PROVIDER"] == "current")
    #expect(child["WAKIL_ORG"] == "acme")
}

@Test func childEnvironmentOmitsTheProviderWhenThereIsNone() {
    let child = AppWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p"], provider: nil)
    #expect(child["WAKIL_PROVIDER"] == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build && make app-test 2>&1 | tail -20`
Expected: FAIL — extra argument `provider` in call.

- [ ] **Step 3: Write minimal implementation**

In `AppWiring.swift`, change the signature and the provider line:

```swift
    static func childProcessEnvironment(
        from environment: [String: String], provider: String?
    ) -> [String: String] {
        var childEnvironment: [String: String] = [
            "HOME": environment["HOME"] ?? NSHomeDirectory(),
            "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        if let org = environment["WAKIL_ORG"] { childEnvironment["WAKIL_ORG"] = org }
        // Taken as a parameter rather than read from `environment`: since
        // 2b-vi the running provider can change mid-session, and a read of
        // the launching shell's WAKIL_PROVIDER would pin every child to
        // whatever the window opened with.
        if let provider { childEnvironment["WAKIL_PROVIDER"] = provider }
        return childEnvironment
    }
```

Update the doc comment above it, which currently says `WAKIL_ORG` and `WAKIL_PROVIDER` "are forwarded only when set".

- [ ] **Step 4: Add `ProviderSelection` and re-type the factory**

In `WindowModel.swift`, above the class:

```swift
/// One provider and the credentials it resolved to. The id travels with
/// the credentials because both are needed at launch and they must not
/// drift: the credentials go to the `claude` child, and the id goes into
/// every MCP server's environment.
public struct ProviderSelection: Sendable {
    public let id: String
    public let credentials: ProviderCredentials
    public init(id: String, credentials: ProviderCredentials) {
        self.id = id
        self.credentials = credentials
    }
}
```

Change the stored property to `private let harnessFactory: @Sendable (ProviderSelection) -> AgentHarness?`, change both initialisers' parameters to match, change `providerId` from `let` to `private(set) var`, and update the one existing call site at `WindowModel.swift:1534`.

- [ ] **Step 5: Rebuild the factory in `WindowSession`**

Replace the `harnessFactory = { ... }` closure so it takes a selection and rebuilds the config JSON per provider:

```swift
            harnessFactory = { selection in
                // Rebuilt per selection, never captured: this JSON carries
                // WAKIL_PROVIDER to every MCP server, so reusing the JSON
                // captured at window open would run the new account's
                // session with the old provider id on its servers.
                let configJSON = agentMCPConfigJSON(
                    shimExecutable: executableURL,
                    socketPath: socketPath,
                    binaries: binaries,
                    organization: environment["WAKIL_ORG"],
                    provider: selection.id)
                return ClaudeCodeCLIHarness(
                    claudePath: selection.credentials.claudePath,
                    configDir: selection.credentials.configDir,
                    oauthToken: selection.credentials.oauthToken,
                    mcpConfigJSON: configJSON,
                    allowedTools: allowedTools)
            }
```

Replace the environment reads at `WindowSession.swift:104, 158, 182` with the provider resolved from `active.json` (Task 7) and the credentials from Task 5's lookup. Delete the `WAKIL_PROVIDER is not set` note at line 158-159 — an unset variable is no longer how a provider goes missing.

- [ ] **Step 6: Run the suite**

Run: `make build && make app-test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/App/AppWiring.swift app/Sources/WakilApp/WindowSession.swift app/Tests/WakilKitTests/AppWiringTests.swift
git commit -m "2b-vi: the harness factory takes a provider, and rebuilds its MCP config per provider"
```

---

## Task 7: `active.json` gains a provider

**Files:**
- Modify: `internal/wakilcore/active.go`
- Test: `internal/wakilcore/active_test.go`

**Interfaces:**
- Consumes: Task 1's `Provider`.
- Produces: an `activeProvider` field on the active-context record, plus its getter/setter, following whatever names `active.go` already uses for project and environment.

- [ ] **Step 1: Read the existing shape first**

Run: `sed -n '1,80p' internal/wakilcore/active.go`
Follow its existing field naming and JSON tags exactly. Do not invent a parallel accessor style.

- [ ] **Step 2: Write the failing test**

```go
func TestActiveProviderRoundTrips(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", ""); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	if err := SetActiveProvider("acme", "main"); err != nil {
		t.Fatalf("SetActiveProvider: %v", err)
	}
	got, err := ActiveProvider("acme")
	if err != nil {
		t.Fatalf("ActiveProvider: %v", err)
	}
	if got != "main" {
		t.Fatalf("ActiveProvider = %q, want main", got)
	}
}

func TestActiveProviderIsEmptyBeforeItIsSet(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", ""); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	got, err := ActiveProvider("acme")
	if err != nil {
		t.Fatalf("ActiveProvider: %v", err)
	}
	if got != "" {
		t.Fatalf("ActiveProvider = %q, want empty", got)
	}
}
```

- [ ] **Step 3: Run to verify it fails, implement, re-run**

Run: `go test ./internal/wakilcore/ -run TestActiveProvider -v`
Expected: FAIL, then PASS after adding the field and the two functions alongside the existing project/environment accessors.

- [ ] **Step 4: Expose it through `wakil-ctx`'s `get_context`**

Add the active provider to whatever `get_context` already returns for project and environment, so `WindowSession` reads it the same way it reads `rootPaths`.

- [ ] **Step 5: Run the Go suite and commit**

```bash
go test ./...
git add internal/wakilcore/ cmd/wakil-ctx/
git commit -m "2b-vi: the active context gains a provider, its fourth axis"
```

---

## Task 8: `session_set_provider` and its refusals

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`
- Create: `app/Tests/WakilKitTests/ProviderSwitchTests.swift`

**Interfaces:**
- Consumes: Task 6's `ProviderSelection` and `var providerId`; Task 5's lookup.
- Produces: `func setProvider(_ id: String) async` on `WindowModel`; a `.control` action named `session_set_provider` taking `{"provider": String}`.

- [ ] **Step 1: Write the failing tests — refusals only**

```swift
import Testing
@testable import WakilKit

@Test func refusesASwitchToTheProviderAlreadyRunning() async {
    let model = await makeModel(providerId: "main")
    await model.setProvider("main")
    #expect(await model.status.contains("already running"))
}

@Test func refusesASwitchWhileATurnIsInFlight() async {
    let model = await makeModel(providerId: "main", turnInFlight: true)
    await model.setProvider("work")
    #expect(await model.status.contains("a turn is in flight"))
}

@Test func refusesASwitchWithAProposalParked() async {
    let model = await makeModel(providerId: "main")
    await model.parkAProposalForTesting()
    await model.setProvider("work")
    #expect(await model.status.contains("waiting for confirmation"))
}

@Test func surfacesTheLookupRefusalVerbatim() async {
    let model = await makeModel(providerId: "main", lookup: FakeLookup(
        refusal: "no credential stored for ref provider:work in org acme — store it with: wakil secrets set provider:work"))
    await model.setProvider("work")
    #expect(await model.status.contains("wakil secrets set provider:work"))
}
```

Build `makeModel` and `FakeLookup` in this file, following the construction `WindowModelTests.swift` already uses for a model with no filesystem. `FakeLookup` conforms to `ProviderCredentialsLookup` and either returns fixed credentials or throws `.refused(refusal)`.

- [ ] **Step 2: Run to verify they fail**

Run: `make build && make app-test 2>&1 | tail -20`
Expected: FAIL — `value of type 'WindowModel' has no member 'setProvider'`.

- [ ] **Step 3: Implement the refusals only**

```swift
    /// Switches the account this window's session runs under.
    ///
    /// Refusals land in `status` rather than throwing, for the same reason
    /// `resume(sessionId:)`'s do: this is reached from a palette selection,
    /// which has nowhere to throw to.
    ///
    /// WHY A TURN IN FLIGHT AND A PARKED PROPOSAL BOTH REFUSE RATHER THAN
    /// QUEUE. A queued switch needs a deferred-state machine nothing else
    /// in this window has, and it defers a decision the operator can simply
    /// re-make in a few seconds. A parked `.mutate` proposal is the sharper
    /// case: it belongs to an agent that is about to stop existing, and
    /// expiring it on the operator's behalf reaches that agent as a refusal
    /// it cannot interpret.
    public func setProvider(_ id: String) async {
        guard id != providerId else {
            status = "set provider \(id): that provider is already running in this window"
            return
        }
        guard !turnInFlight else {
            status = "set provider \(id): a turn is in flight — wait for it to finish"
            return
        }
        guard await confirmations.parked() == nil else {
            status = "set provider \(id): a mutation is waiting for confirmation — "
                + "confirm or cancel it first"
            return
        }
        let credentials: ProviderCredentials
        do {
            credentials = try await lookup.credentials(forProvider: id)
        } catch let ProviderCredentialsLookupError.refused(reason) {
            status = "set provider \(id): \(reason)"
            return
        } catch {
            status = "set provider \(id): \(error)"
            return
        }
        _ = credentials  // Task 9 performs the swap.
    }
```

Use whatever `ConfirmationBroker` actually exposes for "is something parked" — read `ConfirmationBroker.swift` and use the real accessor rather than inventing `parked()`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make build && make app-test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Register the action**

In `registerStandardActions`, beside the other `.control` actions:

```swift
    registry.register(Action(
        name: "session_set_provider",
        kind: .control,
        handler: { params, _ in
            guard case let .string(id)? = params["provider"] else {
                throw ActionError.badParams("session_set_provider needs a string \"provider\"")
            }
            await model.setProvider(id)
            return .object([:])
        }))
```

Match the surrounding registration style exactly — parameter names and error type as the neighbouring actions use them.

- [ ] **Step 6: Pin that the agent cannot call it**

```swift
@Test func theAgentCannotSwitchItsOwnAccount() async {
    let allowed = agentAllowedTools(actions: await registryForTesting().all())
    #expect(!allowed.contains { $0.contains("session_set_provider") })
}
```

`.control` actions are filtered out of `agentAllowedTools` already; this test pins that the new action inherited that and did not get special-cased in.

- [ ] **Step 7: Run the suite and commit**

```bash
make build && make app-test 2>&1 | tail -5
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/ProviderSwitchTests.swift
git commit -m "2b-vi: session_set_provider, and every reason it refuses"
```

---

## Task 9: The swap and the seam

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`setProvider`)
- Modify: `app/Tests/WakilKitTests/ProviderSwitchTests.swift`

**Read `resume(sessionId:)` and its full doc comment before writing a line of this.** The ordering below is copied from it, and both halves were found by review rather than by design.

**Interfaces:**
- Consumes: Task 8's `setProvider`; Task 6's factory.
- Produces: nothing new.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aFailingStartLeavesTheExistingSessionUntouched() async {
    let model = await makeModel(providerId: "main", factoryFails: true)
    let before = await model.sessionId
    await model.setProvider("work")
    #expect(await model.sessionId == before)
    #expect(await model.providerId == "main")
    #expect(await model.thoughts.isEmpty == false)
}

@Test func aSuccessfulSwitchClearsTheThreadAndDrawsASeam() async {
    let model = await makeModel(providerId: "main")
    await model.setProvider("work")
    #expect(await model.providerId == "work")
    let seam = await model.thoughts.last?.text ?? ""
    #expect(seam.contains("main"))
    #expect(seam.contains("work"))
}

@Test func aSwitchMintsAFreshSessionRatherThanForking() async {
    let model = await makeModel(providerId: "main")
    let before = await model.sessionId
    await model.setProvider("work")
    #expect(await model.sessionId != before)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `make build && make app-test 2>&1 | tail -20`
Expected: FAIL — provider unchanged, no seam row.

- [ ] **Step 3: Implement the swap**

Replace `_ = credentials` in `setProvider` with:

```swift
        guard let next = harnessFactory(
            ProviderSelection(id: id, credentials: credentials)) else {
            status = "set provider \(id): no agent session available"
            return
        }

        let fresh = UUID().uuidString
        do {
            // START-THEN-SWAP. Nothing about the running session is touched
            // until `next.start` has returned. `resume(sessionId:)`'s doc
            // comment records what stop-then-start cost when it was tried:
            // a `start` that threw left the operator with no session at all,
            // its process already stopped and its thread already replaced.
            // Do not "fix" this back to stop-then-start.
            try await next.start(
                sessionId: fresh, resumingFrom: nil, workingDirectory: rootPath)
        } catch {
            status = "set provider \(id): \(error)"
            return
        }

        // The generation is bumped BEFORE `stop()`, not after.
        // `ClaudeCodeCLIHarness.stop()` waits for stdout to become buffered
        // events, not for this window to have drained them, and
        // `Task.cancel()` does not stop an `AsyncStream` from delivering
        // values already in its buffer. Bumping here means the old pump
        // compares against a value that has already moved on and drops
        // those events instead of appending them after the seam.
        eventPumpGeneration += 1
        await harness?.stop()

        // A FRESH SESSION, NOT A FORK. A resume forks from the parent's
        // transcript; a provider switch cannot, because transcripts live
        // under the provider's own config dir (`sessions.go`'s
        // `providerSessionsRoot`) and the new account's `claude` cannot
        // read a file under the old account's directory. That is the same
        // fact `resume(sessionId:)` enforces when it refuses a session
        // belonging to another provider. So `resumingFrom` is nil above,
        // and the thread is cleared rather than rebuilt.
        let previous = providerId
        thoughts = []
        appendSeam("account changed: \(previous.isEmpty ? "unset" : previous) → \(id)")
        turnInFlight = false

        harness = next
        sessionId = fresh
        providerId = id
        startEventPump(next)
        status = ""
```

Write `appendSeam` using the same row construction and `nextThoughtId` counter `rebuiltThread` uses — do not reset the counter.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make build && make app-test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Persist the choice**

After a successful swap, write the new provider to `active.json` via Task 7's setter, dispatched the way `resume` dispatches `session_record_parent` — best effort, after the swap, so a failed write costs a remembered default rather than the session.

- [ ] **Step 6: Run the suite and commit**

```bash
make build && make app-test 2>&1 | tail -5
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/ProviderSwitchTests.swift
git commit -m "2b-vi: the swap itself — fresh session, cleared thread, visible seam"
```

---

## Task 10: The indicator

**Files:**
- Modify: `app/Sources/WakilApp/WakilWindow.swift`

**Constraint, from `design-language.md` §5:** green `#8be0c8`, amber `#e8b45a` and red `#e85c5c` are reserved for environment semantics and are **never decorative, anywhere**. The account indicator must not use them. It gets luminance violet `#7c5cff` and text opacity — §5's rule is that text steps down by opacity, never by a different hue.

**Interfaces:**
- Consumes: Task 6's `providerId`.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Place it at the bottom edge**

Render `model.providerId` at the bottom edge, where §9's thought thread and §12's waveform already attach. Follow the typography scale in §6 and the existing bottom-edge treatment rather than inventing sizes.

- [ ] **Step 2: Keep account and environment independently readable**

The pair that matters is "which account, against which environment" — a treatment that blended them would make the dangerous combination *harder* to see. Two distinct elements, not one merged label.

- [ ] **Step 3: Build and look at it**

Run: `make build && open app/Wakil.app`
The judgement — legible without becoming noise — belongs to Task 11's runbook, not to a test.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/WakilApp/WakilWindow.swift
git commit -m "2b-vi: the running account is always on screen"
```

---

## Task 11: Documents, and a runbook of exactly three checks

**Files:**
- Modify: `docs/wakil/design-language.md` (§14), `docs/wakil/operator-todo.md` (§3), `docs/wakil/phase-2a-acceptance.md`, `docs/wakil/north-star.md`
- Create: `docs/wakil/phase-2b-vi-acceptance.md`

**Why three and not ten:** four sub-phases produced runbooks that went unwalked or unrun. A ten-check runbook that is never walked establishes less than a three-check one that is.

- [ ] **Step 1: Amend `design-language.md` §14**

Its scope table gives the Organization *"Claude account / config dir"* — singular, written before the 2026-09-06 org/provider decoupling. Change it to name the provider *set*, and note that the running provider is chosen per session.

- [ ] **Step 2: Amend `operator-todo.md` §3**

Add the two new steps — `--claude-path` on `provider add`, and `wakil secrets set provider:<id> --org <org>` for the token. State that `~/.claude-tokens.zsh` is superseded and should be emptied rather than left as a second source of truth.

**Do not close the rotation item at line 417.** Those two tokens were pasted into an agent transcript on 2026-09-07; moving them into the Keychain does not un-expose them. They still need regenerating with `claude setup-token`.

- [ ] **Step 3: Update `phase-2a-acceptance.md`'s launch commands**

They document the three variables as part of the launch command for the standing checks. Those commands change.

- [ ] **Step 4: Verify the exit criterion, both halves**

```bash
grep -rn 'CLAUDE_CONFIG_DIR\|CLAUDE_CODE_OAUTH_TOKEN\|WAKIL_CLAUDE_PATH\|WAKIL_PROVIDER' app/Sources
```

Exactly three sites may remain, all writes to a child: `ClaudeCodeCLIHarness.swift:104-105`, `agentMCPConfigJSON`'s per-server environment, and `AppWiring.childProcessEnvironment`. Every read must be gone — `WindowModel.swift:301, 305-307, 1538` and `WindowSession.swift:104, 158, 182`.

Then the real half: launch a window with all four variables **unset** and confirm a session starts.

- [ ] **Step 5: Write the runbook**

Create `docs/wakil/phase-2b-vi-acceptance.md` with a `**Status:** not yet run` header and three checks, each with an empty result row (`| _not yet run_ | | |`) — the convention every acceptance document in this repo uses:

1. **The switch** — ⌘K to another account; does it read as deliberate rather than as a failure?
2. **The seam** — does it read as a seam rather than an error, and does it avoid implying the new agent knows the prior conversation?
3. **The indicator** — legible without becoming noise, and are account and environment independently readable?

Add a §1 prerequisite: **run `make build` first.** 16 tests shell out to `bin/wakil-ctx` and `bin/` is per-worktree. 2b-iv's H1 row found this the hard way and no runbook says it yet.

- [ ] **Step 6: Update `north-star.md`'s 2b-vi row**

Mark it **implemented, not met**, and say the runbook is unwalked. Do not write "MET".

- [ ] **Step 7: Full suite and commit**

```bash
make build && make app-test 2>&1 | tail -3
go test ./...
git add docs/
git commit -m "2b-vi: amend the stale §14 scope table, and a three-check runbook"
```

---

## Self-Review

**Spec coverage:** §1 → Tasks 3-5. §2.1 → Task 1. §2.2 → Task 1. §2.3 → Tasks 3-4. §2.4 → Task 5. §2.5 → Task 7. §3.1 → Tasks 6, 8. §3.2 → Task 9. §3.3 → Task 8. §3.4 → Task 9. §4 → Task 10. §5 → Task 11. §6 → distributed. §7 → Task 11 step 4. §8 → not implemented, by design (it is recorded as unowned, not assigned here). §9 → not implemented, by design (the split).

**Placeholders:** none. Three tasks direct the implementer to read existing code and follow its naming rather than guess — Task 7 step 1 (`active.go`), Task 8 step 3 (`ConfirmationBroker`), Task 8 step 5 (registration style). Those are instructions to match a real pattern, not deferred decisions.

**Type consistency:** `ProviderSelection` is produced in Task 6 and consumed in Tasks 8-9. `ProviderCredentialsLookup` / `ProviderCredentialsLookupError.refused` are produced in Task 5 and consumed in Tasks 6, 8. `ProviderTokenRef` is produced in Task 1 and consumed in Tasks 3-4. `secretReader` is produced in Task 2 and consumed in Tasks 3-4. `providerId` becomes `var` in Task 6 and is assigned in Task 9.

**One risk to flag at execution time:** Task 5 deletes `providerCredentials(from:)` while Task 6 fixes the call sites. If the tree does not build between them, commit them together rather than leaving a broken commit.
