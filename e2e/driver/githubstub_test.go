package driver

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// The stub is read by the production client, so a check's expectations rest on what wakil-ticket
// actually decodes from it, not on what the stub meant to say.
func TestGitHubStubAnswersTheProductionClient(t *testing.T) {
	url, stop, err := StartGitHubStub("abc123")
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	gh := &wakilcore.GitHubClient{Endpoint: url, Token: "e2e-token"}
	ctx := context.Background()

	heads, _, err := gh.BranchPRs(ctx, "initech", "api", TicketBranchOwn)
	if err != nil || len(heads) != 1 {
		t.Fatalf("own branch: %v, %d heads", err, len(heads))
	}
	pr := heads[0]
	if pr.Number != 212 || pr.HeadSHA != "abc123" || len(pr.Threads) != 2 || len(pr.Checks) != 2 || pr.Checks[0].State != "failure" {
		t.Fatalf("PR #212 decoded as %+v", pr)
	}
	if _, bases, _ := gh.BranchPRs(ctx, "initech", "api", "main"); len(bases) != 1 {
		t.Fatalf("main's bases: %d", len(bases))
	}
	if _, _, err := gh.BranchPRs(ctx, "initech", "api", TicketBranchBroken); err == nil || !strings.Contains(err.Error(), TicketBrokenMessage) {
		t.Fatalf("broken branch answered %v", err)
	}
	if login, err := gh.Viewer(ctx); err != nil || login != "peter" {
		t.Fatalf("viewer %q, %v", login, err)
	}
	authored, _, err := gh.MyOpenPRs(ctx, []string{"initech"})
	if err != nil || len(authored) != 1 || authored[0].Author != "peter" {
		t.Fatalf("my PRs: %v, %+v", err, authored)
	}
	th, err := gh.ReviewThread(ctx, "T_1")
	if err != nil || th.Repo != "initech/api" || th.Number != 212 || th.Path != "app.txt" || th.Line != 2 {
		t.Fatalf("T_1: %v, %+v", err, th)
	}
	if _, err := gh.ReviewThread(ctx, "T_404"); err == nil {
		t.Fatal("an unknown thread was answered")
	}
	stalled, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
	defer cancel()
	if _, _, err := gh.BranchPRs(stalled, "initech", "api", TicketBranchStall); err == nil {
		t.Fatal("the stalled branch answered")
	}
}
