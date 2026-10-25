package wakilcore

import "strings"

func jiraTokenRef(org string) string { return "jira:" + org }

// SetJiraToken keeps the organisation's Jira sign-in in the Keychain as one line, email:token,
// which is what wakil-pm reads. The email has no ":" because the first one splits the two.
func SetJiraToken(org, email, token string) error {
	email, token = strings.TrimSpace(email), strings.TrimSpace(token)
	if email == "" || token == "" {
		return UserError("the Jira email and the token are both needed")
	}
	if strings.Contains(email, ":") {
		return UserError("a Jira email has no colon in it")
	}
	return SecretSetFor(org, jiraTokenRef(org), email+":"+token)
}
