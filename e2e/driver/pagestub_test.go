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
