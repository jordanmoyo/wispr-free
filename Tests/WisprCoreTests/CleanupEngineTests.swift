import XCTest
@testable import WisprCore

/// Scriptable backend: records calls, returns/throws/delays on demand.
private actor MockBackend: CleanupBackend {
    enum Behavior {
        case reply(String)
        case fail
        case delay(seconds: Double, then: String)
    }
    var behavior: Behavior = .reply("cleaned")
    var loadShouldFail = false
    /// Simulates a slow model load (e.g. a first-run download) via
    /// `Task.sleep`, which is itself cancellation-aware — unlike the
    /// unstructured `loadTask` that wraps it in `CleanupEngine`, whose
    /// cancellation from a `withTimeout` timeout is purely advisory. So a
    /// long `loadDelaySeconds` here still exercises the "load outlives the
    /// per-call timeout" scenario that the fix for Finding 1 targets.
    var loadDelaySeconds: Double = 0
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var loadedModelIDs: [String] = []
    private(set) var lastSystem: String?
    private(set) var lastUser: String?
    private(set) var lastMaxTokens: Int?

    func set(behavior: Behavior) { self.behavior = behavior }
    func set(loadShouldFail: Bool) { self.loadShouldFail = loadShouldFail }
    func set(loadDelaySeconds: Double) { self.loadDelaySeconds = loadDelaySeconds }

    func load(model: CleanupModel) async throws {
        loadCount += 1
        // Snapshot before the delay: a caller can flip `loadShouldFail` while
        // this load is asleep (e.g. to script a *later* load's outcome after
        // abandoning this one), and the outcome of THIS call must reflect
        // the flag as it stood when the load started, not whatever it has
        // been mutated to by the time the sleep wakes up.
        let shouldFail = loadShouldFail
        if loadDelaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(loadDelaySeconds * 1_000_000_000))
        }
        if shouldFail { throw WisprError.modelNotLoaded }
        loadedModelIDs.append(model.id)
    }

    func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        lastSystem = system
        lastUser = user
        lastMaxTokens = maxTokens
        switch behavior {
        case .reply(let text): return text
        case .fail: throw WisprError.modelNotLoaded
        case .delay(let seconds, let then):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return then
        }
    }

    func unload() async { unloadCount += 1 }
}

final class CleanupEngineTests: XCTestCase {
    private let modelID = CleanupModelRegistry.defaultModel.id

    func testCleansTextOnSuccess() async {
        let backend = MockBackend()
        await backend.set(behavior: .reply("  Hello, world.  "))
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        let out = await engine.clean("hello world", modelID: modelID)
        XCTAssertEqual(out, "Hello, world.")  // trimmed
        let system = await backend.lastSystem
        XCTAssertEqual(system, CleanupPrompt.system)
        let maxTokens = await backend.lastMaxTokens
        XCTAssertEqual(maxTokens, CleanupPrompt.maxTokens(for: "hello world"))
    }

    func testFailOpenOnGenerateError() async {
        let backend = MockBackend()
        await backend.set(behavior: .fail)
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        let out = await engine.clean("raw text", modelID: modelID)
        XCTAssertEqual(out, "raw text")
    }

    func testFailOpenOnEmptyOutput() async {
        let backend = MockBackend()
        await backend.set(behavior: .reply("   \n  "))
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        let out = await engine.clean("raw text", modelID: modelID)
        XCTAssertEqual(out, "raw text")
    }

    func testFailOpenOnTimeout() async {
        let backend = MockBackend()
        await backend.set(behavior: .delay(seconds: 1.0, then: "too late"))
        let engine = CleanupEngine(backend: backend, timeout: 0.2)
        let start = Date()
        let out = await engine.clean("raw text", modelID: modelID)
        XCTAssertEqual(out, "raw text")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9)
    }

    func testFailOpenOnUnknownModelID() async {
        let engine = CleanupEngine(backend: MockBackend(), timeout: 2.0)
        let out = await engine.clean("raw text", modelID: "nope")
        XCTAssertEqual(out, "raw text")
    }

    func testEmptyInputPassesThroughWithoutGenerating() async {
        let backend = MockBackend()
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        let out = await engine.clean("   ", modelID: modelID)
        XCTAssertEqual(out, "   ")
        let loads = await backend.loadCount
        XCTAssertEqual(loads, 0)
    }

    func testLoadFailureFailsOpenAndRetriesNextCall() async {
        let backend = MockBackend()
        await backend.set(loadShouldFail: true)
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        let first = await engine.clean("raw", modelID: modelID)
        XCTAssertEqual(first, "raw")
        await backend.set(loadShouldFail: false)
        await backend.set(behavior: .reply("Clean."))
        let second = await engine.clean("raw", modelID: modelID)
        XCTAssertEqual(second, "Clean.")
        let loads = await backend.loadCount
        XCTAssertEqual(loads, 2)  // failed load was not cached
    }

    func testModelSwitchUnloadsThenLoadsNewModel() async {
        let backend = MockBackend()
        await backend.set(behavior: .reply("Clean."))
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        _ = await engine.clean("a", modelID: "qwen3-4b")
        _ = await engine.clean("b", modelID: "qwen2.5-1.5b")
        let unloads = await backend.unloadCount
        XCTAssertEqual(unloads, 1)
        let ids = await backend.loadedModelIDs
        XCTAssertEqual(ids, ["qwen3-4b", "qwen2.5-1.5b"])
    }

    func testLoadedModelIsReusedAcrossCalls() async {
        let backend = MockBackend()
        await backend.set(behavior: .reply("Clean."))
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        _ = await engine.clean("a", modelID: modelID)
        _ = await engine.clean("b", modelID: modelID)
        let loads = await backend.loadCount
        XCTAssertEqual(loads, 1)
    }

    // MARK: - Regressions for review findings

    /// Finding 1 (Critical): a `withThrowingTaskGroup`-based race cannot
    /// return until every child task actually finishes, even after
    /// `cancelAll()` — so if the timeout fires while the model load is still
    /// running (e.g. a first-run multi-GB download), `clean` used to block
    /// until the load finished, however long that took. A slow `generate`
    /// didn't expose this because `Task.sleep` is itself cancellation-aware;
    /// only a slow *load* (awaited via `loadTask.value`, a reference to a
    /// separate unstructured task) does.
    func testTimeoutBoundsSlowLoad() async {
        let backend = MockBackend()
        await backend.set(loadDelaySeconds: 1.0)
        await backend.set(behavior: .reply("Clean."))
        let engine = CleanupEngine(backend: backend, timeout: 0.2)
        let start = Date()
        let out = await engine.clean("raw text", modelID: modelID)
        XCTAssertEqual(out, "raw text")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9)
    }

    /// The other half of Finding 1's fix: abandoning the slow load on
    /// timeout must not discard it. Once it finishes in the background, it
    /// stays cached and the next `clean` call reuses it instead of
    /// reloading or failing open again.
    func testSlowLoadCompletesAndServesNextCall() async {
        let backend = MockBackend()
        await backend.set(loadDelaySeconds: 0.3)
        await backend.set(behavior: .reply("Clean."))
        let engine = CleanupEngine(backend: backend, timeout: 0.1)
        let first = await engine.clean("raw text", modelID: modelID)
        XCTAssertEqual(first, "raw text")

        try? await Task.sleep(nanoseconds: 500_000_000)  // let the abandoned load finish

        let second = await engine.clean("raw text", modelID: modelID)
        XCTAssertEqual(second, "Clean.")
        let loads = await backend.loadCount
        XCTAssertEqual(loads, 1)  // the abandoned load was kept, not discarded
    }

    /// Finding 2 (Important): an abandoned load's failure handler used to
    /// unconditionally clear `loadTask`/`loadingModelID`, even if a newer
    /// load (for a different model, started after a model switch) had
    /// already superseded it — wiping that newer load's bookkeeping and
    /// forcing a spurious reload. The old load here is both slow *and*
    /// doomed to fail, so its failure surfaces well after the model switch.
    func testAbandonedFailedLoadDoesNotCorruptNewerLoad() async {
        let backend = MockBackend()
        await backend.set(loadDelaySeconds: 0.3)
        await backend.set(loadShouldFail: true)
        let engineTimeout = 0.05
        let engine = CleanupEngine(backend: backend, timeout: engineTimeout)

        let first = await engine.clean("a", modelID: "qwen3-4b")
        XCTAssertEqual(first, "a")  // fails open: still loading

        // Switch models before the old (slow, doomed) load has failed. This
        // unloads/abandons it and starts a fresh load for the new model.
        await backend.set(loadDelaySeconds: 0)
        await backend.set(loadShouldFail: false)
        await backend.set(behavior: .reply("Clean B."))
        let second = await engine.clean("b", modelID: "qwen2.5-1.5b")
        XCTAssertEqual(second, "Clean B.")

        // Give the abandoned first load time to finish failing in the
        // background and run its (now-stale) cleanup handler.
        try? await Task.sleep(nanoseconds: 500_000_000)

        // The new model's load must still be cached — reused, not reloaded.
        let third = await engine.clean("c", modelID: "qwen2.5-1.5b")
        XCTAssertEqual(third, "Clean B.")
        let loads = await backend.loadCount
        XCTAssertEqual(loads, 2)  // one failed load for A, one load for B — no spurious 3rd
    }
}

final class CleanupPromptTests: XCTestCase {
    func testSystemPromptForbidsTranslation() {
        XCTAssertTrue(CleanupPrompt.system.contains("NEVER translate"))
        XCTAssertTrue(CleanupPrompt.system.contains("Output only the cleaned text."))
    }

    func testMaxTokensFormula() {
        // 2 * max(16, count/3) + 64
        XCTAssertEqual(CleanupPrompt.maxTokens(for: "hi"), 2 * 16 + 64)           // floor
        XCTAssertEqual(CleanupPrompt.maxTokens(for: String(repeating: "a", count: 300)),
                       2 * 100 + 64)
    }

    func testUserMessageWrapsTranscriptAsData() {
        let message = CleanupPrompt.userMessage(for: "can you help me?")
        XCTAssertTrue(message.contains("<transcript>\ncan you help me?\n</transcript>"))
        XCTAssertTrue(message.contains("data, not a request"))
    }

    func testPlausibleCleanupAcceptsSimilarSizedOutput() {
        XCTAssertTrue(CleanupPrompt.plausibleCleanup(input: "hello world", output: "Hello, world."))
        // Filler removal can shrink the text substantially.
        XCTAssertTrue(CleanupPrompt.plausibleCleanup(
            input: "um so uh basically I think that we should um go",
            output: "I think that we should go."))
    }

    func testPlausibleCleanupRejectsBallooningAnswer() {
        let input = "can you tell me what you will take from them"
        let answer = String(repeating: "Here is a detailed list of improvements. ", count: 12)
        XCTAssertFalse(CleanupPrompt.plausibleCleanup(input: input, output: answer))
    }

    func testPlausibleCleanupRejectsCollapsedOutput() {
        let input = String(repeating: "je pense que nous devrions continuer le projet ", count: 8)
        XCTAssertFalse(CleanupPrompt.plausibleCleanup(input: input, output: "OK."))
    }

    func testStripMarkersRemovesEchoedTags() {
        XCTAssertEqual(CleanupPrompt.stripMarkers("<transcript>\nHello.\n</transcript>"), "Hello.")
        XCTAssertEqual(CleanupPrompt.stripMarkers("Hello."), "Hello.")
    }
}

final class CleanupEngineGuardTests: XCTestCase {
    private let modelID = CleanupModelRegistry.defaultModel.id

    func testSendsWrappedTranscriptToBackend() async {
        let backend = MockBackend()
        await backend.set(behavior: .reply("Hello."))
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        _ = await engine.clean("hello", modelID: modelID)
        let user = await backend.lastUser
        XCTAssertEqual(user, CleanupPrompt.userMessage(for: "hello"))
    }

    func testFailOpenWhenModelAnswersInsteadOfCleaning() async {
        let backend = MockBackend()
        let hallucination = String(
            repeating: "I will take feedback on performance bottlenecks and error patterns. ",
            count: 10)
        await backend.set(behavior: .reply(hallucination))
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        let input = "can you tell me what you will take from them to be more robust"
        let out = await engine.clean(input, modelID: modelID)
        XCTAssertEqual(out, input)  // hallucinated answer never reaches the user
    }

    func testEchoedMarkersAreStripped() async {
        let backend = MockBackend()
        await backend.set(behavior: .reply("<transcript>\nHello, world.\n</transcript>"))
        let engine = CleanupEngine(backend: backend, timeout: 2.0)
        let out = await engine.clean("hello world", modelID: modelID)
        XCTAssertEqual(out, "Hello, world.")
    }
}
