package wakilcore

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// SSHKeyListing is a key pair in ~/.ssh, by its public half's comment.
type SSHKeyListing struct {
	Path      string `json:"path"`
	Comment   string `json:"comment"`
	Type      string `json:"type"`
	Encrypted bool   `json:"encrypted"`
}

// ListSSHKeys lists ~/.ssh's key pairs (a .pub with its private key beside it). Encrypted is true
// when the key does not open without a passphrase; the add sheet then asks for it once.
func ListSSHKeys() []SSHKeyListing {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	pubs, _ := filepath.Glob(filepath.Join(home, ".ssh", "*.pub"))
	out := []SSHKeyListing{}
	for _, pub := range pubs {
		private := strings.TrimSuffix(pub, ".pub")
		if !fileExists(private) {
			continue
		}
		b, err := os.ReadFile(pub)
		if err != nil {
			continue
		}
		f := strings.Fields(string(b))
		if len(f) < 2 {
			continue
		}
		k := SSHKeyListing{Path: private, Type: f[0], Comment: strings.Join(f[2:], " ")}
		k.Encrypted = exec.Command("ssh-keygen", "-y", "-P", "", "-f", private).Run() != nil
		out = append(out, k)
	}
	return out
}

// GenerateGitKey makes an ed25519 key for org's account on host under the organisation's own
// git/ssh folder (call 1), encrypted with a random passphrase that is kept in the Keychain first —
// generated in-process, so the passphrase is never on a command line. It answers the public key
// (`ssh-ed25519 … comment`) and the private key's path.
func GenerateGitKey(org, host, comment string) (string, string, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return "", "", err
	}
	keys := filepath.Join(dir, "git", "ssh")
	if err := os.MkdirAll(keys, 0o700); err != nil {
		return "", "", err
	}
	path := filepath.Join(keys, strings.ToLower(host)+"_ed25519")
	if fileExists(path) {
		// A key an account uses stays; one no account uses (left by an earlier Generate) goes to
		// the Trash, so Generate can make another.
		if a, ok := GitAccountFor(org, host); ok && a.KeyPath == path {
			return "", "", UserError("a key for " + host + " already exists: Remove or Replace the account first")
		}
		for _, p := range []string{path, path + ".pub"} {
			if fileExists(p) {
				if out, err := exec.Command(trashBin, "-s", p).CombinedOutput(); err != nil {
					return "", "", UserError("could not move " + p + " to the Trash: " + strings.TrimSpace(string(out)))
				}
			}
		}
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", "", err
	}
	passphrase := base64.RawURLEncoding.EncodeToString(secret)
	if err := SecretSetFor(org, gitPassphraseRef(host), passphrase); err != nil {
		return "", "", err
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	block, err := ssh.MarshalPrivateKeyWithPassphrase(priv, comment, []byte(passphrase))
	if err != nil {
		return "", "", err
	}
	if err := os.WriteFile(path, pem.EncodeToMemory(block), 0o600); err != nil {
		return "", "", err
	}
	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		return "", "", err
	}
	line := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPub))) + " " + comment + "\n"
	if err := os.WriteFile(path+".pub", []byte(line), 0o644); err != nil {
		return "", "", err
	}
	return line, path, nil
}

// SetGitToken and SetGitKeyPassphrase keep an account's secret in the Keychain.
func SetGitToken(org, host, token string) error {
	return SecretSetFor(org, gitTokenRef(host), strings.TrimSpace(token))
}

// setAPIAccess keeps token for org's ssh GitHub account on host and records how it got there. The
// account keeps its method, key and user: git still pushes over ssh.
func setAPIAccess(org, host, token, how string) error {
	host = strings.ToLower(strings.TrimSpace(host))
	a, ok := GitAccountFor(org, host)
	if !ok {
		return UserError("no git account for " + host + " in " + org)
	}
	if a.Method != "ssh" || a.Provider != "github" {
		return UserError("API access belongs to an ssh GitHub account; " + host + "'s account signs in with " + a.Method)
	}
	if err := SetGitToken(org, host, token); err != nil {
		return err
	}
	a.APIAccess = how
	return AddGitAccount(org, a)
}

// SetGitAPIAccessToken gives org's ssh GitHub account on host API access with an access token.
func SetGitAPIAccessToken(org, host, token string) error {
	return setAPIAccess(org, host, token, "token")
}

// FinishAPIAccessSignIn is SetGitAPIAccessToken for a device flow's token.
func FinishAPIAccessSignIn(org, host, token string) error {
	return setAPIAccess(org, host, token, "signin")
}

// RemoveGitAPIAccess drops an ssh account's API access: its token leaves the Keychain and the
// account stays as it was.
func RemoveGitAPIAccess(org, host string) error {
	host = strings.ToLower(strings.TrimSpace(host))
	a, ok := GitAccountFor(org, host)
	if !ok {
		return UserError("no git account for " + host + " in " + org)
	}
	if a.Method != "ssh" || a.Provider != "github" {
		return UserError("API access belongs to an ssh GitHub account; " + host + "'s account signs in with " + a.Method)
	}
	if err := SecretDelete(org, gitTokenRef(host)); err != nil {
		return err
	}
	a.APIAccess = ""
	return AddGitAccount(org, a)
}

// GitHubTokenFor is the one resolver the ticket view reads GitHub through: org's git account for
// host must be a GitHub one, and carry a token — a Sign in, an access token, or an ssh account's
// API access.
func GitHubTokenFor(org, host string) (string, error) {
	host = strings.ToLower(host)
	a, ok := GitAccountFor(org, host)
	if !ok {
		return "", UserError("Pull requests not read: this organization has no git account for " + host + ". Add one in Settings → Organisation → Git.")
	}
	if a.Provider != "github" {
		return "", UserError("Pull requests are read from GitHub only.")
	}
	if a.Method == "ssh" && a.APIAccess == "" {
		return "", UserError("Pull requests not read: this organization's " + host + " account signs in with SSH, which reads no pull requests. Add API access to the GitHub account in Settings → Organisation → Git.")
	}
	token, _ := SecretGetFor(org, gitTokenRef(host))
	if token == "" {
		return "", UserError("no token kept for " + host)
	}
	return token, nil
}

func SetGitKeyPassphrase(org, host, passphrase string) error {
	return SecretSetFor(org, gitPassphraseRef(host), passphrase)
}

var sshGreetings = []*regexp.Regexp{
	regexp.MustCompile(`Hi ([^!\s]+)! You've successfully authenticated`),
	regexp.MustCompile(`Welcome to GitLab, @([^!\s]+)!`),
	regexp.MustCompile(`logged in as ([^.\s]+)\.`),
}

// parseSSHGreeting reads who a host says a key belongs to from `ssh -T`'s words. Bitbucket's
// "authenticated via ssh key." names nobody: it is a success with no name.
func parseSSHGreeting(text string) (string, bool) {
	for _, re := range sshGreetings {
		if m := re.FindStringSubmatch(text); m != nil {
			return m[1], true
		}
	}
	if strings.Contains(text, "authenticated via ssh key") {
		return "", true
	}
	return "", false
}

// gitUserAPI is where a token's owner is read, per provider (overridable by tests).
var gitUserAPI = map[string]string{
	"github":    "https://api.github.com/user",
	"gitlab":    "https://gitlab.com/api/v4/user",
	"bitbucket": "https://api.bitbucket.org/2.0/user",
}

// TestGitAccount asks the host who org's account for host is: `ssh -T` with the organisation's key
// for an ssh account, the provider's user API with the token otherwise. It answers the name the
// host knows (empty when the host names nobody), or the host's refusal whole.
func TestGitAccount(ctx context.Context, org, host string) (string, error) {
	a, ok := GitAccountFor(org, host)
	if !ok {
		return "", UserError("No git account for " + host + " in " + org + " — add one in Settings → Organisation → Git")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if a.Method == "ssh" {
		inv, _, _, err := credentials(org, "git@"+host+":x.git", GitRemoteOptions{})
		if err != nil {
			return "", err
		}
		var command string
		env := []string{}
		for _, kv := range inv.Env {
			if strings.HasPrefix(kv, "GIT_SSH_COMMAND=") {
				command = strings.TrimPrefix(kv, "GIT_SSH_COMMAND=")
			} else {
				env = append(env, kv)
			}
		}
		cmd := exec.CommandContext(ctx, "/bin/sh", "-c", command+" -T git@"+host)
		cmd.Env = append(remoteEnv(os.TempDir(), false, nil), env...)
		out, _ := cmd.CombinedOutput()
		text := scrubRemoteText(string(out))
		if user, ok := parseSSHGreeting(text); ok {
			return user, nil
		}
		return "", UserError(strings.TrimSpace(text))
	}
	return gitUserViaAPI(ctx, org, a, host)
}

// TestGitAPIAccess asks GitHub who the token behind org's account for host is. It is the test an
// ssh account's API access row has, since TestGitAccount asks ssh for such an account.
func TestGitAPIAccess(ctx context.Context, org, host string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if _, err := GitHubTokenFor(org, host); err != nil {
		return "", err
	}
	a, _ := GitAccountFor(org, host)
	return gitUserViaAPI(ctx, org, a, strings.ToLower(host))
}

// gitUserViaAPI reads the provider's user API with the account's token.
func gitUserViaAPI(ctx context.Context, org string, a GitAccount, host string) (string, error) {
	api, ok := gitUserAPI[a.Provider]
	if !ok {
		return "", UserError("Wakil cannot test a token on " + host + "; it is used on the next fetch")
	}
	token, _ := SecretGetFor(org, gitTokenRef(host))
	if token == "" {
		return "", UserError("no token kept for " + host)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, api, nil)
	if err != nil {
		return "", err
	}
	if a.Provider == "bitbucket" {
		req.SetBasicAuth(GitCredentialUsername(a), token)
	} else {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", UserError(host + " did not answer: " + err.Error())
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode != http.StatusOK {
		return "", UserError(fmt.Sprintf("%s refused the token (HTTP %d)", host, resp.StatusCode))
	}
	var who struct{ Login, Username, Nickname string }
	json.Unmarshal(body, &who)
	for _, n := range []string{who.Login, who.Username, who.Nickname} {
		if n != "" {
			return n, nil
		}
	}
	return "", nil
}
