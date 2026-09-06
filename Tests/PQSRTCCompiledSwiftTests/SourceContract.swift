import Foundation

enum SourceContract {
    enum Error: Swift.Error {
        case missingFunction(String)
    }

    static func sourceBody(of functionName: String, in source: String) throws -> String {
        let marker = "func \(functionName)"
        guard let start = source.range(of: marker),
              let openingBrace = source[start.lowerBound...].firstIndex(of: "{") else {
            throw Error.missingFunction(functionName)
        }
        let suffix = source[start.lowerBound...]
        var depth = 0
        for index in suffix.indices[openingBrace...] {
            switch suffix[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(suffix[...index])
                }
            default:
                break
            }
        }
        throw Error.missingFunction(functionName)
    }
}
