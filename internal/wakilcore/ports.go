package wakilcore

import (
	"fmt"
	"net"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Port blocks (workspaces piece 2, call 7): each checkout gets ten ports from PortBlockStart
// upward — WAKIL_PORT and WAKIL_PORT_1 … WAKIL_PORT_9 — stable across runs, kept by the caller in
// workspaces.json. Main gets none.
const (
	PortBlockStart = 41200
	PortBlockSize  = 10
	portBlockLimit = 65530
)

// PortProbe says whether a port is in use on this machine.
type PortProbe func(port int) bool

// ListeningProbe is the real probe: a port is taken when something answers a connect on the
// loopback, or when it cannot be bound on every interface.
func ListeningProbe(port int) bool {
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	if c, err := net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
		c.Close()
		return true
	}
	l, err := net.Listen("tcp", ":"+strconv.Itoa(port))
	if err != nil {
		return true
	}
	l.Close()
	return false
}

// PortAllocation is what AllocatePortBlocks answers.
type PortAllocation struct {
	// Blocks maps each checkout key to its block's first port.
	Blocks map[string]int `json:"blocks"`
	// Taken lists ports found listening and stepped over, ascending.
	Taken []int `json:"taken"`
}

// AllocatePortBlocks keeps every block in existing and hands each key in want that has none the
// lowest free block: no port of it listening and none held by another key. Keys are served in the
// order given.
func AllocatePortBlocks(existing map[string]int, want []string, probe PortProbe) (PortAllocation, error) {
	out := PortAllocation{Blocks: map[string]int{}, Taken: []int{}}
	held := map[int]bool{}
	for k, base := range existing {
		if base < PortBlockStart || (base-PortBlockStart)%PortBlockSize != 0 {
			return out, UserError(fmt.Sprintf("checkout %q holds port %d, which does not start a block of %d from %d.",
				k, base, PortBlockSize, PortBlockStart))
		}
		if held[base] {
			return out, UserError(fmt.Sprintf("two checkouts hold the port block starting at %d.", base))
		}
		held[base] = true
		out.Blocks[k] = base
	}
	taken := map[int]bool{}
	next := PortBlockStart
	for _, k := range want {
		if _, ok := out.Blocks[k]; ok {
			continue
		}
		for {
			if next+PortBlockSize-1 > portBlockLimit {
				return out, UserError(fmt.Sprintf("No free port block for %s: every block of ten from %d up is held by a checkout or has a port in use (%s).",
					k, PortBlockStart, describeTaken(taken)))
			}
			if held[next] {
				next += PortBlockSize
				continue
			}
			free := true
			for p := next; p < next+PortBlockSize; p++ {
				if probe(p) {
					taken[p] = true
					free = false
				}
			}
			if free {
				break
			}
			next += PortBlockSize
		}
		out.Blocks[k] = next
		held[next] = true
		next += PortBlockSize
	}
	for p := range taken {
		out.Taken = append(out.Taken, p)
	}
	sort.Ints(out.Taken)
	return out, nil
}

func describeTaken(taken map[int]bool) string {
	if len(taken) == 0 {
		return "none in use"
	}
	ports := make([]int, 0, len(taken))
	for p := range taken {
		ports = append(ports, p)
	}
	sort.Ints(ports)
	if len(ports) > 20 {
		return fmt.Sprintf("%d ports in use, %d to %d", len(ports), ports[0], ports[len(ports)-1])
	}
	parts := make([]string, len(ports))
	for i, p := range ports {
		parts[i] = strconv.Itoa(p)
	}
	return "in use: " + strings.Join(parts, ", ")
}

// CheckoutPorts is one repo of a workspace as the env sees it: where it is and its block's first
// port (0 when the workspace has no checkout of it, so it has no ports).
type CheckoutPorts struct {
	Repo string `json:"repo"`
	Path string `json:"path"`
	Port int    `json:"port,omitempty"`
}

// RunContext is the workspace a repo runs in.
type RunContext struct {
	// Workspace is the workspace's slug.
	Workspace string `json:"workspace"`
	// Repo is the repo being run.
	Repo string `json:"repo"`
	// Checkouts lists the workspace's repos, the one being run included.
	Checkouts []CheckoutPorts `json:"checkouts"`
}

var envNameUnsafe = regexp.MustCompile(`[^A-Z0-9]+`)

// RepoEnvName is a repo's folder name as a variable suffix: upper-cased, every run of other
// characters one underscore, a leading digit prefixed with one.
func RepoEnvName(repo string) string {
	s := strings.Trim(envNameUnsafe.ReplaceAllString(strings.ToUpper(repo), "_"), "_")
	if s == "" {
		return "_"
	}
	if s[0] >= '0' && s[0] <= '9' {
		s = "_" + s
	}
	return s
}

// ComposeProjectName is COMPOSE_PROJECT_NAME for a repo in a workspace: <workspace>-<repo>, in the
// characters compose accepts (lower-case letters, digits, '-' and '_', starting with a letter or
// digit).
func ComposeProjectName(workspace, repo string) string {
	clean := func(s string) string {
		var b strings.Builder
		for _, r := range strings.ToLower(s) {
			switch {
			case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_', r == '-':
				b.WriteRune(r)
			default:
				b.WriteRune('-')
			}
		}
		return b.String()
	}
	return strings.TrimLeft(clean(workspace)+"-"+clean(repo), "-_")
}

// WakilEnv is the variables Wakil exports to every command of a repo in a workspace:
// WAKIL_WORKSPACE, WAKIL_REPO, WAKIL_DIR (its checkout), WAKIL_PORT and WAKIL_PORT_1…9 (its block),
// WAKIL_PORT_<REPO> (each repo's first port), WAKIL_DIR_<REPO> (each repo's folder) and
// COMPOSE_PROJECT_NAME.
func WakilEnv(ctx RunContext) (map[string]string, error) {
	env := map[string]string{
		"WAKIL_WORKSPACE":      ctx.Workspace,
		"WAKIL_REPO":           ctx.Repo,
		"COMPOSE_PROJECT_NAME": ComposeProjectName(ctx.Workspace, ctx.Repo),
	}
	byName := map[string]string{}
	var own *CheckoutPorts
	for i, c := range ctx.Checkouts {
		name := RepoEnvName(c.Repo)
		if other, ok := byName[name]; ok && other != c.Repo {
			return nil, UserError(fmt.Sprintf("repos %q and %q both become WAKIL_PORT_%s; rename one folder so each repo has its own variable.",
				other, c.Repo, name))
		}
		byName[name] = c.Repo
		env["WAKIL_DIR_"+name] = c.Path
		if c.Port > 0 {
			env["WAKIL_PORT_"+name] = strconv.Itoa(c.Port)
		}
		if c.Repo == ctx.Repo {
			own = &ctx.Checkouts[i]
		}
	}
	if own == nil {
		return nil, UserError(fmt.Sprintf("workspace %q has no checkout of %s, so it cannot run there.", ctx.Workspace, ctx.Repo))
	}
	env["WAKIL_DIR"] = own.Path
	if own.Port == 0 {
		return nil, UserError(fmt.Sprintf("%s has no port block in workspace %q yet; allocate one before running it.", ctx.Repo, ctx.Workspace))
	}
	env["WAKIL_PORT"] = strconv.Itoa(own.Port)
	for i := 1; i < PortBlockSize; i++ {
		env["WAKIL_PORT_"+strconv.Itoa(i)] = strconv.Itoa(own.Port + i)
	}
	return env, nil
}

var expandPattern = regexp.MustCompile(`\$\$|\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)`)

// ExpandWakil expands $NAME and ${NAME} from vars when NAME starts with WAKIL_ or is in vars;
// $$ is a literal $. Any other $NAME is left for the shell. A $WAKIL_ name vars lacks is an error
// naming it whole.
func ExpandWakil(expr string, vars map[string]string) (string, error) {
	var missing []string
	out := expandPattern.ReplaceAllStringFunc(expr, func(m string) string {
		if m == "$$" {
			return "$"
		}
		sub := expandPattern.FindStringSubmatch(m)
		name := sub[1] + sub[2]
		if v, ok := vars[name]; ok {
			return v
		}
		if strings.HasPrefix(name, "WAKIL_") {
			missing = append(missing, name)
		}
		return m
	})
	if len(missing) > 0 {
		return "", UserError(fmt.Sprintf("%q uses $%s, which this workspace does not have: %s.",
			expr, missing[0], explainMissingWakil(missing[0], vars)))
	}
	return out, nil
}

func explainMissingWakil(name string, vars map[string]string) string {
	if strings.HasPrefix(name, "WAKIL_PORT_") {
		return "no repo of the workspace with that name has a checkout with ports, and a repo's own block runs only to WAKIL_PORT_9"
	}
	if strings.HasPrefix(name, "WAKIL_DIR_") {
		return "no repo of the workspace has that name"
	}
	var known []string
	for k := range vars {
		if strings.HasPrefix(k, "WAKIL_") && !strings.HasPrefix(k, "WAKIL_PORT_") && !strings.HasPrefix(k, "WAKIL_DIR_") {
			known = append(known, "$"+k)
		}
	}
	sort.Strings(known)
	return "the names Wakil exports are " + strings.Join(known, ", ") + ", $WAKIL_PORT_1…9, $WAKIL_PORT_<REPO> and $WAKIL_DIR_<REPO>"
}
