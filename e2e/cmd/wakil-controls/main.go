// Command wakil-controls prints the control denominator and the gate's
// verdict on it.
//
// **It needs no GUI and no bundle**, which is why it is separate from
// wakil-e2e: both halves read Swift source. The gate itself also runs inside
// `make test` (TestEveryAuditedControlIsNamed), because a rule enforced only
// by a target nobody runs is not enforced. This command exists for the other
// question — *what is actually in the set?* — which a passing test does not
// answer.
//
//	go run ./e2e/cmd/wakil-controls
//	go run ./e2e/cmd/wakil-controls --gate-only
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func main() {
	root := flag.String("sources", "app/Sources/WakilApp", "the Swift sources to read")
	gateOnly := flag.Bool("gate-only", false, "print only the gate's verdict")
	flag.Parse()

	if err := run(*root, *gateOnly); err != nil {
		fmt.Fprintln(os.Stderr, "wakil-controls:", err)
		os.Exit(1)
	}
}

func run(root string, gateOnly bool) error {
	identifiers, err := driver.HarvestIdentifiers(root)
	if err != nil {
		return err
	}
	// **Zero is a failure, not an empty report.** Design §2: control coverage
	// is measured against this set, so a harvest that found nothing would make
	// every later coverage claim vacuous — and would do it while exiting 0.
	if len(identifiers) == 0 {
		return fmt.Errorf("no identifiers under %s, so the control denominator is zero", root)
	}

	if !gateOnly {
		for _, identifier := range identifiers {
			suffix := ""
			if identifier.Dynamic {
				suffix = "  (a family; resolved per element against the live tree)"
			}
			fmt.Printf("%-48s %s:%d%s\n",
				identifier.Name, identifier.File, identifier.Line, suffix)
		}
		fmt.Printf("\n%d identifiers across %d audited source(s)\n\n",
			len(identifiers), len(driver.AuditedSources))
	}

	controls, err := driver.AuditControls(root)
	if err != nil {
		return err
	}
	if len(controls) == 0 {
		return fmt.Errorf("audited no controls, so the gate would pass on an empty set")
	}
	failures := driver.GateFailures(controls)
	if len(failures) == 0 {
		fmt.Printf("gate: %d actionable control(s), all named\n", len(controls))
		return nil
	}
	for _, control := range failures {
		fmt.Fprintf(os.Stderr, "  %s:%d  %s: %s\n",
			control.File, control.Line, control.Kind, control.Problem)
	}
	return fmt.Errorf("%d of %d actionable control(s) fail the gate", len(failures), len(controls))
}
