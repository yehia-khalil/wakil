import Testing
@testable import WakilKit

// Names, Calls made 4 and 10: the name step's line is cleaned, not refused. A whitespace-only line
// is a clear — never a blank title (review focus 1) — and a line that cleans to the shown name runs
// nothing.
@Test(arguments: [
    ("Mine", "Old", RenameDraft.set("Mine")),
    ("  ", "Old", .clear),
    ("Old ", "Old", .keep),
    ("", "Old", .clear),
    ("\n\t ", "Old", .clear),
    ("  two \n words ", "Old", .set("two words")),
    ("Old", "Old  name", .set("Old")),
    ("Old name", "Old  name", .keep),
])
func aDraftIsSetClearOrKeep(_ typed: String, _ shown: String, _ want: RenameDraft) {
    #expect(RenameDraft.decide(typed: typed, shown: shown) == want)
}
