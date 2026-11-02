import XCTest
@testable import Strongroom

final class RecoveryTests: XCTestCase {
    private var storage: BlobStorage!
    private let salt = Data(repeating: 9, count: 32)
    private let fast: UInt32 = 1000
    private let patternA = Pattern(dots: [0, 1, 2, 7, 12, 17])
    private let patternB = Pattern(dots: [4, 3, 2, 7, 12, 17])
    private let patternC = Pattern(dots: [20, 21, 22, 17, 12, 7])

    override func setUpWithError() throws {
        storage = try BlobStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storage.root)
    }

    private func create(_ pattern: Pattern) throws -> Vault {
        guard case .notFound(let pending) = try Vault.locate(pattern: pattern, deviceSalt: salt, storage: storage, iterations: fast) else {
            throw VaultError.patternInUse
        }
        return try pending.create()
    }

    private func locate(_ pattern: Pattern) throws -> Vault? {
        if case .found(let vault) = try Vault.locate(pattern: pattern, deviceSalt: salt, storage: storage, iterations: fast) {
            return vault
        }
        return nil
    }

    func testWordlistAndGeneratedPhrase() throws {
        XCTAssertEqual(RecoveryPhrase.wordlist.count, 2048)
        XCTAssertEqual(RecoveryPhrase.wordlist.first, "abandon")
        XCTAssertEqual(RecoveryPhrase.wordlist.last, "zoo")
        let phrase = try RecoveryPhrase.generate()
        let words = phrase.split(separator: " ").map(String.init)
        XCTAssertEqual(words.count, 9)
        XCTAssertTrue(words.allSatisfy { RecoveryPhrase.wordlist.contains($0) })
        XCTAssertNotEqual(phrase, try RecoveryPhrase.generate())
    }

    func testNormalizeAndCustomValidation() {
        XCTAssertEqual(RecoveryPhrase.normalize("  Apple\n banana   CHERRY "), "apple banana cherry")
        XCTAssertThrowsError(try RecoveryPhrase.validateCustom("too short"))
        XCTAssertNoThrow(try RecoveryPhrase.validateCustom("correct horse battery staple"))
    }

    func testRecoverWithPhraseThenChangePattern() async throws {
        let vault = try create(patternA)
        try await vault.importPhoto(Data("secret".utf8))
        try await vault.setRecoveryPhrase("Alpha Bravo  charlie delta echo", iterations: fast)

        guard let recovered = try Vault.recover(phrase: "alpha bravo charlie delta ECHO", storage: storage, iterations: fast) else {
            return XCTFail("phrase should open the vault")
        }
        let recoveredOpened = await recovered.openedHeaderName
        XCTAssertNil(recoveredOpened, "opening by phrase must not treat the recovery header as a pattern header")
        let count = await recovered.items.count
        XCTAssertEqual(count, 1)

        // Simulate "forgot pattern": recovered vault gets pattern B. Recovery header must survive.
        try await recovered.changePattern(to: patternB, deviceSalt: salt, iterations: fast)
        XCTAssertNotNil(try locate(patternB))
        XCTAssertNotNil(try Vault.recover(phrase: "alpha bravo charlie delta echo", storage: storage, iterations: fast))

        // Changing from a pattern-opened vault retires the old pattern.
        let viaB = try XCTUnwrap(try locate(patternB))
        try await viaB.changePattern(to: patternC, deviceSalt: salt, iterations: fast)
        XCTAssertNil(try locate(patternB))
        XCTAssertNotNil(try locate(patternC))
        XCTAssertNil(try Vault.recover(phrase: "wrong words entirely here", storage: storage, iterations: fast))
    }

    func testChangingPhraseRetiresOldOne() async throws {
        let vault = try create(patternA)
        try await vault.setRecoveryPhrase("one two three four five", iterations: fast)
        try await vault.setRecoveryPhrase("six seven eight nine ten", iterations: fast)
        XCTAssertNil(try Vault.recover(phrase: "one two three four five", storage: storage, iterations: fast))
        XCTAssertNotNil(try Vault.recover(phrase: "six seven eight nine ten", storage: storage, iterations: fast))
        let phrase = await vault.snapshot().settings.recoveryPhrase
        XCTAssertEqual(phrase, "six seven eight nine ten")
    }

    func testPatternInUseIsRejected() async throws {
        let a = try create(patternA)
        _ = try create(patternB)
        do {
            try await a.changePattern(to: patternB, deviceSalt: salt, iterations: fast)
            XCTFail("must not take over another vault's pattern")
        } catch VaultError.patternInUse {}
    }

    func testDuressWipeKeepsOnlyItself() async throws {
        let real = try create(patternA)
        try await real.importPhoto(Data("real".utf8))
        try await real.setRecoveryPhrase("real vault phrase words", iterations: fast)
        let decoy = try create(patternB)
        try await decoy.importPhoto(Data("decoy".utf8))
        try await decoy.setRecoveryPhrase("decoy vault phrase words", iterations: fast)
        try await decoy.updateSettings { $0.isDuress = true }

        let opened = try XCTUnwrap(try locate(patternB))
        let removed = try await opened.wipeOtherVaults()
        XCTAssertEqual(removed, 4)  // real: pattern header, recovery header, index, item blob
        XCTAssertNil(try locate(patternA))
        XCTAssertNil(try Vault.recover(phrase: "real vault phrase words", storage: storage, iterations: fast))
        let decoyAgain = try XCTUnwrap(try locate(patternB))
        let count = await decoyAgain.items.count
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(try Vault.recover(phrase: "decoy vault phrase words", storage: storage, iterations: fast))
    }

    func testDestroyRemovesEverything() async throws {
        let vault = try create(patternA)
        try await vault.importPhoto(Data("x".utf8))
        try await vault.setRecoveryPhrase("gone gone gone gone", iterations: fast)
        await vault.destroy()
        XCTAssertEqual(try storage.allNames(), [])
    }
}
