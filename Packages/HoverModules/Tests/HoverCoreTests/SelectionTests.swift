import Testing

@testable import HoverCore

/// The sidebar marking rules are pure value logic in ``Selection``, so the
/// toggle / range / anchor behaviour can be checked directly.
@Suite struct SelectionTests {

    private let ordered = ["a", "b", "c", "d", "e"]

    @Test func toggleAddsRemovesAndSetsAnchor() {
        var sel = Selection()
        sel.toggle("b")
        #expect(sel.markedIDs == ["b"])
        #expect(sel.anchorID == "b")

        sel.toggle("b")
        #expect(sel.markedIDs.isEmpty)
        #expect(sel.anchorID == "b")  // anchor stays put on the last-touched id
    }

    @Test func markAllKeepsExistingAnchor() {
        var sel = Selection()
        sel.markAll(ordered)
        #expect(sel.markedIDs == Set(ordered))
        #expect(sel.anchorID == "a")  // no anchor yet → first

        sel.anchorID = "c"
        sel.markAll(["x", "y"])
        #expect(sel.markedIDs == ["x", "y"])
        #expect(sel.anchorID == "c")  // existing anchor preserved
    }

    @Test func clearEmptiesEverything() {
        var sel = Selection()
        sel.markAll(ordered)
        sel.clear()
        #expect(sel.isEmpty)
        #expect(sel.anchorID == nil)
    }

    @Test func primaryIDOnlyWhenExactlyOne() {
        var sel = Selection()
        #expect(sel.primaryID == nil)
        sel.toggle("b")
        #expect(sel.primaryID == "b")
        sel.toggle("c")
        #expect(sel.primaryID == nil)  // two marked
    }

    @Test func markRangeFromAnchor() {
        var sel = Selection()
        sel.toggle("b")  // anchor b
        sel.markRange(to: "d", in: ordered)
        #expect(sel.markedIDs == ["b", "c", "d"])
        #expect(sel.anchorID == "d")
    }

    @Test func markRangeWorksBackwards() {
        var sel = Selection()
        sel.toggle("d")  // anchor d
        sel.markRange(to: "b", in: ordered)
        #expect(sel.markedIDs == ["b", "c", "d"])
        #expect(sel.anchorID == "b")
    }

    @Test func markRangeFallsBackToFirstMarkedWhenNoAnchor() {
        var sel = Selection()
        sel.markedIDs = ["c"]  // marked but anchor is nil
        sel.markRange(to: "e", in: ordered)
        #expect(sel.markedIDs == ["c", "d", "e"])
        #expect(sel.anchorID == "e")
    }

    @Test func markRangeWithNothingSelectedMarksJustTarget() {
        var sel = Selection()
        sel.markRange(to: "c", in: ordered)
        #expect(sel.markedIDs == ["c"])
        #expect(sel.anchorID == "c")
    }

    @Test func markRangeToUnknownTargetMarksJustTarget() {
        var sel = Selection()
        sel.toggle("b")
        sel.markRange(to: "zzz", in: ordered)
        #expect(sel.markedIDs == ["zzz"])
        #expect(sel.anchorID == "zzz")
    }

    @Test func replaceSwapsIDAndUpdatesAnchor() {
        var sel = Selection()
        sel.toggle("b")  // marked {b}, anchor b
        sel.replace("b", with: "b2")
        #expect(sel.markedIDs == ["b2"])
        #expect(sel.anchorID == "b2")
    }

    @Test func replaceIsNoOpWhenNotMarked() {
        var sel = Selection()
        sel.toggle("b")
        sel.replace("x", with: "y")
        #expect(sel.markedIDs == ["b"])
        #expect(sel.anchorID == "b")
    }

    @Test func unmarkDeletedFixesAnchor() {
        var sel = Selection()
        sel.markAll(["a", "b"])  // anchor a
        sel.unmarkDeleted("a")
        #expect(sel.markedIDs == ["b"])
        #expect(sel.anchorID == "b")  // anchor moved to a remaining id
    }
}
