package wakilcore

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// GitHubClientID and GitLabClientID are Wakil's public OAuth client ids for the device flow
// (3a-iii, R4). Empty until the operator registers the two apps (operator-todo): Sign in is then
// not offered. A device-flow client has no secret, so the ids may ship in the app.
var (
	GitHubClientID = ""
	GitLabClientID = ""
)

type deviceEndpoint struct{ Code, Token string }

var deviceEndpoints = map[string]deviceEndpoint{
	"github": {Code: "https://github.com/login/device/code", Token: "https://github.com/login/oauth/access_token"},
	"gitlab": {Code: "https://gitlab.com/oauth/authorize_device", Token: "https://gitlab.com/oauth/token"},
}

var deviceScopes = map[string]string{
	"github": "repo",
	"gitlab": "read_repository write_repository read_user",
}

func clientID(provider string) string {
	switch provider {
	case "github":
		return GitHubClientID
	case "gitlab":
		return GitLabClientID
	}
	return ""
}

// SignInProviders is which providers Sign in is offered for: those with a client id.
func SignInProviders() map[string]bool {
	return map[string]bool{"github": GitHubClientID != "", "gitlab": GitLabClientID != ""}
}

// DeviceCode is what the operator is shown: the code to type and the page to type it on.
type DeviceCode struct {
	DeviceCode      string `json:"deviceCode"`
	UserCode        string `json:"userCode"`
	VerificationURI string `json:"verificationUri"`
	Interval        int    `json:"interval"`
	ExpiresIn       int    `json:"expiresIn"`
}

func devicePost(ctx context.Context, endpoint string, form url.Values) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, UserError("the provider did not answer: " + err.Error())
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, UserError("the provider's answer was not JSON: " + strings.TrimSpace(string(body)))
	}
	return out, nil
}

// DeviceStart begins a provider's device flow (GitHub, GitLab.com).
func DeviceStart(ctx context.Context, provider string) (DeviceCode, error) {
	id := clientID(provider)
	ep, ok := deviceEndpoints[provider]
	if id == "" || !ok {
		return DeviceCode{}, UserError("Sign in is not set up for " + provider + " in this build; use an SSH key or a token")
	}
	out, err := devicePost(ctx, ep.Code, url.Values{"client_id": {id}, "scope": {deviceScopes[provider]}})
	if err != nil {
		return DeviceCode{}, err
	}
	str := func(k string) string { s, _ := out[k].(string); return s }
	num := func(k string) int { f, _ := out[k].(float64); return int(f) }
	code := DeviceCode{DeviceCode: str("device_code"), UserCode: str("user_code"), VerificationURI: str("verification_uri"),
		Interval: num("interval"), ExpiresIn: num("expires_in")}
	if code.DeviceCode == "" {
		return DeviceCode{}, UserError("the provider refused to start a sign-in: " + str("error_description") + str("error"))
	}
	return code, nil
}

// DevicePoll asks once whether the operator has approved; pending means ask again after the interval.
func DevicePoll(ctx context.Context, provider, deviceCode string) (string, bool, error) {
	ep, ok := deviceEndpoints[provider]
	if !ok {
		return "", false, UserError("no sign-in for " + provider)
	}
	out, err := devicePost(ctx, ep.Token, url.Values{"client_id": {clientID(provider)}, "device_code": {deviceCode},
		"grant_type": {"urn:ietf:params:oauth:grant-type:device_code"}})
	if err != nil {
		return "", false, err
	}
	if tok, _ := out["access_token"].(string); tok != "" {
		return tok, false, nil
	}
	switch e, _ := out["error"].(string); e {
	case "authorization_pending", "slow_down":
		return "", true, nil
	case "expired_token":
		return "", false, UserError("the code expired — Try again")
	case "access_denied":
		return "", false, UserError("the sign-in was declined")
	default:
		return "", false, UserError("the sign-in failed: " + e)
	}
}

// GhLogin is a login the GitHub CLI holds.
type GhLogin struct {
	Host string `json:"host"`
	User string `json:"user"`
}

var ghLoginLine = regexp.MustCompile(`Logged in to (\S+) account (\S+)`)

func parseGhLogins(text string) []GhLogin {
	out := []GhLogin{}
	for _, m := range ghLoginLine.FindAllStringSubmatch(text, -1) {
		out = append(out, GhLogin{Host: m[1], User: m[2]})
	}
	return out
}

// GhLogins lists `gh auth status`'s logins; none when gh is not installed.
func GhLogins() []GhLogin {
	out, _ := exec.Command("gh", "auth", "status").CombinedOutput()
	return parseGhLogins(string(out))
}

// ImportGhLogin copies one gh login's token into org's Keychain once and records a signin account
// for its host: Use a gh login (spec item 1, Sign in's shortcut).
func ImportGhLogin(org, host, user string) error {
	out, err := exec.Command("gh", "auth", "token", "--user", user, "--hostname", host).Output()
	if err != nil {
		return UserError("gh has no token for " + user + " on " + host)
	}
	if err := SetGitToken(org, host, strings.TrimSpace(string(out))); err != nil {
		return err
	}
	return AddGitAccount(org, GitAccount{Host: host, Provider: "github", Method: "signin", User: user})
}

// FinishSignIn keeps a device flow's token and records the account.
func FinishSignIn(org, provider, host, token string) error {
	if err := SetGitToken(org, host, token); err != nil {
		return err
	}
	return AddGitAccount(org, GitAccount{Host: host, Provider: provider, Method: "signin"})
}
