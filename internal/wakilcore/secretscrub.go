package wakilcore

import (
	"encoding/base64"
	"sort"
	"strings"
	"unicode/utf8"
)

// This file holds the credential-scrubbing machinery originally built and
// hardened, over five fix rounds and six adversarial reviews, inside
// JiraClient (jira.go) to answer one threat: an HTTP response (body OR,
// for wakil-http, a response HEADER — value or, as of this fix round,
// NAME) that echoes back a credential this process sent, handing it to
// whatever is reading the MCP tool result — in particular an LLM. Twelve
// declarations came here from JiraClient, and for eight of those twelve
// it was a pure file move within the same package that changes no name,
// no signature, and no behavior, so it required no edit to jira.go's
// existing test suite. The other four are NOT pure moves, and are called
// out here rather than folded into that claim: scrubSecrets lost its
// receiver and
// gained a literals []string parameter (it was
// JiraClient.scrubSecrets(msg string), a method reading c.scrubForms()
// internally; it is now a free function taking the literal set
// explicitly, with no JiraClient-shaped assumption left in it at all),
// and appendSecretForms is new (factored out of the "raw form + four
// base64 encodings" pattern JiraClient.scrubForms already repeated
// inline). Both were verified behavior-preserving for jira.go's own
// callers — see the extraction report — but they are edits, not moves,
// and this comment should not claim otherwise. The remaining two,
// scrubHeaderName and its asciiLower helper, were written fresh in later
// fix rounds for the header-NAME case and never existed in jira.go at
// all. (Counting them as two, not one, because a count that quietly
// folds a helper into its caller is how this comment drifted before.)
//
// Everything else in this file was written here and never lived in
// jira.go: SecretScrubber with NewSecretScrubber, NewAuthHeaderScrubber
// and its authHeaderCredential helper, and the SecretScrubber methods.
// stripPartialCredentialTail is the one addition BOTH clients now use —
// jira.go's search() calls it directly and DoRequest calls it through
// SecretScrubber.StripPartialTail — because the order it imposes on the
// two final display stages is a correctness requirement neither caller
// got right on its own.
//
// It is deliberately credential-agnostic below the JiraClient-specific
// glue that stays in jira.go: JiraClient.scrubForms builds its
// email/token-pair-and-bare-token forms on top of appendSecretForms;
// SecretScrubber (below) builds single-secret forms the same way for
// wakil-http's resolved auth token.

// scrubForm is one credential representation scrubSecrets treats as
// sensitive, together with minLen: the minimum length, in bytes, of a
// TRAILING suffix of this form that stripPartialCredentialSuffix will
// treat as credential material worth stripping (see that function's doc
// comment). minLen is per-form, not a single flat floor, because the
// pair forms are dominated by the (non-secret) email address: a flat
// floor low enough to catch a short partial TOKEN is also low enough to
// fire on an ordinary diagnostic sentence that merely happens to end
// with the account's own email — see Minor-1's false positives,
// "Unauthorized for user person@example.com" and "field 'reporter' is
// invalid for person@example.com", both of which must survive untouched.
type scrubForm struct {
	lit    string
	minLen int
}

// literalsOf extracts the literal strings from forms, for the callers
// (scrubCutPoint, longestScrubForm, scrubSecrets) that only need to
// match text and have no use for minLen.
func literalsOf(forms []scrubForm) []string {
	out := make([]string, len(forms))
	for i, f := range forms {
		out[i] = f.lit
	}
	return out
}

// appendSecretForms appends raw's literal form and its four base64
// encodings (standard/URL-safe, padded/unpadded — different base64
// encoders/proxies/gateways in the wild produce any of the four) to
// forms. rawMinLen gates the raw form; base64MinLen gates all four
// base64 forms — kept as two separate parameters, not one, because a
// base64-encoded suffix threshold does not scale 1:1 with the raw-byte
// threshold it must guarantee overlap with. JiraClient.scrubForms is the
// original, motivating case: its pair form's base64 minLen
// (pairB64Min) is rounded UP to the next 4-char/3-byte base64 block from
// its raw minLen (pairMin), since base64 doesn't encode byte boundaries
// 1:1 — the shortest base64 suffix guaranteed to touch a token byte is
// one full encoded block past ceil(pairMin/3) 3-byte groups. Extracted
// out of JiraClient.scrubForms verbatim (same encodings, same order,
// same per-form minLen split) so wakil-http's SecretScrubber can build
// forms the identical way for a single secret with no pair component.
func appendSecretForms(forms []scrubForm, raw string, rawMinLen, base64MinLen int) []scrubForm {
	return append(forms,
		scrubForm{base64.StdEncoding.EncodeToString([]byte(raw)), base64MinLen},
		scrubForm{base64.RawStdEncoding.EncodeToString([]byte(raw)), base64MinLen},
		scrubForm{base64.URLEncoding.EncodeToString([]byte(raw)), base64MinLen},
		scrubForm{base64.RawURLEncoding.EncodeToString([]byte(raw)), base64MinLen},
		scrubForm{raw, rawMinLen},
	)
}

// jiraScrubMinTokenLen guards against a real failure mode this file's
// own test suite hit while building this: naive substring replacement on
// a short string doesn't just redact a leaked credential, it redacts
// every coincidental occurrence of that string anywhere in msg (observed:
// a one-character test token turned an HTML error page into a wall of
// "[redacted]"). A real Jira API token is a long random string, so this
// floor costs nothing against the actual threat.
//
// It applies ONLY to the forms whose length tracks the token's: the bare
// token and its base64. The email:token pair and ITS base64 are always
// scrubbed regardless, because their length is dominated by the email
// address, not the token — the Authorization header a server can echo
// back is exactly that pair, so short-circuiting on token length would
// reopen the whole leak. A controller probe confirmed this: with
// Token "short", an early return on length surfaced
// "Basic cGVyc29uQGV4YW1wbGUuY29tOnNob3J0", which decodes to
// "person@example.com:short".
//
// The name is kept unchanged by this extraction (rather than renamed to
// something credential-agnostic) so JiraClient's existing tests, which
// reference it directly, need no edit as part of moving it here.
// wakil-http's SecretScrubber reuses this exact constant as its own
// default minimum secret length, for the identical reason: a resolved
// HTTP auth token is not meaningfully different from a Jira API token as
// far as this floor's rationale goes.
const jiraScrubMinTokenLen = 8

// scrubSecrets finds every occurrence of every credential form as a
// (start,end) byte interval in msg, merges overlapping/adjacent
// intervals, and replaces each merged interval with a single
// "[redacted]" marker.
//
// The interval-merge step is round 5's fix for a real gap:
// strings.ReplaceAll (what this function used before) only ever matches
// non-overlapping occurrences left-to-right, so it silently skips any
// occurrence that starts inside one it has already consumed. Given a
// form to scrub — even one scrubCutPoint has already guaranteed is
// wholly inside the display window — a PERIODIC form (one that is itself
// a repetition of a shorter period, e.g. a base64 blob built from
// strings.Repeat of a shorter string) produces exactly this shape: the
// second period-aligned occurrence starts inside the first one's span,
// and ReplaceAll leaves a verbatim fragment of it behind. A real
// Atlassian API token is high-entropy and not periodic, so this does not
// threaten a live credential in practice — but this file's OWN test
// fixtures stand a token in with a literal strings.Repeat, which IS
// periodic, so the test suite's own credential depended on this exact
// gap staying closed (see TestJiraScrubsPeriodicTokenNoOverlapLeak).
// Merging overlapping/adjacent intervals before replacing any of them
// makes "every occurrence is removed" true regardless of periodicity.
//
// Extracted verbatim from JiraClient.scrubSecrets's own body; that
// method (jira.go) now calls this with literalsOf(c.scrubForms()), and
// SecretScrubber.Scrub (below) calls it with its own literal set — same
// function, same behavior, two credential-shape-specific callers.
func scrubSecrets(msg string, literals []string) string {
	type span struct{ start, end int }
	var spans []span
	for _, f := range literals {
		if f == "" {
			continue
		}
		from := 0
		for from <= len(msg) {
			idx := strings.Index(msg[from:], f)
			if idx < 0 {
				break
			}
			start := from + idx
			spans = append(spans, span{start, start + len(f)})
			from = start + 1
		}
	}
	if len(spans) == 0 {
		return msg
	}
	// Sorting is load-bearing, not cosmetic: spans are collected per form,
	// so a later-enumerated form routinely yields a span that starts
	// BEFORE one already in the slice. The merge below only ever compares
	// against the last element, so on unsorted input it silently drops
	// spans. Pinned by TestScrubSecretsMergesDisjointOutOfOrderSpans.
	sort.Slice(spans, func(i, j int) bool { return spans[i].start < spans[j].start })
	merged := make([]span, 0, len(spans))
	for _, s := range spans {
		if n := len(merged); n > 0 && s.start <= merged[n-1].end {
			// Extend only. A span fully NESTED inside the previous one
			// must not shorten it: assigning unconditionally would move
			// the merged end backwards and emit the longer form's tail.
			// sort.Slice is not stable, so equal-start spans can arrive
			// in either order; this guard makes the result independent of
			// that.
			//
			// DELIBERATELY UNTESTED, because no test would be honest. A
			// 300,000-case fuzz over both variants found 83,503 outputs
			// that differ — so the guard is genuinely load-bearing, not
			// dead — but every difference was a stray base64 padding "="
			// escaping, never credential material, and every one needed a
			// token below jiraScrubMinTokenLen (whose token-only forms
			// this code never enumerates anyway). A test pinning a stray
			// "=" would assert padding trivia while implying it covers
			// the nesting hazard. Keeping the guard and saying why is
			// worth more than a test that passes under both versions.
			if s.end > merged[n-1].end {
				merged[n-1].end = s.end
			}
			continue
		}
		merged = append(merged, s)
	}
	var b strings.Builder
	prev := 0
	for _, s := range merged {
		b.WriteString(msg[prev:s.start])
		b.WriteString("[redacted]")
		prev = s.end
	}
	b.WriteString(msg[prev:])
	return b.String()
}

// asciiLower lowercases ASCII A-Z and leaves every other byte — including
// every byte of a multi-byte UTF-8 rune — exactly as it was. It therefore
// returns a string of the SAME byte length as its input, always, which is
// what makes it safe to locate a match in the folded string and then slice
// the original at that offset. strings.ToLower cannot be used for that:
// its Unicode folds change byte length in both directions.
//
// A second caller, describeEditability (sqlconn.go), needs this same
// function for an unrelated reason: comparing SQL identifiers case
// insensitively. strings.ToLower there would be worse than merely
// unnecessary — it is UNICODE case folding, and neither sqlite nor MySQL
// folds an identifier's case beyond ASCII. U+212A KELVIN SIGN ("K")
// proves the two rules disagree: strings.ToLower maps it to ASCII "k"
// (Unicode calls them the same letter), but a table with a primary key
// column literally named "K" (U+212A) and an unrelated ordinary column
// named "k" are two distinct columns to both engines. Using
// strings.ToLower there once folded the key's identity onto the WRONG
// column's values and produced a WHERE predicate that named a different
// row than the one actually keyed "K" — a live, provable "editing row 1
// writes row 2" bug (see TestEditabilityKeyComparisonIsASCIIOnly in
// sqlconn_test.go). Do not let either caller drift back to
// strings.ToLower; for both, it is a correctness bug, not a style choice.
func asciiLower(s string) string {
	var b []byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			if b == nil {
				b = []byte(s)
			}
			b[i] = c + ('a' - 'A')
		}
	}
	if b == nil {
		return s
	}
	return string(b)
}

// scrubHeaderName scrubs credential forms from a response header NAME,
// case-INsensitively — unlike scrubSecrets above (case-sensitive, used
// for header VALUES and the body). This is not a stylistic choice: a
// header name goes through textproto.CanonicalMIMEHeaderKey on the way
// in, which forces the case of every byte (uppercase at the start of
// each hyphen-delimited segment, lowercase everywhere else) regardless
// of whatever case the server actually sent. A credential occurring in a
// header NAME therefore survives with its OWN case altered by a process
// this program does not control, so an exact, case-sensitive literal
// match — correct for scrubSecrets's job — can miss it. This is exactly
// what the fix-round Critical-1 probe found: a letter-first token
// canonicalizes to only its FIRST byte's case changing (e.g.
// "abc123..." becomes "Abc123..."), so the token's own literal, matched
// case-sensitively as a whole string, does not match the canonicalized
// key at all, even though 17 of its 18 bytes are sitting right there
// verbatim.
//
// Case-folding the SEARCH is safe here only because the fold used is
// asciiLower, which is length-preserving BY CONSTRUCTION. That property is
// load-bearing: the spans below are found in the folded string and then
// applied to the ORIGINAL, so any fold that changes a string's byte length
// silently corrupts every offset after it.
//
// This is not hypothetical. An earlier version used strings.ToLower, whose
// Unicode folds are not length-preserving, and a reviewer's probes showed
// exactly the two failure modes: U+023A "Ⱥ" (2 bytes) lowercases to U+2C65
// (3 bytes), growing the string so an offset ran past the end and PANICKED
// with "slice bounds out of range"; and U+212A KELVIN SIGN (3 bytes)
// lowercases to "k" (1 byte), shrinking it so the redaction window drifted
// LEFT — over-redacting the prefix, cutting a rune in half, and leaving a
// verbatim tail of the credential (16 bytes of an 18-byte token with eight
// Kelvin signs in the name).
//
// That version was unreachable through doRequest, because net/http rejects
// non-ASCII header names before this function ever sees them. But the
// safety of a security-critical function should not rest on an unstated
// implementation detail of another package, in an exported method, so the
// fold is now correct on its own terms rather than by that accident.
//
// scrubSecrets deliberately does NOT case-fold at all: it operates on
// arbitrary UTF-8 body and header-VALUE text, where folding is both
// lossy and offset-unsafe. Only header NAMES, which RFC 7230 restricts to
// ASCII "token" characters, can be folded — and only with an ASCII fold.
//
// A matched span is widened to whole runes of name before it is redacted
// (see expandSpanToRuneBoundaries), so that a name which arrives as valid
// UTF-8 leaves as valid UTF-8. Without that, the offsets — which are byte
// offsets into a fold that only guarantees byte LENGTH, not rune
// alignment — could land mid-rune and the redaction cut a character in
// half. Measured, before the fix, with a raw form beginning with a UTF-8
// continuation byte:
//
//	name "X-ébcdefghijklmnop-Echo"  ->  "X-\xc3[redacted]-Echo"  valid=false
//	name "X-abcdefghijklmnoé-Echo"  ->  "X-[redacted]\xa9-Echo"  valid=false
//
// Both halves of a rune have to come from somewhere, and only the raw form
// can supply them: the four base64 forms are ASCII by construction, and a
// literal whose first byte is ASCII can only ever match at a rune boundary
// (asciiLower maps ASCII to ASCII and leaves every other byte alone, so an
// ASCII byte in the fold is an ASCII byte in the original). So this needs a
// secret that is not itself valid UTF-8 — narrow, but a secret is arbitrary
// bytes out of the Keychain, and net/http's rejection of non-ASCII header
// names is the caller's property, not this function's.
func scrubHeaderName(name string, literals []string) string {
	type span struct{ start, end int }
	var spans []span
	lowerName := asciiLower(name)
	for _, f := range literals {
		if f == "" {
			continue
		}
		lowerF := asciiLower(f)
		from := 0
		for from <= len(lowerName) {
			idx := strings.Index(lowerName[from:], lowerF)
			if idx < 0 {
				break
			}
			start := from + idx
			lo, hi := expandSpanToRuneBoundaries(name, start, start+len(f))
			spans = append(spans, span{lo, hi})
			from = start + 1
		}
	}
	if len(spans) == 0 {
		return name
	}
	// Sorting and the merge-only-extend rule below mirror scrubSecrets's
	// own reasoning exactly (see that function's doc comment): spans are
	// collected per form, a later form can yield a span starting before
	// one already collected, and a nested span must not shorten an
	// already-merged one.
	sort.Slice(spans, func(i, j int) bool { return spans[i].start < spans[j].start })
	merged := make([]span, 0, len(spans))
	for _, s := range spans {
		if n := len(merged); n > 0 && s.start <= merged[n-1].end {
			if s.end > merged[n-1].end {
				merged[n-1].end = s.end
			}
			continue
		}
		merged = append(merged, s)
	}
	var b strings.Builder
	prev := 0
	for _, s := range merged {
		b.WriteString(name[prev:s.start])
		b.WriteString("[redacted]")
		prev = s.end
	}
	b.WriteString(name[prev:])
	return b.String()
}

// expandSpanToRuneBoundaries widens the byte range [start,end) of s
// outwards until both ends sit on a UTF-8 rune boundary, and returns the
// widened range. If s is valid UTF-8, every substring cut at the returned
// offsets is therefore a whole number of runes, and so is valid UTF-8.
//
// OUTWARDS is the load-bearing word, and it is the opposite direction from
// truncateBytesAtRuneBoundary above, which snaps its cut backwards. The two
// answer different questions. That function is truncating — dropping bytes
// is always safe, so it takes the shorter string. This one is redacting a
// CREDENTIAL, so narrowing a span would leave the trailing bytes of a rune
// that the credential runs through sitting verbatim in the output. Widening
// can only ever redact more, and the most it can add is the remainder of
// the two runes the span already cuts into — at most utf8.UTFMax-1 bytes at
// each end, and only bytes that are part of a rune already being redacted.
//
// utf8.RuneStart is the same test dropTrailingIncompleteRune reasons about
// from the other side: a byte is a continuation byte exactly when it is not
// a rune start, and a byte offset is a rune boundary exactly when the byte
// at it is a rune start (or it is the end of the string). Both loops are
// bounded by the ends of s, so an s that is not valid UTF-8 in the first
// place terminates rather than running away — it just cannot be made valid,
// which is the caller's input problem and not something to paper over here.
func expandSpanToRuneBoundaries(s string, start, end int) (int, int) {
	for start > 0 && !utf8.RuneStart(s[start]) {
		start--
	}
	for end < len(s) && !utf8.RuneStart(s[end]) {
		end++
	}
	return start, end
}

// longestScrubForm returns the length in bytes of the longest string in
// forms, or 0 if forms is empty. Used to size the error-body read window
// so a credential straddling the truncation cap is always read in full
// before scrubSecrets ever sees it. Originally, and still, jira.go's
// search() is one caller (sizing against jiraErrorBodyCap);
// SecretScrubber.LongestForm (below) is a second, added when this
// function moved into this file: wakil-http's DoRequest sizes its own
// read window against httpBodyCap the identical way.
func longestScrubForm(forms []string) int {
	max := 0
	for _, f := range forms {
		if len(f) > max {
			max = len(f)
		}
	}
	return max
}

// scrubCutPoint chooses, in RAW (pre-scrub) byte coordinates, where to
// cut body before scrubbing it — this is the primary fix for the
// doubled-echo leak described on scrubSecrets's doc comment. Cutting
// first and scrubbing second (as opposed to the reverse, which is its
// own bug — see jiraScrubMinTokenLen's history) is not sufficient by
// itself: a fixed cut at cap can still land in the MIDDLE of a
// credential-form occurrence, leaving a scrub-proof partial. This
// function starts at cap and pushes the cut forward past the END of any
// scrubForms() occurrence that straddles it, so that every form
// occurrence inside body[:cut] is whole. It loops to a fixed point
// because extending the cut to include one occurrence can newly expose
// another starting right where the first one ends.
//
// The straddle logic needs no separate rune-boundary handling once its
// starting point has been snapped once (below) — but not because every
// scrubForms() entry is pure ASCII. Nothing enforces that: Email and
// Token come from the Keychain, and a non-ASCII mailbox (e.g.
// "pérsön@éxample.com") is a legal Jira account email. The real reason
// is that UTF-8 is self-synchronising: a continuation byte (10xxxxxx)
// never starts a valid rune, so within a valid-UTF-8 body, a valid-UTF-8
// substring match (every scrubForms() literal is valid UTF-8 — base64
// output is pure ASCII, and Email/Token are used as the raw strings they
// are) can only begin and end on rune boundaries. There is no byte
// offset that is simultaneously mid-rune in the body and aligned with
// the start or end of a validly-decoding form. A probe confirmed this
// empirically: with Email = "pérsön@éxample.com", scanning 400
// candidate cut offsets through a body containing that email found zero
// mid-rune cuts.
//
// The starting point (cap, before any straddle extension) is snapped
// backward to a rune boundary first: with no credential nearby, cap can
// itself land mid-rune in ordinary non-ASCII body text (Jira instances
// are localised), and if that raw cut became a fixed cap point after
// scrubbing failed to shrink the string, the FINAL display truncation in
// search() would see a string already at or under its cap and skip its
// own rune-boundary check entirely (truncateBytesAtRuneBoundary is a
// no-op when len(s) <= max) — silently re-exposing a split rune that
// this function introduced. Snapping here, before that can happen, is
// what keeps TestJiraErrorBodyCapDoesNotSplitARune passing regardless of
// which layer ends up doing the final cut.
//
// Originally, and still, jira.go's search() is one caller (cutting
// against jiraErrorBodyCap). SecretScrubber.CutPoint (below) is a
// second, added when this function moved into this file: wakil-http's
// DoRequest calls it to cut against httpBodyCap instead. Same function,
// same correctness argument, two credential-shape-specific callers.
func scrubCutPoint(body string, cap int, forms []string) int {
	if cap < 0 {
		cap = 0
	}
	cut := cap
	if cut > len(body) {
		cut = len(body)
	}
	for cut > 0 && cut < len(body) && !utf8.RuneStart(body[cut]) {
		cut--
	}
	for {
		next := cut
		for _, f := range forms {
			if f == "" {
				continue
			}
			searchFrom := 0
			for searchFrom <= len(body) {
				idx := strings.Index(body[searchFrom:], f)
				if idx < 0 {
					break
				}
				start := searchFrom + idx
				end := start + len(f)
				// Only occurrences STARTING before the current cut
				// straddle it; one starting at or after the cut is
				// simply excluded from body[:cut] entirely (and is
				// therefore never displayed at all — safe, not partial).
				if start < cut && end > next {
					next = end
				}
				searchFrom = start + 1
			}
		}
		if next == cut {
			return cut
		}
		// No clamp against len(body) is needed here: next only ever comes
		// from cut's own starting value (already clamped above) or from
		// end := start + len(f) for a strings.Index match found strictly
		// inside body, which by construction satisfies end <= len(body).
		cut = next
	}
}

// stripPartialCredentialSuffix is a SECONDARY, defence-in-depth layer:
// after scrubCutPoint's raw-coordinate cut and scrubbing, search() still
// applies a final jiraErrorBodyCap display truncation to the
// (already-scrubbed) text. Given scrubCutPoint and scrubSecrets are both
// correct — including scrubSecrets's interval-merge fix for overlapping
// occurrences, see that function's doc comment — a complete credential
// form occurrence starting before scrubCutPoint's cut is always fully
// redacted before this final truncation ever runs, so in the common case
// there is nothing left here to strip.
//
// That does not make this function unreachable, and it is not merely a
// hypothetical backstop: a fuzz probe against a 424,700-body corpus
// measured it actually firing — finding and stripping a non-empty
// suffix — 1,808 times. The gap it closes is the read window itself:
// search() reads at most jiraErrorBodyCap+longestScrubForm bytes off the
// wire (io.LimitReader), sized to guarantee that any form occurrence
// STARTING before jiraErrorBodyCap is read in full — but that guarantee
// says nothing about a form occurrence starting AFTER that point. A
// sufficiently dense or periodic run of credential-form occurrences
// (this file's own fixtures use exactly this shape: a repeated literal
// standing in for a high-entropy token) can push scrubCutPoint's cut
// forward, via cascading complete matches, right up to the edge of the
// read window — and the underlying network body can continue beyond
// that window with the START of one more occurrence that never finishes
// arriving before the read stops. That trailing fragment is a genuine,
// unmatched PREFIX of a scrub form: scrubSecrets cannot find it
// (strings.Index needs the whole literal), so it survives scrubbing and
// lands at the very end of the pre-final-truncation text.
//
// This function's job is exactly that shape and nothing more: it strips
// the longest TRAILING suffix of s that is also a prefix of some
// scrubForms() entry — repeating in case stripping one exposes another —
// and it cannot catch a partial anywhere other than the end of s. Each
// form's minLen (scrubForm.minLen, not a single flat floor) bounds how
// short a suffix match must be before it is treated as credential
// material; see that field's doc comment for why the pair forms need a
// higher floor than the token-only forms do.
//
// It is NOT called directly by either display pipeline any more: both
// jira.go's search() and wakil-http's DoRequest go through
// stripPartialCredentialTail below, which sandwiches this function
// between two dropTrailingIncompleteRune calls. Calling it on its own is
// a known leak — see that function's doc comment for the measured case.
func stripPartialCredentialSuffix(s string, forms []scrubForm) string {
	for {
		bestCut := -1
		for _, f := range forms {
			if f.minLen < 1 {
				continue
			}
			maxN := len(f.lit)
			if maxN > len(s) {
				maxN = len(s)
			}
			for n := maxN; n >= f.minLen; n-- {
				if strings.HasSuffix(s, f.lit[:n]) {
					if cand := len(s) - n; bestCut == -1 || cand < bestCut {
						bestCut = cand
					}
					break
				}
			}
		}
		if bestCut == -1 {
			return s
		}
		s = s[:bestCut]
	}
}

// truncateBytesAtRuneBoundary cuts s to at most max BYTES without
// splitting a rune. Byte semantics deliberately: the caller's chosen
// byte cap — jiraErrorBodyCap in jira.go's search(), or httpBodyCap in
// wakil-http's DoRequest (a second caller, added when this function
// moved into this file) — bounds how much text we hand a caller, and
// sessions.go's rune-counting truncateRunes answers a different question
// (display length), so the two are separate on purpose rather than one
// being reused for both.
// A plain s[:max] byte slice can land mid-rune — Jira instances are
// localised, so a non-ASCII error body is ordinary, not exotic — and the
// result would be invalid UTF-8 in an MCP tool error. That degrades
// rather than fails (encoding/json substitutes U+FFFD when marshalling),
// but emitting known-invalid UTF-8 is not something to hand a caller on
// purpose. Verified: a body of 300 U+D55C runes capped at 200 bytes cuts
// two bytes into the 67th rune.
func truncateBytesAtRuneBoundary(s string, max int) string {
	if max <= 0 {
		return ""
	}
	if len(s) <= max {
		return s
	}
	for max > 0 && !utf8.RuneStart(s[max]) {
		max--
	}
	return s[:max]
}

// dropTrailingIncompleteRune removes a trailing incomplete UTF-8 encoding
// from the very end of s, if one is present. This exists because
// truncateBytesAtRuneBoundary's rune-boundary guard is a no-op whenever
// len(s) <= max — i.e. exactly when this matters, since that is the only
// case in which s can still end mid-rune by the time it reaches display.
// Two independent, reachable routes get there:
//  1. leading whitespace trimmed by strings.TrimSpace in search() can
//     pull an otherwise-oversized body under jiraErrorBodyCap, so
//     scrubCutPoint's own snap-to-rune-boundary logic (guarded by
//     `cut < len(body)`) never runs at all, and truncateBytesAtRuneBoundary
//     then sees a string already at or under its cap and does nothing.
//  2. a mid-stream connection drop truncates the network read itself
//     (see search()'s io.ReadAll error handling), independent of any cap
//     this code chooses.
//
// utf8.DecodeLastRuneInString returning (RuneError, 1) is the correct —
// and only — signal for "the last byte does not complete a rune": that
// exact (value, size) pair is returned both for a single stray
// continuation/lead byte AND for a lead byte whose continuation bytes
// are missing, whereas a genuine U+FFFD replacement character actually
// present in the source text decodes with size 3 (its own valid 3-byte
// UTF-8 encoding) and must not be touched. A single drop is not always
// enough: a dangling multi-byte lead (e.g. a 3-byte rune's first TWO
// bytes present, third missing) still decodes as (RuneError, 1) after
// removing just the last byte, since the remaining lead byte is then
// itself incomplete — see this round's report for the exact case that
// caught a single-drop version of this function still leaving a lone
// lead byte behind. Looping up to utf8.UTFMax times bounds this to at
// most one full rune's worth of trailing bytes; a valid UTF-8 string
// never needs more than that to reach a clean boundary.
func dropTrailingIncompleteRune(s string) string {
	for i := 0; i < utf8.UTFMax && s != ""; i++ {
		r, size := utf8.DecodeLastRuneInString(s)
		if r != utf8.RuneError || size != 1 {
			break
		}
		s = s[:len(s)-1]
	}
	return s
}

// stripPartialCredentialTail is the last stage of both display pipelines
// (jira.go's search() and wakil-http's DoRequest): it removes, from the
// end of already-scrubbed display text, both a dangling incomplete UTF-8
// rune and a trailing partial credential form — in an order that leaves
// NEITHER behind.
//
// The order is drop -> strip -> drop, three steps, and each one is load
// bearing:
//
//   - drop FIRST, because stripPartialCredentialSuffix only ever matches
//     a form prefix that is a literal SUFFIX of s. One dangling UTF-8
//     byte sitting after the partial credential is enough to make that
//     suffix test fail, so the strip does nothing, and the drop that used
//     to run afterwards then removed the dangling byte and RE-EXPOSED the
//     credential partial with nothing left to strip it. Measured, with
//     JiraClient{Email: "person@example.com", Token: "sup3rsecrettoken000"}
//     and in = "prefix sup3rsecrett\xe4\xb8":
//     strip->drop = "prefix sup3rsecrett" (leaks a 12-byte partial);
//     drop->strip->drop = "prefix " (does not).
//     End-to-end through SearchIssues with a 192-char token, the old
//     order produced the UserError "Jira error 400: Jira rejected token
//     aB3aB3aB3aB3" — and recall.go's sourceFailureMessage relays a
//     UserError verbatim into SourceStatus.Message, a field of a
//     SUCCESSFUL wakil-recall result whose own tool description tells the
//     model to read it. So this is not merely a diagnostic string.
//
//   - drop LAST, because the naive two-line swap (drop -> strip) has an
//     exact MIRROR of the same bug. stripPartialCredentialSuffix cuts s
//     at len(s)-n for a form prefix of n bytes; that cut point is a
//     boundary in the FORM, not necessarily a rune boundary in s. If a
//     credential form's first byte is a UTF-8 continuation byte, the cut
//     lands mid-rune and leaves invalid UTF-8 at the end — which is the
//     exact thing the trailing drop existed to prevent in the first
//     place. Measured, with Token "\xb8abcdefgh" and
//     in = "hello \xe4\xb8abcdefgh": drop->strip = "hello \xe4" (invalid
//     UTF-8); the third step yields "hello ".
//
// Three steps is not a proven fixpoint, and this comment will not claim
// it is: in principle the final drop could itself uncover yet another
// form prefix. Reaching that needs a credential whose own first byte is
// a UTF-8 continuation byte AND a second form prefix immediately in
// front of the dangling bytes — i.e. a secret that is not valid UTF-8 at
// its start. Neither source of secrets here can produce one in practice
// (a Jira API token is ASCII; an Authorization header value has to be
// made of header-legal bytes for Go to put it on the wire at all), so
// the third step is where this stops rather than looping to a fixpoint.
// If a non-UTF-8 secret ever becomes reachable, make this alternate
// drop/strip until the string stops changing, then drop once more.
func stripPartialCredentialTail(s string, forms []scrubForm) string {
	s = dropTrailingIncompleteRune(s)
	s = stripPartialCredentialSuffix(s, forms)
	return dropTrailingIncompleteRune(s)
}

// SecretScrubber is the credential-agnostic counterpart of JiraClient's
// scrub machinery above: it redacts one raw secret value — and its
// base64 encodings — from text before it reaches an MCP caller.
// wakil-http's DoRequest builds one from the resolved auth token and
// scrubs the response body, every response header VALUE, and every
// response header NAME with it, answering the identical threat
// JiraClient answers (a server echoing back the credential it was sent)
// for an arbitrary HTTP API instead of Jira specifically.
//
// The body and header-value paths reuse every layer above completely
// unchanged: the same interval-merge scrub, the same raw-coordinate cut
// point, the same partial-suffix defence in depth, the same rune-safe
// truncation. The header-NAME path is the one exception — scrubHeaderName
// is new, not reused, because header names are case-folded in transit and
// so need a case-insensitive match that the body and value paths must NOT
// have (folding arbitrary UTF-8 is both lossy and offset-unsafe).
type SecretScrubber struct {
	forms []scrubForm
}

// NewSecretScrubber builds a scrubber for one raw secret value. A value
// shorter than jiraScrubMinTokenLen bytes, or empty, is excluded
// entirely and NewSecretScrubber returns a scrubber with no forms at all
// — mirroring JiraClient.scrubForms's own token-length gate exactly (see
// jiraScrubMinTokenLen's doc comment for why a short literal must not be
// scrubbed: it would redact unrelated coincidental text rather than a
// real credential). The four base64 encodings are gated at the same
// floor as the raw form, since — unlike JiraClient's pair case — there
// is no non-secret prefix here to protect a lower base64 floor against.
func NewSecretScrubber(secret string) *SecretScrubber {
	var forms []scrubForm
	if len(secret) >= jiraScrubMinTokenLen {
		forms = appendSecretForms(forms, secret, jiraScrubMinTokenLen, jiraScrubMinTokenLen)
	}
	return &SecretScrubber{forms: forms}
}

// NewAuthHeaderScrubber builds a scrubber for a stored Authorization
// header VALUE, enumerating BOTH the whole header value AND the bare
// credential inside it as separate forms.
//
// This exists because enumerating only the whole value is a real,
// reproduced leak. wakil-http stores the ENTIRE Authorization header
// value under one secret ref — for any bearer API that value is
// "Bearer <token>", not "<token>" — and a server that rejects the
// request commonly echoes back only the credential, not the scheme
// word it was sent with:
//
//	{"error":"invalid token","token":"kGh3FAKEnotARealCredentialXXXX..."}
//
// Built from the whole value alone, no form of this scrubber matches
// that body: "Bearer kGh3..." is absent, and the bare token is not a
// form at all, so all 192 bytes of the credential reached the caller
// verbatim (measured through doRequest against an httptest server).
//
// jira.go's scrubForms answers the identical threat correctly and this
// mirrors its reasoning directly: it enumerates the "email:token" pair
// AND the bare token as separate forms, precisely because a server can
// echo either one, and the pair alone would miss a bare-token echo.
// "Bearer <token>" is the same shape as "email:token" — a non-secret
// prefix glued to the secret — so it needs the same two-form treatment.
//
// The split is RFC 9110's credentials grammar
// ("credentials = auth-scheme [ 1*SP ( token68 / #auth-param ) ]"): the
// scheme is one token, then whitespace, then the credential. So the bare
// form is everything after the first run of whitespace. That covers
// "Bearer <token>", "Basic <base64>", "Token <key>", and the like, and
// degenerates safely for a value with no whitespace at all (an API that
// wants the raw key as the whole header value), where the bare form
// would equal the whole value and is simply not added twice.
//
// Both forms are gated at jiraScrubMinTokenLen, the same floor
// NewSecretScrubber uses: a scheme word plus a two-character credential
// would otherwise add a 2-byte literal that redacts every coincidental
// occurrence of those two bytes anywhere in the response. See that
// constant's doc comment for the observed "wall of [redacted]" this
// prevents.
func NewAuthHeaderScrubber(headerValue string) *SecretScrubber {
	var forms []scrubForm
	if len(headerValue) >= jiraScrubMinTokenLen {
		forms = appendSecretForms(forms, headerValue, jiraScrubMinTokenLen, jiraScrubMinTokenLen)
	}
	if bare := authHeaderCredential(headerValue); bare != headerValue && len(bare) >= jiraScrubMinTokenLen {
		forms = appendSecretForms(forms, bare, jiraScrubMinTokenLen, jiraScrubMinTokenLen)
	}
	return &SecretScrubber{forms: forms}
}

// authHeaderCredential returns the credential portion of an Authorization
// header value: everything after the first run of whitespace, which per
// RFC 9110's "credentials = auth-scheme [ 1*SP ... ]" grammar is exactly
// what follows the scheme word. It returns the value unchanged when there
// is no whitespace in it (the whole value IS the credential), which is
// how NewAuthHeaderScrubber detects that there is no second form to add.
func authHeaderCredential(v string) string {
	i := strings.IndexAny(v, " \t")
	if i < 0 {
		return v
	}
	return strings.TrimLeft(v[i:], " \t")
}

// Literals returns the literal strings this scrubber matches — used to
// size a read window (see LongestForm) or to feed CutPoint/Scrub
// directly.
func (s *SecretScrubber) Literals() []string { return literalsOf(s.forms) }

// LongestForm returns the length in bytes of the longest form this
// scrubber matches, or 0 if it holds no forms at all (secret was empty
// or shorter than jiraScrubMinTokenLen).
func (s *SecretScrubber) LongestForm() int { return longestScrubForm(s.Literals()) }

// Scrub redacts every occurrence of every form in msg — see scrubSecrets.
func (s *SecretScrubber) Scrub(msg string) string { return scrubSecrets(msg, s.Literals()) }

// CutPoint chooses, in raw pre-scrub byte coordinates, where to cut body
// before scrubbing it — see scrubCutPoint's doc comment.
func (s *SecretScrubber) CutPoint(body string, cap int) int {
	return scrubCutPoint(body, cap, s.Literals())
}

// StripPartialTail removes a trailing partial credential form and a
// trailing incomplete UTF-8 rune from str, in the only order that leaves
// neither behind — see stripPartialCredentialTail's doc comment. It
// deliberately does not expose stripPartialCredentialSuffix on its own,
// because calling that without the surrounding drops is the bug
// stripPartialCredentialTail exists to fix.
func (s *SecretScrubber) StripPartialTail(str string) string {
	return stripPartialCredentialTail(str, s.forms)
}

// ScrubHeaderName redacts every occurrence of every form in name,
// case-insensitively — see scrubHeaderName's doc comment for why header
// NAMES need case-insensitive matching where Scrub (used for header
// VALUES and the body) deliberately does not.
func (s *SecretScrubber) ScrubHeaderName(name string) string {
	return scrubHeaderName(name, s.Literals())
}
