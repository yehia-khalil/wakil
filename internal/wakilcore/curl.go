package wakilcore

import (
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
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
	reasonFragment   = "a #fragment is not sent"
	reasonExtra      = "curl would request it as a second URL"
	reasonUnread     = "an option Wakil does not read, and the value it takes"
	reasonMalformed  = "not a header Wakil can read: no colon, or a name that is not one token"
	reasonNoName     = "a header with an empty name"
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
	"-g": true, "--globoff": true, "-N": true, "--no-buffer": true, "-4": true, "--ipv4": true,
	"-6": true, "--ipv6": true, "-0": true, "--http1.0": true,
}

// Options that take a value which Wakil does not read (from `curl --help all`, curl 8.7.1).
// The value is consumed and dropped with the option, by the option's name: a pasted
// -U alice:secret, --oauth2-bearer, -x http://u:secret@proxy or -E cert:pass must neither
// fill the request nor be read as the URL (Amendment 11d).
var curlValueUnread = func() map[string]bool {
	m := map[string]bool{}
	for _, f := range strings.Fields(`--abstract-unix-socket --alt-svc --aws-sigv4 --cacert --capath --cert
		--cert-type --ciphers --config --connect-to --continue-at --cookie-jar --create-file-mode
		--crlfile --curves --delegation --dns-interface --dns-ipv4-addr --dns-ipv6-addr --dns-servers
		--doh-url --dump-header --egd-file --engine --etag-compare --etag-save --expect100-timeout
		--ftp-account --ftp-alternative-to-user --ftp-method --ftp-port --ftp-ssl-ccc-mode
		--happy-eyeballs-timeout-ms --haproxy-clientip --help --hostpubmd5 --hostpubsha256 --hsts
		--interface --ipfs-gateway --keepalive-time --key --key-type --krb --libcurl --limit-rate
		--local-port --login-options --mail-auth --mail-from --mail-rcpt --max-filesize --max-redirs
		--netrc-file --noproxy --oauth2-bearer --output-dir --parallel-max --pass --pinnedpubkey
		--preproxy --proto --proto-default --proto-redir --proxy --proxy-cacert --proxy-capath
		--proxy-cert --proxy-cert-type --proxy-ciphers --proxy-crlfile --proxy-header --proxy-key
		--proxy-key-type --proxy-pass --proxy-pinnedpubkey --proxy-service-name
		--proxy-tls13-ciphers --proxy-tlsauthtype --proxy-tlspassword --proxy-tlsuser --proxy-user
		--proxy1.0 --pubkey --quote --random-file --range --rate --request-target --resolve
		--retry-delay --retry-max-time --sasl-authzid --service-name --socks4 --socks4a --socks5
		--socks5-gssapi-service --socks5-hostname --speed-limit --speed-time --stderr
		--telnet-option --tftp-blksize --time-cond --tls-max --tls13-ciphers --tlsauthtype
		--tlspassword --tlsuser --trace --trace-ascii --trace-config --unix-socket --url-query
		--variable`) {
		m[f] = true
	}
	for _, c := range "EKCcDPhxUQrYytz" {
		m["-"+string(c)] = true
	}
	return m
}()

func curlKnownBoolean(flag string) bool {
	switch flag {
	case "-G", "--get", "-I", "--head", "-k", "--insecure":
		return true
	}
	return curlIgnored[flag]
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
	trimmed := strings.TrimLeftFunc(text, curlBlank)
	if after, ok := strings.CutPrefix(trimmed, "curl"); !ok || after == "" {
		return CurlRequest{}, UserError("not a cURL command")
	} else if next, _ := utf8.DecodeRuneInString(after); !curlBlank(next) && next != '\\' {
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
			// Combined short flags: each boolean letter stands alone; the first letter that takes
			// a value takes the rest of the word (or the next word). The first letter that is
			// unknown, or takes a value Wakil does not read, is dropped with the rest of the
			// word, and the scan of the word stops.
			for j := 1; j < len(w); j++ {
				c := w[j]
				single := "-" + string(c)
				if curlShortWithValue[c] || curlValueUnread[single] || !curlKnownBoolean(single) {
					flag = single
					if j+1 < len(w) {
						attached, hasAttached = w[j+1:], true
					}
					break
				}
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
			if strings.ContainsAny(v, "\r\n") {
				// A line break would smuggle a second header inside this one's value.
				drop("a malformed header", reasonMalformed)
				continue
			}
			name, val, hasColon := strings.Cut(v, ":")
			name = strings.TrimSpace(name)
			if !hasColon {
				// curl: "X;" is header X with an empty value. X must be one token: any other
				// text with no colon is no header.
				if x, ok := strings.CutSuffix(strings.TrimSpace(v), ";"); ok && curlIsToken(strings.TrimSpace(x)) {
					name = strings.TrimSpace(x)
				} else {
					drop(curlMalformedLabel(v), reasonMalformed)
					continue
				}
			}
			if name == "" {
				drop("a header with no name", reasonNoName)
				continue
			}
			if !curlIsToken(name) {
				drop(curlMalformedLabel(name), reasonMalformed)
				continue
			}
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
		case curlValueUnread[flag] || strings.HasPrefix(flag, "--expand-"):
			value()
			drop(flag, reasonUnread)
		case !curlKnownBoolean(flag):
			// A flag Wakil has never heard of may take a value. Drop the next word with it
			// unless it looks like a URL or another flag.
			drop(flag, reasonUnknown)
			if !hasAttached && i+1 < len(words) {
				if n := words[i+1]; !strings.Contains(n, "://") && !strings.HasPrefix(n, "-") {
					i++
				}
			}
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
	if err := curlSanitizeURL(&r, drop); err != nil {
		return CurlRequest{}, err
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
			drop("a body on a "+r.Method, "a body on a "+r.Method+" is not sent")
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
		ru, size := utf8.DecodeRuneInString(s[i:])
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
		case curlBlank(ru):
			flush()
			i += size - 1
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
					j = curlANSIEscape(s, j+1, &cur)
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
			cur.WriteString(s[i : i+size])
			inWord = true
			i += size - 1
		}
	}
	flush()
	return words, nil
}

// curlANSIEscape decodes the escape whose letter is at s[k] (inside $'…'), writes it to cur and
// returns the index of its last byte: \n \t \r \a \b \e \f \v \\ \' \" \?, \xHH, \uXXXX,
// \UXXXXXXXX and octal \NNN. An escape bash does not know is kept as written.
func curlANSIEscape(s string, k int, cur *strings.Builder) int {
	digits := func(from, max, base int) (int, int) { // value, index of last digit (from-1 if none)
		end := from
		set := "0123456789abcdefABCDEF"
		if base == 8 {
			set = "01234567"
		}
		for end < len(s) && end-from < max && strings.IndexByte(set, s[end]) >= 0 {
			end++
		}
		n, _ := strconv.ParseUint(s[from:end], base, 32)
		return int(n), end - 1
	}
	switch c := s[k]; c {
	case 'n':
		cur.WriteByte('\n')
	case 't':
		cur.WriteByte('\t')
	case 'r':
		cur.WriteByte('\r')
	case 'a':
		cur.WriteByte(7)
	case 'b':
		cur.WriteByte(8)
	case 'e', 'E':
		cur.WriteByte(27)
	case 'f':
		cur.WriteByte(12)
	case 'v':
		cur.WriteByte(11)
	case '\\', '\'', '"', '?':
		cur.WriteByte(c)
	case 'x':
		if n, last := digits(k+1, 2, 16); last >= k+1 {
			cur.WriteByte(byte(n))
			return last
		}
		cur.WriteString("\\x")
	case 'u', 'U':
		max := 4
		if c == 'U' {
			max = 8
		}
		if n, last := digits(k+1, max, 16); last >= k+1 {
			if r := rune(n); utf8.ValidRune(r) {
				cur.WriteRune(r)
			} else {
				cur.WriteRune(utf8.RuneError)
			}
			return last
		}
		cur.WriteString("\\" + string(c))
	case '0', '1', '2', '3', '4', '5', '6', '7':
		n, last := digits(k, 3, 8)
		cur.WriteByte(byte(n))
		return last
	default:
		cur.WriteByte('\\')
		cur.WriteByte(c)
	}
	return k
}

// curlIsToken reports whether s is an RFC 7230 token: the only thing a header name may be.
func curlIsToken(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte("!#$%&'*+-.^_`|~", c) >= 0) {
			return false
		}
	}
	return true
}

// curlMalformedLabel names a malformed header. The first word of one can itself be the secret,
// so it is named by that word only when the word is followed by more text and is a header Wakil
// refuses by name (Authorization, Cookie, Host, Proxy-*); otherwise it is not echoed at all.
func curlMalformedLabel(text string) string {
	if fields := strings.Fields(text); len(fields) > 1 {
		first := fields[0]
		lower := strings.ToLower(first)
		if curlIsToken(first) && (lower == "authorization" || lower == "cookie" || lower == "host" || strings.HasPrefix(lower, "proxy-")) {
			return first
		}
	}
	return "a malformed header"
}

// curlBlank is what separates words outside quotes, for every rune, and what may follow
// "curl": Unicode white space (the White_Space property), the byte order mark an editor leaves at
// the start of a paste, and the zero width space. It is exactly the set of Swift's trigger,
// apiPasteIsCurl; both tests enumerate the same list.
func curlBlank(r rune) bool { return unicode.IsSpace(r) || r == 0xFEFF || r == 0x200B }

const curlNoHost = "the URL names no host Wakil can read"

// curlSanitizeURL leaves in r.URL only a URL with a scheme and a valid host and no userinfo.
// Userinfo is a credential: it is cut and named. Anything it cannot read as scheme://host is
// refused with a fixed sentence, so no part of a malformed URL — a credential written as
// "//u:pw@h", "https:/u:pw@h" or "https://u:pw/x@h" — leaves ParseCurl.
func curlSanitizeURL(r *CurlRequest, drop func(string, string)) error {
	if strings.IndexFunc(r.URL, curlBlank) >= 0 {
		// Backstop: whitespace the word splitter missed would carry the rest of the command
		// into the path.
		return UserError("not a cURL command Wakil can read: a URL with whitespace")
	}
	u, err := url.Parse(r.URL)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return UserError(curlNoHost)
	}
	if u.User != nil {
		authStart := strings.Index(r.URL, "://") + 3
		authEnd := len(r.URL)
		if i := strings.IndexAny(r.URL[authStart:], "/?"); i >= 0 {
			authEnd = authStart + i
		}
		at := strings.LastIndexByte(r.URL[authStart:authEnd], '@')
		if at < 0 {
			return UserError(curlNoHost)
		}
		r.URL = r.URL[:authStart] + r.URL[authStart+at+1:]
		name := "the URL's user"
		if _, has := u.User.Password(); has {
			name = "the URL's user:password"
		}
		drop(name, reasonCredential)
		if u, err = url.Parse(r.URL); err != nil || u.User != nil || u.Host == "" {
			return UserError(curlNoHost)
		}
	}
	if !curlValidHost(u.Hostname()) {
		return UserError(curlNoHost)
	}
	return nil
}

// curlValidHost: a DNS-style name (letters, digits, '-', '_', '.') or an IP address.
func curlValidHost(h string) bool {
	if h == "" {
		return false
	}
	if net.ParseIP(h) != nil {
		return true
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}
