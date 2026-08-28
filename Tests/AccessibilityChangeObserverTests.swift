import XCTest
@testable import Beacon

@MainActor
final class AccessibilityChangeObserverTests: XCTestCase {
    func testObserverStreamEmitsBoundedFallbackEvent() async {
        let observer = AccessibilityChangeObserver()
        let events = observer.events(for: Int32.max, fallbackInterval: 0.02)
        var iterator = events.makeAsyncIterator()
        var received: [AccessibilityChangeEvent] = []

        if let first = await iterator.next() { received.append(first) }
        if !received.contains(.fallbackTimer), let second = await iterator.next() { received.append(second) }
        observer.stop()

        XCTAssertTrue(received.contains(.fallbackTimer))
    }
}
