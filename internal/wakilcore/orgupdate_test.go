package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func orgFilePath(t *testing.T, org string) string {
	t.Helper()
	dir, err := OrgDirFor(org)
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, orgFileName)
}

// TestUpdateOrgWritesOnlyWhatItWasGiven is the read-modify-write rule, and
// it is the property the whole edit path is built to have (#199): the pane
// sends the field the operator changed, and every other field on disk is
// read at dispatch and written back unchanged.
//
// A write that flushed the pane's own idea of all three fields would
// silently overwrite a hand edit made while the pane was open — and
// editing config by hand is the product, not a workaround.
func TestUpdateOrgWritesOnlyWhatItWasGiven(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{
		DisplayName: "Acme", JiraBase: "https://acme.atlassian.net",
	}); err != nil {
		t.Fatal(err)
	}

	displayName := "Acme Corporation"
	if err := UpdateOrg("acme", OrgPatch{DisplayName: &displayName}); err != nil {
		t.Fatal(err)
	}

	o, err := LoadOrgFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if o.DisplayName != "Acme Corporation" {
		t.Errorf("DisplayName = %q", o.DisplayName)
	}
	if o.JiraBase != "https://acme.atlassian.net" {
		t.Errorf("JiraBase = %q; a field not in the patch must survive", o.JiraBase)
	}
}

// TestUpdateOrgReadsDiskAtWriteTimeNotPaneTime is the same rule stated as
// the scenario that motivates it: the operator opens the pane, edits
// org.json by hand in a shell, then saves a DIFFERENT field from the pane.
// The hand edit must survive.
func TestUpdateOrgReadsDiskAtWriteTimeNotPaneTime(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{DisplayName: "Acme"}); err != nil {
		t.Fatal(err)
	}

	// The pane is open and holds {DisplayName: "Acme", JiraBase: ""}.
	// Meanwhile, by hand:
	handEdited := Org{DisplayName: "Acme", JiraBase: "https://typed-by-hand.atlassian.net"}
	b, err := json.MarshalIndent(handEdited, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(orgFilePath(t, "acme"), b, 0o600); err != nil {
		t.Fatal(err)
	}

	// The operator now saves the display name from the pane.
	displayName := "Acme Corporation"
	if err := UpdateOrg("acme", OrgPatch{DisplayName: &displayName}); err != nil {
		t.Fatal(err)
	}

	o, err := LoadOrgFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if o.JiraBase != "https://typed-by-hand.atlassian.net" {
		t.Errorf("JiraBase = %q; the hand edit was overwritten", o.JiraBase)
	}
	if o.DisplayName != "Acme Corporation" {
		t.Errorf("DisplayName = %q", o.DisplayName)
	}
}

// TestUpdateOrgClearsAFieldSetToEmpty. A patch carrying an empty string is
// not the same as a patch carrying nothing, and the pointer is what tells
// them apart: an operator who clears the Jira site means to clear it, and
// a rule of "empty means unchanged" would leave them unable to.
func TestUpdateOrgClearsAFieldSetToEmpty(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{
		DisplayName: "Acme", JiraBase: "https://acme.atlassian.net",
	}); err != nil {
		t.Fatal(err)
	}
	empty := ""
	if err := UpdateOrg("acme", OrgPatch{JiraBase: &empty}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrgFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if o.JiraBase != "" {
		t.Errorf("JiraBase = %q; an explicit empty must clear the field", o.JiraBase)
	}
	if o.DisplayName != "Acme" {
		t.Errorf("DisplayName = %q", o.DisplayName)
	}
}

// TestUpdateOrgRefusesADefaultProviderNamingNothing — the existing rule
// (normaliseOrg), reached through the new door. A shape-valid id naming no
// registered provider is exactly as unusable as a malformed one, and
// accepting it surfaces much later as a "selected" provider that never
// existed, which reads as something wrong with the provider that IS
// running.
func TestUpdateOrgRefusesADefaultProviderNamingNothing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{DisplayName: "Acme"}); err != nil {
		t.Fatal(err)
	}
	ghost := "not-registered"
	err := UpdateOrg("acme", OrgPatch{DefaultProvider: &ghost})
	if err == nil {
		t.Fatal("UpdateOrg accepted a defaultProvider naming no registered provider")
	}
	o, loadErr := LoadOrgFor("acme")
	if loadErr != nil {
		t.Fatal(loadErr)
	}
	if o.DefaultProvider != "" {
		t.Errorf("a refused patch must not be half-written: DefaultProvider = %q", o.DefaultProvider)
	}
	if o.DisplayName != "Acme" {
		t.Errorf("a refused patch must not touch the rest of the record: %+v", o)
	}
}

// TestUpdateOrgAcceptsADefaultProviderThatIsRegistered, so the refusal
// above is about existence rather than about the field being unsettable.
func TestUpdateOrgAcceptsADefaultProviderThatIsRegistered(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	configDir := filepath.Join(t.TempDir(), ".claude-main")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: configDir,
	}); err != nil {
		t.Fatal(err)
	}
	main := "main"
	if err := UpdateOrg("acme", OrgPatch{DefaultProvider: &main}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrgFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if o.DefaultProvider != "main" {
		t.Errorf("DefaultProvider = %q", o.DefaultProvider)
	}
}

// TestUpdateOrgNormalisesJiraBase — the same normalisation CreateOrg and
// SaveOrg apply, reached through the new door, so a value typed into the
// pane and one typed at the shell are stored identically.
func TestUpdateOrgNormalisesJiraBase(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	base := "https://acme.atlassian.net/"
	if err := UpdateOrg("acme", OrgPatch{JiraBase: &base}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrgFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if o.JiraBase != "https://acme.atlassian.net" {
		t.Errorf("JiraBase = %q; want the trailing slash normalised away", o.JiraBase)
	}

	bad := "http://acme.atlassian.net"
	if err := UpdateOrg("acme", OrgPatch{JiraBase: &bad}); err == nil {
		t.Error("UpdateOrg accepted a non-https Jira base")
	}
	o, err = LoadOrgFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if o.JiraBase != "https://acme.atlassian.net" {
		t.Errorf("a refused patch left %q on disk", o.JiraBase)
	}
}

// TestUpdateOrgRefusesAnOrgThatDoesNotExist. Creation goes through
// CreateOrg so the "already exists" check has exactly one home; this is
// the mirror rule, so an update cannot bring an organisation into being
// through a typo in its id.
func TestUpdateOrgRefusesAnOrgThatDoesNotExist(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	displayName := "Ghost"
	if err := UpdateOrg("nope", OrgPatch{DisplayName: &displayName}); err == nil {
		t.Fatal("UpdateOrg created an organisation that did not exist")
	}
}

// TestUpdateOrgWithAnEmptyPatchIsANoOp — nothing to write, and nothing
// written. Worth pinning because the alternative is a rewrite that
// normalises whatever happens to be on disk, which is a write the operator
// never asked for.
func TestUpdateOrgWithAnEmptyPatchIsANoOp(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{DisplayName: "Acme"}); err != nil {
		t.Fatal(err)
	}
	path := orgFilePath(t, "acme")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := UpdateOrg("acme", OrgPatch{}); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Errorf("an empty patch rewrote the file:\nbefore %s\nafter  %s", before, after)
	}
}

// TestUpdateOrgWritesSpeechProviderAndLeavesTheRest is 2d-ii's field on
// the read-modify-write path: the Speech row sends only this key.
func TestUpdateOrgWritesSpeechProviderAndLeavesTheRest(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{DisplayName: "Acme"}); err != nil {
		t.Fatal(err)
	}
	engine := "apple"
	if err := UpdateOrg("acme", OrgPatch{SpeechProvider: &engine}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrgFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if o.SpeechProvider != "apple" {
		t.Errorf("SpeechProvider = %q", o.SpeechProvider)
	}
	if o.DisplayName != "Acme" {
		t.Errorf("DisplayName = %q; a field not in the patch must survive", o.DisplayName)
	}
}

// TestSpeechProviderIsStoredAsGivenEvenWhenUnknown: the Swift side falls
// back to Apple and says so (interaction rule 7), so Go must not refuse an
// engine id it has never heard of — Go does not know which engines exist.
func TestSpeechProviderIsStoredAsGivenEvenWhenUnknown(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	engine := "  whisper-local  "
	if err := UpdateOrg("acme", OrgPatch{SpeechProvider: &engine}); err != nil {
		t.Fatal(err)
	}
	o, _ := LoadOrgFor("acme")
	if o.SpeechProvider != "whisper-local" {
		t.Errorf("SpeechProvider = %q, want trimmed whisper-local", o.SpeechProvider)
	}
}

// TestOrgJSONWithoutSpeechProviderStillReads: every org.json written before
// 2d-ii lacks the key, and omitempty keeps an unset one out of new files.
func TestOrgJSONWithoutSpeechProviderStillReads(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("acme", Org{DisplayName: "Acme"}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(orgFilePath(t, "acme"))
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatal(err)
	}
	if _, present := raw["speechProvider"]; present {
		t.Errorf("an unset speechProvider must be omitted, got %s", b)
	}
	o, err := LoadOrgFor("acme")
	if err != nil || o.SpeechProvider != "" {
		t.Errorf("LoadOrgFor = %+v, %v", o, err)
	}
}

func TestUpdateOrgSetsAndClearsQuickProvider(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	id := "qwen"
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &id}); err != nil {
		t.Fatal(err)
	}
	o, _ := LoadOrgFor("initech")
	if o.QuickProvider != "qwen" {
		t.Fatalf("quickProvider = %q", o.QuickProvider)
	}
	empty := ""
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &empty}); err != nil {
		t.Fatal(err)
	}
	o, _ = LoadOrgFor("initech")
	if o.QuickProvider != "" {
		t.Errorf("not cleared: %q", o.QuickProvider)
	}
}

func TestUpdateOrgRefusesAnUnboundQuickProvider(t *testing.T) {
	localOrg(t)
	id := "ghost"
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &id}); err == nil {
		t.Error("accepted a quickProvider that names no provider")
	}
}

func TestUpdateOrgSetsTheQuickTaskSwitches(t *testing.T) {
	localOrg(t)
	on, off := true, false
	if err := UpdateOrg("initech", OrgPatch{GhostText: &off, FastPath: &on, CommitDrafts: &off}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrgFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if o.GhostText == nil || *o.GhostText || o.FastPath == nil || !*o.FastPath {
		t.Fatalf("ghostText=%v fastPath=%v", o.GhostText, o.FastPath)
	}
	if o.CommitDrafts == nil || *o.CommitDrafts {
		t.Fatalf("commitDrafts=%v", o.CommitDrafts)
	}
}

func TestConfigTreeResolvesTheQuickTaskSwitches(t *testing.T) {
	localOrg(t)
	tree, err := LoadConfigTreeFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	// Nothing set: ghost-text on, fast path off (no local quick provider).
	if !tree.Org.GhostText || tree.Org.FastPath {
		t.Fatalf("defaults: ghostText=%v fastPath=%v", tree.Org.GhostText, tree.Org.FastPath)
	}
	// 3a-ii-b: commit drafts are on until switched off.
	if !tree.Org.CommitDrafts {
		t.Fatal("defaults: commitDrafts off")
	}
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	q := "qwen"
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &q}); err != nil {
		t.Fatal(err)
	}
	tree, _ = LoadConfigTreeFor("initech")
	if !tree.Org.FastPath {
		t.Fatal("a local quick provider should turn the fast path on by default")
	}
	off := false
	_ = UpdateOrg("initech", OrgPatch{FastPath: &off})
	tree, _ = LoadConfigTreeFor("initech")
	if tree.Org.FastPath {
		t.Fatal("the org's own value must win over the default")
	}
}

func TestConfigTreeGhostTextFallsBackToTheAppSetting(t *testing.T) {
	localOrg(t)
	off := false
	if err := UpdateEditorAppSettings(EditorAppPatch{GhostText: &off}); err != nil {
		t.Fatal(err)
	}
	tree, _ := LoadConfigTreeFor("initech")
	if tree.Org.GhostText {
		t.Fatal("an operator who turned ghost-text off app-wide keeps it off")
	}
}

func TestUpdateOrgSetsAndClearsTheGitIdentity(t *testing.T) {
	localOrg(t)
	name, email := "Org Person", "org@example.test"
	if err := UpdateOrg("initech", OrgPatch{GitName: &name, GitEmail: &email}); err != nil {
		t.Fatal(err)
	}
	o, _ := LoadOrgFor("initech")
	if OrgGitIdentity(o) != (GitIdentity{Name: name, Email: email}) {
		t.Fatalf("%+v", o)
	}
	empty := ""
	if err := UpdateOrg("initech", OrgPatch{GitEmail: &empty}); err != nil {
		t.Fatal(err)
	}
	o, _ = LoadOrgFor("initech")
	if o.GitEmail != "" || o.GitName != name {
		t.Fatalf("%+v", o)
	}
	if OrgGitIdentity(nil) != (GitIdentity{}) {
		t.Fatal("nil org must give the zero identity")
	}
}

func TestAGitIdentityWithANewlineIsRefused(t *testing.T) {
	localOrg(t)
	bad := "a@b\nx"
	err := UpdateOrg("initech", OrgPatch{GitEmail: &bad})
	if err == nil || err.Error() != "gitName and gitEmail cannot hold a newline" {
		t.Fatalf("err %v", err)
	}
}
