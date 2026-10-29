package wakilcore

// OrgPatch names the fields of an Org record an edit intends to change.
//
// **Pointers, because an empty string is a value and not an absence.** An
// operator who clears the Jira site means to clear it; a rule of "empty
// means unchanged" would leave them unable to, and a rule of "empty means
// clear" would have every save from the settings pane wipe every field the
// operator did not touch. The pointer is the only shape that tells the two
// apart.
//
// The org id is deliberately not a field. It is the directory name, so
// there is one place it can be written and no way for the two to disagree
// — the same reason `Org` itself omits it.
type OrgPatch struct {
	DisplayName       *string
	JiraBase          *string
	DefaultProvider   *string
	SpeechProvider    *string
	QuickProvider     *string
	GitName           *string
	GitEmail          *string
	GhostText         *bool
	FastPath          *bool
	CommitDrafts      *bool
	ConversationNames *bool
	PullStrategy      *string
	// 3a-iii-b: the organisation's agent instructions.
	AgentGeneral          *string
	GitCommitInstructions *string
	GitPRInstructions     *string
}

// isEmpty reports whether this patch would change nothing.
func (p OrgPatch) isEmpty() bool {
	return p.DisplayName == nil && p.JiraBase == nil && p.DefaultProvider == nil &&
		p.SpeechProvider == nil && p.QuickProvider == nil && p.GitName == nil && p.GitEmail == nil && p.GhostText == nil && p.FastPath == nil &&
		p.CommitDrafts == nil && p.ConversationNames == nil && p.PullStrategy == nil &&
		p.AgentGeneral == nil && p.GitCommitInstructions == nil && p.GitPRInstructions == nil
}

// apply returns o with this patch's named fields replaced.
func (p OrgPatch) apply(o Org) Org {
	if p.DisplayName != nil {
		o.DisplayName = *p.DisplayName
	}
	if p.JiraBase != nil {
		o.JiraBase = *p.JiraBase
	}
	if p.DefaultProvider != nil {
		o.DefaultProvider = *p.DefaultProvider
	}
	if p.SpeechProvider != nil {
		o.SpeechProvider = *p.SpeechProvider
	}
	if p.QuickProvider != nil {
		o.QuickProvider = *p.QuickProvider
	}
	if p.GitName != nil {
		o.GitName = *p.GitName
	}
	if p.GitEmail != nil {
		o.GitEmail = *p.GitEmail
	}
	if p.GhostText != nil {
		v := *p.GhostText
		o.GhostText = &v
	}
	if p.FastPath != nil {
		v := *p.FastPath
		o.FastPath = &v
	}
	if p.AgentGeneral != nil {
		o.AgentGeneral = *p.AgentGeneral
	}
	if p.GitCommitInstructions != nil {
		o.GitCommitInstructions = *p.GitCommitInstructions
	}
	if p.GitPRInstructions != nil {
		o.GitPRInstructions = *p.GitPRInstructions
	}
	if p.PullStrategy != nil {
		o.PullStrategy = *p.PullStrategy
	}
	if p.CommitDrafts != nil {
		v := *p.CommitDrafts
		o.CommitDrafts = &v
	}
	if p.ConversationNames != nil {
		v := *p.ConversationNames
		o.ConversationNames = &v
	}
	return o
}

// UpdateOrg changes the named fields of org's record, leaving every other
// field exactly as it is on disk.
//
// **Read-modify-write, from disk, at the moment of the write** — which is
// the property the settings pane's whole edit path is built to have
// (#199). The pane holds no configuration of its own and never flushes
// one: it sends the field the operator changed, and this reads the rest
// back off disk. So an operator who edits org.json by hand while the pane
// is open, and then saves a different field from the pane, keeps their
// hand edit. Editing config by hand is the product, not a workaround, and
// a UI that quietly punished it would be the wrong half of parity.
//
// **Validation is normaliseOrg's, unchanged**, so a value typed into the
// pane and one typed at the shell are refused and normalised identically:
// the Jira site through `normalizeJiraBase`, and a default provider that
// must both be shape-valid and name a provider actually registered under
// org. A refusal writes nothing — the patch is applied to an in-memory
// copy and normalised before the file is touched, so a rejected edit
// cannot leave a half-written record.
//
// **It refuses an organisation that does not exist**, the mirror of
// CreateOrg's "already exists" check, so that a typo in an org id cannot
// bring an organisation into being through the edit path. `LoadOrgFor`
// treats a registered org with no org.json as an empty record rather than
// an error, which is the case this has to let through: an organisation can
// legitimately exist with nothing in its file yet.
//
// **An empty patch writes nothing at all.** The alternative is a rewrite
// that normalises whatever happens to be on disk — a write the operator
// never asked for, against a file they may be editing by hand.
func UpdateOrg(org string, patch OrgPatch) error {
	if patch.isEmpty() {
		return nil
	}
	// Existence first, and through OrgDirFor rather than LoadOrgFor: the
	// latter answers for a registered org with no record yet, which is a
	// state this must accept, so it cannot also be the existence check.
	if _, err := OrgDirFor(org); err != nil {
		return err
	}
	current, err := LoadOrgFor(org)
	if err != nil {
		return err
	}
	return SaveOrg(org, patch.apply(*current))
}
