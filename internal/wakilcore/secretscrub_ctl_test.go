package wakilcore

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// TestScrubHeaderNameFoldIsLengthPreserving pins that scrubHeaderName's
// case fold cannot corrupt the span offsets it computes. The spans are
// found in the folded string and applied to the ORIGINAL, so a fold that
// changes byte length silently breaks every offset after it.
//
// The earlier strings.ToLower version failed exactly here, and both
// directions were reachable: U+023A "\u023a" (2 bytes) folds to U+2C65
// (3 bytes) and GREW the string until an offset ran past the end and
// panicked; U+212A KELVIN SIGN (3 bytes) folds to "k" (1 byte) and SHRANK
// it, drifting the redaction window left so it over-redacted the prefix,
// cut a rune in half, and left a verbatim tail of the credential — 16
// bytes of an 18-byte token with eight Kelvin signs in the name.
//
// net/http rejects non-ASCII header names, so none of this was reachable
// through doRequest; scrubHeaderName is exported via
// SecretScrubber.ScrubHeaderName, and a security function should not rely
// on another package's unstated input filtering.
//
// MUTATION-VERIFIED: swapping asciiLower back to strings.ToLower panics
// on the growing case and leaks on the shrinking one.
func TestScrubHeaderNameFoldIsLengthPreserving(t *testing.T) {
	const token = "0123456789abcdef01"
	sc := NewSecretScrubber(token)

	for _, name := range []string{
		"X-\u023a-" + token,                              // grows under Unicode folding
		strings.Repeat("\u023a", 10) + token,             // grows a lot
		"X-\u212a-" + token,                              // shrinks
		"X-" + strings.Repeat("\u212a", 8) + "-" + token, // shrinks a lot
		"X-\u0130-" + token,                              // shrinks by one
		"X-Echo-" + token,                                // the ordinary ASCII case
		// Case-varied credential. token[:6] is all digits, so upper-casing
		// THAT prefix was a no-op and the case was byte-identical to the
		// plain one above — it pinned nothing. Upper-case the hex tail,
		// which actually has letters in it.
		token[:10] + strings.ToUpper(token[10:]),
	} {
		got := sc.ScrubHeaderName(name) // must not panic

		if strings.Contains(got, token) {
			t.Errorf("name %q: full token survived: %q", name, got)
		}
		// No verbatim fragment of the credential may survive.
		for n := len(token); n >= 6; n-- {
			for i := 0; i+n <= len(token); i++ {
				if strings.Contains(got, token[i:i+n]) {
					t.Errorf("name %q: %d-byte credential fragment %q survived: %q", name, n, token[i:i+n], got)
					n = 0
					break
				}
			}
			if n == 0 {
				break
			}
		}
		if utf8.ValidString(name) && !utf8.ValidString(got) {
			t.Errorf("name %q: fold cut a rune in half: %q", name, got)
		}
		if !strings.Contains(got, "[redacted]") {
			t.Errorf("name %q: scrub did not fire: %q", name, got)
		}
	}
}

// TestAsciiLowerPreservesByteLength pins asciiLower's load-bearing
// property directly, independent of any caller.
func TestAsciiLowerPreservesByteLength(t *testing.T) {
	for _, s := range []string{
		"", "abc", "ABC", "X-Echo-ABC123",
		"\u023a", "\u212a", "\u0130", "\u0131", "\u017f",
		"\u00df", "\u4f60\u597d", "\U0001d11e",
		"MiXeD-\u212a-CaSe",
	} {
		got := asciiLower(s)
		if len(got) != len(s) {
			t.Errorf("asciiLower(%q) changed byte length: %d -> %d (%q)", s, len(s), len(got), got)
		}
		// The named property above is byte length. Also assert the fold
		// actually happened and touched ONLY A-Z, since a length-preserving
		// no-op would satisfy the length check on its own.
		for i := 0; i < len(s); i++ {
			want := s[i]
			if want >= 'A' && want <= 'Z' {
				want += 'a' - 'A'
			}
			if got[i] != want {
				t.Errorf("asciiLower(%q) byte %d = %q, want %q", s, i, got[i], want)
			}
		}
	}
}

// TestScrubHeaderNameOutputIsValidUTF8 pins the OTHER way scrubHeaderName's
// byte offsets could cut a rune in half. The fold-length test above covers
// offsets that DRIFT; this covers offsets that are exact but land
// mid-rune, which the fold cannot prevent because it guarantees byte
// length, not rune alignment.
//
// The fixtures are the reproduced ones, and they are not accidentally
// ASCII — an all-ASCII name here would prove nothing, since an ASCII
// literal can only ever match at a rune boundary (see scrubHeaderName's
// doc comment). Both need a raw form that is not valid UTF-8, which is why
// the secrets below are byte strings and not text:
//
//	midrune: the literal begins with a continuation byte, so the match
//	         starts inside the "é" that precedes it. Before the fix:
//	         "X-\xc3[redacted]-Echo", valid=false.
//	tailrune: the literal ends with a lone lead byte, so the match ends
//	         inside the "é" it starts. Before the fix:
//	         "X-[redacted]\xa9-Echo", valid=false.
//
// Each case asserts three things, because any one alone is passable by a
// cheat: the name went in valid (so the function is answerable for the
// output), the redaction actually FIRED, and no fragment of the credential
// survived — a "fix" that simply stopped redacting would produce valid
// UTF-8 too.
func TestScrubHeaderNameOutputIsValidUTF8(t *testing.T) {
	for _, tc := range []struct {
		label  string
		secret string
		name   string
	}{
		{"midrune", "\xa9bcdefghijklmnop", "X-\xc3" + "\xa9bcdefghijklmnop" + "-Echo"},
		{"tailrune", "abcdefghijklmno\xc3", "X-" + "abcdefghijklmno\xc3" + "\xa9-Echo"},
		{"midrune-repeated", "\xa9bcdefghijklmnop", "X-\xc3\xa9bcdefghijklmnop-é-\xc3\xa9bcdefghijklmnop"},
	} {
		if !utf8.ValidString(tc.name) {
			t.Fatalf("%s: fixture is broken — the name must go IN valid for the output to be this function's fault: %q", tc.label, tc.name)
		}
		if utf8.ValidString(tc.secret) {
			t.Fatalf("%s: fixture is broken — a valid-UTF-8 literal can only match on a rune boundary and pins nothing: %q", tc.label, tc.secret)
		}

		got := NewSecretScrubber(tc.secret).ScrubHeaderName(tc.name)
		if !utf8.ValidString(got) {
			t.Errorf("%s: scrubHeaderName cut a rune in half: %q", tc.label, got)
		}
		if !strings.Contains(got, "[redacted]") {
			t.Errorf("%s: scrub did not fire, so validity proves nothing: %q", tc.label, got)
		}
		if strings.Contains(got, tc.secret) {
			t.Errorf("%s: full credential survived: %q", tc.label, got)
		}
		// No verbatim run of the credential may survive either — this is
		// what catches a "widen inwards" fix, which would leave the
		// credential's leading or trailing bytes behind.
		for n := len(tc.secret); n >= 6; n-- {
			for i := 0; i+n <= len(tc.secret); i++ {
				if strings.Contains(got, tc.secret[i:i+n]) {
					t.Errorf("%s: %d-byte credential fragment %q survived: %q", tc.label, n, tc.secret[i:i+n], got)
					n = 0
					break
				}
			}
			if n == 0 {
				break
			}
		}
	}
}

// TestExpandSpanToRuneBoundaries pins the helper directly: it must widen,
// never narrow, and must be a no-op on a span already aligned.
func TestExpandSpanToRuneBoundaries(t *testing.T) {
	const s = "aé€b" // 1 + 2 + 3 + 1 bytes
	if len(s) != 7 {
		t.Fatalf("fixture is not the byte layout this test reasons about: %d", len(s))
	}
	for _, tc := range []struct{ start, end, wantLo, wantHi int }{
		{0, 1, 0, 1}, // "a": already aligned both ends
		{2, 3, 1, 3}, // inside "é" on both sides -> the whole rune
		{1, 4, 1, 6}, // starts on "é", ends inside "€" -> through "€"
		{4, 5, 3, 6}, // wholly inside "€"
		{0, 7, 0, 7}, // the whole string
		{6, 7, 6, 7}, // "b": already aligned
	} {
		lo, hi := expandSpanToRuneBoundaries(s, tc.start, tc.end)
		if lo != tc.wantLo || hi != tc.wantHi {
			t.Errorf("expandSpanToRuneBoundaries(%q, %d, %d) = (%d,%d), want (%d,%d)",
				s, tc.start, tc.end, lo, hi, tc.wantLo, tc.wantHi)
		}
		if lo > tc.start || hi < tc.end {
			t.Errorf("span (%d,%d) narrowed to (%d,%d): narrowing leaves credential bytes behind",
				tc.start, tc.end, lo, hi)
		}
		if !utf8.ValidString(s[:lo]) || !utf8.ValidString(s[hi:]) {
			t.Errorf("span (%d,%d) -> (%d,%d) does not sit on rune boundaries", tc.start, tc.end, lo, hi)
		}
	}
}
