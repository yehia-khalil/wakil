package wakilcore

import (
	"context"
	"strconv"
)

// PickDatabase selects one Database from env by name.
//
// The resolution rules and their reasons live on `pickNamed`, which
// `PickAPI` shares: name optional, empty allowed only for a single-entry
// environment, duplicates rejected as ambiguous rather than resolved to the
// first. What stays here is the WORDING, because "no database named X" and
// "no api entry named X" send an operator to different lines of
// project.json — and `wakil-db`'s tests pin these sentences.
func PickDatabase(env Environment, name string) (Database, error) {
	return pickNamed(env.Databases, name, func(d Database) string { return d.Name },
		pickMessages{
			noneConfigured: "no databases configured for this environment",
			nameOneOfThem:  "multiple databases in this environment — name one of them",
			notFound: func(n string) string {
				return "no database named " + n + " in this environment"
			},
			ambiguous: func(n string) string {
				return "ambiguous configuration: multiple databases named " + n + " in this environment"
			},
		})
}

// OpenDatabase resolves d's driver and secret ref, reads the credential
// from the Keychain, and opens a read-only Conn to it.
//
// Connection.ReadOnly is set to true unconditionally, because that is what
// this function unconditionally does — it is the only route that is not
// OpenDatabaseWritable. It used to be set from a per-database ReadOnly
// field, which was removed on 2026-09-10 (issue #14) for reporting a
// safety property it did not have: every driver's read-only gate is
// unconditional and none of them ever consulted the flag, so a database
// configured readOnly:false was no more writable through here than one
// configured readOnly:true. The flag survives on Connection only as a
// label — String() prints it — and must stay something no driver branches
// on, or the gate stops being unconditional.
func OpenDatabase(ctx context.Context, d Database) (Conn, error) {
	drv, err := GetDriver(d.Driver)
	if err != nil {
		return nil, err
	}
	url, err := SecretGet(d.Ref)
	if err != nil {
		return nil, err
	}
	// Writable is the ONE field here derived from configuration rather
	// than fixed by the route: it says whether an edit could ever
	// succeed, so a read can decline to advertise one it cannot honour.
	// It grants nothing — see Connection.Writable.
	return drv.Connect(ctx, Connection{
		Ref: d.Ref, URL: url, ReadOnly: true, Writable: d.WriteRef != "",
	})
}

// OpenDatabaseWritable resolves d's driver and its SEPARATE write
// credential, and opens a connection whose Write can succeed.
//
// The order of the three steps is deliberate. The writeRef check comes
// first, so a database that was never configured for writing is refused
// without a Keychain lookup — the operator's login keychain is not
// consulted to answer a question that configuration alone already answers.
// The driver is resolved second, so an unknown driver is reported as an
// unknown driver rather than as a missing secret. Only then is the
// credential read.
//
// This function is the ONLY route to a writable Conn. OpenDatabase is
// untouched and still cannot produce one.
func OpenDatabaseWritable(ctx context.Context, d Database) (Conn, error) {
	if d.WriteRef == "" {
		return nil, UserError("database " + strconv.Quote(d.Name) +
			" is not configured for writing: add a \"writeRef\" naming a Keychain entry " +
			"whose credential the server has granted write permission to")
	}
	drv, err := GetDriver(d.Driver)
	if err != nil {
		return nil, err
	}
	url, err := SecretGet(d.WriteRef)
	if err != nil {
		return nil, err
	}
	return drv.ConnectWritable(ctx, Connection{
		Ref: d.WriteRef, URL: url, ReadOnly: false, Writable: true,
	})
}
