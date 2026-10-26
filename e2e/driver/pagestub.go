package driver

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// PageFixtures is where the browser checks' pages live, relative to the
// repository root the e2e runs from.
const PageFixtures = "e2e/fixtures/pages"

// BigBinSize is how large `/big.bin` says it is, and BigBinRate how fast it
// arrives: 10 MB at 64 KB/s is minutes, so a download check has all the time
// it needs to see progress and cancel before it finishes.
const (
	BigBinSize = 10 * 1024 * 1024
	BigBinRate = 64 * 1024
)

// bigBinTick is how often a slice of BigBinRate goes out. Small slices keep
// the rate even within a second, so "at most 64 KB in half a second" holds.
const bigBinTick = 125 * time.Millisecond

// StartPageStub serves the browser checks' pages from dir on loopback http,
// so a check navigates to the same page every run and needs no network. Its
// port changes on every launch; a check names it with PageStubToken.
//
// `/big.bin` is not a file: it streams BigBinSize zero bytes at BigBinRate,
// with a Content-Length, so a download has a known total and a progress.
// `/stall.html` is not one either: it sends its head and never finishes.
func StartPageStub(dir string) (string, func(), error) {
	// Absolute and checked now: a relative http.Dir resolves at each request,
	// and a missing folder would answer every page 404 rather than fail here.
	dir, err := filepath.Abs(dir)
	if err != nil {
		return "", nil, err
	}
	if _, err := os.Stat(filepath.Join(dir, "a.html")); err != nil {
		return "", nil, fmt.Errorf("the page stub has no pages at %s (run from the repository root): %w", dir, err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/big.bin", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/octet-stream")
		w.Header().Set("content-disposition", `attachment; filename="big.bin"`)
		w.Header().Set("content-length", strconv.Itoa(BigBinSize))
		w.WriteHeader(http.StatusOK)
		flusher, _ := w.(http.Flusher)
		slice := make([]byte, BigBinRate*int(bigBinTick)/int(time.Second))
		ticker := time.NewTicker(bigBinTick)
		defer ticker.Stop()
		for sent := 0; sent < BigBinSize; {
			n := min(len(slice), BigBinSize-sent)
			if _, err := w.Write(slice[:n]); err != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
			sent += n
			select {
			case <-ticker.C:
			case <-r.Context().Done():
				return
			}
		}
	})
	// A page that never finishes: its head, then nothing until the tab stops it (or the stub
	// closes), so the tab stays loading and the browser's Stop button is there to press.
	mux.HandleFunc("/stall.html", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "<!doctype html><html><head><meta charset=\"utf-8\"><title>Stall</title></head><body><p>Still loading")
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		<-r.Context().Done()
	})
	mux.Handle("/", http.FileServer(http.Dir(dir)))
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	return "http://" + ln.Addr().String(), func() { srv.Close() }, nil
}
