import Foundation
import Testing
@testable import WakilKit

@MainActor
@Test func workRunsInTheOrderItWasEnqueuedEvenWhenTheFirstIsSlow() async {
    let chain = SurfaceChain()
    var order: [Int] = []
    chain.enqueue { try? await Task.sleep(nanoseconds: 50_000_000); order.append(1) }
    chain.enqueue { order.append(2) }
    chain.enqueue { order.append(3) }
    await chain.settled()
    #expect(order == [1, 2, 3])
}

@MainActor
@Test func enqueueHandsBackTheWorksResult() async {
    let chain = SurfaceChain()
    let task = chain.enqueue { 42 }
    #expect(await task.value == 42)
}

@MainActor
@Test func settledOnAnEmptyChainReturns() async {
    await SurfaceChain().settled()
}

@MainActor
@Test func focusGenerationsOnlyGoUp() {
    let a = SurfaceChain.nextFocusGeneration()
    let b = SurfaceChain.nextFocusGeneration()
    #expect(b > a)
}
