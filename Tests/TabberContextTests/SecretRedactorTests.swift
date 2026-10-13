import Testing
@testable import TabberContext

@Suite struct SecretRedactorTests {
    private func redact(_ s: String) -> String { SecretRedactor.redact(s) }

    @Test func pemPrivateKey() {
        let text = "here:\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1x\nabc\n-----END RSA PRIVATE KEY-----\nthanks"
        #expect(redact(text) == "here:\n[redacted]\nthanks")
    }

    @Test func truncatedPemKeyIsRedactedToTheEnd() {
        #expect(redact("key -----BEGIN PRIVATE KEY-----\nMIIabc\ndef") == "key [redacted]")
        #expect(redact("-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl") == "[redacted]")
    }

    @Test func cloudAndServiceKeys() {
        #expect(redact("id AKIAIOSFODNN7EXAMPLE ok") == "id [redacted] ok")
        #expect(redact("ASIAY34FZKBOKMUTVV7A") == "[redacted]")
        #expect(redact("use sk-proj-abc123DEF456ghi789JKL now") == "use [redacted] now")
        #expect(redact("sk-ant-api03-AbCdEf123456_ghIJ-klmn") == "[redacted]")
        #expect(redact("stripe sk_live_51H8abcdEFGHijkl") == "stripe [redacted]")
        #expect(redact("ghp_16C7e42F292c6912E7710c838347Ae178B4a done") == "[redacted] done")
        #expect(redact("github_pat_11ABCDEFG0123456789_abcdefghijklmnop") == "[redacted]")
        #expect(redact("token xoxb-1234567890-abcdefghij") == "token [redacted]")
        #expect(redact("AIzaSyA-1234567890abcdefghijklmnopqrstu") == "[redacted]")
    }

    @Test func jwt() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(redact("Cookie: session=\(jwt);") == "Cookie: session=[redacted];")
    }

    @Test func bearerToken() {
        #expect(redact("Authorization: Bearer abcdef0123456789abcdef") == "Authorization: Bearer [redacted]")
    }

    @Test func passwordAssignments() {
        #expect(redact("password: hunter2") == "password: [redacted]")
        #expect(redact("The password: hunter2. Thanks") == "The password: [redacted]. Thanks")
        #expect(redact("DB_PASSWORD=s3cr3t!") == "DB_PASSWORD=[redacted]")
        #expect(redact("passwd=letmein please") == "passwd=[redacted] please")
        #expect(redact("{\"api_key\": \"abcd1234\"}") == "{\"api_key\": [redacted]}")
        #expect(redact("client_secret = 'xyz987'") == "client_secret = [redacted]")
        // Not an assignment.
        #expect(redact("Forgot your password? Reset it here.") == "Forgot your password? Reset it here.")
    }

    @Test func cardNumbers() {
        #expect(redact("Card 4111 1111 1111 1111 exp 12/25") == "Card [redacted] exp 12/25")
        #expect(redact("4111111111111111") == "[redacted]")
        #expect(redact("amex 3782-822463-10005.") == "amex [redacted].")
        #expect(redact("4111 1111 1111 1111 12/25") == "[redacted] 12/25")
        // Luhn fails, wrong prefix, too short, or a phone number: left alone.
        #expect(redact("4111 1111 1111 1112") == "4111 1111 1111 1112")
        #expect(redact("order 1234567890123") == "order 1234567890123")
        #expect(redact("call +1 415 555 0132") == "call +1 415 555 0132")
        #expect(redact("total 1,234,567.89") == "total 1,234,567.89")
    }

    @Test func ibans() {
        #expect(redact("IBAN GB82 WEST 1234 5698 7654 32 thanks") == "IBAN [redacted] thanks")
        #expect(redact("DE89370400440532013000") == "[redacted]")
        #expect(redact("GB00 WEST 1234 5698 7654 32") == "GB00 WEST 1234 5698 7654 32")
    }

    @Test func ordinaryTextIsUntouched() {
        let text = "Let's meet at 3:30 — it costs $25, 50% off. Can't wait! Ref: AB-1234, see https://example.com/a?b=c"
        #expect(redact(text) == text)
        #expect(!SecretRedactor.containsSecret("Hi Sarah, the invoice #10422 is attached."))
    }

    @Test func secretLookingTokens() {
        #expect(SecretRedactor.looksLikeSecretToken("Tr0ub4dor&3"))
        #expect(SecretRedactor.looksLikeSecretToken("a3f5c9e1b2d4f6a8c0e2b4d6f8a0c2e4"))
        #expect(SecretRedactor.looksLikeSecretToken("x8Kq2mPz9LwR4vNt7YbC3dFg"))
        #expect(SecretRedactor.looksLikeSecretToken("AKIAIOSFODNN7EXAMPLE"))
        #expect(!SecretRedactor.looksLikeSecretToken("hunter"))
        #expect(!SecretRedactor.looksLikeSecretToken("fetchUserProfile"))
        #expect(!SecretRedactor.looksLikeSecretToken("https://github.com/org/repo/pull/42?token=abc"))
        #expect(!SecretRedactor.looksLikeSecretToken("chris@example.com"))
        #expect(!SecretRedactor.looksLikeSecretToken("~/Code/tabber/Sources"))
        #expect(!SecretRedactor.looksLikeSecretToken("two words"))
    }

    @Test func validators() {
        #expect(SecretRedactor.luhn("79927398713"))
        #expect(!SecretRedactor.luhn("79927398710"))
        #expect(SecretRedactor.isValidIBAN("FR14 2004 1010 0505 0001 3M02 606"))
        #expect(!SecretRedactor.isValidIBAN("FR15 2004 1010 0505 0001 3M02 606"))
    }
}
