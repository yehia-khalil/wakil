package driver

import "testing"

func TestAnUndrawnElementHasNoFrameToJudge(t *testing.T) {
	if _, err := drawnRect(Element{Identifier: "editor.ticket.remove:notDone:n1", Undrawn: true}); err == nil {
		t.Error("an undrawn element's zero frame was judged as if it were drawn")
	}
	if _, err := drawnRect(Element{Identifier: "rail.db-1", Width: 10, Height: 10}); err != nil {
		t.Error(err)
	}
}
