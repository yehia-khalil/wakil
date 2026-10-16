package driver

import (
	"net"
	"strings"
	"testing"
	"time"
)

func TestStallListenerAcceptsAndNeverAnswers(t *testing.T) {
	stall, err := StartStallListener()
	if err != nil {
		t.Fatal(err)
	}
	defer stall.Close()
	if !strings.HasPrefix(stall.Origin(), "https://127.0.0.1:") {
		t.Fatalf("origin = %q", stall.Origin())
	}
	conn, err := net.Dial("tcp", strings.TrimPrefix(stall.Origin(), "https://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte("\x16\x03\x01")) // the start of a ClientHello
	conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if n, err := conn.Read(make([]byte, 1)); n != 0 || err == nil {
		t.Fatalf("the listener answered: n=%d err=%v", n, err)
	}
}

func TestStallListenerCloseDropsItsConnections(t *testing.T) {
	stall, err := StartStallListener()
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.Dial("tcp", strings.TrimPrefix(stall.Origin(), "https://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	time.Sleep(50 * time.Millisecond)
	stall.Close()
	conn.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("the connection outlived Close")
	}
}
