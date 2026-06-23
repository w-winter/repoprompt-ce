import Foundation

/// Represents a structured "API surface" for a file.
struct FileAPI: Codable {
    // MARK: - Codable Stored Properties

    let filePath: String
    var imports: [String]
    var exports: [String]
    var classes: [ClassInfo]
    var interfaces: [InterfaceInfo]
    var aliases: [TypeAliasInfo]
    var literalUnions: [String]
    var functions: [FunctionInfo]
    var enums: [EnumInfo]
    var globalVars: [VariableInfo]
    var macros: [String]
    let referencedTypes: [String]

    // MARK: - Computed-on-Init Properties

    let apiDescription: String
    let definedTypeNames: Set<String>
    let pathAndImportsDescription: String
    let apiTokenCount: Int

    // MARK: - CodingKeys

    enum CodingKeys: String, CodingKey {
        case filePath, imports, exports, classes, interfaces, aliases,
             literalUnions, functions, enums, globalVars, macros, referencedTypes
    }

    // MARK: - Init

    init(
        filePath: String,
        imports: [String],
        exports: [String] = [],
        classes: [ClassInfo],
        interfaces: [InterfaceInfo] = [],
        aliases: [TypeAliasInfo] = [],
        literalUnions: [String] = [],
        functions: [FunctionInfo],
        enums: [EnumInfo],
        globalVars: [VariableInfo],
        macros: [String],
        referencedTypes: [String]
    ) {
        self.filePath = filePath
        self.imports = imports
        self.exports = exports
        self.classes = classes
        self.interfaces = interfaces
        self.aliases = aliases
        self.literalUnions = literalUnions
        self.functions = functions
        self.enums = enums
        self.globalVars = globalVars
        self.macros = macros
        self.referencedTypes = referencedTypes

        let summary = CodeMapAPIContentFormatter.summarize(
            classes: classes,
            interfaces: interfaces,
            aliases: aliases,
            literalUnions: literalUnions,
            functions: functions,
            enums: enums,
            globalVars: globalVars,
            exports: exports,
            macros: macros
        )
        apiDescription = summary.apiDescription
        definedTypeNames = summary.definedTypeNames

        // Path + import lines
        pathAndImportsDescription = CodeMapAPIContentFormatter.pathAndImportsBlock(displayPath: filePath, imports: imports)

        // Cache token count for performance
        apiTokenCount = summary.apiTokenCount
    }

    // MARK: - Codable

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filePath, forKey: .filePath)
        try c.encode(imports, forKey: .imports)
        try c.encode(exports, forKey: .exports)
        try c.encode(classes, forKey: .classes)
        try c.encode(interfaces, forKey: .interfaces)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(literalUnions, forKey: .literalUnions)
        try c.encode(functions, forKey: .functions)
        try c.encode(enums, forKey: .enums)
        try c.encode(globalVars, forKey: .globalVars)
        try c.encode(macros, forKey: .macros)
        try c.encode(referencedTypes, forKey: .referencedTypes)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            filePath: c.decode(String.self, forKey: .filePath),
            imports: c.decode([String].self, forKey: .imports),
            exports: c.decodeIfPresent([String].self, forKey: .exports) ?? [],
            classes: c.decode([ClassInfo].self, forKey: .classes),
            interfaces: c.decodeIfPresent([InterfaceInfo].self, forKey: .interfaces) ?? [],
            aliases: c.decodeIfPresent([TypeAliasInfo].self, forKey: .aliases) ?? [],
            literalUnions: c.decodeIfPresent([String].self, forKey: .literalUnions) ?? [],
            functions: c.decode([FunctionInfo].self, forKey: .functions),
            enums: c.decode([EnumInfo].self, forKey: .enums),
            globalVars: c.decode([VariableInfo].self, forKey: .globalVars),
            macros: c.decode([String].self, forKey: .macros),
            referencedTypes: c.decode([String].self, forKey: .referencedTypes)
        )
    }

    // MARK: - Utilities

    func getFullAPIDescription() -> String {
        getFullAPIDescription(displayPath: filePath)
    }

    /// Returns the complete API description with a caller-specified display path.
    /// This avoids downstream string replacement when switching between Full/Relative paths.
    func getFullAPIDescription(displayPath: String) -> String {
        let pathAndImports = CodeMapAPIContentFormatter.pathAndImportsBlock(displayPath: displayPath, imports: imports)
        return [pathAndImports, apiDescription].joined()
    }

    /// Estimates the token count for the full rendered API description using the
    /// same display-path-aware header as `getFullAPIDescription(displayPath:)`.
    func estimatedFullAPIDescriptionTokens(displayPath: String) -> Int {
        TokenCalculationService.estimateTokens(for: CodeMapAPIContentFormatter.pathAndImportsBlock(displayPath: displayPath, imports: imports)) + apiTokenCount
    }

    /// Prints the captured API description.
    func printAPI() {
        print(apiDescription)
    }
}
