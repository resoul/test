import Foundation
import Testing
@testable import Flux

@Suite(.serialized, .timeLimit(.minutes(1)))
struct R01Audit {
    @Test func modifyLosesConcurrentIncrement() async {
        let state = CurrentValue(0)
        await R01Hooks.read.arm()
        let first = Task { await state.modify { $0 + 1 } }
        let second = Task { await state.modify { $0 + 1 } }
        await R01Hooks.read.wait(2)
        await R01Hooks.read.release()
        await first.value
        await second.value
        #expect(await state.value == 1)  // Correct atomic result would be 2 (#56).
    }

    @Test func distinctModifyLosesConcurrentIncrement() async {
        let state = CurrentValueDistinct(0)
        await R01Hooks.read.arm()
        let first = Task { await state.modify { $0 + 1 } }
        let second = Task { await state.modify { $0 + 1 } }
        await R01Hooks.read.wait(2)
        await R01Hooks.read.release()
        await first.value
        await second.value
        #expect(await state.value == 1)  // #56, distinct does not make modify atomic.
    }

    @Test func distinctSetEmitsDuplicate() async {
        let state = CurrentValueDistinct(0)
        await R01Hooks.replayed.reset()
        var iterator = state.stream.makeAsyncIterator()
        await R01Hooks.replayed.wait()
        #expect(await iterator.next() == 0)
        await R01Hooks.read.arm()
        let first = Task { await state.set(1) }
        await R01Hooks.read.wait()
        let second = Task { await state.set(1) }
        await R01Hooks.read.wait(2)
        await R01Hooks.read.releaseOne()
        await first.value
        #expect(await iterator.next() == 1)
        await R01Hooks.read.release()
        await second.value
        #expect(await iterator.next() == 1)  // #56: duplicate notification.
    }

    @Test func replayOverwritesNewerState() async {
        let state = CurrentValue(0)
        await R01Hooks.replay.arm()
        await R01Hooks.replayed.reset()
        var iterator = state.stream.makeAsyncIterator()
        await R01Hooks.replay.wait()
        await state.set(1)
        await R01Hooks.replay.release()
        await R01Hooks.replayed.wait()
        #expect(await state.value == 1)
        #expect(await iterator.next() == 0)  // #57: stale replay replaced buffered 1.
    }

    @Test @MainActor func cancelBeforeMainActorDelivery() async {
        await R01Hooks.sinkEnded.reset()
        var values: [Int] = []
        let subscription = Flux.from([1, 2, 3]).sinkOnMain { values.append($0) }
        subscription.cancel()  // Task cannot start until this actor yields.
        await R01Hooks.sinkEnded.wait()
        #expect(values == [1, 2, 3])  // Characterize buffered delivery after cancel.
    }

    @Test func latestCanYieldOldValueAfterSwitch() async {
        let outer = AsyncStream<Int>.makeStream()
        let old = Pipe<Int>()
        let fresh = Pipe<Int>()
        let registered = AsyncStream<Int>.makeStream()
        var registrations = registered.stream.makeAsyncIterator()
        await R01Hooks.latest.arm()
        await R01Hooks.switched.reset()
        var iterator = Flux { outer.stream }
            .flatMapLatest(bufferingPolicy: .bufferingNewest(1)) { id in
                Flux {
                    let stream = (id == 1 ? old : fresh).stream
                    registered.continuation.yield(id)
                    return stream
                }
            }.stream.makeAsyncIterator()
        outer.continuation.yield(1)
        #expect(await registrations.next() == 1)
        old.send(10)
        await R01Hooks.latest.wait()  // Old value passed its cancellation guard.
        outer.continuation.yield(2)
        await R01Hooks.switched.wait(2)  // Replacement has cancelled the old task.
        #expect(await registrations.next() == 2)
        await R01Hooks.latest.release()
        #expect(await iterator.next() == 10)  // Old response still reaches output.
        fresh.send(20)
        #expect(await iterator.next() == 20)
        outer.continuation.finish()
        #expect(await iterator.next() == nil)
        registered.continuation.finish()
    }

    @Test func lateResponseAfterCancellationIsDropped() async {
        let outer = AsyncStream<Int>.makeStream()
        let old = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let fresh = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let registered = AsyncStream<Int>.makeStream()
        let terminated = AsyncStream<Void>.makeStream()
        old.continuation.onTermination = { _ in
            terminated.continuation.yield(())
            terminated.continuation.finish()
        }
        var registrations = registered.stream.makeAsyncIterator()
        await R01Hooks.latest.reset()
        await R01Hooks.switched.reset()
        var iterator = Flux { outer.stream }
            .flatMapLatest(bufferingPolicy: .bufferingNewest(1)) { id in
                Flux {
                    registered.continuation.yield(id)
                    return id == 1 ? old.stream : fresh.stream
                }
            }.stream.makeAsyncIterator()
        outer.continuation.yield(1)
        #expect(await registrations.next() == 1)
        outer.continuation.yield(2)
        await R01Hooks.switched.wait(2)
        #expect(await registrations.next() == 2)
        for await _ in terminated.stream {}
        // A producer ignoring cancellation cannot revive the terminated stream.
        if case .terminated = old.continuation.yield(10) {
        } else {
            Issue.record("Old source accepted a response after termination")
        }
        fresh.continuation.yield(20)
        #expect(await iterator.next() == 20)
        outer.continuation.finish()
        #expect(await iterator.next() == nil)
        registered.continuation.finish()
    }

    @Test @MainActor func cancelDuringMainActorDelivery() async {
        await R01Hooks.sinkEnded.reset()
        var values: [Int] = []
        var subscription: Subscription?
        subscription = Flux.from([1, 2, 3]).sinkOnMain { value in
            values.append(value)
            subscription?.cancel()
        }
        await R01Hooks.sinkEnded.wait()
        #expect(values == [1, 2, 3])  // #58 also occurs after cancellation in callback.
        subscription = nil
    }

    @Test func pipeBufferIsBoundedAndOverflowIsObservable() async {
        let pipe = Pipe<Int>(bufferingPolicy: .bufferingNewest(2))
        var iterator = pipe.stream.makeAsyncIterator()
        #expect(pipe.subscriberCount == 1)
        var dropped: [Int] = []
        for value in 0..<100 {
            for result in pipe.sendObservingOverflow(value) {
                if case .dropped(let old) = result { dropped.append(old) }
            }
        }
        pipe.finish()
        #expect(dropped == Array(0..<98))
        #expect(await iterator.next() == 98)
        #expect(await iterator.next() == 99)
        #expect(await iterator.next() == nil)
        #expect(pipe.subscriberCount == 0)
        #expect(pipe.flux.map { $0 }.inheritedBufferingPolicy == .bufferingNewest(2))
        #expect(CurrentValue(0).flux.map { $0 }.inheritedBufferingPolicy == .bufferingNewest(1))
        #expect(Flux.from([1]).inheritedBufferingPolicy == nil)
    }

    @Test func cancellationReleasesSourceAndBagPrunes() async {
        let pipe = Pipe<Int>()
        let bag = SubscriptionBag()
        await R01Hooks.sinkEnded.reset()
        let subscription = pipe.flux.sink { _ in }
        subscription.store(in: bag)
        #expect(bag.count == 1)
        #expect(pipe.subscriberCount == 1)
        subscription.cancel()
        await R01Hooks.sinkEnded.wait()
        #expect(bag.count == 0)
        #expect(pipe.subscriberCount == 0)
    }

    @Test func bagDeinitCancelsAndReleasesHandle() {
        let pipe = Pipe<Int>()
        weak var weakSubscription: Subscription?
        do {
            let bag = SubscriptionBag()
            let subscription = Subscription { pipe.finish() }
            weakSubscription = subscription
            subscription.store(in: bag)
            #expect(bag.count == 1)
        }
        #expect(weakSubscription == nil)
        #expect(pipe.subscriberCount == 0)
    }
}
