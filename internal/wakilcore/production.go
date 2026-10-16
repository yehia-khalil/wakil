package wakilcore

import "strings"

// productionName is the one environment name that means production on its
// own, matched trimmed and case-folded.
//
// **Only the exact word, and widening the set stays refused** — for the
// second time (#182). With most actions declaring no price, a `.mutate`
// against an unrecognised environment already returns `.gate`, so `prod` is
// *confirmed* rather than unguarded; adding it here would convert a `prod`
// database mutation from `.gate` to `.block` and cost the operator the write
// entirely. What Decision 26 adds is not a wider name match — it is a way for
// the configuration to SAY so, which is strictly better than a longer list of
// words somebody guessed.
const productionName = "production"

// suspiciousNames are spellings a reader would take for production. They do
// not match, and that is the point: each is surfaced once with the
// environment listing so a reader of the configuration is not left trusting
// the name.
var suspiciousNames = []string{"prod", "prd", "live", "preprod"}

func foldEnvironmentName(name string) string {
	return strings.ToLower(strings.TrimSpace(name))
}

// EnvironmentIsProduction reports whether `env`, named `name`, is production.
//
// **The flag decides; the name is only its default.** Production when the
// environment declares `true`, or declares nothing and is named `production`.
// This is the one place that answer is computed on the Go side, and Swift's
// `isProductionEnvironment` is its counterpart across the wire — the two are
// kept in step the way `VoidPalette` and `writeGate` were made to agree on
// 2026-09-14, by there being one rule per side and no third copy.
//
// Invariant 8 is unchanged by this. What changed is how Wakil LEARNS which
// environment is production, not what it does about it.
func EnvironmentIsProduction(name string, env Environment) bool {
	if env.Production != nil {
		return *env.Production
	}
	return foldEnvironmentName(name) == productionName
}

// EnvironmentNamingNotice returns a sentence about a configuration a reader
// would misread, or "" when there is nothing surprising to say.
//
// **Surfaced once, with the environment listing, and never per call.** A
// warning attached to every action that touches the environment is a warning
// nobody reads; one attached to the listing is met exactly when somebody is
// looking at the environments.
//
// **It does not name the environment**, because it is carried ON that
// environment (`EnvironmentInfo.Notice`) and is drawn beside its own row. A
// sentence that opened with the name was written for a heap of notices that
// had lost track of which one each belonged to; repeating it now would say
// the row's own title back to it, in a place where width is scarce.
//
// Two shapes qualify, and they are the two directions the name and the
// behaviour can disagree in:
//
//   - a `prod`, `prd`, `live` or `preprod` carrying no flag — it reads as
//     production and is not;
//   - a `production` declaring `false` — it reads as production and is not,
//     deliberately, and a reader should be told the disarm was meant.
//
// An environment that declares a flag either way has answered the question,
// so a suspiciously named one that declares is not surfaced.
func EnvironmentNamingNotice(name string, env Environment) string {
	folded := foldEnvironmentName(name)
	if env.Production == nil {
		for _, s := range suspiciousNames {
			if folded == s {
				return "Reads like production and is not: only the exact name " +
					"\"production\" is production by default. Add \"production\": true if it is."
			}
		}
		return ""
	}
	if !*env.Production && folded == productionName {
		return "Named production, and declares \"production\": false — " +
			"so it is not one: no red room, and no typed confirmation."
	}
	return ""
}

// EnvironmentIsReadOnly reports whether NOTHING in env can be written to:
// true only when no database it defines names a writeRef AND it declares
// no API entry. An environment declaring neither reports true vacuously
// (nothing writable is configured), so it is never evidence that an
// environment IS configured.
//
// **It asked databases only until #182, and that made it wrong for 2c-iv.**
// An environment holding an API entry is writable through it — `api_send`
// puts a POST on the wire — so an environment with no writable database
// and a configured API reported read-only while carrying the one surface
// in the product that can change somebody else's system. The loop was
// never the answer to "is anything writable"; it was the answer to "is any
// DATABASE writable", and it had only ever been asked the first question.
// An API entry needs no write credential to be writable, unlike a
// database: there is no read-only HTTP, so configuring one IS the grant,
// which is why presence is the whole test.
//
// **It asks WriteRef, not the former ReadOnly field, and that change was a
// correctness fix rather than a refactor.** ReadOnly granted nothing and
// protected nothing — OpenDatabase carried it into Connection and no
// driver ever consulted it, every driver's read-only gate being
// unconditional — so a safety indicator derived from it was reporting a
// fact about a field that governed no behaviour. Worse, it could be wrong
// in the dangerous direction: a database carrying BOTH readOnly:true and a
// writeRef made this function report the environment protected while a
// mutation there would gate and then run. WriteRef is the only input to
// whether a write can happen at all (OpenDatabaseWritable refuses without
// it, before it reads the Keychain), so it is the only honest input here.
// Issue #14.
func EnvironmentIsReadOnly(env Environment) bool {
	for _, d := range env.Databases {
		if d.WriteRef != "" {
			return false
		}
	}
	return len(env.API) == 0
}
