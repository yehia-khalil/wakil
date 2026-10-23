package wakilcore

import (
	"context"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// RemoteURL is a git remote as 3a-iii reads it. An scp-like `git@host:path` is Scheme "ssh".
type RemoteURL struct {
	Scheme, User, Host, Port, Path string
}

// ParseRemoteURL reads a remote's URL. Only ssh, https and file remotes are allowed (Decision 44):
// ext::, git:// and plain http:// are refused before git ever runs.
func ParseRemoteURL(raw string) (RemoteURL, error) {
	raw = strings.TrimSpace(raw)
	if i := strings.Index(raw, "::"); i > 0 && !strings.Contains(raw[:i], "/") {
		return RemoteURL{}, UserError("protocol not allowed: " + raw[:i])
	}
	if strings.Contains(raw, "://") {
		u, err := url.Parse(raw)
		if err != nil {
			return RemoteURL{}, UserError("not a git remote: " + raw)
		}
		switch u.Scheme {
		case "ssh", "https":
		case "file":
			return RemoteURL{Scheme: "file", Path: u.Path}, nil
		default:
			return RemoteURL{}, UserError("protocol not allowed: " + u.Scheme)
		}
		r := RemoteURL{Scheme: u.Scheme, Host: u.Hostname(), Port: u.Port(), Path: strings.TrimPrefix(u.Path, "/")}
		if u.User != nil {
			r.User = u.User.Username()
		}
		return r, nil
	}
	// An absolute path is git's local (file) transport: `git clone /path/repo.git` records it so.
	if filepath.IsAbs(raw) {
		return RemoteURL{Scheme: "file", Path: raw}, nil
	}
	// scp-like: [user@]host:path, where host has no slash before the colon.
	colon := strings.Index(raw, ":")
	if colon <= 0 || strings.Contains(raw[:colon], "/") {
		return RemoteURL{}, UserError("not a git remote: " + raw)
	}
	r := RemoteURL{Scheme: "ssh", Host: raw[:colon], Path: raw[colon+1:]}
	if at := strings.LastIndex(r.Host, "@"); at >= 0 {
		r.User, r.Host = r.Host[:at], r.Host[at+1:]
	}
	return r, nil
}

// SSHRoute is the part of an ssh config that says how to reach a host — never which key to use.
type SSHRoute struct {
	HostName, Port, User, ProxyJump, HostKeyAlias string
}

// ResolveSSHRoute asks `ssh -G` how the operator's ~/.ssh/config reaches alias, and keeps only the
// route (call 3): an alias such as github-umbrella finds github.com, while its IdentityFile lines
// are dropped so a push can never fall back to another account's key.
func ResolveSSHRoute(alias string) (SSHRoute, error) {
	config := "/dev/null"
	if home, err := os.UserHomeDir(); err == nil {
		if p := filepath.Join(home, ".ssh", "config"); fileExists(p) {
			config = p
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ssh", "-G", "-F", config, alias).Output()
	if err != nil {
		return SSHRoute{}, UserError("could not resolve the ssh host " + alias + ": " + err.Error())
	}
	var r SSHRoute
	for _, line := range strings.Split(string(out), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), " ")
		if !ok {
			continue
		}
		switch key {
		case "hostname":
			r.HostName = value
		case "port":
			r.Port = value
		case "user":
			r.User = value
		case "proxyjump":
			r.ProxyJump = value
		case "hostkeyalias":
			r.HostKeyAlias = value
		}
	}
	if r.HostName == "" {
		r.HostName = alias
	}
	return r, nil
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// RemoteHost is the real host a remote reaches: an ssh alias resolved through ResolveSSHRoute.
func RemoteHost(remote RemoteURL) string {
	if remote.Scheme == "ssh" {
		if r, err := ResolveSSHRoute(remote.Host); err == nil {
			return strings.ToLower(r.HostName)
		}
	}
	return strings.ToLower(remote.Host)
}

// GitHostSuggestion is a host the organisation's projects push to, and how many roots do.
type GitHostSuggestion struct {
	Host         string `json:"host"`
	Repositories int    `json:"repositories"`
}

// GitHostSuggestions reads each of org's project roots' `origin` and counts the real hosts, the
// most-used first: what + Add a git account offers before anything is typed.
func GitHostSuggestions(org string) []GitHostSuggestion {
	entries, err := LoadRegistryFor(org)
	if err != nil {
		return nil
	}
	counts := map[string]int{}
	for _, entry := range entries {
		p, err := LoadProject(entry.Path)
		if err != nil {
			continue
		}
		for _, root := range p.Roots {
			cmd := exec.Command("git", "-C", root.Path, "remote", "get-url", "origin")
			cmd.Env = gitScrubbedEnv(root.Path)
			out, err := cmd.Output()
			if err != nil {
				continue
			}
			remote, err := ParseRemoteURL(string(out))
			if err != nil || remote.Scheme == "file" {
				continue
			}
			if host := RemoteHost(remote); host != "" {
				counts[host]++
			}
		}
	}
	out := []GitHostSuggestion{}
	for h, n := range counts {
		out = append(out, GitHostSuggestion{Host: h, Repositories: n})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Repositories != out[j].Repositories {
			return out[i].Repositories > out[j].Repositories
		}
		return out[i].Host < out[j].Host
	})
	return out
}
