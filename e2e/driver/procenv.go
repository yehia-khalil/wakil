package driver

import "strings"

// EnvFromPS reads the named environment variables out of `ps -Ewww -p <pid>`
// output.
//
// **What it is for.** Two guards depend on it, and both fail silently without
// one:
//
//   - **Teardown identifies its own instance by HOME**, never by process name.
//     Killing "the Wakil process" would kill the operator's.
//   - **The runner asserts its fixture PATH reached the app's spawned Go
//     child.** The Keychain isolation is a `security` shim on that PATH
//     (docs/wakil/agent-e2e-probe.md §2); a launcher that dropped PATH would
//     write into the operator's login keychain, and nothing would say so.
//
// A key that is not set is **absent** from the result rather than empty,
// because the two are different facts: TMPDIR, for instance, reaches the app
// but is not propagated to its Go children.
//
// The last occurrence wins. `ps -E` prints the environment after the command,
// so a bundle launched through `env HOME=… ` carries the assignment twice, and
// it is the environment copy that says what the process actually got.
//
// **Known limit:** a value containing a space cannot be recovered, because ps
// gives no quoting to recover it from. No variable this harness reads has one,
// and a fixture directory with a space in its name is a thing the runner
// refuses rather than mis-parses.
func EnvFromPS(output string, keys ...string) map[string]string {
	wanted := make(map[string]bool, len(keys))
	for _, key := range keys {
		wanted[key] = true
	}
	found := map[string]string{}
	for _, token := range strings.Fields(output) {
		name, value, ok := strings.Cut(token, "=")
		if !ok || !wanted[name] {
			continue
		}
		found[name] = value
	}
	return found
}
