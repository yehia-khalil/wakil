# 2c-iv Amendment 11 — a cURL command pasted into the path: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A cURL command pasted into an API pane's path editor replaces the pane's draft with that request, switching to the matching entry, dropping what Wakil cannot carry, and saying so in one line with **Undo**.

**Architecture:** Go reads the command and the configuration; Swift decides and writes. `wakil-http` gains two read-only tools: `parse_curl` (pure — tokenizes a POSIX-shell cURL command and returns the request curl would send, with dropped items named, never valued) and `locate_api_url` (configuration only — which entry, in which environment, a URL belongs to). WakilKit gains a pure fill (`apiCurlFill`), one write action `api_fill_from_curl`, one restore action `api_undo_fill`, and the pane's kept draft. WakilApp's path editor hands a `curl …` paste to the pane, which dispatches through its surface doors and draws the line.

**Tech Stack:** Go 1.x (`internal/wakilcore`, `cmd/wakil-http`, the MCP Go SDK), Swift 6 (WakilKit with swift-testing; WakilApp, AppKit/SwiftUI), the e2e harness (`e2e/`, JSONL checks).

**Spec:** `docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md`, §"2026-10-05 — a cURL command pasted into the path" (Amendment 11, 11a–11e), with the correction recorded in Task 1 Step 1 (the entry match moves to Go).

## Global Constraints

- **The wire, `read_pane`'s shape, every existing action's schema and Decision 27's wording are unchanged.** Two Go tools and two Swift actions are added; nothing existing is renamed.
- **Swift parses no shell and no cURL** (2c-ii-b precedent). Every cURL rule lives in `internal/wakilcore/curl.go`.
- **A dropped item is named, never carried with its value.** No credential, cookie, file path or unknown argument value from the pasted text appears in `parse_curl`'s result, the journal, `read_pane` or Recent.
- **`api_fill_from_curl` declares `secretParams: ["text"]`**, so the registry journals the pasted text as `[redacted]`.
- **Every ruling is WakilKit's, with a test that fails first** — the fill, the line's wording, the kept draft and its forgetting, `apiPasteIsCurl`. WakilApp only applies them. `make app-test` shows each new test red before its code exists.
- **Every dispatch goes through the surface doors** (`operateInOrder`, `operateFlushed`, `flush()` on `WindowModel`'s surface chain); the editor never dispatches.
- **Identifiers go only on an element with an accessibility action, set only when they change.** The one new identifier is `api.fill.undo` (spelled `"api.fill.undo"`, so `make controls` harvests it).
- **Interaction Rules:** no dialog (1); the line is whole (8); after the fill the caret is at the end of the path (3); the pane stays where it is, entry switch included (6); drop, don't refuse, except the host invariant (7).
- **Refusal wording, verbatim:** `not a cURL command`; `not a cURL command Wakil can read: Windows cmd quoting`; `not a cURL command Wakil can read: more than one command`; `the cURL command names no URL`; `this cURL is for <host>; no entry in <environment> has that host (entries: <names>)`; `this cURL is for <entry> in <environment>; switch environment first`.
- **Line wording:** `Filled from cURL · <entry>` then, when anything was dropped, ` · dropped: <names joined by ", ">`. Refusals are the same line in amber.
- **No GUI target without the operator's OK, every time** (`make e2e`, `make e2e-new`, launching the app). Subagents run gates in the foreground, never backgrounded.
- **Commits carry no `Co-Authored-By` and no "Generated with" line.**

## Review Focus

1. **A credential in a header's value under a different-case name** (`AUTHORIZATION: Bearer x`, `cookie: a=b`, `Proxy-Authorization: …`) — expected: dropped and named by the name as typed; the value appears nowhere. Pinned in Task 1 (`TestParseCurlNeverCarriesADroppedValue`).
2. **A base URL with a path prefix** (`https://api.example.com/v2`) and a pasted URL under it, beside another entry on the same host with no prefix — expected: the longest base path wins, and the draft's path is what follows it. Pinned in Task 2 (`TestLocateAPIURLLongestBasePathWins`).
3. **Default ports and host case** (`https://API.Example.com:443/x` against `https://api.example.com`) — expected: a match. Pinned in Task 2 (`TestLocateAPIURLNormalizesHostAndDefaultPort`).
4. **A paste while a bound value sits in the draft** — expected: the fill replaces the whole draft (the binding goes with it), and **Undo brings the binding back**, because Undo restores the kept draft directly, never through `api_set_request`'s no-new-binding rule. Pinned in Task 4 (`undoRestoresABindingTheFillReplaced`).
5. **The agent fills a pane while the operator is typing in it** — expected: Decision 27's refusal, `the operator is editing Path` (or the field they are in), and nothing written. Pinned in Task 4 (`anAgentFillUnderTheOperatorsHandIsRefused`).

---

### Task 1: `ParseCurl` — the command, read the way a shell and curl read it

**Files:**
- Create: `internal/wakilcore/curl.go`
- Create: `internal/wakilcore/curl_test.go`
- Modify: `docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md` (one correction paragraph at the end of Amendment 11)

**Interfaces:**
- Consumes: nothing.
- Produces (Go, package `wakilcore`):
  ```go
  type CurlHeader struct { Name string `json:"name"`; Value string `json:"value"` }
  type CurlDropped struct { Name string `json:"name"`; Reason string `json:"reason"` }
  type CurlRequest struct {
      Method  string        `json:"method"`
      URL     string        `json:"url"`
      Headers []CurlHeader  `json:"headers"`
      Body    string        `json:"body"`
      HasBody bool          `json:"hasBody"`
      Dropped []CurlDropped `json:"dropped"`
      Ignored []string      `json:"ignored"`
  }
  func ParseCurl(text string) (CurlRequest, error) // error is a UserError with the verbatim refusal
  ```

- [ ] **Step 1: Record the spec correction**

Append to the end of Amendment 11 in the spec:

```markdown
**Corrected while writing the plan (2026-10-05).** 11b's match cannot stay in Swift: the api actions
read the active environment's entries only (`list_apis`), and 11b's *"an entry matches only in
another environment"* needs every environment's. The match is a second read-only `wakil-http`
tool, `locate_api_url {url}`, which reads the project configuration and nothing else. Swift still
decides what the match means (switch, refuse, fill). And `parse_curl` returns
`content-type: application/x-www-form-urlencoded` for `-d` data with no content type, because that
is the request curl would send.
```

- [ ] **Step 2: Write the failing tests**

```go
package wakilcore

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseCurlAppliesWhatTheRequestCarries(t *testing.T) {
	for _, tc := range []struct {
		name string
		text string
		want CurlRequest
	}{
		{"bare GET", `curl https://api.example.com/v1/items`,
			CurlRequest{Method: "GET", URL: "https://api.example.com/v1/items"}},
		{"-X and a header", `curl -X DELETE -H 'X-Trace: 1' https://api.example.com/v1/items/7`,
			CurlRequest{Method: "DELETE", URL: "https://api.example.com/v1/items/7",
				Headers: []CurlHeader{{"X-Trace", "1"}}}},
		{"attached -X", `curl -XPATCH https://a.example/x`,
			CurlRequest{Method: "PATCH", URL: "https://a.example/x"}},
		{"-d implies POST and form content type", `curl https://a.example/x -d 'a=1'`,
			CurlRequest{Method: "POST", URL: "https://a.example/x",
				Headers: []CurlHeader{{"Content-Type", "application/x-www-form-urlencoded"}},
				Body:    "a=1", HasBody: true}},
		{"-d with an explicit content type keeps it", `curl https://a.example/x -H 'content-type: application/json' --data-raw '{"a":1}'`,
			CurlRequest{Method: "POST", URL: "https://a.example/x",
				Headers: []CurlHeader{{"content-type", "application/json"}},
				Body:    `{"a":1}`, HasBody: true}},
		{"repeated -d joins with &", `curl https://a.example/x -d a=1 -d b=2`,
			CurlRequest{Method: "POST", URL: "https://a.example/x",
				Headers: []CurlHeader{{"Content-Type", "application/x-www-form-urlencoded"}},
				Body:    "a=1&b=2", HasBody: true}},
		{"--json", `curl --json '{"a":1}' https://a.example/x`,
			CurlRequest{Method: "POST", URL: "https://a.example/x",
				Headers: []CurlHeader{{"Content-Type", "application/json"}},
				Body:    `{"a":1}`, HasBody: true}},
		{"-G moves data into the query", `curl -G https://a.example/x -d a=1 -d b=2`,
			CurlRequest{Method: "GET", URL: "https://a.example/x?a=1&b=2"}},
		{"-G onto an existing query", `curl -G 'https://a.example/x?z=0' -d a=1`,
			CurlRequest{Method: "GET", URL: "https://a.example/x?z=0&a=1"}},
		{"--data-urlencode", `curl https://a.example/x --data-urlencode 'q=a b&c'`,
			CurlRequest{Method: "POST", URL: "https://a.example/x",
				Headers: []CurlHeader{{"Content-Type", "application/x-www-form-urlencoded"}},
				Body:    "q=a+b%26c", HasBody: true}},
		{"-I is HEAD", `curl -I https://a.example/x`,
			CurlRequest{Method: "HEAD", URL: "https://a.example/x"}},
		{"--url", `curl --url https://a.example/x`,
			CurlRequest{Method: "GET", URL: "https://a.example/x"}},
		{"-A and -e are headers", `curl -A 'agent/1' -e https://ref.example https://a.example/x`,
			CurlRequest{Method: "GET", URL: "https://a.example/x",
				Headers: []CurlHeader{{"User-Agent", "agent/1"}, {"Referer", "https://ref.example"}}}},
		{"Chrome copy as cURL (bash)", "curl 'https://a.example/x' \\\n  -H 'accept: */*' \\\n  -H 'accept-language: en' \\\n  --compressed",
			CurlRequest{Method: "GET", URL: "https://a.example/x",
				Headers: []CurlHeader{{"accept", "*/*"}, {"accept-language", "en"}},
				Ignored: []string{"--compressed"}}},
		{"$'…' quoting", `curl https://a.example/x --data-raw $'{"a":"line\nbreak"}'`,
			CurlRequest{Method: "POST", URL: "https://a.example/x",
				Headers: []CurlHeader{{"Content-Type", "application/x-www-form-urlencoded"}},
				Body:    "{\"a\":\"line\nbreak\"}", HasBody: true}},
		{"double quotes with escapes", `curl "https://a.example/x" -H "X-Q: \"q\""`,
			CurlRequest{Method: "GET", URL: "https://a.example/x",
				Headers: []CurlHeader{{"X-Q", `"q"`}}}},
		{"leading whitespace", "  \n curl https://a.example/x",
			CurlRequest{Method: "GET", URL: "https://a.example/x"}},
		{"ignored flags", `curl -sSL -v -i --max-time 5 -o out.json https://a.example/x`,
			CurlRequest{Method: "GET", URL: "https://a.example/x",
				Ignored: []string{"-s", "-S", "-L", "-v", "-i", "--max-time", "-o"}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseCurl(tc.text)
			if err != nil {
				t.Fatalf("ParseCurl: %v", err)
			}
			normalize(&got)
			normalize(&tc.want)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got  %+v\nwant %+v", got, tc.want)
			}
		})
	}
}

func TestParseCurlDropsAndNamesWhatWakilCannotCarry(t *testing.T) {
	for _, tc := range []struct {
		name    string
		text    string
		dropped []string // names, in order
	}{
		{"authorization header", `curl -H 'Authorization: Bearer s3cr3t' https://a.example/x`, []string{"Authorization"}},
		{"cookie header any case", `curl -H 'COOKIE: sid=s3cr3t' https://a.example/x`, []string{"COOKIE"}},
		{"host and proxy headers", `curl -H 'Host: evil' -H 'Proxy-Authorization: s3cr3t' https://a.example/x`, []string{"Host", "Proxy-Authorization"}},
		{"-u", `curl -u admin:s3cr3t https://a.example/x`, []string{"-u"}},
		{"-b", `curl -b 'sid=s3cr3t' https://a.example/x`, []string{"-b"}},
		{"-F", `curl -F 'file=@/etc/passwd' https://a.example/x`, []string{"-F"}},
		{"--data @file", `curl --data @/Users/me/s3cr3t.json https://a.example/x`, []string{"--data @file"}},
		{"-T", `curl -T /tmp/s3cr3t https://a.example/x`, []string{"-T"}},
		{"-k", `curl -k https://a.example/x`, []string{"-k"}},
		{"unknown flag", `curl --frobnicate https://a.example/x`, []string{"--frobnicate"}},
		{"a body on a GET", `curl -X GET -d 'a=1' https://a.example/x`, []string{"a body on a GET"}},
		{"a fragment", `curl 'https://a.example/x#s3cr3t'`, []string{"#fragment"}},
		{"an extra argument", `curl https://a.example/x s3cr3t`, []string{"an extra argument"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseCurl(tc.text)
			if err != nil {
				t.Fatalf("ParseCurl: %v", err)
			}
			var names []string
			for _, d := range got.Dropped {
				names = append(names, d.Name)
				if d.Reason == "" {
					t.Errorf("dropped %q carries no reason", d.Name)
				}
			}
			if !reflect.DeepEqual(names, tc.dropped) {
				t.Fatalf("dropped %v, want %v", names, tc.dropped)
			}
		})
	}
}

// Review Focus 1: the value of anything dropped appears nowhere in the result.
func TestParseCurlNeverCarriesADroppedValue(t *testing.T) {
	// The URL comes first: an unknown flag is read as taking no value, so the word after it is
	// an extra argument — dropped by name — rather than the URL.
	text := `curl 'https://a.example/x#s3cr3t' -H 'AUTHORIZATION: Bearer s3cr3t' -H 'cookie: a=s3cr3t' ` +
		`-u u:s3cr3t -b s3cr3t -F f=@s3cr3t --data @s3cr3t -T s3cr3t --frobnicate s3cr3t`
	got, err := ParseCurl(text)
	if err != nil {
		t.Fatalf("ParseCurl: %v", err)
	}
	if blob := fmt.Sprintf("%+v", got); strings.Contains(blob, "s3cr3t") {
		t.Fatalf("a dropped value leaked: %s", blob)
	}
}

func TestParseCurlRefusesWhatItCannotRead(t *testing.T) {
	for _, tc := range []struct{ name, text, want string }{
		{"not curl", `wget https://a.example/x`, "not a cURL command"},
		{"windows cmd", `curl ^"https://a.example/x^"`, "not a cURL command Wakil can read: Windows cmd quoting"},
		{"two commands &&", `curl https://a.example/x && curl https://b.example`, "not a cURL command Wakil can read: more than one command"},
		{"pipe", `curl https://a.example/x | jq .`, "not a cURL command Wakil can read: more than one command"},
		{"semicolon", `curl https://a.example/x; ls`, "not a cURL command Wakil can read: more than one command"},
		{"unterminated quote", `curl 'https://a.example/x`, "not a cURL command Wakil can read: an unterminated quote"},
		{"no URL", `curl -X POST`, "the cURL command names no URL"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ParseCurl(tc.text)
			if err == nil || err.Error() != tc.want {
				t.Fatalf("err = %v, want %q", err, tc.want)
			}
		})
	}
}

func normalize(r *CurlRequest) {
	if len(r.Headers) == 0 { r.Headers = nil }
	if len(r.Dropped) == 0 { r.Dropped = nil }
	if len(r.Ignored) == 0 { r.Ignored = nil }
}
```

Add `"fmt"` to the imports.

- [ ] **Step 3: Run them to see them fail**

Run: `go test ./internal/wakilcore/ -run 'TestParseCurl' -v`
Expected: FAIL to compile — `undefined: ParseCurl`, `undefined: CurlRequest`.

- [ ] **Step 4: Write `curl.go`**

```go
package wakilcore

import (
	"net/url"
	"strings"
)

// CurlHeader, CurlDropped and CurlRequest are parse_curl's answer: the request curl would
// send, and what of the command Wakil does not carry — by NAME. A dropped item's value is
// never kept: a pasted Authorization token, a -u password or a cookie must not leave this
// function (Amendment 11d).
type CurlHeader struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type CurlDropped struct {
	Name   string `json:"name"`
	Reason string `json:"reason"`
}

type CurlRequest struct {
	Method  string        `json:"method"`
	URL     string        `json:"url"`
	Headers []CurlHeader  `json:"headers"`
	Body    string        `json:"body"`
	HasBody bool          `json:"hasBody"`
	Dropped []CurlDropped `json:"dropped"`
	Ignored []string      `json:"ignored"`
}

const (
	reasonCredential = "a credential — the entry's credential comes from wakil secrets set-api"
	reasonCookie     = "a cookie — Wakil sends no cookie"
	reasonManaged    = "managed by Wakil"
	reasonMultipart  = "a multipart form — Wakil sends no multipart body"
	reasonFile       = "a body read from a file — Wakil reads no file on a paste"
	reasonInsecure   = "Wakil always verifies TLS"
	reasonUnknown    = "not a flag Wakil reads"
	reasonGetBody    = "a body on a GET is not sent"
	reasonFragment   = "a #fragment is not sent"
	reasonExtra      = "curl would request it as a second URL"
)

// Flags that change curl and not the request: ignored without a word (11c). The value
// they take, if any, is skipped too.
var curlIgnoredWithValue = map[string]bool{
	"-o": true, "--output": true, "-m": true, "--max-time": true, "--connect-timeout": true,
	"-w": true, "--write-out": true, "--retry": true,
}
var curlIgnored = map[string]bool{
	"-s": true, "--silent": true, "-S": true, "--show-error": true, "-v": true, "--verbose": true,
	"-i": true, "--include": true, "-L": true, "--location": true, "--compressed": true,
	"-O": true, "--remote-name": true, "--http1.1": true, "--http2": true, "-f": true, "--fail": true,
}

// Short flags that take a value, for splitting combined short flags (-sSX POST, -XPOST).
var curlShortWithValue = map[byte]bool{
	'X': true, 'H': true, 'd': true, 'u': true, 'b': true, 'F': true, 'T': true, 'A': true,
	'e': true, 'o': true, 'm': true, 'w': true,
}

// ParseCurl reads text as one cURL command — POSIX shell quoting, as Chrome's and Firefox's
// "Copy as cURL (bash)", Postman and API docs write it — and answers the request curl would
// send. It touches no network, no configuration and no file.
func ParseCurl(text string) (CurlRequest, error) {
	trimmed := strings.TrimLeft(text, " \t\r\n")
	if !strings.HasPrefix(trimmed, "curl ") && !strings.HasPrefix(trimmed, "curl\\") &&
		!strings.HasPrefix(trimmed, "curl\t") && !strings.HasPrefix(trimmed, "curl\n") {
		return CurlRequest{}, UserError("not a cURL command")
	}
	if strings.Contains(trimmed, `^"`) {
		return CurlRequest{}, UserError("not a cURL command Wakil can read: Windows cmd quoting")
	}
	words, err := curlWords(trimmed)
	if err != nil {
		return CurlRequest{}, err
	}
	words = words[1:] // "curl"

	var r CurlRequest
	var data []string
	explicitMethod, get, head := "", false, false
	dataIsJSON := false
	drop := func(name, reason string) { r.Dropped = append(r.Dropped, CurlDropped{name, reason}) }

	for i := 0; i < len(words); i++ {
		w := words[i]
		next := func() (string, bool) {
			if i+1 < len(words) {
				i++
				return words[i], true
			}
			return "", false
		}
		flag, attached, hasAttached := w, "", false
		if strings.HasPrefix(w, "--") {
			if eq := strings.IndexByte(w, '='); eq > 0 {
				flag, attached, hasAttached = w[:eq], w[eq+1:], true
			}
		} else if strings.HasPrefix(w, "-") && len(w) > 2 {
			// Combined short flags: each boolean letter stands alone; the first letter that
			// takes a value takes the rest of the word (or the next word).
			for j := 1; j < len(w); j++ {
				c := w[j]
				if curlShortWithValue[c] {
					flag = "-" + string(c)
					if j+1 < len(w) {
						attached, hasAttached = w[j+1:], true
					}
					break
				}
				single := "-" + string(c)
				if j == len(w)-1 {
					flag = single
				} else {
					handleBoolean(single, &r, &get, &head, drop)
				}
			}
		}
		value := func() (string, bool) {
			if hasAttached {
				return attached, true
			}
			return next()
		}

		switch {
		case !strings.HasPrefix(flag, "-"):
			if r.URL == "" {
				r.URL = w
			} else {
				drop("an extra argument", reasonExtra)
			}
		case flag == "-X" || flag == "--request":
			v, _ := value()
			explicitMethod = strings.ToUpper(v)
		case flag == "--url":
			v, _ := value()
			r.URL = v
		case flag == "-H" || flag == "--header":
			v, _ := value()
			name, val, _ := strings.Cut(v, ":")
			name = strings.TrimSpace(name)
			val = strings.TrimSpace(val)
			switch lower := strings.ToLower(name); {
			case lower == "authorization":
				drop(name, reasonCredential)
			case lower == "cookie":
				drop(name, reasonCookie)
			case lower == "host" || strings.HasPrefix(lower, "proxy-"):
				drop(name, reasonManaged)
			default:
				r.Headers = append(r.Headers, CurlHeader{name, val})
			}
		case flag == "-A" || flag == "--user-agent":
			v, _ := value()
			r.Headers = append(r.Headers, CurlHeader{"User-Agent", v})
		case flag == "-e" || flag == "--referer":
			v, _ := value()
			r.Headers = append(r.Headers, CurlHeader{"Referer", v})
		case flag == "-d" || flag == "--data" || flag == "--data-ascii" || flag == "--data-binary" || flag == "--json":
			v, _ := value()
			if strings.HasPrefix(v, "@") {
				drop(flag+" @file", reasonFile)
				continue
			}
			if flag == "--json" {
				dataIsJSON = true
			}
			data = append(data, v)
		case flag == "--data-raw":
			v, _ := value()
			data = append(data, v)
		case flag == "--data-urlencode":
			v, _ := value()
			if name, content, ok := strings.Cut(v, "="); ok {
				data = append(data, name+"="+url.QueryEscape(content))
			} else if strings.Contains(v, "@") {
				drop(flag+" @file", reasonFile)
			} else {
				data = append(data, url.QueryEscape(v))
			}
		case flag == "-u" || flag == "--user":
			value()
			drop("-u", reasonCredential)
		case flag == "-b" || flag == "--cookie":
			value()
			drop("-b", reasonCookie)
		case flag == "-F" || flag == "--form" || flag == "--form-string":
			value()
			drop("-F", reasonMultipart)
		case flag == "-T" || flag == "--upload-file":
			value()
			drop("-T", reasonFile)
		case curlIgnoredWithValue[flag]:
			value()
			r.Ignored = append(r.Ignored, flag)
		default:
			handleBoolean(flag, &r, &get, &head, drop)
		}
	}

	if r.URL == "" {
		return CurlRequest{}, UserError("the cURL command names no URL")
	}
	if hash := strings.IndexByte(r.URL, '#'); hash >= 0 {
		r.URL = r.URL[:hash]
		drop("#fragment", reasonFragment)
	}

	joined := strings.Join(data, "&")
	switch {
	case explicitMethod != "":
		r.Method = explicitMethod
	case head:
		r.Method = "HEAD"
	case get:
		r.Method = "GET"
	case len(data) > 0:
		r.Method = "POST"
	default:
		r.Method = "GET"
	}
	if get && len(data) > 0 {
		sep := "?"
		if strings.Contains(r.URL, "?") {
			sep = "&"
		}
		r.URL += sep + joined
	} else if len(data) > 0 {
		if r.Method == "GET" || r.Method == "HEAD" {
			drop("a body on a "+r.Method, reasonGetBody)
		} else {
			r.Body, r.HasBody = joined, true
			if !hasHeader(r.Headers, "content-type") {
				ct := "application/x-www-form-urlencoded"
				if dataIsJSON {
					ct = "application/json"
				}
				r.Headers = append(r.Headers, CurlHeader{"Content-Type", ct})
			}
		}
	}
	return r, nil
}

func handleBoolean(flag string, r *CurlRequest, get, head *bool, drop func(string, string)) {
	switch {
	case flag == "-G" || flag == "--get":
		*get = true
	case flag == "-I" || flag == "--head":
		*head = true
	case flag == "-k" || flag == "--insecure":
		drop("-k", reasonInsecure)
	case curlIgnored[flag]:
		r.Ignored = append(r.Ignored, flag)
	default:
		drop(flag, reasonUnknown)
	}
}

func hasHeader(headers []CurlHeader, lower string) bool {
	for _, h := range headers {
		if strings.EqualFold(h.Name, lower) {
			return true
		}
	}
	return false
}

// curlWords splits a command the way a POSIX shell would: single quotes, double quotes with
// \" \\ \$ \` and \-newline escapes, $'…' with C escapes, and \-newline continuations. An
// unquoted ;, & or | means more than one command.
func curlWords(s string) ([]string, error) {
	var words []string
	var cur strings.Builder
	inWord := false
	flush := func() {
		if inWord {
			words = append(words, cur.String())
			cur.Reset()
			inWord = false
		}
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\' && i+1 < len(s) && (s[i+1] == '\n' || (s[i+1] == '\r' && i+2 < len(s) && s[i+2] == '\n')):
			if s[i+1] == '\r' {
				i++
			}
			i++
		case c == '\\' && i+1 < len(s):
			cur.WriteByte(s[i+1])
			inWord = true
			i++
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			flush()
		case c == ';' || c == '|' || c == '&':
			return nil, UserError("not a cURL command Wakil can read: more than one command")
		case c == '\'':
			end := strings.IndexByte(s[i+1:], '\'')
			if end < 0 {
				return nil, UserError("not a cURL command Wakil can read: an unterminated quote")
			}
			cur.WriteString(s[i+1 : i+1+end])
			inWord = true
			i += end + 1
		case c == '$' && i+1 < len(s) && s[i+1] == '\'':
			j := i + 2
			for ; j < len(s) && s[j] != '\''; j++ {
				if s[j] == '\\' && j+1 < len(s) {
					j++
					switch s[j] {
					case 'n':
						cur.WriteByte('\n')
					case 't':
						cur.WriteByte('\t')
					case 'r':
						cur.WriteByte('\r')
					default:
						cur.WriteByte(s[j])
					}
					continue
				}
				cur.WriteByte(s[j])
			}
			if j >= len(s) {
				return nil, UserError("not a cURL command Wakil can read: an unterminated quote")
			}
			inWord = true
			i = j
		case c == '"':
			j := i + 1
			for ; j < len(s) && s[j] != '"'; j++ {
				if s[j] == '\\' && j+1 < len(s) && strings.IndexByte("\"\\$`\n", s[j+1]) >= 0 {
					j++
					if s[j] != '\n' {
						cur.WriteByte(s[j])
					}
					continue
				}
				cur.WriteByte(s[j])
			}
			if j >= len(s) {
				return nil, UserError("not a cURL command Wakil can read: an unterminated quote")
			}
			inWord = true
			i = j
		default:
			cur.WriteByte(c)
			inWord = true
		}
	}
	flush()
	return words, nil
}
```

Note for the implementer: `UserError` is `internal/wakilcore`'s existing user-facing error constructor (`grep -n "func UserError" internal/wakilcore/*.go`). If `strings.Cut` on a header with no colon leaves `val` empty, the header is kept with an empty value — curl's `-H 'X-Empty;'` form is not special-cased.

- [ ] **Step 5: Run the tests to see them pass**

Run: `go test ./internal/wakilcore/ -run 'TestParseCurl' -v`
Expected: PASS, every subtest. Fix the implementation (not the expectations) for any failure, except where a test contradicts the spec — then stop and report.

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/curl.go internal/wakilcore/curl_test.go docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md
git commit -m "2c-iv Amendment 11: ParseCurl reads a cURL command the way a shell and curl would, naming what it drops"
```

---

### Task 2: `LocateAPIURL`, and both tools on `wakil-http`

**Files:**
- Create: `internal/wakilcore/apilocate.go`, `internal/wakilcore/apilocate_test.go`
- Modify: `cmd/wakil-http/main.go` (two `mcp.AddTool` calls before `return s` in `newServer`)
- Test: `cmd/wakil-http/main_test.go` (two tool tests)

**Interfaces:**
- Consumes: `ParseCurl` (Task 1); `Resolve()` (`internal/wakilcore/resolve.go:121`, returns `*Resolved` with `Project *Project` and `Environment string`).
- Produces:
  ```go
  type APILocation struct {
      Found       bool     `json:"found"`
      Active      bool     `json:"active"`       // matched in the active environment
      Environment string   `json:"environment"`  // where it matched; the active one when not found
      Entry       string   `json:"entry,omitempty"`
      Path        string   `json:"path"`         // after the base path, with ?query; "" for the base itself
      Host        string   `json:"host"`         // the URL's host, for the refusal
      Entries     []string `json:"entries"`      // the active environment's entry names, for the refusal
  }
  func LocateAPIURL(p Project, activeEnv, rawURL string) APILocation
  ```
  Tools: `parse_curl {text}` → `CurlRequest`; `locate_api_url {url}` → `APILocation`.

- [ ] **Step 1: Write the failing tests**

```go
package wakilcore

import "testing"

func locateProject() Project {
	return Project{Environments: map[string]Environment{
		"staging": {API: []ApiConfig{
			{Name: "billing", BaseURL: "https://billing.example.com"},
			{Name: "catalog", BaseURL: "https://api.example.com"},
			{Name: "catalog-v2", BaseURL: "https://api.example.com/v2/"},
		}},
		"qa": {API: []ApiConfig{{Name: "catalog", BaseURL: "https://catalog-qa.example.com"}}},
	}}
}

func TestLocateAPIURLInTheActiveEnvironment(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://billing.example.com/v1/invoices?paid=true")
	if !got.Found || !got.Active || got.Entry != "billing" || got.Environment != "staging" ||
		got.Path != "/v1/invoices?paid=true" {
		t.Fatalf("%+v", got)
	}
}

// Review Focus 2.
func TestLocateAPIURLLongestBasePathWins(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://api.example.com/v2/items/7")
	if got.Entry != "catalog-v2" || got.Path != "/items/7" {
		t.Fatalf("%+v", got)
	}
	got = LocateAPIURL(locateProject(), "staging", "https://api.example.com/v20/items")
	if got.Entry != "catalog" || got.Path != "/v20/items" {
		t.Fatalf("a base path must match whole segments: %+v", got)
	}
	got = LocateAPIURL(locateProject(), "staging", "https://api.example.com/v2")
	if got.Entry != "catalog-v2" || got.Path != "" {
		t.Fatalf("the base itself: %+v", got)
	}
}

// Review Focus 3.
func TestLocateAPIURLNormalizesHostAndDefaultPort(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://BILLING.example.com:443/x")
	if got.Entry != "billing" || got.Path != "/x" {
		t.Fatalf("%+v", got)
	}
	if got := LocateAPIURL(locateProject(), "staging", "http://billing.example.com/x"); got.Found {
		t.Fatalf("another scheme is another origin: %+v", got)
	}
	if got := LocateAPIURL(locateProject(), "staging", "https://billing.example.com:8443/x"); got.Found {
		t.Fatalf("another port is another origin: %+v", got)
	}
}

func TestLocateAPIURLInAnotherEnvironment(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://catalog-qa.example.com/x")
	if !got.Found || got.Active || got.Environment != "qa" || got.Entry != "catalog" {
		t.Fatalf("%+v", got)
	}
}

func TestLocateAPIURLNowhere(t *testing.T) {
	got := LocateAPIURL(locateProject(), "staging", "https://other.example.net/x")
	if got.Found || got.Host != "other.example.net" || got.Environment != "staging" {
		t.Fatalf("%+v", got)
	}
	want := []string{"billing", "catalog", "catalog-v2"}
	if len(got.Entries) != 3 || got.Entries[0] != want[0] || got.Entries[2] != want[2] {
		t.Fatalf("entries %v, want %v", got.Entries, want)
	}
}
```

In `cmd/wakil-http/main_test.go`, add (reusing `setupProject` and `connectedClient`):

```go
func TestParseCurlTool(t *testing.T) {
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "parse_curl", Arguments: map[string]any{"text": `curl -X POST https://a.example/x -H 'Authorization: Bearer s3cr3t' -d '{}'`}})
	if err != nil || res.IsError {
		t.Fatalf("parse_curl: %v %+v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	if strings.Contains(string(raw), "s3cr3t") || !strings.Contains(string(raw), `"Authorization"`) {
		t.Fatalf("structured: %s", raw)
	}
}

func TestLocateAPIURLTool(t *testing.T) {
	setupProject(t, `"staging":{"api":[{"name":"billing","baseUrl":"https://billing.example.com"}]},`+
		`"qa":{"api":[{"name":"catalog","baseUrl":"https://catalog-qa.example.com"}]}`, "staging")
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "locate_api_url", Arguments: map[string]any{"url": "https://catalog-qa.example.com/x"}})
	if err != nil || res.IsError {
		t.Fatalf("locate_api_url: %v %+v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(raw), `"environment":"qa"`) || !strings.Contains(string(raw), `"entry":"catalog"`) {
		t.Fatalf("structured: %s", raw)
	}
}
```

Add the imports the file lacks (`encoding/json`, `strings`).

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore/ -run TestLocateAPIURL -v && go test ./cmd/wakil-http/ -run 'TestParseCurlTool|TestLocateAPIURLTool' -v`
Expected: FAIL — `undefined: LocateAPIURL`; the tool tests fail with an unknown tool.

- [ ] **Step 3: Write `apilocate.go`**

```go
package wakilcore

import (
	"net/url"
	"sort"
	"strings"
)

type APILocation struct {
	Found       bool     `json:"found"`
	Active      bool     `json:"active"`
	Environment string   `json:"environment"`
	Entry       string   `json:"entry,omitempty"`
	Path        string   `json:"path"`
	Host        string   `json:"host"`
	Entries     []string `json:"entries"`
}

// LocateAPIURL answers which API entry a URL belongs to (Amendment 11b): the same origin
// (scheme, host, port — host case and the scheme's default port normalized), and the URL's
// path at or under the entry's base path, by whole segments. The active environment first;
// the longest base path wins. Then the other environments, by name. It reads the given
// project and nothing else.
func LocateAPIURL(p Project, activeEnv, rawURL string) APILocation {
	loc := APILocation{Environment: activeEnv}
	u, err := url.Parse(rawURL)
	if err != nil {
		return loc
	}
	loc.Host = u.Hostname()
	for _, e := range p.Environments[activeEnv].API {
		loc.Entries = append(loc.Entries, e.Name)
	}
	sort.Strings(loc.Entries)

	if entry, rest, ok := bestEntry(p.Environments[activeEnv].API, u); ok {
		loc.Found, loc.Active, loc.Entry, loc.Path = true, true, entry, rest
		return loc
	}
	names := make([]string, 0, len(p.Environments))
	for name := range p.Environments {
		if name != activeEnv {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		if entry, rest, ok := bestEntry(p.Environments[name].API, u); ok {
			loc.Found, loc.Environment, loc.Entry, loc.Path = true, name, entry, rest
			return loc
		}
	}
	return loc
}

func bestEntry(entries []ApiConfig, u *url.URL) (string, string, bool) {
	best, bestLen, rest, found := "", -1, "", false
	for _, e := range entries {
		base, err := url.Parse(e.BaseURL)
		if err != nil || !sameOrigin(base, u) {
			continue
		}
		bp := strings.TrimSuffix(base.EscapedPath(), "/")
		up := u.EscapedPath()
		if bp != "" && up != bp && !strings.HasPrefix(up, bp+"/") {
			continue
		}
		if len(bp) > bestLen {
			best, bestLen, found = e.Name, len(bp), true
			rest = strings.TrimPrefix(up, bp)
			if u.RawQuery != "" {
				rest += "?" + u.RawQuery
			}
		}
	}
	return best, rest, found
}

func sameOrigin(a, b *url.URL) bool {
	if !strings.EqualFold(a.Scheme, b.Scheme) || !strings.EqualFold(a.Hostname(), b.Hostname()) {
		return false
	}
	return effectivePort(a) == effectivePort(b)
}

func effectivePort(u *url.URL) string {
	if p := u.Port(); p != "" {
		return p
	}
	switch strings.ToLower(u.Scheme) {
	case "https":
		return "443"
	case "http":
		return "80"
	}
	return ""
}
```

- [ ] **Step 4: Register both tools** in `cmd/wakil-http/main.go`'s `newServer`, after `list_apis` and before `return s`:

```go
	type parseCurlArg struct {
		Text string `json:"text" jsonschema:"the pasted text, starting with curl"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "parse_curl", Description: "Read a cURL command (POSIX shell quoting, as a browser's Copy as cURL (bash) writes it) and answer the request curl would send: method, url, headers, body. READ-ONLY and pure: no network, no configuration, no file read, nothing sent. What Wakil does not carry — a credential or cookie header, -u, -b, -F, a body read from a file, -k, an unknown flag, a body on a GET, a #fragment — is listed in dropped BY NAME with a reason, and its value is never returned. Flags that only change curl (-s, -v, -L, --compressed, -o, …) are listed in ignored."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a parseCurlArg) (*mcp.CallToolResult, wakilcore.CurlRequest, error) {
			r, err := wakilcore.ParseCurl(a.Text)
			if err != nil {
				return mcpx.ToolErr("wakil-http", err), wakilcore.CurlRequest{}, nil
			}
			return nil, r, nil
		})

	type locateArg struct {
		URL string `json:"url" jsonschema:"an absolute URL"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "locate_api_url", Description: "Say which API entry an absolute URL belongs to: the same origin (scheme, host, port) and a path at or under the entry's base path, the longest base path winning. The active environment is searched first (active true), then the project's other environments by name (active false, environment names where). found false means no entry in the project has that origin and path; entries then lists the active environment's entry names. READ-ONLY: reads the project configuration and nothing else."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a locateArg) (*mcp.CallToolResult, wakilcore.APILocation, error) {
			r, err := wakilcore.Resolve()
			if err != nil {
				return mcpx.ToolErr("wakil-http", err), wakilcore.APILocation{}, nil
			}
			return nil, wakilcore.LocateAPIURL(*r.Project, r.Environment, a.URL), nil
		})
```

If `cmd/wakil-http/schema_test.go`'s `TestOutputSchemasAreObjects` lists tool names explicitly, add both.

- [ ] **Step 5: Run the tests to see them pass**

Run: `go test ./internal/wakilcore/ ./cmd/wakil-http/ -v -run 'TestLocateAPIURL|TestParseCurl|TestOutputSchemas'`
Expected: PASS. Then `go test ./...` — green.

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/apilocate.go internal/wakilcore/apilocate_test.go cmd/wakil-http/
git commit -m "2c-iv Amendment 11: locate_api_url and parse_curl on wakil-http — read-only, by name"
```

---

### Task 3: `apiCurlFill` — what the fill means, in WakilKit

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiCurlFill.swift`
- Create: `app/Tests/WakilKitTests/ApiCurlFillTests.swift`

**Interfaces:**
- Consumes: `ApiDraft`, `ApiPart`, `ApiQueryRow`, `ApiHeaderRow` (`ApiDraft.swift`); the existing path↔query split used by `api_set_request`'s path view — find it with `grep -n "func apiPathQuery\|func apiSplitPathQuery\|func apiPathAndQuery" app/Sources/WakilKit/Api/ApiPathQuery.swift` and use it rather than writing a second split.
- Produces:
  ```swift
  public struct ApiCurlParsed: Sendable, Equatable {
      public var method: String; public var url: String
      public var headers: [(name: String, value: String)]   // Equatable by hand
      public var body: String; public var hasBody: Bool
      public var dropped: [String]                          // names only
      public init(json: JSONValue) throws                   // parse_curl's structuredContent
  }
  public struct ApiCurlLocation: Sendable, Equatable {
      public var found: Bool; public var active: Bool; public var environment: String
      public var entry: String; public var path: String; public var host: String; public var entries: [String]
      public init(json: JSONValue) throws                   // locate_api_url's structuredContent
  }
  public enum ApiCurlFill: Sendable, Equatable {
      case fill(draft: ApiDraft, switchesEntry: Bool, dropped: [String])
      case refused(String)
  }
  public func apiCurlFill(_ parsed: ApiCurlParsed, _ location: ApiCurlLocation, current: ApiDraft) -> ApiCurlFill
  public func apiCurlFillLine(entry: String, dropped: [String]) -> ApiBindLine
  public func apiPasteIsCurl(_ text: String) -> Bool
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

private func parsed(
    method: String = "GET", url: String = "https://billing.example.com/v1/x",
    headers: [(String, String)] = [], body: String = "", hasBody: Bool = false, dropped: [String] = []
) -> ApiCurlParsed {
    ApiCurlParsed(method: method, url: url, headers: headers.map { (name: $0.0, value: $0.1) },
                  body: body, hasBody: hasBody, dropped: dropped)
}

private func here(entry: String = "billing", path: String = "/v1/x") -> ApiCurlLocation {
    ApiCurlLocation(found: true, active: true, environment: "staging", entry: entry, path: path,
                    host: "billing.example.com", entries: ["billing", "catalog"])
}

@Test("A fill replaces the whole draft: method, path, query, headers, body")
func aFillReplacesTheWholeDraft() {
    var current = ApiDraft.empty
    current.entry = "billing"
    current.headers = [ApiHeaderRow(name: "x-old", value: [.literal("1")])]
    current.body = [.literal("old")]
    let fill = apiCurlFill(
        parsed(method: "POST", headers: [("X-Trace", "7")], body: "{\"a\":1}", hasBody: true),
        here(path: "/v1/x?paid=true&page=2"), current: current)
    guard case .fill(let draft, let switches, let dropped) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.entry == "billing")
    #expect(!switches)
    #expect(dropped.isEmpty)
    #expect(draft.method == "POST")
    #expect(draft.path == [.literal("/v1/x")])
    #expect(draft.query == [ApiQueryRow(name: "paid", value: [.literal("true")]),
                            ApiQueryRow(name: "page", value: [.literal("2")])])
    #expect(draft.headers == [ApiHeaderRow(name: "X-Trace", value: [.literal("7")])])
    #expect(draft.body == [.literal("{\"a\":1}")])
}

@Test("content-type goes to Wakil's own row, whatever its case")
func contentTypeGoesToItsOwnRow() {
    let fill = apiCurlFill(parsed(method: "POST", headers: [("Content-Type", "application/json")],
                                  body: "{}", hasBody: true), here(), current: .empty)
    guard case .fill(let draft, _, _) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.contentType == "application/json")
    #expect(draft.headers.isEmpty)
}

@Test("Another entry in this environment switches the pane to it")
func anotherEntrySwitches() {
    var current = ApiDraft.empty
    current.entry = "catalog"
    let fill = apiCurlFill(parsed(), here(entry: "billing"), current: current)
    guard case .fill(let draft, let switches, _) = fill else { Issue.record("\(fill)"); return }
    #expect(draft.entry == "billing")
    #expect(switches)
}

@Test("An entry only in another environment is refused, naming it")
func anotherEnvironmentIsRefused() {
    var loc = here(entry: "catalog")
    loc.active = false
    loc.environment = "qa"
    #expect(apiCurlFill(parsed(), loc, current: .empty)
        == .refused("this cURL is for catalog in qa; switch environment first"))
}

@Test("No entry has the host: refused, naming the host and the entries")
func noEntryIsRefused() {
    let loc = ApiCurlLocation(found: false, active: false, environment: "staging", entry: "",
                              path: "", host: "api.other.com", entries: ["billing", "catalog"])
    #expect(apiCurlFill(parsed(url: "https://api.other.com/x"), loc, current: .empty)
        == .refused("this cURL is for api.other.com; no entry in staging has that host (entries: billing, catalog)"))
}

@Test("parse_curl's dropped names pass through to the line")
func droppedPassThrough() {
    let fill = apiCurlFill(parsed(dropped: ["Authorization", "-k"]), here(), current: .empty)
    guard case .fill(_, _, let dropped) = fill else { Issue.record("\(fill)"); return }
    #expect(dropped == ["Authorization", "-k"])
}

@Test("The line names the entry, and what was dropped")
func theLine() {
    #expect(apiCurlFillLine(entry: "billing", dropped: [])
        == ApiBindLine(text: "Filled from cURL · billing", caution: false))
    #expect(apiCurlFillLine(entry: "billing", dropped: ["Authorization", "-k"])
        == ApiBindLine(text: "Filled from cURL · billing · dropped: Authorization, -k", caution: false))
}

@Test("Only text starting with curl, after leading whitespace, is a cURL paste")
func pasteIsCurl() {
    #expect(apiPasteIsCurl("curl https://a"))
    #expect(apiPasteIsCurl("  \n\tcurl 'https://a'"))
    #expect(apiPasteIsCurl("curl\\\n  https://a"))
    #expect(!apiPasteIsCurl("curly"))
    #expect(!apiPasteIsCurl("/v1/curl"))
    #expect(!apiPasteIsCurl("curl"))
}

@Test("ApiCurlParsed reads parse_curl's result, names only for dropped")
func parsedReadsTheTool() throws {
    let json: JSONValue = .object([
        "method": .string("POST"), "url": .string("https://a.example/x"),
        "headers": .array([.object(["name": .string("X"), "value": .string("1")])]),
        "body": .string("b"), "hasBody": .bool(true),
        "dropped": .array([.object(["name": .string("-u"), "reason": .string("a credential …")])]),
        "ignored": .array([.string("-s")]),
    ])
    let p = try ApiCurlParsed(json: json)
    #expect(p.method == "POST" && p.body == "b" && p.hasBody && p.dropped == ["-u"])
    #expect(p.headers.count == 1 && p.headers[0].name == "X" && p.headers[0].value == "1")
}
```

The memberwise `init` used by the helpers above is internal; declare it in the implementation.

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && swift test --filter ApiCurlFillTests`
Expected: FAIL to compile — `cannot find 'ApiCurlParsed' in scope`.

- [ ] **Step 3: Write `ApiCurlFill.swift`**

```swift
import Foundation

/// Amendment 11 — a cURL command pasted into the path. **Nothing here reads cURL or a shell**:
/// `parse_curl` (Go) has already read the command and `locate_api_url` (Go) has placed its
/// URL. This decides what that means for the pane — fill, switch, or refuse — and words the line.
public struct ApiCurlParsed: Sendable, Equatable {
    public var method: String
    public var url: String
    public var headers: [(name: String, value: String)]
    public var body: String
    public var hasBody: Bool
    /// What `parse_curl` did not carry, by name. Never a value (11d).
    public var dropped: [String]

    init(method: String, url: String, headers: [(name: String, value: String)],
         body: String, hasBody: Bool, dropped: [String]) {
        self.method = method; self.url = url; self.headers = headers
        self.body = body; self.hasBody = hasBody; self.dropped = dropped
    }

    public init(json: JSONValue) throws {
        guard case .object(let o) = json else { throw ApiCurlUnreadable() }
        func string(_ key: String) -> String {
            if case .string(let s)? = o[key] { return s }
            return ""
        }
        method = string("method")
        url = string("url")
        body = string("body")
        if case .bool(let b)? = o["hasBody"] { hasBody = b } else { hasBody = false }
        headers = {
            guard case .array(let items)? = o["headers"] else { return [] }
            return items.compactMap { item in
                guard case .object(let h) = item, case .string(let n)? = h["name"] else { return nil }
                if case .string(let v)? = h["value"] { return (name: n, value: v) }
                return (name: n, value: "")
            }
        }()
        dropped = {
            guard case .array(let items)? = o["dropped"] else { return [] }
            return items.compactMap { item in
                guard case .object(let d) = item, case .string(let n)? = d["name"] else { return nil }
                return n
            }
        }()
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.method == b.method && a.url == b.url && a.body == b.body && a.hasBody == b.hasBody
            && a.dropped == b.dropped && a.headers.count == b.headers.count
            && zip(a.headers, b.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

public struct ApiCurlLocation: Sendable, Equatable {
    public var found: Bool
    public var active: Bool
    public var environment: String
    public var entry: String
    public var path: String
    public var host: String
    public var entries: [String]

    init(found: Bool, active: Bool, environment: String, entry: String, path: String,
         host: String, entries: [String]) {
        self.found = found; self.active = active; self.environment = environment
        self.entry = entry; self.path = path; self.host = host; self.entries = entries
    }

    public init(json: JSONValue) throws {
        guard case .object(let o) = json else { throw ApiCurlUnreadable() }
        func string(_ key: String) -> String {
            if case .string(let s)? = o[key] { return s }
            return ""
        }
        func flag(_ key: String) -> Bool {
            if case .bool(let b)? = o[key] { return b }
            return false
        }
        found = flag("found"); active = flag("active")
        environment = string("environment"); entry = string("entry")
        path = string("path"); host = string("host")
        entries = {
            guard case .array(let items)? = o["entries"] else { return [] }
            return items.compactMap { if case .string(let s) = $0 { return s }; return nil }
        }()
    }
}

struct ApiCurlUnreadable: Error {}

public enum ApiCurlFill: Sendable, Equatable {
    case fill(draft: ApiDraft, switchesEntry: Bool, dropped: [String])
    case refused(String)
}

/// 11a–11c: the whole draft from the command, on the entry its URL names. Refused — and the
/// draft untouched — only when the URL belongs to no entry of this environment.
public func apiCurlFill(_ parsed: ApiCurlParsed, _ location: ApiCurlLocation, current: ApiDraft) -> ApiCurlFill {
    guard location.found else {
        return .refused("this cURL is for \(location.host); no entry in \(location.environment) "
            + "has that host (entries: \(location.entries.joined(separator: ", ")))")
    }
    guard location.active else {
        return .refused("this cURL is for \(location.entry) in \(location.environment); "
            + "switch environment first")
    }
    var draft = ApiDraft.empty
    draft.entry = location.entry
    draft.method = parsed.method
    // The existing path↔query split, on location.path — see Interfaces and the note below.
    let split = apiPathAndQueryParts(location.path)
    draft.path = split.path
    draft.query = split.query
    for header in parsed.headers {
        if header.name.caseInsensitiveCompare("content-type") == .orderedSame {
            draft.contentType = header.value
        } else {
            draft.headers.append(ApiHeaderRow(name: header.name, value: [.literal(header.value)]))
        }
    }
    draft.body = parsed.hasBody && !parsed.body.isEmpty ? [.literal(parsed.body)] : []
    return .fill(draft: draft, switchesEntry: location.entry != current.entry, dropped: parsed.dropped)
}

public func apiCurlFillLine(entry: String, dropped: [String]) -> ApiBindLine {
    var text = "Filled from cURL · \(entry)"
    if !dropped.isEmpty { text += " · dropped: " + dropped.joined(separator: ", ") }
    return ApiBindLine(text: text, caution: false)
}

/// 11a: the path editor reads a paste as a cURL command only when, after leading whitespace,
/// it starts with `curl` and a space, tab, newline or `\` line continuation.
public func apiPasteIsCurl(_ text: String) -> Bool {
    let trimmed = text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
    guard trimmed.hasPrefix("curl"), trimmed.count > 4 else { return false }
    let next = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)]
    return next == " " || next == "\t" || next == "\n" || next == "\\"
}
```

**`apiPathAndQueryParts` is a placeholder name for the existing split — replace it with the real function** (the Interfaces grep). If the existing split works on parts rather than a string, call it with `[.literal(location.path)]`. If no split function takes a path-with-query, write `apiPathAndQueryParts(_ s: String) -> (path: [ApiPart], query: [ApiQueryRow])` in this file, splitting at the first `?`, then each `&`-separated item at its first `=`, **percent-decoding names and values with `removingPercentEncoding`** (falling back to the raw text when that returns nil), and add a test `aQueryIsSplitAndDecoded` with `"/x?a=1&b=two%20words&flag"` → path `/x`, rows `a=1`, `b=two words`, `flag=` (empty).

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd app && swift test --filter ApiCurlFillTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Api/ApiCurlFill.swift app/Tests/WakilKitTests/ApiCurlFillTests.swift
git commit -m "2c-iv Amendment 11: apiCurlFill — the whole draft from a parsed command, on the entry its URL names"
```

---

### Task 4: `api_fill_from_curl`, `api_undo_fill`, and the kept draft

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (the kept draft)
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift` (two actions, registered after `api_set_request`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`fillFromCurlSurface`, `undoFillFromSurface`, beside `bindFromSurface` at ~4271)
- Modify: `app/Tests/WakilKitTests/ApiRecentTests.swift` (the comment in `curlEmitsAndNeverParses`)
- Create: `app/Tests/WakilKitTests/ApiCurlActionTests.swift`

**Interfaces:**
- Consumes: Task 3's `apiCurlFill`, `ApiCurlParsed(json:)`, `ApiCurlLocation(json:)`, `apiCurlFillLine`; `PaneStore.setApiDraft(paneId:draft:resolution:)`, `apiDraftCollisions(origin:writing:focused:)`, `apiEntry(named:action:http:)`, `apiPaneOrigin(baseURL:)`, `layout?.retitle(id:to:)`, `apiPaneTitle(entry:)` — all used by `api_set_request` (`ApiActions.swift:551–765`); the `http: (any ToolCaller)?` parameter of `registerApiActions`.
- Produces:
  ```swift
  // PaneStore
  func keepApiDraft(paneId: String, _ draft: ApiDraft) async        // a fill keeps what it replaced
  func apiKeptDraft(paneId: String) async -> ApiDraft?
  func forgetApiKeptDraft(paneId: String) async
  // Actions: "api_fill_from_curl" {pane, text} -> {pane, entry, switched, dropped:[names], line}
  //          "api_undo_fill" {pane} -> {pane, entry}
  // WindowModel
  public func fillFromCurlSurface(pane: String, text: String) async -> ApiBindOutcome
  public func undoFillFromSurface(pane: String) async -> ApiBindOutcome
  ```
  **The kept draft is forgotten** by every other write to the pane's draft (`setApiDraft` called from anywhere but these two actions), by a Send (`recordApiSend`), and by the next fill (which keeps its own). `read_pane` does not show it.

- [ ] **Step 1: Write the failing tests** in `ApiCurlActionTests.swift`. Use the existing test doubles: find a `ToolCaller` fake with `grep -rn "ToolCaller" app/Tests/WakilKitTests | head` (the api tests answer `list_apis` from one); extend or add a fake `CurlHTTP` that answers `parse_curl` and `locate_api_url` from canned `structuredContent`, records every call's name and arguments, and answers `list_apis` with `billing` (`https://billing.example.com`) and `catalog` (`https://api.example.com`). Register actions with `registerApiActions(into:panes:layout:http:activeContext:)` as `ApiRecentTests.curlReadsTheRowsCredentialNotTheRenderingPanes` does.

Tests, each one `@Test` with the quoted title:
1. `"A fill writes the whole draft and answers the line's parts"` — dispatch `api_fill_from_curl` `{pane, text}` with the fake answering a POST to billing; assert `panes.apiDraft` equals the expected draft; the result's `entry == "billing"`, `switched`, `dropped`, `line`.
2. `"A fill to another entry switches the pane and retitles it"` — pane on `catalog`, fill for billing: the snapshot's entry is `billing`, origin `https://billing.example.com`, credentialed as listed; `switched == true`.
3. `"A refused fill leaves the draft untouched and throws the refusal"` — location not found: dispatch throws; `String(describing: error)` contains `no entry in staging has that host`; the draft equals what it was.
4. `"Undo puts back the draft the fill replaced, and forgets it"` — set a draft, fill, `api_undo_fill`: the draft equals the original; a second `api_undo_fill` throws `nothing to undo`.
5. `undoRestoresABindingTheFillReplaced` — `"Undo brings back a binding the fill replaced"` (Review Focus 4): put a bound part in the path (use the existing api_bind test fixture helper — `grep -rn "func bound\|binding:" app/Tests/WakilKitTests/ApiHandBindTests.swift | head`), fill, undo: the bound part is back exactly.
6. `"Any other write forgets the kept draft"` — fill, then `api_set_request` with a method: `api_undo_fill` throws `nothing to undo`. Same after `panes.recordApiSend`.
7. `anAgentFillUnderTheOperatorsHandIsRefused` — `"An agent fill while the operator is in a field is Decision 27's refusal"` (Review Focus 5): set the pane's focus to the path the way the existing Decision 27 tests do (`grep -rn "underTheOperatorsHand\|apiFocus" app/Tests/WakilKitTests | head -3`), dispatch with origin `.agent`: throws, wording contains `the operator is editing Path`; nothing written; with origin `.ui` it fills.
8. `"The pasted text is journalled as redacted"` — dispatch a fill whose text holds `s3cr3t`; read the journal file under the registry's journal directory; it does not contain `s3cr3t`, and does contain `[redacted]`.
9. `"parse_curl's refusal is the fill's refusal"` — the fake answers `parse_curl` with `isError: true` and text `not a cURL command`: dispatch throws with that wording; `locate_api_url` was never called.

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && swift test --filter ApiCurlActionTests`
Expected: FAIL — `unknown action api_fill_from_curl` (or a compile error for `apiKeptDraft`).

- [ ] **Step 3: The kept draft in `PaneStore`**

Add, beside the api draft storage (`grep -n "func setApiDraft" app/Sources/WakilKit/Panes/PaneStore.swift`):

```swift
    /// Amendment 11a: the draft a cURL fill replaced, once, for **Undo**. Forgotten by every
    /// other write to the draft, by a Send, and by the next fill.
    private var apiKept: [String: ApiDraft] = [:]

    public func keepApiDraft(paneId: String, _ draft: ApiDraft) { apiKept[paneId] = draft }
    public func apiKeptDraft(paneId: String) -> ApiDraft? { apiKept[paneId] }
    public func forgetApiKeptDraft(paneId: String) { apiKept[paneId] = nil }
```

and `apiKept[paneId] = nil` as the first line of `setApiDraft` and of `recordApiSend`. The two new actions call `setApiDraft` first and `keepApiDraft` after it, so the fill's own write does not forget what it keeps.

- [ ] **Step 4: The two actions** in `registerApiActions`, after `api_set_request`:

```swift
    await registry.register(Action(
        name: "api_fill_from_curl",
        description: "Replace an api pane's WHOLE draft with the request a cURL command describes "
            + "— what the operator's paste of `curl …` into the path does. text is the command, "
            + "POSIX shell quoting. Its URL must belong to an entry of the active environment: "
            + "another entry switches the pane to it; an entry only in another environment, or "
            + "no entry, is refused and nothing is written. Credentials, cookies, -F, a body "
            + "from a file, -k, unknown flags, a body on a GET and a #fragment are dropped and "
            + "named in dropped. The replaced draft is kept once for api_undo_fill. text is "
            + "journalled redacted. Refused like api_set_request while the operator is in a "
            + "field of this pane.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "pane": .object(["type": .string("string")]),
                "text": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("pane"), .string("text")]),
        ]),
        secretParams: ["text"],
        handler: { params in
            let action = "api_fill_from_curl"
            guard case .object(let fields) = params,
                  case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            guard case .string(let text)? = fields["text"] else {
                throw ApiActionError.notFreeText(action: action, region: "text", found: "missing")
            }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)
            // A fill writes every region (Decision 27, as api_set_request names them).
            let collisions = apiDraftCollisions(
                origin: ActionRegistry.dispatchOrigin,
                writing: ApiWriteKey.allCases,
                focused: await panes.apiFocus(paneId: paneId))
            guard collisions.isEmpty else {
                throw ApiActionError.underTheOperatorsHand(
                    action: action, fields: collisions.map(\.label))
            }
            guard let http else { throw ApiActionError.curlRefused(action: action, line: "wakil-http is not running") }
            let parsedResult = try await http.callTool(
                name: "parse_curl", arguments: .object(["text": .string(text)]),
                timeout: MCPClient.readReplyTimeout)
            let parsed = try ApiCurlParsed(json: try apiToolStructured(parsedResult, action: action))
            let located = try await http.callTool(
                name: "locate_api_url", arguments: .object(["url": .string(parsed.url)]),
                timeout: MCPClient.readReplyTimeout)
            let location = try ApiCurlLocation(json: try apiToolStructured(located, action: action))
            let current = await panes.apiDraft(paneId: paneId)
            switch apiCurlFill(parsed, location, current: current) {
            case .refused(let line):
                throw ApiActionError.curlRefused(action: action, line: line)
            case .fill(let draft, let switches, let dropped):
                let entry = try await apiEntry(named: draft.entry, action: action, http: http)
                await panes.setApiDraft(
                    paneId: paneId, draft: draft,
                    resolution: (apiPaneOrigin(baseURL: entry.baseURL), entry.credentialed))
                await panes.keepApiDraft(paneId: paneId, current)
                if switches { await layout?.retitle(id: paneId, to: apiPaneTitle(entry: draft.entry)) }
                return .object([
                    "pane": .string(paneId), "entry": .string(draft.entry),
                    "switched": .bool(switches),
                    "dropped": .array(dropped.map { .string($0) }),
                    "line": .string(apiCurlFillLine(entry: draft.entry, dropped: dropped).text),
                ])
            }
        }
    ))

    await registry.register(Action(
        name: "api_undo_fill",
        description: "Put back the draft the last api_fill_from_curl on this pane replaced — its "
            + "bindings included — and forget it. Refused ('nothing to undo') when there is none: "
            + "any other write to the draft, or a Send, forgets it.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["pane": .object(["type": .string("string")])]),
            "required": .array([.string("pane")]),
        ]),
        handler: { params in
            let action = "api_undo_fill"
            guard case .object(let fields) = params,
                  case .string(let paneId)? = fields["pane"], !paneId.isEmpty
            else { throw ApiActionError.missingPane(action: action) }
            try await requireOpenPane(paneId, action: action, layout: layout)
            try await requireApiPane(paneId, action: action, layout: layout)
            guard let kept = await panes.apiKeptDraft(paneId: paneId) else {
                throw ApiActionError.curlRefused(action: action, line: "nothing to undo")
            }
            let listing = await apiListing(http: http) ?? []
            let resolved = apiReresolution(entry: kept.entry, listing: listing)
            await panes.setApiDraft(
                paneId: paneId, draft: kept, resolution: (resolved.origin, resolved.credentialed))
            await layout?.retitle(id: paneId, to: apiPaneTitle(entry: kept.entry))
            return .object(["pane": .string(paneId), "entry": .string(kept.entry)])
        }
    ))
```

Adapt to what the code really has, without changing behaviour: `ApiWriteKey` may need `CaseIterable` (add it if it is a plain `String` enum); `Action`'s initializer takes `secretParams` (`Action.swift:210`) — keep the argument order the initializer declares; add `case curlRefused(action: String, line: String)` to `ApiActionError` whose description is exactly `line`; write `apiToolStructured(_:action:)` — the `structuredContent` object of a tool result, or `throw ApiActionError.curlRefused(action:line:)` with the tool's error text when `isError` is true (`apiListingRead` at `ApiActions.swift:240` shows the shape). Check `setApiDraft`'s `resolution` parameter type at its declaration and pass what it takes.

- [ ] **Step 5: `WindowModel`'s surface doors**, beside `bindFromSurface` (~4271), in the same shape: wait for `surfaceChain`, dispatch with `origin: .ui`, wrap the result as `ApiBindOutcome.result` or `.refused(String(describing: error))`, `refreshPanes()`:

```swift
    /// Amendment 11: the path editor's `curl …` paste, after every call the pane queued before it.
    public func fillFromCurlSurface(pane: String, text: String) async -> ApiBindOutcome {
        await surfaceChain?.value
        let outcome: ApiBindOutcome
        do {
            outcome = .result(try await registry.dispatch(
                name: "api_fill_from_curl",
                params: .object(["pane": .string(pane), "text": .string(text)]),
                origin: .ui, environment: environment, confirmation: nil))
            status = ""
        } catch {
            outcome = .refused(String(describing: error))
        }
        await refreshPanes()
        return outcome
    }

    /// Amendment 11: the line's **Undo**.
    public func undoFillFromSurface(pane: String) async -> ApiBindOutcome {
        await surfaceChain?.value
        let outcome: ApiBindOutcome
        do {
            outcome = .result(try await registry.dispatch(
                name: "api_undo_fill", params: .object(["pane": .string(pane)]),
                origin: .ui, environment: environment, confirmation: nil))
            status = ""
        } catch {
            outcome = .refused(String(describing: error))
        }
        await refreshPanes()
        return outcome
    }
```

And a pure summary in `ApiCurlFill.swift`, with a test in `ApiCurlFillTests.swift` (`"A fill's outcome is its line; a refusal is amber"`):

```swift
public func apiCurlFillSummary(_ outcome: ApiBindOutcome) -> ApiBindLine {
    switch outcome {
    case .refused(let message): return ApiBindLine(text: message, caution: true)
    case .result(let value):
        guard case .object(let o) = value, case .string(let line)? = o["line"] else {
            return ApiBindLine(text: "", caution: false)
        }
        return ApiBindLine(text: line, caution: false)
    }
}
```

- [ ] **Step 6: `curlEmitsAndNeverParses`'s comment.** In `ApiRecentTests.swift`, replace `// and nothing ever reads it back.` with `// and Wakil never reads its own line back — a pasted cURL command is read by Go's parse_curl (Amendment 11), not by this emitter.`

- [ ] **Step 7: Run the tests to see them pass**

Run: `cd app && swift test --filter 'ApiCurlActionTests|ApiCurlFillTests|ApiRecentTests'`
Expected: PASS. Then from the repo root, in the foreground: `make app-bundle && make app-test` — green.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit app/Tests/WakilKitTests
git commit -m "2c-iv Amendment 11: api_fill_from_curl and api_undo_fill — one write, the paste journalled redacted"
```

---

### Task 5: The paste, the line and **Undo** in the pane

**Files:**
- Modify: `app/Sources/WakilApp/ApiFieldEditor.swift` (`ApiEditorActions.pastedCurl`, `readSelection`)
- Modify: `app/Sources/WakilApp/ApiPane.swift` (the closures, the dispatch, the line's **Undo**)
- Modify: `app/Sources/WakilApp/ApiPane+Fields.swift` (pass `pastedCurl` to the path editor only)
- Modify: wherever `ApiPane` is constructed with `bind:` (`grep -rn "bind: {" app/Sources/WakilApp | head`) — pass the two new closures from `WindowModel`
- Modify: `app/Sources/WakilKit/...` — none (the rulings are Task 3's)

**Interfaces:**
- Consumes: `apiPasteIsCurl(_:)`, `apiCurlFillSummary(_:)` (WakilKit); `WindowModel.fillFromCurlSurface(pane:text:)`, `undoFillFromSurface(pane:)` (Task 4).
- Produces: identifier `api.fill.undo` on the line's **Undo** button.

- [ ] **Step 1: The editor hands a `curl …` paste to the pane.** Add to `ApiEditorActions`:

```swift
    /// Amendment 11a: a paste whose text `apiPasteIsCurl` reads as a cURL command — the path
    /// field only (`nil` everywhere else, where a paste stays text).
    var pastedCurl: ((String) -> Void)? = nil
```

and at the top of `ApiFieldTextView.readSelection(from:type:)`, before the clip is read:

```swift
        if let pastedCurl = coordinator?.parent.actions.pastedCurl,
           pboard.data(forType: .apiEditor) == nil,
           let plain = pboard.string(forType: .string), apiPasteIsCurl(plain) {
            pastedCurl(plain)
            return true
        }
```

(Read how `ApiFieldEditor` reaches its `actions` — `coordinator?.parent.actions` may be named differently; use what `typed` goes through.)

- [ ] **Step 2: The pane dispatches it and draws the line.** In `ApiPane`, beside `let bind:`:

```swift
    let fillFromCurl: (_ text: String) async -> ApiBindOutcome
    let undoFill: () async -> ApiBindOutcome
    /// Whether the line under the request is a fill's, so it draws **Undo** (11a).
    @State var fillUndoable = false
```

the fill, following `drop(_:)`'s shape (flush first, generation guard):

```swift
    /// Amendment 11a: the path's `curl …` paste. The fields are flushed first, so the fill lands
    /// after what was typed; the line says what happened, with **Undo** after a fill.
    func pasteCurl(_ text: String) {
        flush()
        issued += 1
        let generation = issued
        bindGeneration = generation
        Task { @MainActor in
            let outcome = await fillFromCurl(text)
            guard bindGeneration == generation else { return }
            bindLine = apiCurlFillSummary(outcome)
            if case .result = outcome {
                fillUndoable = true
                held = [:]
                pathEditor.textView?.window?.makeFirstResponder(pathEditor.textView)
                pathEditor.textView?.moveToEndOfDocument(nil)
            } else {
                fillUndoable = false
            }
        }
    }

    func undoCurlFill() {
        issued += 1
        let generation = issued
        bindGeneration = generation
        Task { @MainActor in
            let outcome = await undoFill()
            guard bindGeneration == generation else { return }
            fillUndoable = false
            if case .refused(let message) = outcome {
                bindLine = ApiBindLine(text: message, caution: true)
            } else {
                bindLine = nil
            }
        }
    }
```

(`held = [:]` drops typing the fill replaced, which `flush()` already wrote; use the pane's real name for its path editor handle — `grep -n "ApiEditorHandle()" app/Sources/WakilApp/ApiPane*.swift`. Wherever the pane clears `bindLine` on an edit — `operateInOrder` sets `bindLine = nil` — also set `fillUndoable = false`.)

and in `resultLine`, after the `Text`:

```swift
            if fillUndoable {
                Button("Undo") { undoCurlFill() }
                    .buttonStyle(.plain)
                    .foregroundStyle(ink)
                    .accessibilityIdentifier("api.fill.undo")
            }
```

laid out in an `HStack` with the text, matching the line's existing font.

- [ ] **Step 3: Wire the closures.** In `ApiPane+Fields.swift`, pass `pastedCurl: { text in pasteCurl(text) }` to the **path** editor's `ApiEditorActions` only. Where `ApiPane(…, bind: …)` is built, pass `fillFromCurl: { text in await model.fillFromCurlSurface(pane: id, text: text) }` and `undoFill: { await model.undoFillFromSurface(pane: id) }` using the same names the `bind:` closure uses. **Check every construction site passes them** — `grep -rn "ApiPane(" app/Sources/WakilApp` — an injectable left at a default is the never-wired failure this repo has hit before.

- [ ] **Step 4: Headless gates**

Run, in the foreground: `make app-bundle && make app-test && make controls && go test ./...`
Expected: all green; `make controls` lists `api.fill.undo` as an actionable control.

- [ ] **Step 5: Commit**

```bash
git add app/Sources
git commit -m "2c-iv Amendment 11: a curl paste into the path fills the pane; the line carries Undo"
```

---

### Task 6: The checks, and the runbook's check 11

**Files:**
- Create: `e2e/checks/seeded/api-paste-curl.jsonl`, `e2e/checks/seeded/api-paste-curl-refused.jsonl`
- Modify: `docs/wakil/phase-2c-iv-acceptance.md` (check 11, before the machine-walk markers)

**Interfaces:**
- Consumes: the fixture's staging entries `billing` (`https://billing.e2e-fixture.invalid`) and `catalog` (`https://catalog.e2e-fixture.invalid`), and `qa`'s `catalog` (`https://catalog-qa.e2e-fixture.invalid`) — `e2e/driver/seed.go:290–393`; the actions and identifier from Tasks 4–5.

- [ ] **Step 1: Write the checks**

`api-paste-curl.jsonl`:

```json
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"get","path":[{"literal":"/before"}]}}}
{"dispatch":{"action":"api_fill_from_curl","params":{"pane":"api-1","text":"curl -X POST 'https://billing.e2e-fixture.invalid/v1/invoices?paid=true' -H 'Authorization: Bearer s3cr3t' -H 'X-Trace: 7' -H 'content-type: application/json' -d '{\"a\":1}' -k"}}}
{"expect":{"pane":"api-1","field":"entry","equals":"billing"}}
{"expect":{"pane":"api-1","field":"request.method","equals":"POST"}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/v1/invoices"}}
{"expect":{"pane":"api-1","field":"request.query[0].name","equals":"paid"}}
{"expect":{"pane":"api-1","field":"request.headers[0].name","equals":"X-Trace"}}
{"expect":{"pane":"api-1","field":"request.contentType","equals":"application/json"}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","equals":"{\"a\":1}"}}
{"expect":{"tree":"contains","text":"Filled from cURL · billing · dropped: Authorization, -k"}}
{"do":{"click":"api.fill.undo"}}
{"expect":{"pane":"api-1","field":"entry","equals":"catalog"}}
{"expect":{"pane":"api-1","field":"request.method","equals":"GET"}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/before"}}
```

Before writing the expects, confirm each `field` path against an existing check's spelling (`grep -h '"field":"' e2e/checks/seeded/api-*.jsonl | sort -u | head -40`) — `entry`, `request.contentType` and `request.headers[0].name` must be the names `read_pane` really publishes; correct the check, not `read_pane`.

**The fill is dispatched, so the line must still reach the screen.** A dispatched fill does not run the pane's `pasteCurl`, so the line and **Undo** are drawn only if the pane learns of a fill it did not start. If Task 5's line is `@State` set only by `pasteCurl`, this check's `tree contains` and `click api.fill.undo` will fail: then make the line published state instead — the pane reads it from `ApiSnapshot` the way it reads `bindLine`'s neighbours (`grep -n "lastFill\|bindLine" app/Sources/WakilKit/Panes/PaneStore.swift`) — with a WakilKit test, and record it in the report. Decide this before Step 2.

`api-paste-curl-refused.jsonl`:

```json
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"get","path":[{"literal":"/kept"}]}}}
{"dispatch":{"action":"api_fill_from_curl","params":{"pane":"api-1","text":"curl https://api.other.invalid/x"}},"refuses":"no entry in staging has that host"}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/kept"}}
{"dispatch":{"action":"api_fill_from_curl","params":{"pane":"api-1","text":"curl https://catalog-qa.e2e-fixture.invalid/x"}},"refuses":"switch environment first"}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/kept"}}
```

(Check the `refuses` spelling against `e2e/driver/run.go:684` and an existing check using it.)

- [ ] **Step 2: Parse headless**

Run: `go test ./e2e/...`
Expected: green.

- [ ] **Step 3: Check 11 in the runbook** — add before the machine-walk markers, in the file's voice and wrap width:

```markdown
- [ ] **11. A cURL command pasted into the path is that request.** In a browser's devtools,
      copy a request to an entry of this environment as cURL (bash). Click into an api
      pane's path and paste: **the method, path, query, headers and body fill**, the line
      says *Filled from cURL · <entry>* and names what it dropped (an `Authorization`, a
      cookie), and the caret sits at the end of the path. Press Send — it goes. Press
      **Undo** on a fresh fill — the previous draft comes back, a filled chip included.
      Paste a cURL for another entry: the pane switches to it. Paste one for a host no
      entry has: refused in amber, naming the host, and nothing changes. Paste `curl` into
      a header value or the body: it stays text.
```

- [ ] **Step 4: STOP — the controller asks the operator for a GUI window**, then runs `make e2e-new E2E_NEW_ARGS="--base 42c75ce"` (both new checks must be red against main, for a behavioural reason: the action does not exist there, so `api_fill_from_curl` is refused as unknown — acceptable here, since the action IS the new behaviour) and `make e2e` (check its exit status, not a piped tail), then `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2c-iv-acceptance.md` on a clean tree.

- [ ] **Step 5: Commit**

```bash
git add e2e/checks/seeded/api-paste-curl.jsonl e2e/checks/seeded/api-paste-curl-refused.jsonl docs/wakil/phase-2c-iv-acceptance.md
git commit -m "2c-iv Amendment 11: the paste's checks, and the runbook's check 11"
```

- [ ] **Step 6: STOP — the operator walks check 11.** Hand over: *"Ready for the Walk rung: check 11, a cURL paste from a browser. The machine section is green and rendered. After your walk: the phase log entry, then the PR."* No agent ticks a box.

---

## Self-review

- **Spec coverage.** 11a: the trigger is Task 5 (path only, `apiPasteIsCurl` in Task 3); the whole-draft replace is Tasks 3–4; the line and Undo are Tasks 3–5; the kept draft's forgetting is Task 4; the caret at the end is Task 5; placeholders as text is Task 3 (literal parts only). 11b: the match is Task 2 (corrected into Go, Task 1 Step 1); switch, other-environment and no-match are Task 3, with the draft untouched on refusal tested in Task 4. 11c: every row is a Task 1 test. 11d: `parse_curl` and `locate_api_url` are Task 2; `api_fill_from_curl` is Task 4; the journal redaction is Task 4 test 8; `curlEmitsAndNeverParses`'s comment is Task 4 Step 6. 11e: Go tests Tasks 1–2; WakilKit Tasks 3–4; e2e and check 11 Task 6.
- **Placeholders.** One deliberate, bounded one: Task 3's `apiPathAndQueryParts` names the existing split the implementer must find, with the exact fallback to write and its test if none fits.
- **Types.** `CurlRequest`/`CurlDropped`/`CurlHeader`, `APILocation`, `ApiCurlParsed`, `ApiCurlLocation`, `ApiCurlFill`, `apiCurlFill`, `apiCurlFillLine`, `apiCurlFillSummary`, `apiPasteIsCurl`, `keepApiDraft`/`apiKeptDraft`/`forgetApiKeptDraft`, `fillFromCurlSurface`/`undoFillFromSurface`, `pastedCurl`, `api.fill.undo` — the same in every task that names them.
- **Review Focus.** Each of the five lines has its test in its owning task (Tasks 1, 2, 2, 4, 4).
