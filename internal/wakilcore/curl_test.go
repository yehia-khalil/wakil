package wakilcore

import (
	"fmt"
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
	if len(r.Headers) == 0 {
		r.Headers = nil
	}
	if len(r.Dropped) == 0 {
		r.Dropped = nil
	}
	if len(r.Ignored) == 0 {
		r.Ignored = nil
	}
}

// Review Focus 1, flags BEFORE the URL: a value-taking flag Wakil does not read must take its
// value with it — never leave it to be read as the URL or as a header.
func TestParseCurlNeverCarriesAValueOfAFlagBeforeTheURL(t *testing.T) {
	for _, text := range []string{
		`curl -U alice:s3cr3t https://a.example/x`,
		`curl --oauth2-bearer s3cr3t https://a.example/x`,
		`curl -x http://u:s3cr3t@proxy:8080 https://a.example/x`,
		`curl -E client.pem:s3cr3t https://a.example/x`,
		`curl -c s3cr3t https://a.example/x`,
		`curl --pass s3cr3t https://a.example/x`,
		`curl --proxy-user u:s3cr3t https://a.example/x`,
		`curl -K s3cr3t https://a.example/x`,
		`curl --resolve s3cr3t:443:127.0.0.1 https://a.example/x`,
		`curl --frobnicate s3cr3t https://a.example/x`,
		`curl -Ualice:s3cr3t https://a.example/x`,
		`curl -ku u:s3cr3t https://a.example/x`,
		`curl -sEcert:s3cr3t https://a.example/x`,
		`curl -Eclient.pem:s3cr3t https://a.example/x`,
		`curl -sU alice:s3cr3t https://a.example/x`,
		`curl -H 'Authorization s3cr3t' https://a.example/x`,
		`curl -H 'Authorization s3cr3t;' https://a.example/x`,
		`curl -H 'Cookie s3cr3t;' https://a.example/x`,
		`curl -H 'Authorization s3cr3t: x' https://a.example/x`,
		"curl -H $'s3cr3t\tx y' https://a.example/x",
		`curl -H 's3cr3t' https://a.example/x`,
		`curl -H ': s3cr3t' https://a.example/x`,
		`curl -H $'X: a\r\nAuthorization: s3cr3t' https://a.example/x`,
		`curl -H $'X: a\nCookie: s3cr3t' https://a.example/x`,
	} {
		got, err := ParseCurl(text)
		if err != nil {
			t.Fatalf("%s: ParseCurl: %v", text, err)
		}
		if got.URL != "https://a.example/x" {
			t.Errorf("%s: URL = %q", text, got.URL)
		}
		if blob := fmt.Sprintf("%+v", got); strings.Contains(blob, "s3cr3t") {
			t.Errorf("%s: a dropped value leaked: %s", text, blob)
		}
		if len(got.Dropped) == 0 {
			t.Errorf("%s: nothing dropped", text)
		}
	}
}

func TestParseCurlDecodesDollarQuotesAndReadsMalformedHeaders(t *testing.T) {
	for _, tc := range []struct {
		name, text, body string
		headers          []CurlHeader
		dropped          []string
	}{
		{"chrome unicode escape", `curl https://a.example/x --data-raw $'{"m":"hi!"}'`, `{"m":"hi!"}`, nil, nil},
		{"hex and octal", `curl https://a.example/x --data-raw $'\x41\101é\U0001F600\a\e\'\\'`, "AAé\U0001F600\a\x1b'\\", nil, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseCurl(tc.text)
			if err != nil {
				t.Fatal(err)
			}
			if got.Body != tc.body {
				t.Fatalf("body %q, want %q", got.Body, tc.body)
			}
		})
	}
	got, err := ParseCurl(`curl -H 'X-Empty;' https://a.example/x`)
	if err != nil {
		t.Fatal(err)
	}
	if want := []CurlHeader{{"X-Empty", ""}}; !reflect.DeepEqual(got.Headers, want) || len(got.Dropped) != 0 {
		t.Fatalf("headers %+v dropped %+v", got.Headers, got.Dropped)
	}
	got, _ = ParseCurl(`curl -H 'Authorization s3cr3t' https://a.example/x`)
	if len(got.Dropped) != 1 || got.Dropped[0].Name != "Authorization" || len(got.Headers) != 0 {
		t.Fatalf("headers %+v dropped %+v", got.Headers, got.Dropped)
	}
}

func TestParseCurlNamesAMalformedHeaderOnlyByADeniedName(t *testing.T) {
	for _, tc := range []struct{ text, name string }{
		{`curl -H 'Authorization s3cr3t;' https://a.example/x`, "Authorization"},
		{`curl -H 'Cookie s3cr3t;' https://a.example/x`, "Cookie"},
		{"curl -H $'s3cr3t\tx y' https://a.example/x", "a malformed header"},
		{`curl -H 'X-Foo bar' https://a.example/x`, "a malformed header"},
		{`curl -H ': s3cr3t' https://a.example/x`, "a header with no name"},
	} {
		got, err := ParseCurl(tc.text)
		if err != nil {
			t.Fatal(err)
		}
		if len(got.Headers) != 0 || len(got.Dropped) != 1 || got.Dropped[0].Name != tc.name {
			t.Errorf("%s: headers %+v dropped %+v, want one drop named %q", tc.text, got.Headers, got.Dropped, tc.name)
		}
	}
}

// Final review: Unicode whitespace outside quotes separates words, exactly as the Swift trigger
// (apiPasteIsCurl) reads it; a URL's userinfo is a credential; HEAD's body reason names HEAD.
func TestParseCurlNeverCarriesAValueAfterUnicodeWhitespaceOrInTheURL(t *testing.T) {
	nb := " "
	for _, text := range []string{
		"curl https://a.example/x" + nb + "-H" + nb + "'Authorization: Bearer s3cr3t'",
		"curl https://a.example/x" + nb + "-u" + nb + "u:s3cr3t",
		"curl https://a.example/x" + nb + "--cookie" + nb + "sid=s3cr3t",
		"curl https://a.example/x -u u:s3cr3t",
		"curl https://u:s3cr3t@a.example/x",
		"curl --expand-url https://u:s3cr3t@a.example/x https://a.example/x",
		"curl --frobnicate https://u:s3cr3t@a.example/x",
		"curl --url https://s3cr3t@a.example/x",
	} {
		got, err := ParseCurl(text)
		if err != nil {
			continue // a refusal carries no value either
		}
		if blob := fmt.Sprintf("%+v", got); strings.Contains(blob, "s3cr3t") {
			t.Errorf("%q: a dropped value leaked: %s", text, blob)
		}
	}
	got, err := ParseCurl("curl https://u:s3cr3t@a.example/x")
	if err != nil || got.URL != "https://a.example/x" || len(got.Dropped) != 1 || got.Dropped[0].Name != "the URL's user:password" {
		t.Fatalf("got %+v err %v", got, err)
	}
}

func TestParseCurlReadsWhatTheSwiftTriggerAccepts(t *testing.T) {
	for _, tc := range []struct{ name, text string }{
		{"crlf after curl", "curl\r\nhttps://a.example/x"},
		{"leading BOM", "\ufeffcurl https://a.example/x"},
		{"leading NBSP", " curl https://a.example/x"},
		{"NBSP after curl", "curl https://a.example/x"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseCurl(tc.text)
			if err != nil || got.URL != "https://a.example/x" {
				t.Fatalf("got %+v err %v", got, err)
			}
		})
	}
}

func TestParseCurlRefusesAURLWithWhitespaceAndNamesHEAD(t *testing.T) {
	if _, err := ParseCurl("curl 'https://a.example/x y'"); err == nil {
		t.Fatal("a URL with whitespace was accepted")
	}
	got, _ := ParseCurl(`curl -I -d a=1 https://a.example/x`)
	if len(got.Dropped) != 1 || got.Dropped[0].Name != "a body on a HEAD" || got.Dropped[0].Reason != "a body on a HEAD is not sent" {
		t.Fatalf("dropped %+v", got.Dropped)
	}
	got, _ = ParseCurl(`curl --expand-data s3cr3t https://a.example/x`)
	if len(got.Dropped) != 1 || got.Dropped[0].Name != "--expand-data" || fmt.Sprintf("%+v", got) != fmt.Sprintf("%+v", CurlRequest{Method: "GET", URL: "https://a.example/x", Dropped: got.Dropped}) {
		t.Fatalf("got %+v", got)
	}
}

// Second fix wave: one blank predicate for every rune; a malformed URL never leaves ParseCurl.
func TestParseCurlNeverCarriesAValueThroughVFFZWSPOrAMalformedURL(t *testing.T) {
	const url = "https://api.x/v1/a"
	for _, text := range []string{
		"curl\v-H 'Authorization:S3CR' " + url,
		"curl " + url + " -H 'X: y'\v-H\v'Authorization: Bearer S3CR'",
		"curl " + url + " -d 'a=1'\v-u\vu:S3CR",
		"curl\f-H 'Authorization:S3CR' " + url,
		"curl " + url + " -H 'X: y'\f-H\f'Authorization: Bearer S3CR'",
		"curl " + url + "\u200b-H\u200b'Authorization:S3CR'",
		"curl " + url + " -H 'X: y'\u200b-u\u200bu:S3CR",
		"curl\u200b" + url + "\u200b-b\u200bS3CR",
		"curl //u:S3CR@api.x/v1/a",
		"curl https:/u:S3CR@api.x/v1/a",
		"curl https://u:S3/CR@api.x/v1/a",
		"curl 'https://u:S3?CR@api.x/v1/a'",
		"curl 'https://u:S3#CR@api.x/v1/a'",
		"curl https://u:S3CR@api.x/v1/a",
		"curl https://S3CR@api.x/v1/a",
		"curl https://u:S3CR@@api.x/v1/a",
		"curl https://api.x%40S3CR/v1/a",
		"curl https://[u:S3CR@api.x/v1/a",
	} {
		got, err := ParseCurl(text)
		if err != nil {
			if strings.Contains(err.Error(), "S3CR") {
				t.Errorf("%q: the refusal carries the secret: %v", text, err)
			}
			continue
		}
		if blob := fmt.Sprintf("%+v", got); strings.Contains(blob, "S3CR") {
			t.Errorf("%q: a dropped value leaked: %s", text, blob)
		}
	}
	for _, text := range []string{
		"curl //u:S3CR@api.x/v1/a", "curl https:/u:S3CR@api.x/v1/a", "curl https://u:S3/CR@api.x/v1/a",
		"curl 'https://u:S3?CR@api.x/v1/a'", "curl 'https://u:S3#CR@api.x/v1/a'", "curl api.x/v1/a",
	} {
		if _, err := ParseCurl(text); err == nil || err.Error() != "the URL names no host Wakil can read" {
			t.Errorf("%q: err = %v", text, err)
		}
	}
	got, err := ParseCurl("curl\v-H 'Authorization:S3CR' " + url)
	if err != nil || got.URL != url || len(got.Dropped) != 1 || got.Dropped[0].Name != "Authorization" {
		t.Errorf("\\v-separated: %+v %v", got, err)
	}
	for text, name := range map[string]string{
		"curl https://user@api.x/v1/a":    "the URL's user",
		"curl https://user:pw@api.x/v1/a": "the URL's user:password",
	} {
		got, err := ParseCurl(text)
		if err != nil || got.URL != url || len(got.Dropped) != 1 || got.Dropped[0].Name != name {
			t.Errorf("%q: %+v %v", text, got, err)
		}
	}
	// An @ in the path or query is data, not userinfo.
	got, err = ParseCurl("curl 'https://api.x/v1/a@b?c=d@e'")
	if err != nil || got.URL != "https://api.x/v1/a@b?c=d@e" || len(got.Dropped) != 0 {
		t.Errorf("@ in path: %+v %v", got, err)
	}
}

// Every scalar Go and Swift treat as a word separator. The same list is in
// ApiCurlFillTests.swift; neither side may drift from it.
var curlBlankScalars = []rune{
	0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680,
	0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
	0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
}

func TestCurlBlankIsExactlyTheSharedList(t *testing.T) {
	in := map[rune]bool{}
	for _, r := range curlBlankScalars {
		in[r] = true
	}
	for r := rune(0); r <= 0x10FFFF; r++ {
		if curlBlank(r) != in[r] {
			t.Fatalf("curlBlank(%U) = %v, list says %v", r, curlBlank(r), in[r])
		}
	}
}
