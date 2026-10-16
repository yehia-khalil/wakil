import Testing
import Foundation
@testable import WakilKit

@Test func aParkedRequestReachesTheSubscriber() async {
    let broker = ResumeBroker()
    let stream = await broker.requests()
    await broker.request(ResumeRequest(sessionId: "s-1"))

    var seen: ResumeRequest?
    for await r in stream {
        seen = r
        break
    }
    #expect(seen?.sessionId == "s-1")
}

// The whole reason this is not ConfirmationBroker: `request` must not
// suspend until something happens to the request, because the caller is
// an MCP handler whose process is about to be replaced by the very swap
// it is asking for. It parks and returns.
@Test func requestDoesNotWaitForTheRequestToBeHandled() async {
    let broker = ResumeBroker()
    _ = await broker.requests()          // a subscriber that never drains
    await broker.request(ResumeRequest(sessionId: "s-1"))
    await broker.request(ResumeRequest(sessionId: "s-2"))
    // Reaching here at all is the assertion: neither call blocked.
    #expect(Bool(true))
}

@Test func requestsBeforeAnySubscriberAreNotLost() async {
    let broker = ResumeBroker()
    await broker.request(ResumeRequest(sessionId: "s-early"))
    let stream = await broker.requests()
    var seen: [String] = []
    for await r in stream {
        seen.append(r.sessionId)
        break
    }
    #expect(seen == ["s-early"])
}

// `requests()` now enforces a single consumer (see its doc comment) rather
// than fanning every request out to however many subscribers happen to be
// live. This project's Swift Testing setup cannot catch the
// `preconditionFailure` a second call trips, so this does not attempt that
// — instead it exercises the property the single-continuation storage
// exists to guarantee: the one subscriber there is sees every request, in
// order, none dropped and none duplicated.
@Test func theSoleSubscriberReceivesEveryRequest() async {
    let broker = ResumeBroker()
    let stream = await broker.requests()
    await broker.request(ResumeRequest(sessionId: "s-1"))
    await broker.request(ResumeRequest(sessionId: "s-2"))

    var seen: [String] = []
    var iterator = stream.makeAsyncIterator()
    seen.append((await iterator.next())?.sessionId ?? "<none>")
    seen.append((await iterator.next())?.sessionId ?? "<none>")
    #expect(seen == ["s-1", "s-2"])
}

// Fix round 2, finding: `clearContinuation()` used to nil `continuation`
// on termination without ever setting anything that stops `request(_:)`
// from falling back to buffering — so once the sole subscriber's stream
// ended, every later request queued in a buffer nothing could ever drain
// (the gate forbids a second `requests()` call, so there is no possible
// future drain). This exercises the fix: terminate the stream by
// cancelling the task that's consuming it (verified separately that Swift
// honours this — cancelling a task suspended in `AsyncStream.next()` makes
// it return and fires `onTermination(.cancelled)`), then confirm a request
// made afterwards does not accumulate in the buffer.
@Test func requestsAfterTheSoleSubscriberIsGoneAreDroppedNotHoarded() async {
    let broker = ResumeBroker()
    let stream = await broker.requests()

    let consumer = Task {
        for await _ in stream {}
    }
    consumer.cancel()
    _ = await consumer.value

    // `onTermination` dispatches `clearContinuation()` via `Task { await
    // self?.clearContinuation() }` from off this actor, so it is not
    // ordered against `consumer.value` resolving. Poll rather than assume
    // it has already landed — same idiom `ConfirmationBrokerTests` uses to
    // wait for a continuation to actually park before acting on it.
    while await !broker.hasLostItsSubscriber() { await Task.yield() }

    await broker.request(ResumeRequest(sessionId: "s-after"))
    #expect(await broker.bufferedRequestCount() == 0)
}
