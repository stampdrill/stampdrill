import Foundation
import Testing
@testable import StampdrillCore

struct SensitiveDataTests {
    private func hidden(_ text: String, secrets: Set<String> = []) -> [String] {
        SensitiveData.ranges(in: text, secrets: secrets).map { (text as NSString).substring(with: $0) }
    }

    @Test func recognisesCredentialNames() {
        for name in ["token", "accessToken", "refresh_token", "X-Auth-Token", "password", "client_secret", "apiKey",
                     "x-api-key", "Authorization", "Set-Cookie", "sessionId", "pwd", "privateKey", "CSRF"] {
            #expect(SensitiveData.isSensitiveName(name), "\(name)")
        }
        for name in ["token_type", "expires_in", "tokenUrl", "passwordPolicy", "username", "email", "id", "Content-Type",
                     "author", "cookieDomain"] {
            #expect(!SensitiveData.isSensitiveName(name), "\(name)")
        }
    }

    @Test func hidesJSONFields() {
        let body = """
        {
          "id": 1,
          "username": "emilys",
          "accessToken": "abc.def-123",
          "refreshToken": "r-456",
          "token_type": "Bearer",
          "pin": 1234,
          "profile": { "password": "p\\"ss" }
        }
        """
        #expect(hidden(body) == ["abc.def-123", "r-456", "1234", #"p\"ss"#])
    }

    @Test func hidesFormsHeadersAndXML() {
        #expect(hidden("grant_type=password&username=ann&password=hunter2&client_secret=s3cr3t") == ["hunter2", "s3cr3t"])
        #expect(hidden("https://example.com/cb?code=1&access_token=xyz987&state=ok") == ["xyz987"])
        #expect(hidden("Content-Type: text/plain\nAuthorization: Basic YW5uOmh1bnRlcjI=\nX-Api-Key: k-1\n") == ["Basic YW5uOmh1bnRlcjI=", "k-1"])
        #expect(hidden("<login><user>ann</user><password>hunter2</password></login>") == ["hunter2"])
    }

    @Test func hidesTokensWhateverTheirName() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"
        #expect(hidden(#"{ "data": "\#(jwt)" }"#) == [jwt])
        #expect(hidden("sent Bearer abcdefgh12345678 to the API") == ["abcdefgh12345678"])
        #expect(hidden("echo: my-own-token and more", secrets: ["my-own-token"]) == ["my-own-token"])
        #expect(SensitiveData.isSensitiveValue(jwt))
        #expect(!SensitiveData.isSensitiveValue("hello"))
    }

    @Test func leavesOrdinaryBodiesAlone() {
        #expect(hidden(#"{ "title": "Tokens and secrets explained", "views": 12 }"#).isEmpty)
        #expect(hidden("").isEmpty)
    }
}
