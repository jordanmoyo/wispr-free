import XCTest
@testable import WisprCore

final class DeliveryRulesTests: XCTestCase {
    private let target = "com.example.App"
    private let terminal = "com.apple.Terminal"

    // MARK: - ruleMode

    func testRuleModeNoRulesDefaultsToInsert() {
        XCTAssertEqual(DeliveryPolicy.ruleMode(rules: [], target: target), .insert)
    }

    func testRuleModeReturnsMatchingRuleMode() {
        let rules = [DeliveryRule(bundleID: target, displayName: "App", mode: .copyOnly)]
        XCTAssertEqual(DeliveryPolicy.ruleMode(rules: rules, target: target), .copyOnly)

        let rules2 = [DeliveryRule(bundleID: target, displayName: "App", mode: .insertAndSend)]
        XCTAssertEqual(DeliveryPolicy.ruleMode(rules: rules2, target: target), .insertAndSend)
    }

    func testRuleModeNilTargetDefaultsToInsert() {
        let rules = [DeliveryRule(bundleID: target, displayName: "App", mode: .copyOnly)]
        XCTAssertEqual(DeliveryPolicy.ruleMode(rules: rules, target: nil), .insert)
    }

    func testRuleModeNoMatchDefaultsToInsert() {
        let rules = [DeliveryRule(bundleID: "com.other.App", displayName: "Other", mode: .copyOnly)]
        XCTAssertEqual(DeliveryPolicy.ruleMode(rules: rules, target: target), .insert)
    }

    // MARK: - effectiveMode: frontmost mismatch degrades to copyOnly

    func testEffectiveModeFrontmostMismatchDegradesInsertToCopyOnly() {
        let rules = [DeliveryRule(bundleID: target, displayName: "App", mode: .insert)]
        let mode = DeliveryPolicy.effectiveMode(rules: rules, target: target, frontmost: "com.other.App")
        XCTAssertEqual(mode, .copyOnly)
    }

    func testEffectiveModeFrontmostMismatchDegradesInsertAndSendToCopyOnly() {
        let rules = [DeliveryRule(bundleID: target, displayName: "App", mode: .insertAndSend)]
        let mode = DeliveryPolicy.effectiveMode(rules: rules, target: target, frontmost: "com.other.App")
        XCTAssertEqual(mode, .copyOnly)
    }

    func testEffectiveModeFrontmostNilDegradesToCopyOnlyWhenTargetNonNil() {
        let rules = [DeliveryRule(bundleID: target, displayName: "App", mode: .insert)]
        let mode = DeliveryPolicy.effectiveMode(rules: rules, target: target, frontmost: nil)
        XCTAssertEqual(mode, .copyOnly)
    }

    // MARK: - effectiveMode: terminal degradation

    func testEffectiveModeInsertAndSendOnTerminalDegradesToInsert() {
        let rules = [DeliveryRule(bundleID: terminal, displayName: "Terminal", mode: .insertAndSend)]
        let mode = DeliveryPolicy.effectiveMode(rules: rules, target: terminal, frontmost: terminal)
        XCTAssertEqual(mode, .insert)
    }

    func testEffectiveModeInsertAndSendOnEveryTerminalBundleDegradesToInsert() {
        for bundleID in DeliveryPolicy.terminalBundleIDs {
            let rules = [DeliveryRule(bundleID: bundleID, displayName: "Term", mode: .insertAndSend)]
            let mode = DeliveryPolicy.effectiveMode(rules: rules, target: bundleID, frontmost: bundleID)
            XCTAssertEqual(mode, .insert, "expected insert for \(bundleID)")
        }
    }

    // MARK: - effectiveMode: normal path

    func testEffectiveModeInsertAndSendNormalAppMatchingFrontmostStaysInsertAndSend() {
        let rules = [DeliveryRule(bundleID: target, displayName: "App", mode: .insertAndSend)]
        let mode = DeliveryPolicy.effectiveMode(rules: rules, target: target, frontmost: target)
        XCTAssertEqual(mode, .insertAndSend)
    }

    func testEffectiveModeNilTargetDefaultsToInsert() {
        let rules = [DeliveryRule(bundleID: target, displayName: "App", mode: .copyOnly)]
        let mode = DeliveryPolicy.effectiveMode(rules: rules, target: nil, frontmost: nil)
        XCTAssertEqual(mode, .insert)
    }

    func testEffectiveModeCopyOnlyMatchingFrontmostStaysCopyOnly() {
        let rules = [DeliveryRule(bundleID: target, displayName: "App", mode: .copyOnly)]
        let mode = DeliveryPolicy.effectiveMode(rules: rules, target: target, frontmost: target)
        XCTAssertEqual(mode, .copyOnly)
    }

    // MARK: - terminalBundleIDs contents

    func testTerminalBundleIDsExactSet() {
        XCTAssertEqual(DeliveryPolicy.terminalBundleIDs, [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp",
            "com.github.wez.wezterm",
            "net.kovidgoyal.kitty",
            "co.zeit.hyper",
        ])
    }
}
