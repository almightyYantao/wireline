import AppKit
import SwiftUI
import XCTest
@testable import Wireline

/// The in-window modal presenter's pure parts: how a card is sized to the
/// window, the flip pose along the animation, and when Esc closes a dialog.
@MainActor
final class ModalTests: XCTestCase {
    func testCardKeepsItsIdealSizeWhenTheWindowHasRoom() {
        let size = WLModalFit.fit(ideal: CGSize(width: 480, height: 580),
                                  available: ProposedViewSize(width: 1200, height: 800))
        XCTAssertEqual(size, CGSize(width: 480, height: 580))
    }

    func testCardShrinksToTheWindow() {
        // The theme editor in the 600 × 660 Settings window, less the margins.
        let size = WLModalFit.fit(ideal: CGSize(width: 640, height: 600),
                                  available: ProposedViewSize(width: 560, height: 560))
        XCTAssertEqual(size, CGSize(width: 560, height: 560))
    }

    func testUnspecifiedRoomKeepsTheIdealSize() {
        let size = WLModalFit.fit(ideal: CGSize(width: 400, height: 220), available: .unspecified)
        XCTAssertEqual(size, CGSize(width: 400, height: 220))
    }

    func testFlipStartsTiltedSmallAndClear() {
        let pose = WLFlipEffect.pose(0)
        XCTAssertEqual(pose.angle, -WLFlipEffect.tilt)
        XCTAssertEqual(pose.scale, WLFlipEffect.startScale, accuracy: 1e-9)
        XCTAssertEqual(pose.opacity, 0)
    }

    func testFlipEndsFlatFullSizeAndOpaque() {
        let pose = WLFlipEffect.pose(1)
        XCTAssertEqual(pose.angle, 0)
        XCTAssertEqual(pose.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(pose.opacity, 1)
    }

    func testFlipIsSolidBeforeItIsFlat() {
        // Opacity runs ahead of the turn: no ghost card halfway through.
        let pose = WLFlipEffect.pose(0.5)
        XCTAssertEqual(pose.opacity, 1)
        XCTAssertEqual(pose.angle, -WLFlipEffect.tilt / 2, accuracy: 1e-9)
    }

    func testSpringOvershootTipsPastFlatAndStaysOpaque() {
        let pose = WLFlipEffect.pose(1.04)
        XCTAssertGreaterThan(pose.angle, 0)
        XCTAssertGreaterThan(pose.scale, 1)
        XCTAssertEqual(pose.opacity, 1)
    }

    func testEscapeClosesTheTopDialog() {
        XCTAssertTrue(WLModalRegistry.closesOnEscape(keyCode: 53, modifiers: [], composing: false, escapeCloses: true))
        // Caps Lock / function-key flags don't count as modifiers.
        XCTAssertTrue(WLModalRegistry.closesOnEscape(keyCode: 53, modifiers: [.capsLock, .function],
                                                     composing: false, escapeCloses: true))
    }

    func testEscapeLeavesInputMethodsAndPalettesAlone() {
        // Mid-composition (pinyin, kana) Esc cancels the marked text instead.
        XCTAssertFalse(WLModalRegistry.closesOnEscape(keyCode: 53, modifiers: [], composing: true, escapeCloses: true))
        // ⌘K / ⌘P step back out of a sub-page on Esc themselves.
        XCTAssertFalse(WLModalRegistry.closesOnEscape(keyCode: 53, modifiers: [], composing: false, escapeCloses: false))
    }

    func testOtherKeysAndChordsPassThrough() {
        XCTAssertFalse(WLModalRegistry.closesOnEscape(keyCode: 36, modifiers: [], composing: false, escapeCloses: true))
        XCTAssertFalse(WLModalRegistry.closesOnEscape(keyCode: 53, modifiers: [.command], composing: false, escapeCloses: true))
        XCTAssertFalse(WLModalRegistry.closesOnEscape(keyCode: 53, modifiers: [.option], composing: false, escapeCloses: true))
    }
}
