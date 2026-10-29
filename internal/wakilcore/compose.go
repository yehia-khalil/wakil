package wakilcore

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"go.yaml.in/yaml/v3"
)

// Compose isolation (workspaces piece 2, call 8): a repo's own compose file runs with
// COMPOSE_PROJECT_NAME=<workspace>-<repo>, and its fixed published host ports are moved into the
// checkout's block by a generated override file using compose's `!override`. A fixed
// container_name cannot run twice; the recipe says so.

// ComposeFileNames are the names compose itself looks for, in its order.
var ComposeFileNames = []string{"compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"}

// ComposeOverridePath is where the generated override goes, relative to the checkout.
const ComposeOverridePath = ".wakil/compose.ports.yml"

// FindComposeFile returns the first compose file compose would read in dir, or "".
func FindComposeFile(dir string) string {
	for _, n := range ComposeFileNames {
		if st, err := os.Stat(filepath.Join(dir, n)); err == nil && !st.IsDir() {
			return n
		}
	}
	return ""
}

// ComposeFacts is what Wakil reads from a compose file.
type ComposeFacts struct {
	File     string           `json:"file"`
	Services []ComposeService `json:"services"`
}

// ComposeService is one service, in file order.
type ComposeService struct {
	Name          string        `json:"name"`
	Image         string        `json:"image,omitempty"`
	Build         bool          `json:"build"`
	ContainerName string        `json:"containerName,omitempty"`
	Ports         []ComposePort `json:"ports"`
}

// Port kinds.
const (
	PortFixed     = "fixed"
	PortVariable  = "variable"
	PortEphemeral = "ephemeral"
)

// ComposePort is one entry of a service's ports, short or long syntax.
type ComposePort struct {
	Long      bool     `json:"long"`
	HostIP    string   `json:"hostIp,omitempty"`
	Published string   `json:"published,omitempty"`
	Target    string   `json:"target"`
	Protocol  string   `json:"protocol,omitempty"`
	Kind      string   `json:"kind"`
	Variables []string `json:"variables,omitempty"`
	// Extra keeps a long entry's other keys (mode, name, app_protocol) in order.
	Extra [][2]string `json:"-"`
}

var composeVarPattern = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}|\$([A-Za-z_][A-Za-z0-9_]*)`)

func classifyPublished(p *ComposePort) {
	switch {
	case p.Published == "":
		p.Kind = PortEphemeral
	case strings.Contains(p.Published, "$"):
		p.Kind = PortVariable
		for _, m := range composeVarPattern.FindAllStringSubmatch(p.Published, -1) {
			p.Variables = append(p.Variables, m[1]+m[2])
		}
	default:
		p.Kind = PortFixed
	}
}

// ParseCompose reads a compose file's services and their ports.
func ParseCompose(b []byte, file string) (ComposeFacts, error) {
	facts := ComposeFacts{File: file, Services: []ComposeService{}}
	var doc yaml.Node
	if err := yaml.Unmarshal(b, &doc); err != nil {
		return facts, UserError(fmt.Sprintf("%s is not valid YAML: %v", file, err))
	}
	if len(doc.Content) == 0 {
		return facts, nil
	}
	root := doc.Content[0]
	services := mappingValue(root, "services")
	if services == nil || services.Kind != yaml.MappingNode {
		return facts, nil
	}
	for i := 0; i+1 < len(services.Content); i += 2 {
		name := services.Content[i].Value
		var raw struct {
			Image         string      `yaml:"image"`
			Build         yaml.Node   `yaml:"build"`
			ContainerName string      `yaml:"container_name"`
			Ports         []yaml.Node `yaml:"ports"`
		}
		if err := services.Content[i+1].Decode(&raw); err != nil {
			return facts, UserError(fmt.Sprintf("%s: service %s cannot be read: %v", file, name, err))
		}
		svc := ComposeService{Name: name, Image: raw.Image, Build: raw.Build.Kind != 0, ContainerName: raw.ContainerName, Ports: []ComposePort{}}
		for _, pn := range raw.Ports {
			p, err := parseComposePort(&pn)
			if err != nil {
				return facts, UserError(fmt.Sprintf("%s: service %s: %v", file, name, err))
			}
			svc.Ports = append(svc.Ports, p)
		}
		facts.Services = append(facts.Services, svc)
	}
	return facts, nil
}

func mappingValue(n *yaml.Node, key string) *yaml.Node {
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			return n.Content[i+1]
		}
	}
	return nil
}

func parseComposePort(n *yaml.Node) (ComposePort, error) {
	if n.Kind == yaml.ScalarNode {
		return parseShortPort(n.Value)
	}
	if n.Kind != yaml.MappingNode {
		return ComposePort{}, fmt.Errorf("a ports entry is a string or a mapping")
	}
	p := ComposePort{Long: true}
	for i := 0; i+1 < len(n.Content); i += 2 {
		k, v := n.Content[i].Value, n.Content[i+1].Value
		switch k {
		case "target":
			p.Target = v
		case "published":
			p.Published = v
		case "host_ip":
			p.HostIP = v
		case "protocol":
			p.Protocol = v
		default:
			p.Extra = append(p.Extra, [2]string{k, v})
		}
	}
	classifyPublished(&p)
	return p, nil
}

// parseShortPort reads [HOST_IP:][HOST_PORT:]CONTAINER_PORT[/PROTOCOL]; HOST_IP may be [v6].
func parseShortPort(s string) (ComposePort, error) {
	p := ComposePort{}
	rest := s
	if i := strings.LastIndex(rest, "/"); i >= 0 {
		p.Protocol, rest = rest[i+1:], rest[:i]
	}
	if strings.HasPrefix(rest, "[") {
		end := strings.Index(rest, "]")
		if end < 0 {
			return p, fmt.Errorf("port %q has an unclosed [", s)
		}
		p.HostIP, rest = rest[1:end], strings.TrimPrefix(rest[end+1:], ":")
	}
	parts := splitComposePort(rest)
	switch len(parts) {
	case 1:
		p.Target = parts[0]
	case 2:
		p.Published, p.Target = parts[0], parts[1]
	case 3:
		if p.HostIP != "" {
			return p, fmt.Errorf("port %q has two host addresses", s)
		}
		p.HostIP, p.Published, p.Target = parts[0], parts[1], parts[2]
	default:
		return p, fmt.Errorf("port %q is not HOST_IP:HOST_PORT:CONTAINER_PORT", s)
	}
	classifyPublished(&p)
	return p, nil
}

// splitComposePort splits on ':' outside ${…}, so ${PORT:-80}:80 is two parts.
func splitComposePort(s string) []string {
	var parts []string
	depth, start := 0, 0
	for i := 0; i < len(s); i++ {
		switch {
		case s[i] == '{':
			depth++
		case s[i] == '}':
			depth--
		case s[i] == ':' && depth == 0:
			parts = append(parts, s[start:i])
			start = i + 1
		}
	}
	return append(parts, s[start:])
}

// PortRemap is one fixed host port moved into the block.
type PortRemap struct {
	Service  string `json:"service"`
	From     int    `json:"from"`
	To       int    `json:"to"`
	Protocol string `json:"protocol,omitempty"`
}

// ComposeVariable is a published port the compose file already reads from a variable.
type ComposeVariable struct {
	Service  string `json:"service"`
	Variable string `json:"variable"`
}

// ContainerName is a service's fixed container_name.
type ContainerName struct {
	Service string `json:"service"`
	Name    string `json:"name"`
}

// ComposeOverrideResult is the override for one checkout and what was found on the way.
type ComposeOverrideResult struct {
	ProjectName    string            `json:"projectName"`
	ComposeFile    string            `json:"composeFile"`
	File           string            `json:"file"`
	YAML           string            `json:"yaml"`
	Remaps         []PortRemap       `json:"remaps"`
	Variables      []ComposeVariable `json:"variables"`
	ContainerNames []ContainerName   `json:"containerNames"`
	CannotRunTwice string            `json:"cannotRunTwice,omitempty"`
}

// ComposeOverride moves every fixed published host port into the block starting at base, using
// the lowest offsets not in reserved (the offsets the recipe's ports already give to variables).
// The same host port seen twice (tcp and udp, two addresses) keeps one new port. YAML is empty when
// nothing is fixed.
func ComposeOverride(facts ComposeFacts, workspace, repo string, base int, reserved []int) (ComposeOverrideResult, error) {
	out := ComposeOverrideResult{
		ProjectName: ComposeProjectName(workspace, repo), ComposeFile: facts.File, File: ComposeOverridePath,
		Remaps: []PortRemap{}, Variables: []ComposeVariable{}, ContainerNames: []ContainerName{},
	}
	used := map[int]bool{}
	for _, r := range reserved {
		used[r] = true
	}
	assigned := map[int]int{}
	nextOffset := func(from int) (int, error) {
		if to, ok := assigned[from]; ok {
			return to, nil
		}
		for off := 0; off < PortBlockSize; off++ {
			if !used[off] {
				used[off] = true
				assigned[from] = base + off
				return base + off, nil
			}
		}
		return 0, UserError(fmt.Sprintf("%s publishes more fixed ports than the block of %d from %d has room for; give some of them a variable in the compose file and map it under ports.",
			repo, PortBlockSize, base))
	}
	var b strings.Builder
	b.WriteString("# Generated by Wakil for this workspace: fixed host ports moved into its block.\n")
	b.WriteString("# Rewritten on every run; edit the recipe, not this file.\nservices:\n")
	any := false
	for _, svc := range facts.Services {
		if svc.ContainerName != "" {
			out.ContainerNames = append(out.ContainerNames, ContainerName{svc.Name, svc.ContainerName})
		}
		hasFixed := false
		for _, p := range svc.Ports {
			if p.Kind == PortVariable {
				for _, v := range p.Variables {
					out.Variables = append(out.Variables, ComposeVariable{svc.Name, v})
				}
			}
			if p.Kind == PortFixed {
				hasFixed = true
			}
		}
		if !hasFixed {
			continue
		}
		any = true
		fmt.Fprintf(&b, "  %s:\n    ports: !override\n", yamlKey(svc.Name))
		for _, p := range svc.Ports {
			if p.Kind == PortFixed {
				lo, hi, err := portRange(p.Published)
				if err != nil {
					return out, UserError(fmt.Sprintf("%s: service %s publishes %q, which is not a port number or range.", facts.File, svc.Name, p.Published))
				}
				var first, last int
				for port := lo; port <= hi; port++ {
					to, err := nextOffset(port)
					if err != nil {
						return out, err
					}
					if port == lo {
						first = to
					}
					if to != first+(port-lo) {
						return out, UserError(fmt.Sprintf("%s: service %s publishes the range %s, which cannot be moved into one run of the block; give it a variable in the compose file.", facts.File, svc.Name, p.Published))
					}
					last = to
					out.Remaps = append(out.Remaps, PortRemap{svc.Name, port, to, p.Protocol})
				}
				if lo == hi {
					p.Published = strconv.Itoa(first)
				} else {
					p.Published = fmt.Sprintf("%d-%d", first, last)
				}
			}
			b.WriteString("      - " + renderComposePort(p) + "\n")
		}
	}
	out.Remaps = dedupeRemaps(out.Remaps)
	if any {
		out.YAML = b.String()
	}
	if len(out.ContainerNames) > 0 {
		var names []string
		for _, c := range out.ContainerNames {
			names = append(names, fmt.Sprintf("%s in %s", c.Name, c.Service))
		}
		out.CannotRunTwice = fmt.Sprintf("%s's compose file names its containers (container_name: %s), so it cannot run in two workspaces at once. Run it from one place with Bring to Main, or remove container_name from %s.",
			repo, strings.Join(names, ", "), facts.File)
	}
	return out, nil
}

func dedupeRemaps(in []PortRemap) []PortRemap {
	seen := map[string]bool{}
	out := []PortRemap{}
	for _, r := range in {
		k := fmt.Sprintf("%s|%d|%s", r.Service, r.From, r.Protocol)
		if !seen[k] {
			seen[k] = true
			out = append(out, r)
		}
	}
	return out
}

func portRange(s string) (int, int, error) {
	lo, hi, isRange := strings.Cut(s, "-")
	a, err := strconv.Atoi(lo)
	if err != nil {
		return 0, 0, err
	}
	if !isRange {
		return a, a, nil
	}
	z, err := strconv.Atoi(hi)
	if err != nil || z < a {
		return 0, 0, fmt.Errorf("bad range")
	}
	return a, z, nil
}

func renderComposePort(p ComposePort) string {
	if p.Long {
		var parts []string
		parts = append(parts, "target: "+p.Target)
		if p.Published != "" {
			parts = append(parts, "published: "+strconv.Quote(p.Published))
		}
		if p.HostIP != "" {
			parts = append(parts, "host_ip: "+strconv.Quote(p.HostIP))
		}
		if p.Protocol != "" {
			parts = append(parts, "protocol: "+p.Protocol)
		}
		for _, kv := range p.Extra {
			parts = append(parts, kv[0]+": "+strconv.Quote(kv[1]))
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	s := p.Target
	if p.Published != "" {
		s = p.Published + ":" + s
	}
	if p.HostIP != "" {
		ip := p.HostIP
		if strings.Contains(ip, ":") {
			ip = "[" + ip + "]"
		}
		s = ip + ":" + s
	}
	if p.Protocol != "" {
		s += "/" + p.Protocol
	}
	return strconv.Quote(s)
}

var plainYAMLKey = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

func yamlKey(s string) string {
	if plainYAMLKey.MatchString(s) {
		return s
	}
	return strconv.Quote(s)
}

// ReservedOffsets is the block offsets a recipe's ports already use ($WAKIL_PORT is 0,
// $WAKIL_PORT_n is n), ascending.
func ReservedOffsets(ports map[string]string) []int {
	seen := map[int]bool{}
	re := regexp.MustCompile(`\$\{?WAKIL_PORT(?:_([1-9]))?\b`)
	for _, expr := range ports {
		for _, m := range re.FindAllStringSubmatch(expr, -1) {
			n := 0
			if m[1] != "" {
				n, _ = strconv.Atoi(m[1])
			}
			seen[n] = true
		}
	}
	out := []int{}
	for n := range seen {
		out = append(out, n)
	}
	sort.Ints(out)
	return out
}
