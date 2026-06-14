import CryptoKit
import Foundation
import Security

/// Pure helpers for the Sign in with Apple nonce, kept free of UIKit/Firebase so the
/// security-critical bits (cryptographic nonce + SHA-256) are unit-testable without hardware
/// or a configured Firebase app. See `AuthService.signInWithApple()` for usage.
enum AppleNonce {

    /// A cryptographically random nonce of `length` characters from an unbiased charset.
    static func random(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] =
            Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var byte: UInt8 = 0
                let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
                guard status == errSecSuccess else {
                    fatalError("Unable to generate nonce: SecRandomCopyBytes failed (OSStatus \(status))")
                }
                return byte
            }
            for random in randoms where remaining > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    /// Lowercase hex SHA-256 digest of `input` — the value sent to Apple as the request nonce.
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
