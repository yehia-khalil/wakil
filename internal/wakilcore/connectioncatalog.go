package wakilcore

// ConnectionField is one value a connection needs. Env and Header say where it goes upstream:
// an environment variable of a stdio server, or an HTTP header of a remote one. A field with
// neither is only recorded (Datadog's site, Amplitude's region) and shapes the address or the sign-in.
type ConnectionField struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Secret bool   `json:"secret"`
	Env    string `json:"env,omitempty"`
	Header string `json:"header,omitempty"`
}

// ConnectionKind is a ready-made connection the operator picks from a list instead of typing an address.
type ConnectionKind struct {
	ID        string            `json:"id"`
	Title     string            `json:"title"`
	Transport string            `json:"transport"`
	Command   string            `json:"command,omitempty"`
	URL       string            `json:"url,omitempty"`
	SignIn    string            `json:"signIn"`
	Args      []string          `json:"args,omitempty"`
	Fields    []ConnectionField `json:"fields"`
}

// Amplitude's two addresses (see its entry below): ResolvedConnectionURL picks the EU one.
const (
	amplitudeUSURL = "https://mcp.amplitude.com/mcp"
	amplitudeEUURL = "https://mcp.eu.amplitude.com/mcp"
)

// ConnectionCatalog is the ready-made list. "custom" is not an entry: it is Kind "custom" on a
// Connection. Jira is not here: it is wakil-pm.
var ConnectionCatalog = []ConnectionKind{
	{
		// https://github.com/github/github-mcp-server (remote server, personal access token).
		ID: "github", Title: "GitHub", Transport: "http", URL: "https://api.githubcopilot.com/mcp/", SignIn: "token",
		Fields: []ConnectionField{{ID: "token", Label: "Access token", Secret: true, Header: "Authorization: Bearer"}},
	},
	{
		ID: "atlassian", Title: "Atlassian (Confluence)", Transport: "http", URL: "https://mcp.atlassian.com/v1/mcp", SignIn: "browser",
	},
	{
		// Doc: https://docs.datadoghq.com/bits_ai/mcp_server/setup/ — the address is per site;
		// {site} is the "site" field's value (the page lists one host per site and publishes
		// the US1 one, https://mcp.datadoghq.com/api/unstable/mcp-server/mcp). Header sign-in
		// is the documented fallback to OAuth: the page's config sends the headers DD_API_KEY
		// and DD_APPLICATION_KEY, each carrying the bare key (checked 2026-10-25).
		ID: "datadog", Title: "Datadog", Transport: "http", URL: "https://mcp.{site}/api/unstable/mcp-server/mcp", SignIn: "fields",
		Fields: []ConnectionField{
			{ID: "site", Label: "Datadog site (for example datadoghq.com)"},
			{ID: "apiKey", Label: "API key", Secret: true, Header: "DD_API_KEY"},
			{ID: "appKey", Label: "Application key", Secret: true, Header: "DD_APPLICATION_KEY"},
		},
	},
	{
		// Doc: https://amplitude.com/docs/amplitude-ai/amplitude-mcp/other-clients — OAuth 2.0 in the
		// browser, no API-key option. US is https://mcp.amplitude.com/mcp; the EU address,
		// https://mcp.eu.amplitude.com/mcp, is chosen by the "region" field ("us" or "eu").
		ID: "amplitude", Title: "Amplitude", Transport: "http", URL: amplitudeUSURL, SignIn: "browser",
		Fields: []ConnectionField{{ID: "region", Label: "Data region (us or eu)"}},
	},
	{
		// Doc: https://docs.slack.dev/ai/mcp-server — Streamable HTTP, confidential OAuth with the
		// operator's own Slack app (client_id and client_secret); dynamic client registration is not supported.
		ID: "slack", Title: "Slack", Transport: "http", URL: "https://mcp.slack.com/mcp", SignIn: "browser",
		Fields: []ConnectionField{
			{ID: "clientId", Label: "Slack app client ID"},
			{ID: "clientSecret", Label: "Slack app client secret", Secret: true},
		},
	},
}
