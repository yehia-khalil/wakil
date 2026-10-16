package wakilcore

// StatementClass is what the query surface needs to know before it runs
// anything: whether this text is a read, a mutation, or neither.
//
// Reason is non-empty only for "neither", and it is the GATE'S OWN
// sentence, verbatim. A second wording composed here would drift from the
// refusal that actually happens when the statement runs, and the operator
// would be told one thing and then shown another.
type StatementClass struct {
	Kind   string `json:"kind"`
	Reason string `json:"reason,omitempty"`
}

// ClassifyStatement answers whether statement is a read, a mutation, or
// neither, for a database of the given driver kind.
//
// **It opens no connection and touches no credential.** Every function it
// calls is a pure text or structural check, which is what makes asking
// before running cheap enough to do on every Return in the query line.
//
// **It is not a gate and must never be used as one.** The real refusals
// still happen in sqlConn.Read and sqlConn.Write, unchanged, whatever this
// says. What this buys is that the query line can route to db_run_query or
// db_run_mutation without Wakil's Swift half parsing SQL — see spec §9.
// A wrong answer here sends a statement to the wrong action and the gate
// on that path refuses it; a wrong answer cannot let anything through.
//
// **An unknown driver answers "neither".** Guessing that an unregistered
// driver speaks SQL is how a Mongo-shaped JSON document would get handed
// to a SQL gate, and the honest answer for a driver Wakil does not have is
// that it cannot say.
func ClassifyStatement(driver, statement string) StatementClass {
	switch driver {
	case "mongo":
		if err := AssertMongoReadOnly(statement); err != nil {
			msg, _ := IsUserError(err)
			if msg == "" {
				msg = err.Error()
			}
			// Deliberately not "mutation". mongoConn.Write refuses every
			// statement — the driver's write path is honestly
			// unimplemented — so routing this to db_run_mutation would
			// raise a confirmation plane for something that cannot run.
			return StatementClass{Kind: "neither", Reason: msg}
		}
		return StatementClass{Kind: "read"}
	case "sqlite", "mysql":
		if AssertSQLReadOnly(statement) == nil {
			return StatementClass{Kind: "read"}
		}
		if err := AssertSQLMutation(statement); err != nil {
			msg, _ := IsUserError(err)
			if msg == "" {
				msg = err.Error()
			}
			return StatementClass{Kind: "neither", Reason: msg}
		}
		return StatementClass{Kind: "mutation"}
	default:
		return StatementClass{
			Kind:   "neither",
			Reason: "no driver named " + driver + " in this build, so this statement cannot be judged",
		}
	}
}
