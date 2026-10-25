package wakilcore

import (
	"encoding/json"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// MCPConnection is one of an organisation's own MCP servers, behind Wakil's gate. Kind is a catalog
// id or "custom"; Transport is stdio (Command and Args) or http (URL); SignIn is token, fields,
// browser or none. Values holds the non-secret field values (a site, a region). The secrets are
// one Keychain item, conn:<name>, a JSON object of field → value — never here. Allow is the
// operator's per-tool switch; Hints is the server's own word on each tool (readOnly, writes,
// destructive or "").
type MCPConnection struct {
	Name      string            `json:"name"`
	Kind      string            `json:"kind"`
	Transport string            `json:"transport"`
	Command   string            `json:"command,omitempty"`
	Args      []string          `json:"args,omitempty"`
	URL       string            `json:"url,omitempty"`
	SignIn    string            `json:"signIn"`
	Values    map[string]string `json:"values,omitempty"`
	Allow     map[string]bool   `json:"allow,omitempty"`
	Hints     map[string]string `json:"hints,omitempty"`
}

func connectionRef(name string) string { return "conn:" + name }

var connectionNamePattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// validateConnectionName refuses a name that is not a lowercase slug, or that is Wakil's own:
// the "wakil" prefix is for its built-in servers (wakil-pm, wakil-ctx, ...).
func validateConnectionName(name string) error {
	if name == "wakil" || strings.HasPrefix(name, "wakil-") {
		return UserError("the name " + name + " is reserved for Wakil's own servers")
	}
	if !connectionNamePattern.MatchString(name) {
		return UserError("a connection's name is lowercase letters, digits and hyphens, starting with a letter (at most 32 characters)")
	}
	return nil
}

func validateConnection(c MCPConnection) error {
	if err := validateConnectionName(c.Name); err != nil {
		return err
	}
	known := c.Kind == "custom"
	for _, k := range ConnectionCatalog {
		if k.ID == c.Kind {
			known = true
		}
	}
	if !known {
		return UserError("unknown connection kind " + c.Kind)
	}
	switch c.Transport {
	case "stdio":
		if c.Command == "" {
			return UserError("a stdio connection needs a command")
		}
	case "http":
		if c.URL == "" {
			return UserError("an http connection needs an address")
		}
	default:
		return UserError("a connection's transport is stdio or http")
	}
	switch c.SignIn {
	case "token", "fields", "browser", "none":
	default:
		return UserError("a connection's sign-in is token, fields, browser or none")
	}
	return nil
}

func indexOfConnection(o *Org, name string) int {
	for i, have := range o.Connections {
		if have.Name == name {
			return i
		}
	}
	return -1
}

// AddConnection records c for org. An empty Name becomes the kind's id, then <kind>-2, <kind>-3...
func AddConnection(org string, c MCPConnection) (MCPConnection, error) {
	if _, err := OrgDirFor(org); err != nil {
		return MCPConnection{}, err
	}
	o, err := LoadOrgFor(org)
	if err != nil {
		return MCPConnection{}, err
	}
	c.Name = strings.TrimSpace(c.Name)
	if c.Name == "" {
		base := c.Kind
		c.Name = base
		for n := 2; indexOfConnection(o, c.Name) >= 0; n++ {
			c.Name = base + "-" + strconv.Itoa(n)
		}
	}
	if err := validateConnection(c); err != nil {
		return MCPConnection{}, err
	}
	if indexOfConnection(o, c.Name) >= 0 {
		return MCPConnection{}, UserError("org " + org + " already has a connection named " + c.Name)
	}
	o.Connections = append(o.Connections, c)
	if err := SaveOrg(org, *o); err != nil {
		return MCPConnection{}, err
	}
	return c, nil
}

// UpdateConnection applies edit to org's connection called name and saves it. If edit renames
// it, the Keychain item moves to the new ref.
func UpdateConnection(org, name string, edit func(*MCPConnection)) error {
	o, err := LoadOrgFor(org)
	if err != nil {
		return err
	}
	i := indexOfConnection(o, name)
	if i < 0 {
		return UserError("no connection " + name + " in " + org)
	}
	c := o.Connections[i]
	edit(&c)
	if err := validateConnection(c); err != nil {
		return err
	}
	renamed := c.Name != name
	if renamed {
		if indexOfConnection(o, c.Name) >= 0 {
			return UserError("org " + org + " already has a connection named " + c.Name)
		}
		secrets, err := ConnectionSecrets(org, name)
		if err != nil {
			return err
		}
		if len(secrets) > 0 {
			if err := storeConnectionSecrets(org, c.Name, secrets); err != nil {
				return err
			}
		}
	}
	o.Connections[i] = c
	if err := SaveOrg(org, *o); err != nil {
		return err
	}
	if renamed {
		return SecretDelete(org, connectionRef(name))
	}
	return nil
}

// RemoveConnection forgets org's connection called name and deletes its Keychain item.
func RemoveConnection(org, name string) error {
	o, err := LoadOrgFor(org)
	if err != nil {
		return err
	}
	i := indexOfConnection(o, name)
	if i < 0 {
		return UserError("no connection " + name + " in " + org)
	}
	if err := SecretDelete(org, connectionRef(name)); err != nil {
		return err
	}
	o.Connections = append(o.Connections[:i:i], o.Connections[i+1:]...)
	return SaveOrg(org, *o)
}

// ConnectionFor is org's connection called name, if it has one. An organization that cannot be
// read counts as having none; ConnectionForErr tells the two apart.
func ConnectionFor(org, name string) (MCPConnection, bool) {
	c, ok, err := ConnectionForErr(org, name)
	return c, ok && err == nil
}

// ConnectionForErr is org's connection called name: ok is false when org has no such connection,
// and err is set when org's configuration could not be read at all.
func ConnectionForErr(org, name string) (MCPConnection, bool, error) {
	o, err := LoadOrgFor(org)
	if err != nil {
		return MCPConnection{}, false, err
	}
	if i := indexOfConnection(o, name); i >= 0 {
		return o.Connections[i], true, nil
	}
	return MCPConnection{}, false, nil
}

// ConnectionSecrets is the connection's secret fields; none stored is an empty map, not an error.
func ConnectionSecrets(org, name string) (map[string]string, error) {
	raw, err := SecretGetFor(org, connectionRef(name))
	if err != nil {
		if msg, ok := IsUserError(err); ok && strings.HasPrefix(msg, "no credential stored") {
			return map[string]string{}, nil
		}
		return nil, err
	}
	out := map[string]string{}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, UserError("the stored secrets for connection " + name + " are not a JSON object")
	}
	return out, nil
}

// SetConnectionSecrets merges values into the connection's secret item. A custom env: or header:
// key Wakil reserves (ReservedConnectionSecretKey) is refused and nothing is written.
func SetConnectionSecrets(org, name string, values map[string]string) error {
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if ReservedConnectionSecretKey(k) {
			return UserError(k + " is reserved: Wakil sets it itself, so a connection may not keep its own value for it")
		}
	}
	return storeConnectionSecrets(org, name, values)
}

// storeConnectionSecrets merges values into the connection's secret item as they are; a rename
// moves an item this way, whatever it already holds.
func storeConnectionSecrets(org, name string, values map[string]string) error {
	have, err := ConnectionSecrets(org, name)
	if err != nil {
		return err
	}
	for k, v := range values {
		have[k] = v
	}
	raw, err := json.Marshal(have)
	if err != nil {
		return err
	}
	return SecretSetFor(org, connectionRef(name), string(raw))
}

// ReservedConnectionSecretKey is whether key is a custom env: or header: key Wakil keeps for itself:
// an environment variable that steers Wakil or the server's loader (WAKIL_*, DYLD_*, NODE_OPTIONS,
// PATH), or a header the transport or the protocol owns (Authorization, Host, Content-Type, Mcp-*).
// Names compare case-insensitively. upstream.go skips one already stored.
func ReservedConnectionSecretKey(key string) bool {
	if name, ok := strings.CutPrefix(key, "env:"); ok {
		n := strings.ToUpper(name)
		return strings.HasPrefix(n, "WAKIL_") || strings.HasPrefix(n, "DYLD_") || n == "NODE_OPTIONS" || n == "PATH"
	}
	if name, ok := strings.CutPrefix(key, "header:"); ok {
		n := strings.ToLower(name)
		return n == "authorization" || n == "host" || n == "content-type" || strings.HasPrefix(n, "mcp-")
	}
	return false
}

var connectionURLField = regexp.MustCompile(`\{([A-Za-z0-9_]+)\}`)

// ResolvedConnectionURL is the address Wakil dials for c: each {field} in URL replaced by that
// field's value (Datadog's {site}), and Amplitude's EU address when its region is "eu". A field
// with no value stays as written, so the dial error shows what is missing. An address the
// operator typed over the ready-made one is kept.
func ResolvedConnectionURL(c MCPConnection) string {
	u := c.URL
	if c.Kind == "amplitude" && u == amplitudeUSURL && c.Values["region"] == "eu" {
		u = amplitudeEUURL
	}
	return connectionURLField.ReplaceAllStringFunc(u, func(m string) string {
		if v := c.Values[m[1:len(m)-1]]; v != "" {
			return v
		}
		return m
	})
}

// ToolAllowed is whether the gate lets tool through, and whether the operator cannot change that.
// A destructive tool is locked and never allowed; otherwise the operator's stored switch wins, and
// with none only a readOnly tool is allowed.
func ToolAllowed(c MCPConnection, tool string) (allowed, locked bool) {
	hint := c.Hints[tool]
	if hint == "destructive" {
		return false, true
	}
	if v, ok := c.Allow[tool]; ok {
		return v, false
	}
	return hint == "readOnly", false
}

// SetConnectionAllow stores the operator's switch for tool; a locked tool has none.
func SetConnectionAllow(org, name, tool string, allow bool) error {
	c, ok := ConnectionFor(org, name)
	if !ok {
		return UserError("no connection " + name + " in " + org)
	}
	if _, locked := ToolAllowed(c, tool); locked {
		return UserError(tool + " is destructive and stays off")
	}
	return UpdateConnection(org, name, func(c *MCPConnection) {
		if c.Allow == nil {
			c.Allow = map[string]bool{}
		}
		c.Allow[tool] = allow
	})
}
