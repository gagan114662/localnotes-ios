import XCTest
@testable import LocalNotes

/// Deterministic behaviour tests through public interfaces (no model, no mic needed).
final class ContextualizerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func seg(_ s: TimeInterval, _ text: String) -> Contextualizer.Seg {
        .init(id: UUID(), text: text, start: t0.addingTimeInterval(s), end: t0.addingTimeInterval(s + 4))
    }

    func testTimedSlidesOwnTheSpeechSpokenWhileVisible() {
        let a = Contextualizer.Vis(id: UUID(), text: "# Pricing", capturedAt: t0.addingTimeInterval(10), pageIndex: nil)
        let b = Contextualizer.Vis(id: UUID(), text: "# Next steps", capturedAt: t0.addingTimeInterval(60), pageIndex: nil)
        let segs = [seg(0, "hello everyone"), seg(20, "basic is nine dollars"), seg(70, "book the venue")]
        let ch = Contextualizer().chapters(segments: segs, visuals: [a, b])
        XCTAssertEqual(ch.count, 3)                       // intro (no slide) + 2 slides
        XCTAssertNil(ch[0].visualID)
        XCTAssertEqual(ch[1].visualID, a.id)
        XCTAssertTrue(ch[1].speech.contains("nine dollars"))
        XCTAssertEqual(ch[2].visualID, b.id)
        XCTAssertTrue(ch[2].speech.contains("venue"))
    }

    func testEveryFinalSegmentLandsInExactlyOneChapter() {
        let segs = (0..<50).map { seg(Double($0) * 5, "sentence number \($0) about the plan") }
        let pages = (0..<3).map { Contextualizer.Vis(id: UUID(), text: "Slide \($0)", capturedAt: nil, pageIndex: $0) }
        let ids = Contextualizer().chapters(segments: segs, visuals: pages).flatMap(\.segmentIDs)
        XCTAssertEqual(ids.count, segs.count)
        XCTAssertEqual(Set(ids), Set(segs.map(\.id)))
    }

    func testRuleBasedNotesFindActionItemsAndInventNothing() {
        let ch = Chapter(visualID: nil, visualText: "# Next Steps\nBook the venue", segmentIDs: [],
                         speech: "We need to book the venue next week. The weather was nice. Daniel will finish onboarding by October thirtieth.",
                         start: nil, end: nil)
        let md = RuleBasedNotes.render([ch])
        XCTAssertTrue(md.contains("## Next Steps"))
        XCTAssertTrue(md.contains("- [ ] We need to book the venue next week."))
        XCTAssertTrue(md.contains("- [ ] Daniel will finish onboarding by October thirtieth."))
        XCTAssertFalse(md.contains("- [ ] The weather was nice."))
    }
}
