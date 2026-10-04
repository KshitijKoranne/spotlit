import SwiftUI
import StoreKit
import StoreKitTest
import XCTest
@testable import Spotlit

@MainActor
final class SpotlitTests: XCTestCase {
    func testPresetSaveName() {
        XCTAssertNil(Presets.saveName("   "))
        XCTAssertNil(Presets.saveName(" demo ")) // built-in, any case
        XCTAssertEqual(Presets.saveName("  My Talk \n"), "My Talk")
    }

    func testHotKeyLabel() {
        XCTAssertEqual(HotKeys.label(value: "1,6144,⌃⌥S"), "⌃⌥S")
        XCTAssertEqual(HotKeys.label(value: "43,6144,⌃⌥,"), "⌃⌥,") // the label may hold a comma
        XCTAssertEqual(HotKeys.label(value: ""), "None")
        XCTAssertEqual(HotKeys.label(value: "1,x,⌃S"), "None")
    }

    func testPaintHexRoundTrip() {
        for hex in Paint.free + ["#123456", "#FE0102"] { XCTAssertEqual(Color(hex: hex).hex, hex) }
        XCTAssertEqual(Paint.colors("g:ocean").count, 2)
        XCTAssertEqual(Paint.colors("#FF0000").count, 1)
    }

    @available(macOS 14.0, *) // SKTestSession.buyProduct(identifier:options:)
    func testStore() async throws {
        let session = try SKTestSession(configurationFileNamed: "Spotlit")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        let store = Store.shared
        await store.refresh()
        XCTAssertFalse(store.isPro)

        // ponytail: the session buys without UI; Product.purchase() waits for a sheet that tests can't answer.
        try await session.buyProduct(identifier: Store.trialID, options: []).finish() // as Store.purchase does
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertTrue(store.trialUsed)
        XCTAssertFalse(store.purchased)
        XCTAssertEqual(try XCTUnwrap(store.trialEndsAt).timeIntervalSinceNow, Store.trialLength, accuracy: 300)

        session.clearTransactions()
        await store.refresh()
        XCTAssertFalse(store.isPro)

        let t = try await session.buyProduct(identifier: Store.proID, options: [])
        await t.finish()
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertTrue(store.purchased)
        try session.refundTransaction(identifier: UInt(t.id))
        // A refund reaches the app a moment later (the app hears it on Transaction.updates).
        for _ in 0..<50 where store.purchased {
            try await Task.sleep(nanoseconds: 100_000_000)
            await store.refresh()
        }
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.purchased)
    }
}
