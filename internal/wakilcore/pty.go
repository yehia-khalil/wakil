package wakilcore

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

// ioctlPTY issues one pseudo-terminal ioctl.
//
// `arg` is a value for the ones that take none and a pointer for
// `TIOCPTYGNAME`, which is why it is a `uintptr` rather than a typed
// parameter.
func ioctlPTY(fd, request, arg uintptr) error {
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, arg); errno != 0 {
		return errno
	}
	return nil
}

// runOnPTY runs cmd with a pseudo-terminal for its standard streams and
// returns everything it wrote, with terminal control sequences removed.
//
// # Why the mint cannot use a pipe
//
// `claude setup-token` renders through an interactive console UI, and that
// UI writes **nothing at all** when its output is not a terminal. Measured
// on 2026-09-23 against CLI 2.1.280: spawned with pipes and `/dev/null` on
// stdin it opens the browser by itself, accepts the callback on
// `http://localhost:<port>/callback`, and then emits **zero bytes** — so
// the token it minted is unreachable, the process does not exit, and the
// operator is left on "Trip 2 of 2" until the five-minute deadline turns
// it into an uncertain outcome. A real credential now exists at Anthropic
// that Wakil never caught.
//
// That failure was not a coding slip: the two-trip design was established
// by READING the CLI's bundled JavaScript rather than running it, and
// `scripts/probe/setuptoken/setup-token-probe.sh` is committed unrun —
// `provider-login-probe.md` §11.1 says so plainly. A terminal was the one
// thing the reading could not tell us we needed.
//
// # The terminal is an input to the tool, so Wakil supplies it
//
// Not a workaround: `setup-token` is a terminal program, and Wakil spawns
// it the way a terminal would. The child gets its own session and a
// controlling terminal, which is also what stops it reaching for the
// parent's.
//
// # Stdin stays open but silent
//
// The PTY's own slave is the child's stdin, so a read blocks rather than
// returning EOF instantly. `setup-token` does not need anything typed —
// it opens the browser unprompted — but a console UI handed a closed
// stdin can decide it has no operator and behave differently, and that
// difference is exactly what was never measured.
func runOnPTY(cmd *exec.Cmd) (string, error) {
	master, slave, err := openPTY()
	if err != nil {
		return "", err
	}
	defer master.Close()

	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	// Its own session, with the PTY as the controlling terminal — what
	// makes `isatty` true for the child and keeps it off ours.
	cmd.SysProcAttr.Setsid = true
	cmd.SysProcAttr.Setctty = true

	// **A very wide terminal, so nothing the CLI prints ever wraps.**
	// This is the hazard `SettingsForms.dc.html` already warns operators
	// about in the manual flow — "setup-token wraps across terminal lines
	// and a mouse selection captures the wraps as real characters". A
	// console UI wraps to the width it is told, and a hard newline landing
	// inside the token is indistinguishable from the end of it: the decode
	// refuses anything carrying whitespace, so a wrapped token is silently
	// no token at all. 400 columns is far past any credential's length.
	if err := unix.IoctlSetWinsize(int(master.Fd()), unix.TIOCSWINSZ, &unix.Winsize{
		Row: 100, Col: 400,
	}); err != nil {
		slave.Close()
		return "", UserError("could not size the terminal: " + err.Error())
	}

	if err := cmd.Start(); err != nil {
		slave.Close()
		return "", err
	}
	// Closed in the PARENT once the child holds it, or the master never
	// sees the end of output: a slave still open here keeps the line
	// alive after the child is gone.
	slave.Close()

	// Read until the child's side closes. On Darwin that surfaces as
	// EIO rather than EOF, which is the normal end of a PTY session and
	// not a failure — the bytes already read are the answer either way.
	var out bytes.Buffer
	// The read error is deliberately NOT consulted (#271). An earlier
	// version classified it and then returned the same thing either way —
	// a distinction the comment claimed and the code did not make. There
	// is nothing to decide: Darwin ends a PTY session with EIO rather than
	// EOF, which is the normal end and not a failure, and for any other
	// read error the bytes already in the buffer are still the best answer
	// there is. A token on the buffer is worth more than the reason the
	// read stopped, and `cmd.Wait`'s status is what the caller judges by.
	_, _ = io.Copy(&out, master)
	return stripTerminalControls(out.String()), cmd.Wait()
}

// openPTY allocates a pseudo-terminal pair.
//
// Darwin has no `posix_openpt` in the syscall table, so this is the ioctl
// sequence `posix_openpt` performs: grant, unlock, then ask for the
// slave's name.
func openPTY() (master, slave *os.File, err error) {
	master, err = os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		return nil, nil, UserError("could not allocate a terminal for the credential step: " +
			err.Error())
	}
	fd := master.Fd()
	// Raw ioctls: Darwin has no `IoctlGetPtsName`, and `TIOCPTYGNAME`
	// writes the slave's path into a caller-supplied buffer rather than
	// returning an int, so none of the typed helpers fit.
	if err := ioctlPTY(fd, unix.TIOCPTYGRANT, 0); err != nil {
		master.Close()
		return nil, nil, UserError("could not grant the terminal: " + err.Error())
	}
	if err := ioctlPTY(fd, unix.TIOCPTYUNLK, 0); err != nil {
		master.Close()
		return nil, nil, UserError("could not unlock the terminal: " + err.Error())
	}
	// 128 bytes is the size `TIOCPTYGNAME` writes — the kernel's own
	// `SPECNAMELEN + 1` — and a shorter buffer is a silent overrun.
	var buf [128]byte
	if err := ioctlPTY(fd, unix.TIOCPTYGNAME, uintptr(unsafe.Pointer(&buf[0]))); err != nil {
		master.Close()
		return nil, nil, UserError("could not name the terminal: " + err.Error())
	}
	name := string(buf[:bytes.IndexByte(buf[:], 0)])
	slave, err = os.OpenFile(name, os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		master.Close()
		return nil, nil, UserError("could not open the terminal " + name + ": " + err.Error())
	}
	return master, slave, nil
}

// terminalControls matches the escape sequences a console UI paints with.
//
// **Stripped before the token is looked for, never after.** A console UI
// repositions the cursor and repaints, so the token arrives with escape
// sequences around it — and `DecodeMintedToken` refuses anything carrying
// whitespace or stray bytes, which is the behaviour that keeps a half-read
// token from being stored. Removing the control bytes first is what lets
// that strictness stay strict.
var terminalControls = regexp.MustCompile(`\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-Z\\-_]|\x1b\[[0-?]*[ -/]*[@-~]`)

// stripTerminalControls replaces each control run with a SPACE.
//
// **A space, not nothing and not a newline**, and the choice is the whole
// correctness of the decode. This UI positions with escapes rather than
// spaces, so deleting them glues neighbouring words together — and a token
// glued to the word after it is a longer string that still carries the
// prefix, which is precisely what `DecodeMintedToken` would then store.
// A newline is no safer in the other direction: it is whitespace, and a
// sequence landing mid-token would split it into two rejected halves.
// A space separates without joining, and whitespace is what the decode
// already treats as a boundary.
//
// `\r` is rewritten too: it is how a repaint returns to column zero, and
// leaving it in makes one rendered line look like two.
func stripTerminalControls(s string) string {
	return strings.ReplaceAll(terminalControls.ReplaceAllString(s, " "), "\r", " ")
}
