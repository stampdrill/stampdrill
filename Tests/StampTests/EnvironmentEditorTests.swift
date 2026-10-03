import Testing
@testable import Stamp

struct EnvironmentEditorTests {
    private let original = """
    # Shared settings

    dimension environment = local, prod

    vars {
      # where the API lives
      host = localhost(TOMCAT)
    }

    vars environment=prod {
      host = "api.example.com"
    }

    """

    @Test func addsAndUpdatesDimensions() {
        var editor = EnvironmentEditor(text: original)
        editor.setDimension("region", values: ["eu", "us"])
        editor.setDimension("environment", values: ["local", "qa", "prod"])
        #expect(editor.text.hasPrefix("""
        # Shared settings

        dimension environment = local, qa, prod
        dimension region = eu, us

        vars {
        """))
    }

    @Test func addsTheFirstDimensionBelowTheHeaderComment() {
        var editor = EnvironmentEditor(text: "# Top\n\nvars {\n  a = 1\n}\n")
        editor.setDimension("user", values: ["emily"])
        #expect(editor.text == "# Top\n\ndimension user = emily\n\nvars {\n  a = 1\n}\n")
    }

    @Test func renamesDimensionsEverywhere() {
        var editor = EnvironmentEditor(text: original)
        editor.renameDimension("environment", to: "stage")
        let document = Document.parse(editor.text)
        #expect(document.dimensions.map(\.name) == ["stage"])
        #expect(document.variableSets[1].conditions == [.init(dimension: "stage", values: ["prod"])])
    }

    @Test func editsVariablesInPlace() {
        var editor = EnvironmentEditor(text: original)
        editor.setVariable("host", source: "localhost(NGINX)", inSetAt: 0)
        editor.setVariable("token", source: "secret(\"abc\")", inSetAt: 0)
        editor.setVariable("greeting", source: "Hello there", inSetAt: 1)
        #expect(editor.text.contains("""
        vars {
          # where the API lives
          host = localhost(NGINX)
          token = secret("abc")
        }

        vars environment=prod {
          host = "api.example.com"
          @greeting = Hello there
        }
        """))
        #expect(Document.parse(editor.text).diagnostics.isEmpty)
    }

    @Test func renamesAndRemovesVariables() {
        var editor = EnvironmentEditor(text: original)
        editor.renameVariable("host", to: "baseHost")
        editor.removeVariable("baseHost", fromSetAt: 1)
        let document = Document.parse(editor.text)
        #expect(document.variableSets.map { $0.declarations.map(\.name) } == [["baseHost"], []])
    }

    @Test func addsAndRemovesSets() {
        var editor = EnvironmentEditor(text: original)
        editor.addSet(conditions: [.init(dimension: "environment", values: ["local"])])
        editor.setVariable("debug", source: "true", inSetAt: 2)
        #expect(editor.text.hasSuffix("""
        vars environment=local {
          debug = true
        }

        """))
        editor.removeSet(at: 1)
        editor.setConditions([.init(dimension: "environment", values: ["local", "prod"])], forSetAt: 1)
        let document = Document.parse(editor.text)
        #expect(document.variableSets.map(\.label) == ["*", "environment=local|prod"])
        #expect(document.diagnostics.isEmpty)
    }
}

struct CombinationEditingTests {
    @Test func createsTheBlockForACombinationOnFirstUse() {
        var editor = EnvironmentEditor(text: """
        dimension env = test, stage
        dimension region = eu, latam

        vars region=latam, env=stage {
          host = "stage.latam"
        }
        """)
        editor.setVariable("timeout", source: "30", where: [.init(dimension: "env", values: ["stage"]), .init(dimension: "region", values: ["latam"])])
        editor.setVariable("host", source: "\"eu\"", where: [.init(dimension: "region", values: ["eu"])])
        let document = Document.parse(editor.text)
        #expect(document.variableSets.map(\.label) == ["region=latam, env=stage", "region=eu"])
        #expect(document.variableSets[0].declarations.map(\.name) == ["host", "timeout"])
    }

    @Test func removesEmptiedBlocks() {
        var editor = EnvironmentEditor(text: "vars env=test {\n  a = 1\n}\n\nvars {\n  b = 2\n}\n")
        editor.removeVariable("a", where: [.init(dimension: "env", values: ["test"])])
        #expect(editor.text == "vars {\n  b = 2\n}\n")
        editor.renameVariable("b", to: "c", where: [])
        #expect(editor.text == "vars {\n  c = 2\n}\n")
    }
}
