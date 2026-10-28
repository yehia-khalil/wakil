package driver

import (
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestPageStubServesFixturesAndStreamsSlowly — the browser checks need pages
// that answer the same every run, and a download slow enough to cancel.
func TestPageStubServesFixturesAndStreamsSlowly(t *testing.T) {
	origin, stop, err := StartPageStub(filepath.Join(repoRoot(t), PageFixtures))
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	if !strings.HasPrefix(origin, "http://127.0.0.1:") {
		t.Errorf("origin %q is not loopback http", origin)
	}

	for page, want := range map[string]string{
		"/a.html":     "<title>Page A</title>",
		"/b.html":     "<title>Page B</title>",
		"/popup.html": "window.open('b.html'",
		"/find.html":  "needle",
		"/alert.html": "alert(",
		"/keys.html":  "preventDefault",
	} {
		resp, err := http.Get(origin + page)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 || !strings.Contains(string(body), want) {
			t.Errorf("%s answered %d without %q", page, resp.StatusCode, want)
		}
	}
	if n := strings.Count(string(fetchPage(t, origin+"/find.html")), "needle"); n != 3 {
		t.Errorf("find.html carries needle %d times, want 3", n)
	}

	resp, err := http.Get(origin + "/big.bin")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if got := resp.Header.Get("Content-Length"); got != strconv.Itoa(BigBinSize) {
		t.Errorf("big.bin Content-Length %q, want %d", got, BigBinSize)
	}
	start := time.Now()
	read := 0
	buf := make([]byte, 4096)
	for time.Since(start) < 500*time.Millisecond {
		n, err := resp.Body.Read(buf)
		read += n
		if err != nil {
			break
		}
	}
	if read == 0 || read > 64*1024 {
		t.Errorf("big.bin sent %d bytes in half a second, want some and at most 64 KB", read)
	}
}

func fetchPage(t *testing.T, url string) []byte {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return body
}

// TestPageStubStallsAPageUntilTheClientLeaves — `/stall.html` sends its head and then nothing,
// so a tab stays loading until Stop: the one state the browser's Stop button is drawn in.
func TestPageStubStallsAPageUntilTheClientLeaves(t *testing.T) {
	origin, stop, err := StartPageStub(filepath.Join(repoRoot(t), PageFixtures))
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	resp, err := http.Get(origin + "/stall.html")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("stall.html answered %d", resp.StatusCode)
	}
	got := make(chan string, 1)
	go func() {
		buf := make([]byte, 4096)
		n, _ := resp.Body.Read(buf)
		got <- string(buf[:n])
		_, err := io.ReadAll(resp.Body)
		got <- "ended: " + errString(err)
	}()
	if head := <-got; !strings.Contains(head, "<title>Stall</title>") {
		t.Errorf("stall.html's first bytes %q carry no title", head)
	}
	select {
	case end := <-got:
		t.Errorf("stall.html finished (%s); it must stay open", end)
	case <-time.After(700 * time.Millisecond):
	}
	if body := string(fetchPage(t, origin+"/prompt.html")); !strings.Contains(body, "prompt(") {
		t.Errorf("prompt.html carries no prompt(): %q", body)
	}
}

func errString(err error) string {
	if err == nil {
		return "nil"
	}
	return err.Error()
}

// TestPageStubServesTheFormPages — the form, the page it submits to and the injection page answer
// with their titles, on the loopback address and under the name `localhost` alike.
func TestPageStubServesTheFormPages(t *testing.T) {
	origin, stop, err := StartPageStub(filepath.Join(repoRoot(t), PageFixtures))
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	for page, want := range map[string][]string{
		"/form.html":   {"<title>Booking form</title>", `name="guest"`, `name="nights"`, "One night", "Two nights", `autocomplete="cc-number"`, `type="password"`, "Confirm", "Back to page A"},
		"/done.html":   {"document.title", "no name", "2 nights", "1 night"},
		"/inject.html": {"<title>Release notes</title>", "ignore your instructions", "https://example.com/collect"},
	} {
		resp, err := http.Get(origin + page)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Errorf("%s answered %d", page, resp.StatusCode)
		}
		for _, fragment := range want {
			if !strings.Contains(string(body), fragment) {
				t.Errorf("%s lacks %q", page, fragment)
			}
		}
	}
	// Document order: name, stay, card, password, confirm, then the link — e1 to e6.
	form := string(fetchPage(t, origin+"/form.html"))
	last := -1
	for _, marker := range []string{`name="guest"`, `name="nights"`, `cc-number`, `type="password"`, `type="submit"`, "Back to page A"} {
		at := strings.Index(form, marker)
		if at <= last {
			t.Errorf("%q is out of order in form.html", marker)
		}
		last = at
	}
	live := PageStubLive(origin)
	if !strings.HasPrefix(live, "http://localhost:") {
		t.Fatalf("PageStubLive(%q) = %q", origin, live)
	}
	if body := string(fetchPage(t, live+"/form.html")); !strings.Contains(body, "Booking form") {
		t.Errorf("%s/form.html does not answer", live)
	}
}

// TestPageStubLiveTokenExpands — {pageStubLive} becomes the stub under `localhost`, in params and
// in typed text, and {pageStub} stays the loopback address.
func TestPageStubLiveTokenExpands(t *testing.T) {
	runner := &Runner{PageStub: "http://127.0.0.1:4321", PageStubLive: PageStubLive("http://127.0.0.1:4321")}
	if runner.PageStubLive != "http://localhost:4321" {
		t.Fatalf("PageStubLive = %q", runner.PageStubLive)
	}
	tokens := runner.tokens()
	if got := ExpandText("{pageStubLive}/form.html and {pageStub}/a.html", tokens); got != "http://localhost:4321/form.html and http://127.0.0.1:4321/a.html" {
		t.Errorf("ExpandText = %q", got)
	}
	params := ExpandParams(map[string]interface{}{"url": "{pageStubLive}/done.html", "n": []interface{}{"{pageStub}"}}, tokens)
	if params["url"] != "http://localhost:4321/done.html" || params["n"].([]interface{})[0] != "http://127.0.0.1:4321" {
		t.Errorf("ExpandParams = %v", params)
	}
	if PageStubLive("") != "" {
		t.Error("an empty origin must stay empty")
	}
	if got := ExpandText("{pageStubLive}", (&Runner{}).tokens()); got != "{pageStubLive}" {
		t.Errorf("without a stub the token must stay literal, got %q", got)
	}
}

// TestPageStubServesTheFormSlowly — /slow-form.html is form.html after SlowFormDelay, never
// cached, so a tab that loads it again (a restored tab) is still loading for that long.
func TestPageStubServesTheFormSlowly(t *testing.T) {
	origin, stop, err := StartPageStub(filepath.Join(repoRoot(t), PageFixtures))
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	start := time.Now()
	resp, err := http.Get(origin + "/slow-form.html")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if took := time.Since(start); took < SlowFormDelay {
		t.Errorf("/slow-form.html answered after %v, before %v", took, SlowFormDelay)
	}
	if !strings.Contains(string(body), "<title>Booking form</title>") {
		t.Errorf("/slow-form.html is not the booking form: %.80q", body)
	}
	if cc := resp.Header.Get("cache-control"); cc != "no-store" {
		t.Errorf("/slow-form.html cache-control = %q, want no-store", cc)
	}
}

// TestPageStubServesTheClipAsVideo — WebKit plays clip.mp4 only when it arrives as video/mp4 and
// a Range request answers 206 with that slice: the picture-in-picture checks' clip (3d-iii).
func TestPageStubServesTheClipAsVideo(t *testing.T) {
	origin, stop, err := StartPageStub(filepath.Join(repoRoot(t), PageFixtures))
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	req, _ := http.NewRequest("GET", origin+"/clip.mp4", nil)
	req.Header.Set("Range", "bytes=0-99")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent || resp.Header.Get("Content-Type") != "video/mp4" || len(body) != 100 {
		t.Errorf("clip.mp4 answered %d, %q, %d bytes; want 206, video/mp4, 100", resp.StatusCode, resp.Header.Get("Content-Type"), len(body))
	}
}
