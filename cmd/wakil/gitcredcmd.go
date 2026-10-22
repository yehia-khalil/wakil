package main

import (
	"bufio"
	"fmt"
	"io"
	"strings"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// runGitCredential is git's credential helper for an organisation's token account (3a-iii):
// `wakil --org <org> git-credential --host <host> get` answers the host's username and the token
// from the Keychain. store and erase do nothing — Wakil keeps the token, not git.
func runGitCredential(args []string, stdin io.Reader, stdout, stderr io.Writer, read secretReader,
	account func(host string) (wakilcore.GitAccount, bool)) int {
	host, op := "", ""
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--host" && i+1 < len(args):
			host = args[i+1]
			i++
		default:
			op = args[i]
		}
	}
	if op != "get" {
		return 0
	}
	// git sends its request on stdin. The helper reaches every git process the command starts — a
	// submodule on another host, a push URL elsewhere — so it answers only https on its own host,
	// and says nothing otherwise (git then has no credential, and fails without one).
	req := map[string]string{}
	s := bufio.NewScanner(stdin)
	for s.Scan() {
		if k, v, ok := strings.Cut(s.Text(), "="); ok {
			req[k] = v
		}
	}
	if req["protocol"] != "https" || req["host"] != host {
		return 0
	}
	a, ok := account(host)
	if !ok {
		fmt.Fprintln(stderr, "no git account for "+host)
		return 1
	}
	token, err := read(wakilcore.GitTokenRef(host))
	if err != nil || token == "" {
		fmt.Fprintln(stderr, "no token kept for "+host)
		return 1
	}
	fmt.Fprintf(stdout, "username=%s\npassword=%s\n", wakilcore.GitCredentialUsername(a), token)
	return 0
}

// runGitAskpass answers ssh's passphrase prompt for an organisation's key from the Keychain.
func runGitAskpass(args []string, stdout, stderr io.Writer, read secretReader) int {
	host := ""
	for i := 0; i+1 < len(args); i++ {
		if args[i] == "--host" {
			host = args[i+1]
		}
	}
	pass, err := read(wakilcore.GitPassphraseRef(host))
	if err != nil || pass == "" {
		fmt.Fprintln(stderr, "no passphrase kept for "+host)
		return 1
	}
	fmt.Fprintln(stdout, pass)
	return 0
}
