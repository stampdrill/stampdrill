import Testing
@testable import StampdrillCore
import Stamp

struct EnvironmentMatrixTests {
    private let matrix = EnvironmentMatrix(document: Document.parse("""
    dimension application = security, content, messaging
    dimension region = eu, latam, mena
    dimension environment = local, qa, prod

    vars {
      protocol = "http"
      host = localhost(WEB)
    }

    vars environment=local {
      host = localhost(TOMCAT)
      username = secret("test")
    }

    vars environment=prod, region=eu {
      host = "eu.example.com"
    }

    vars environment=prod {
      host = "example.com"
    }
    """), origin: "environment.stamp")

    private func value(_ name: String, _ selection: DimensionSelection) throws -> Value? {
        try Scope(layers: matrix.layers(for: selection), builtins: Builtins.standard).lookup(name)
    }

    @Test func defaultsToFirstValues() {
        #expect(matrix.defaultSelection == ["application": "security", "region": "eu", "environment": "local"])
        #expect(matrix.normalized(["environment": "prod", "region": "nowhere", "extra": "x"])
            == ["application": "security", "environment": "prod"])
    }

    @Test func appliesMatchingSetsBySpecificity() throws {
        #expect(try value("host", ["environment": "local"]) == "localhost:8080")
        #expect(try value("host", ["environment": "prod", "region": "eu"]) == "eu.example.com")
        #expect(try value("host", ["environment": "prod", "region": "mena"]) == "example.com")
        #expect(try value("protocol", ["environment": "prod"]) == "http")
    }

    @Test func anyValueOnlyMatchesUnconstrainedSets() throws {
        #expect(try value("host", [:]) == "localhost")
        #expect(try value("username", [:]) == nil)
    }

    @Test func labelsLayersWithTheirOrigin() {
        let labels = matrix.layers(for: ["environment": "prod", "region": "eu"]).map(\.label)
        #expect(labels == [
            "environment.stamp vars *",
            "environment.stamp vars environment=prod",
            "environment.stamp vars environment=prod, region=eu",
        ])
    }

    @Test func reportsUnknownConditions() {
        let broken = EnvironmentMatrix(document: Document.parse("""
        dimension environment = local
        vars stage=qa {
          a = 1
        }
        vars environment=prod {
          a = 2
        }
        """), origin: "environment.stamp")
        #expect(broken.problems.map(\.message) == ["unknown dimension 'stage'", "'environment' has no value 'prod'"])
    }
}

struct LocalEnvironmentTests {
    @Test func personalVariablesWinOverSharedOnes() throws {
        let workspace = makeWorkspace([
            "environment.stamp": """
            dimension environment = local, prod
            vars environment=prod {
              token = "shared-prod"
              host = "api.example.com"
            }
            """,
            "environment.local.stamp": """
            vars {
              token = "mine"
            }
            """,
            "a.stamp": "GET https://{{host}}",
        ])
        #expect(workspace.requestFiles.map(\.relativePath) == ["a.stamp"])
        let scope = Scope(layers: workspace.environment.layers(for: ["environment": "prod"]), builtins: Builtins.standard)
        #expect(try scope.lookup("token") == "mine")
        #expect(try scope.lookup("host") == "api.example.com")
    }
}
