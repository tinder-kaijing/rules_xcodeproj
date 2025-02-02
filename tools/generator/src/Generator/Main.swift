import Darwin
import Foundation
import ZippyJSON
import PathKit

@main
extension Generator {
    /// The entry point for the `generator` tool.
    static func main() {
        let logger = DefaultLogger()

        do {
            let arguments = try parseArguments(CommandLine.arguments)
            let project = try readProject(path: arguments.specPath)
            let rootDirs = try readRootDirectories(path: arguments.rootDirsPath)
            let xccurrentversions = try readXCCurrentVersions(
                path: arguments.xccurrentversionsPath
            )
            let extensionPointIdentifiers = try readExtensionPointIdentifiers(
                path: arguments.extensionPointIdentifiersPath
            )
            let directories = Directories(
                workspace: rootDirs.workspaceDirectory,
                projectRoot: arguments.projectRootDirectory,
                external: rootDirs.externalDirectory,
                bazelOut: rootDirs.bazelOutDirectory,
                internalDirectoryName: "rules_xcodeproj",
                workspaceOutput: arguments.workspaceOutputPath
            )

            try Generator(logger: logger).generate(
                buildMode: arguments.buildMode,
                forFixtures: arguments.forFixtures,
                project: project,
                xccurrentversions: xccurrentversions,
                extensionPointIdentifiers: extensionPointIdentifiers,
                directories: directories,
                outputPath: arguments.outputPath
            )
        } catch {
            logger.logError(error.localizedDescription)
            exit(1)
        }
    }

    struct Arguments {
        let specPath: Path
        let rootDirsPath: Path
        let xccurrentversionsPath: Path
        let extensionPointIdentifiersPath: Path
        let outputPath: Path
        let workspaceOutputPath: Path
        let projectRootDirectory: Path
        let buildMode: BuildMode
        let forFixtures: Bool
    }

    static func parseArguments(_ arguments: [String]) throws -> Arguments {
        guard arguments.count == 9 else {
            throw UsageError(message: """
Usage: \(arguments[0]) <path/to/project.json> <path/to/root_dirs> \
<path/to/xccurrentversions.json> <path/to/extensionPointIdentifiers.json> \
<path/to/output/project.xcodeproj> <workspace/relative/output/path> \
(xcode|bazel) <1 is for fixtures, otherwise 0>
""")
        }

        let workspaceOutput = arguments[6]
        let workspaceOutputComponents = workspaceOutput.split(separator: "/")

        // Generate a relative path to the project root
        // e.g. "examples/ios/iOS App.xcodeproj" -> "../.."
        // e.g. "project.xcodeproj" -> ""
        let projectRoot = (0 ..< (workspaceOutputComponents.count - 1))
            .map { _ in ".." }
            .joined(separator: "/")

        guard
            let buildMode = BuildMode(rawValue: arguments[7])
        else {
            throw UsageError(message: """
ERROR: build_mode wasn't one of the supported values: xcode, bazel
""")
        }

        return Arguments(
            specPath: Path(arguments[1]),
            rootDirsPath: Path(arguments[2]),
            xccurrentversionsPath: Path(arguments[3]),
            extensionPointIdentifiersPath: Path(arguments[4]),
            outputPath: Path(arguments[5]),
            workspaceOutputPath: Path(workspaceOutput),
            projectRootDirectory: Path(projectRoot),
            buildMode: buildMode,
            forFixtures: arguments[8] == "1"
        )
    }

    static func readProject(path: Path) throws -> Project {
        let decoder = ZippyJSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(Project.self, from: try path.read())
        } catch let error as DecodingError {
            // Return a more detailed error message
            throw PreconditionError(message: error.message)
        }
    }

    struct RootDirectories {
        let workspaceDirectory: Path
        let externalDirectory: Path
        let bazelOutDirectory: Path
    }

    static func readRootDirectories(path: Path) throws -> RootDirectories {
        let rootDirs = try path.read(.utf8)
            .split(separator: "\n")
            .map(String.init)

        guard rootDirs.count == 3 else {
            throw UsageError(message: """
The root_dirs_file must contain three lines: one for the workspace directory, \
one for the external repositories directory, and one for the bazel-out \
directory.
""")
        }

        return RootDirectories(
            workspaceDirectory: Path(rootDirs[0]),
            externalDirectory: Path(rootDirs[1]),
            bazelOutDirectory: Path(rootDirs[2])
        )
    }

    static func readXCCurrentVersions(path: Path) throws -> [XCCurrentVersion] {
        let decoder = ZippyJSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(
                [XCCurrentVersion].self,
                from: try path.read()
            )
        } catch let error as DecodingError {
            // Return a more detailed error message
            throw PreconditionError(message: error.message)
        }
    }

    static func readExtensionPointIdentifiers(
        path: Path
    ) throws -> [TargetID: ExtensionPointIdentifier] {
        let decoder = ZippyJSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(
                [TargetID: ExtensionPointIdentifier].self,
                from: try path.read()
            )
        } catch let error as DecodingError {
            // Return a more detailed error message
            throw PreconditionError(message: error.message)
        }
    }
}

private extension DecodingError {
    var message: String {
        guard let context = context else {
            return "An unknown decoding error occurred."
        }

        return """
At codingPath [\(context.codingPathString)]: \(context.debugDescription)
"""
    }

    private var context: Context? {
        switch self {
        case let .typeMismatch(_, context): return context
        case let .valueNotFound(_, context): return context
        case let .keyNotFound(_, context): return context
        case let .dataCorrupted(context): return context
        @unknown default: return nil
        }
    }
}

private extension DecodingError.Context {
    var codingPathString: String {
        return codingPath.map(\.stringValue).joined(separator: ", ")
    }
}
