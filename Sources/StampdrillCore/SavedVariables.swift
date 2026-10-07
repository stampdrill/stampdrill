import Stamp

/// Writes values from `save` statements into `environment.local.stamp`, in the
/// variable set for the dimension values that were selected when they ran.
public enum SavedVariables {
    public static func apply(
        _ values: [(name: String, value: Value)], selection: DimensionSelection, environment: EnvironmentMatrix, to text: String
    ) -> String {
        let conditions = environment.dimensions.compactMap { dimension in
            selection[dimension.name].map { VariableSet.Condition(dimension: dimension.name, values: [$0]) }
        }
        var editor = EnvironmentEditor(text: text)
        for (name, value) in values {
            editor.setVariable(name, source: value.sourceLiteral, where: conditions)
        }
        return editor.text
    }
}
