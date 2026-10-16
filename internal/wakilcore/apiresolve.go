package wakilcore

// PickAPI selects one ApiConfig from env by name.
//
// **It shares PickDatabase's resolver rather than mirroring it.** An
// environment's API entries and its databases are the same kind of thing —
// named, credentialed resources of one environment — and the two used to be
// line-for-line copies whose comments each argued the other had to behave
// identically. `pickNamed` is that agreement made structural; only the
// wording is this function's. The nil/empty default is kept for headless
// use, where there is no pane to choose an entry from.
//
// **A resolved entry's authHeader is validated here**, at the one gate
// every request passes through, so a header that cannot carry a credential
// is refused before the Keychain is read rather than producing a silently
// unauthenticated request. See ValidateAuthHeader for which names and why.
//
// **An unknown name fails loudly and never falls back.** There is no "use
// the only one" or "use the default" path out of a typo, for the same
// reason: a request that silently reached a different backend would carry a
// credential to a host the operator never reviewed.
func PickAPI(env Environment, name string) (ApiConfig, error) {
	entry, err := pickNamed(env.API, name, func(a ApiConfig) string { return a.Name },
		pickMessages{
			noneConfigured: "no api configured for this environment",
			nameOneOfThem:  "multiple api entries in this environment — name one of them",
			notFound: func(n string) string {
				return "no api entry named " + n + " in this environment"
			},
			ambiguous: func(n string) string {
				return "ambiguous configuration: multiple api entries named " + n + " in this environment"
			},
		})
	if err != nil {
		return ApiConfig{}, err
	}
	if err := ValidateAuthHeader(entry.AuthHeader); err != nil {
		return ApiConfig{}, err
	}
	return entry, nil
}
