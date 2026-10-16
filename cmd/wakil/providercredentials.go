package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"unicode"

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
	p, err := wakilcore.LoadProviderFor(org, id)
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
	// Resolved, not read straight off the record: a --share binding names
	// a config dir another org homes and inherits that record's binary.
	// See wakilcore.ResolveProviderClaudePath.
	claudePath, err := wakilcore.ResolveProviderClaudePath(*p)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	token, err := read(wakilcore.ProviderTokenRef(id))
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}

	// ALL whitespace is removed, interior included, and this is the one
	// place in the codebase where that is safe to do.
	//
	// An OAuth token cannot contain whitespace — it is the base64url
	// alphabet plus dashes — so any that is present was added in transit and
	// removing it can only restore the value. `SecretSet` deliberately does
	// NOT do this: it takes secrets of every kind, and a database password
	// containing a space is ordinary (`wakil secrets set-db` stores exactly
	// those), so a blanket strip there would silently corrupt a credential
	// that was correct. Knowing what the value IS, is what makes this legal.
	//
	// MEASURED, 2026-09-11. Both provider tokens on the operator's machine
	// carried two newlines and two spaces in the MIDDLE of the string:
	// `claude setup-token` printed a 108-character token across three
	// terminal lines and a mouse selection captured the wraps as real
	// characters. 112 stored, four of them junk. Stripping them returned a
	// token that authenticated against the live API on the first try. The
	// alternative — the operator noticing a wrapped paste by eye, every
	// time, forever — is not a thing to design around.
	token = strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return r
	}, token)
	if token == "" {
		fmt.Fprintln(stderr, message(wakilcore.UserError("the stored token for provider "+
			strconv.Quote(id)+" in org "+org+" is entirely whitespace — re-store it with: "+
			"wakil secrets set "+wakilcore.ProviderTokenRef(id)+" --org "+org)))
		return 2
	}

	out, err := json.Marshal(providerCredentialsJSON{
		ConfigDir: p.ConfigDir, ClaudePath: claudePath, OAuthToken: token,
	})
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	fmt.Fprintln(stdout, string(out))
	return 0
}
