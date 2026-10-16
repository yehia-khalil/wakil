package driver

import (
	"net"
	"sync"
)

// StallListener is a server that accepts connections and never answers: a
// TLS client's handshake waits on it until the client gives up. It is the
// slow server the cancel check sends to (2c-iv W14), with no certificate to
// trust — wakil-http requires https and trusts only the system roots, so a
// local HTTPS server could not be reached at all, while a stalled handshake
// is reached and simply never completes. Go's transport gives up after its
// 10 s TLSHandshakeTimeout, which is the window a check has to cancel in.
type StallListener struct {
	ln    net.Listener
	mu    sync.Mutex
	conns []net.Conn
}

func StartStallListener() (*StallListener, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	s := &StallListener{ln: ln}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			s.mu.Lock()
			s.conns = append(s.conns, conn)
			s.mu.Unlock()
		}
	}()
	return s, nil
}

// Origin is the baseUrl the fixture's `slow` entry carries.
func (s *StallListener) Origin() string { return "https://" + s.ln.Addr().String() }

// Close stops accepting and drops every connection it is holding.
func (s *StallListener) Close() error {
	err := s.ln.Close()
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.conns {
		c.Close()
	}
	s.conns = nil
	return err
}
