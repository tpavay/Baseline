import Foundation
import Testing
@testable import Baseline

struct AppleNonceTests {

    @Test func randomHasRequestedLength() {
        #expect(AppleNonce.random(length: 1).count == 1)
        #expect(AppleNonce.random(length: 32).count == 32)
        #expect(AppleNonce.random(length: 100).count == 100)
    }

    @Test func randomDefaultsTo32() {
        #expect(AppleNonce.random().count == 32)
    }

    @Test func randomUsesOnlyAllowedCharacters() {
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = AppleNonce.random(length: 256)
        #expect(nonce.allSatisfy { allowed.contains($0) })
    }

    @Test func randomIsUniqueAcrossCalls() {
        // Collisions across 32-char random strings are astronomically unlikely.
        let nonces = Set((0..<50).map { _ in AppleNonce.random() })
        #expect(nonces.count == 50)
    }

    @Test func sha256MatchesKnownVectors() {
        #expect(AppleNonce.sha256("abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AppleNonce.sha256("")
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256IsLowercaseHexOf64Characters() {
        let digest = AppleNonce.sha256(AppleNonce.random())
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
