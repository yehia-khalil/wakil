package wakilcore

import (
	"strconv"
	"strings"
	"unicode"
)

// DatabaseConnection is a database's non-secret connection parts, kept in
// project.json. Only passwords live in the Keychain; Go builds the
// driver's connection string from these and the password at connect time.
//
// WriteUser is the second login the write credential uses against the
// same server (same host, port and database).
type DatabaseConnection struct {
	Host      string `json:"host,omitempty"`
	Port      string `json:"port,omitempty"`
	Database  string `json:"database,omitempty"`
	User      string `json:"user,omitempty"`
	Path      string `json:"path,omitempty"`
	WriteUser string `json:"writeUser,omitempty"`
}

// databaseDrivers is the order the settings form offers drivers in.
var databaseDrivers = []string{"mysql", "mongo", "sqlite"}

// defaultDatabasePort is the port each server driver listens on unless
// told otherwise; "" for a driver that is not a server.
func defaultDatabasePort(driver string) string {
	switch driver {
	case "mysql":
		return "3306"
	case "mongo":
		return "27017"
	}
	return ""
}

// isServerDriver reports whether driver connects to a server (host, port,
// user and password) rather than a file.
func isServerDriver(driver string) bool { return defaultDatabasePort(driver) != "" }

// BuildConnectionString builds the connection string driver reads.
//
// user is passed explicitly so the write login reuses the same parts with
// its own user. A refusal never quotes the password: it is drawn on
// screen. Each shape has characters it treats as structure and no way to
// escape some of them — MySQL splits a user from its password on the
// FIRST ':' — so a part that would be read back as a different part is
// refused in words, and nothing is stored.
func BuildConnectionString(driver string, c DatabaseConnection, user, password string) (string, error) {
	switch driver {
	case "sqlite":
		if c.Path == "" {
			return "", UserError("a SQLite database needs the path to its file")
		}
		return c.Path, nil
	case "mysql", "mongo":
		return buildServerConnectionString(driver, c, user, password)
	}
	return "", UserError(strconv.Quote(driver) + " is not a driver Wakil has — choose one of " +
		strings.Join(databaseDrivers, ", "))
}

func buildServerConnectionString(driver string, c DatabaseConnection, user, password string) (string, error) {
	if c.Host == "" {
		return "", UserError("a host is needed")
	}
	if user == "" {
		return "", UserError("a user is needed")
	}
	if c.Database == "" {
		return "", UserError("a database name is needed")
	}
	if strings.IndexFunc(c.Host, func(r rune) bool {
		return strings.ContainsRune("/?#@()", r) || unicode.IsSpace(r)
	}) >= 0 {
		return "", UserError("the host " + strconv.Quote(c.Host) + " contains a character " +
			"that would be read as part of the address — give the name or IP alone")
	}
	if strings.IndexFunc(c.Database, func(r rune) bool {
		return strings.ContainsRune("/?#", r) || unicode.IsSpace(r)
	}) >= 0 {
		return "", UserError("the database name " + strconv.Quote(c.Database) +
			" cannot contain / ? # or spaces")
	}

	port := c.Port
	if port == "" {
		port = defaultDatabasePort(driver)
	}
	if !validPort(port) {
		return "", UserError("the port must be a number from 1 to 65535")
	}

	if driver == "mysql" {
		// ParseDSN takes the last '@' before the address and the first ':'
		// of what precedes it — so a password may carry anything and a user
		// may not carry a colon. The format has no escape for it.
		if strings.Contains(user, ":") {
			return "", UserError("a MySQL user cannot contain \":\" — the connection string " +
				"has no way to escape it")
		}
		return user + ":" + password + "@tcp(" + c.Host + ":" + port + ")/" + c.Database, nil
	}
	return "mongodb://" + percentEncodedUserinfo(user) + ":" + percentEncodedUserinfo(password) +
		"@" + c.Host + ":" + port + "/" + c.Database, nil
}

func validPort(port string) bool {
	if port == "" {
		return false
	}
	for i := 0; i < len(port); i++ {
		if port[i] < '0' || port[i] > '9' {
			return false
		}
	}
	n, err := strconv.Atoi(port)
	return err == nil && n >= 1 && n <= 65535
}

// percentEncodedUserinfo keeps RFC 3986's unreserved characters and
// encodes every other byte, which is stricter than a URI requires and
// exactly what a mongo URI's parser decodes.
func percentEncodedUserinfo(text string) string {
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		ch := text[i]
		switch {
		case ch >= 'A' && ch <= 'Z', ch >= 'a' && ch <= 'z', ch >= '0' && ch <= '9',
			ch == '-', ch == '.', ch == '_', ch == '~':
			b.WriteByte(ch)
		default:
			b.WriteByte('%')
			b.WriteByte(hex[ch>>4])
			b.WriteByte(hex[ch&15])
		}
	}
	return b.String()
}
