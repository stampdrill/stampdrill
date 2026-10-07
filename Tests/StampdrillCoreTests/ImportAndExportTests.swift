import Foundation
import Testing
@testable import StampdrillCore
@testable import Stamp

struct CurlExporterTests {
    @Test func buildsAQuotedCommand() throws {
        let request = ResolvedRequest(
            name: "login", method: "POST", url: URL(string: "https://example.com/login?next=/home")!,
            headers: [HTTPField("Content-Type", "application/json"), HTTPField("Authorization", "Bearer s3cr3t")],
            body: Data(#"{"user":"o'neil"}"#.utf8), timeout: 10, secrets: ["s3cr3t"]
        )
        #expect(CurlExporter.command(for: request, masked: true) == #"""
        curl \
          --request POST \
          'https://example.com/login?next=/home' \
          --header 'Content-Type: application/json' \
          --header 'Authorization: Bearer ••••••' \
          --data-raw '{"user":"o'\''neil"}' \
          --location \
          --max-time 10
        """#)
    }
}
