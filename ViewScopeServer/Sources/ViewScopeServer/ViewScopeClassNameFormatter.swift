import Foundation

@_silgen_name("swift_demangle")
private func swift_demangle(
    _ mangledName: UnsafePointer<CChar>?,
    _ mangledNameLength: UInt,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?

public enum ViewScopeClassNameFormatter {
    public static func displayName(for rawClassName: String) -> String {
        let demangled = demangledClassName(from: rawClassName)
        if demangled != rawClassName {
            return normalizedDemangledName(demangled)
        }
        return rawClassName.components(separatedBy: ".").last ?? rawClassName
    }

    public static func demangledClassName(from rawClassName: String) -> String {
        guard looksMangled(rawClassName) else {
            return rawClassName
        }

        return rawClassName.withCString { mangledPointer in
            guard let demangledPointer = swift_demangle(
                mangledPointer,
                UInt(rawClassName.utf8.count),
                nil,
                nil,
                0
            ) else {
                return rawClassName
            }
            defer { free(demangledPointer) }
            return String(cString: demangledPointer)
        }
    }

    public static func normalizedDemangledName(_ demangledClassName: String) -> String {
        guard let moduleRange = demangledClassName.range(of: ".("),
              demangledClassName.hasSuffix(")") else {
            return demangledClassName
        }

        let moduleName = String(demangledClassName[..<moduleRange.lowerBound])
        let innerStart = demangledClassName.index(moduleRange.upperBound, offsetBy: 0)
        let innerEnd = demangledClassName.index(before: demangledClassName.endIndex)
        let inner = String(demangledClassName[innerStart..<innerEnd])
        guard let separatorRange = inner.range(of: " in ") else {
            return demangledClassName
        }

        let typeName = String(inner[..<separatorRange.lowerBound])
        let contextName = String(inner[separatorRange.upperBound...])
        return "\(moduleName).\(typeName) \(contextName)"
    }

    private static func looksMangled(_ value: String) -> Bool {
        value.hasPrefix("_T") || value.hasPrefix("$s") || value.hasPrefix("$S")
    }
}
