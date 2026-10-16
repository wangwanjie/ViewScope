import Foundation
import ObjectiveC.runtime

// MARK: - 语法树

/// console 参数。
enum ViewScopeConsoleArgument: Equatable {
    case number(Double)
    case bool(Bool)
    case null
    case string(String)
    /// #RRGGBB / #RRGGBBAA，已解析为 sRGB 分量。
    case color(red: Double, green: Double, blue: Double, alpha: Double)
    /// {x, y} / {w, h} / {x, y, w, h} / {top, left, bottom, right}
    case structValue([Double])
    /// @<objectID>
    case objectReference(String)
}

/// 解析后的表达式：`[keyPath "."] message`。
struct ViewScopeConsoleExpression: Equatable {
    /// 依次求值的零参 getter。
    var keyPath: [String]
    /// 最终调用的 selector，例如 "frame"、"setHidden:"、"insertSubview:atIndex:"。
    var selector: String
    var arguments: [ViewScopeConsoleArgument]
}

struct ViewScopeConsoleParseError: Error, Equatable {
    var message: String
}

// MARK: - 解析器

/// 表达式解析器。
///
/// ```
/// expression := [keyPath "."] message
/// keyPath    := identifier ("." identifier)*
/// message    := identifier | (keyword ":" argument)+
/// argument   := number | YES | NO | true | false | nil | "string" | #RRGGBB[AA] | {a, b[, c, d]} | @objectID
/// ```
struct ViewScopeConsoleParser {
    private let characters: [Character]
    private var index = 0

    private init(_ text: String) {
        characters = Array(text)
    }

    static func parse(_ text: String) throws -> ViewScopeConsoleExpression {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard trimmed.isEmpty == false else {
            throw ViewScopeConsoleParseError(message: "empty expression")
        }
        var parser = ViewScopeConsoleParser(trimmed)
        return try parser.parseExpression()
    }

    private var isAtEnd: Bool {
        index >= characters.count
    }

    private var current: Character? {
        isAtEnd ? nil : characters[index]
    }

    private mutating func skipWhitespace() {
        while let character = current, character.isWhitespace {
            index += 1
        }
    }

    private static func isIdentifierHead(_ character: Character) -> Bool {
        character == "_" || character == "$" || (character.isASCII && character.isLetter)
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        isIdentifierHead(character) || (character.isASCII && character.isNumber)
    }

    private mutating func parseIdentifier() throws -> String {
        guard let head = current, Self.isIdentifierHead(head) else {
            throw ViewScopeConsoleParseError(message: "expected an identifier at position \(index + 1)")
        }
        var identifier = ""
        while let character = current, Self.isIdentifierBody(character) {
            identifier.append(character)
            index += 1
        }
        return identifier
    }

    private mutating func parseExpression() throws -> ViewScopeConsoleExpression {
        var keyPath: [String] = []
        while true {
            skipWhitespace()
            let identifier = try parseIdentifier()
            guard let next = current else {
                // 单个标识符：零参消息。
                return ViewScopeConsoleExpression(keyPath: keyPath, selector: identifier, arguments: [])
            }
            if next == "." {
                keyPath.append(identifier)
                index += 1
                continue
            }
            if next == ":" {
                return try parseKeywordMessage(firstKeyword: identifier, keyPath: keyPath)
            }
            throw ViewScopeConsoleParseError(message: "unexpected '\(next)' at position \(index + 1)")
        }
    }

    private mutating func parseKeywordMessage(firstKeyword: String, keyPath: [String]) throws -> ViewScopeConsoleExpression {
        var selector = ""
        var arguments: [ViewScopeConsoleArgument] = []
        var keyword = firstKeyword
        while true {
            // 当前位置是 ":"。
            index += 1
            selector += keyword + ":"
            skipWhitespace()
            arguments.append(try parseArgument())
            skipWhitespace()
            if isAtEnd {
                break
            }
            keyword = try parseIdentifier()
            guard current == ":" else {
                throw ViewScopeConsoleParseError(message: "expected ':' after '\(keyword)'")
            }
        }
        return ViewScopeConsoleExpression(keyPath: keyPath, selector: selector, arguments: arguments)
    }

    private mutating func parseArgument() throws -> ViewScopeConsoleArgument {
        guard let character = current else {
            throw ViewScopeConsoleParseError(message: "missing argument")
        }
        switch character {
        case "\"":
            return .string(try parseString())
        case "#":
            return try parseColor()
        case "{":
            return .structValue(try parseStruct())
        case "@":
            index += 1
            var token = ""
            while let next = current, next.isASCII, next.isLetter || next.isNumber || next == "_" || next == "-" {
                token.append(next)
                index += 1
            }
            guard token.isEmpty == false else {
                throw ViewScopeConsoleParseError(message: "expected an object ID after '@'")
            }
            return .objectReference(token)
        default:
            if Self.isIdentifierHead(character) {
                let word = try parseIdentifier()
                switch word {
                case "YES", "true":
                    return .bool(true)
                case "NO", "false":
                    return .bool(false)
                case "nil", "NULL", "Nil":
                    return .null
                default:
                    throw ViewScopeConsoleParseError(message: "unknown literal '\(word)'")
                }
            }
            return .number(try parseNumber())
        }
    }

    private mutating func parseString() throws -> String {
        // 跳过起始引号。
        index += 1
        var result = ""
        while let character = current {
            index += 1
            if character == "\"" {
                return result
            }
            if character == "\\" {
                guard let escaped = current else {
                    break
                }
                index += 1
                switch escaped {
                case "n":
                    result.append("\n")
                case "t":
                    result.append("\t")
                case "r":
                    result.append("\r")
                default:
                    result.append(escaped)
                }
                continue
            }
            result.append(character)
        }
        throw ViewScopeConsoleParseError(message: "unterminated string")
    }

    private mutating func parseColor() throws -> ViewScopeConsoleArgument {
        var token = "#"
        index += 1
        while let character = current, character.isHexDigit {
            token.append(character)
            index += 1
        }
        guard let rgba = ViewScopeColorParsing.rgba(fromHex: token) else {
            throw ViewScopeConsoleParseError(message: "invalid color '\(token)'")
        }
        return .color(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }

    private mutating func parseStruct() throws -> [Double] {
        // 跳过 "{"。
        index += 1
        var values: [Double] = []
        while true {
            skipWhitespace()
            values.append(try parseNumber())
            skipWhitespace()
            guard let character = current else {
                throw ViewScopeConsoleParseError(message: "unterminated struct literal")
            }
            index += 1
            if character == "}" {
                break
            }
            guard character == "," else {
                throw ViewScopeConsoleParseError(message: "expected ',' or '}' in struct literal")
            }
        }
        guard [2, 4, 6].contains(values.count) else {
            throw ViewScopeConsoleParseError(message: "struct literal needs 2, 4 or 6 numbers")
        }
        return values
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        var token = ""
        if let sign = current, sign == "-" || sign == "+" {
            token.append(sign)
            index += 1
        }
        // 十六进制整数。
        if current == "0", index + 1 < characters.count, characters[index + 1] == "x" || characters[index + 1] == "X" {
            index += 2
            var hex = ""
            while let character = current, character.isHexDigit {
                hex.append(character)
                index += 1
            }
            guard let value = UInt64(hex, radix: 16) else {
                throw ViewScopeConsoleParseError(message: "invalid hex number")
            }
            return token == "-" ? -Double(value) : Double(value)
        }
        while let character = current, character.isASCII, character.isNumber || character == "." || character == "e" || character == "E" || ((character == "-" || character == "+") && (token.last == "e" || token.last == "E")) {
            token.append(character)
            index += 1
        }
        guard let value = Double(token), value.isFinite else {
            index = start
            let found = current.map { String($0) } ?? "end of input"
            throw ViewScopeConsoleParseError(message: "expected a value but found '\(found)'")
        }
        return value
    }
}

// MARK: - 求值器

/// 执行 console 表达式、维护返回对象缓存、提供自动补全。
@MainActor
final class ViewScopeConsoleEvaluator {
    /// 返回对象缓存上限（LRU，强引用）。
    static let cacheLimit = 64
    /// 补全结果上限。
    static let completionLimit = 500

    private var cache: [String: AnyObject] = [:]
    private var cacheOrder: [String] = []

    init() {}

    /// 清空缓存（`stop()` 或会话切换时调用）。
    func reset() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    var cachedObjectCount: Int {
        cache.count
    }

    // MARK: 拒绝列表

    private static let deniedSelectors: Set<String> = [
        "dealloc", "release", "retain", "autorelease", "retainCount", "zone",
        "performSelector:", "performSelector:withObject:", "performSelector:withObject:withObject:",
        "forwardInvocation:", "methodForSelector:", "doesNotRecognizeSelector:",
        "_tryRetain", "_isDeallocating", "allowsWeakReference", "retainWeakReference"
    ]

    /// 遵循 ARC 的所有权命名约定：前缀后面紧跟大写字母、冒号或结尾才算命中，避免误伤 `initialFirstResponder`、`newline` 之类。
    private static let deniedPrefixes = ["init", "new", "copy", "mutableCopy"]

    static func isDenied(selector: String) -> Bool {
        if deniedSelectors.contains(selector) {
            return true
        }
        if selector.hasPrefix("performSelector") {
            return true
        }
        for prefix in deniedPrefixes where selector.hasPrefix(prefix) {
            let rest = selector.dropFirst(prefix.count)
            guard let next = rest.first else {
                return true
            }
            if next == ":" || next.isUppercase {
                return true
            }
        }
        return false
    }

    // MARK: 缓存

    /// 规范化对象 ID（地址统一为不带前导零的小写十六进制）。
    static func canonicalObjectID(_ objectID: String) -> String {
        if let address = ViewScopeNodeIdentity.parseAddress(objectID) {
            return "0x" + String(address, radix: 16, uppercase: false)
        }
        return objectID
    }

    @discardableResult
    func cacheObject(_ object: AnyObject) -> String {
        let objectID = ViewScopeNodeIdentity.address(of: object)
        cache[objectID] = object
        cacheOrder.removeAll { $0 == objectID }
        cacheOrder.append(objectID)
        while cacheOrder.count > Self.cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return objectID
    }

    func cachedObject(for objectID: String) -> AnyObject? {
        let key = Self.canonicalObjectID(objectID)
        guard let object = cache[key] else {
            return nil
        }
        // 命中后移到队尾（最近使用）。
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return object
    }

    // MARK: 目标解析

    func resolveTarget(_ reference: ViewScopeRemoteObjectReference, in context: ViewScopeSnapshotBuilder.ReferenceContext) -> AnyObject? {
        if reference.kind == .returnedObject {
            return cachedObject(for: reference.objectID)
        }
        return ViewScopeConsoleTargetResolver.resolve(reference, in: context)
    }

    /// `@objectID`：先查返回对象缓存，再查当前抓取里的节点对象。
    func resolveObjectReference(_ objectID: String, in context: ViewScopeSnapshotBuilder.ReferenceContext) -> AnyObject? {
        if let object = cachedObject(for: objectID) {
            return object
        }
        guard let address = ViewScopeNodeIdentity.parseAddress(objectID) else {
            return nil
        }
        for reference in context.nodeReferences.values {
            if let object = reference.resolvedObject,
               UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()) == address {
                return object
            }
        }
        return nil
    }

    // MARK: 执行

    func evaluate(
        _ request: ViewScopeConsoleInvokeRequestPayload,
        context: ViewScopeSnapshotBuilder.ReferenceContext,
        language: ViewScopeInterfaceLanguage
    ) -> ViewScopeConsoleInvokeResponsePayload {
        func failure(_ message: String) -> ViewScopeConsoleInvokeResponsePayload {
            ViewScopeConsoleInvokeResponsePayload(
                submittedExpression: request.expression,
                target: request.target,
                errorMessage: message
            )
        }

        guard let target = resolveTarget(request.target, in: context) else {
            return failure(language.text("server.console.target_not_found"))
        }

        let expression: ViewScopeConsoleExpression
        do {
            expression = try ViewScopeConsoleParser.parse(request.expression)
        } catch let error as ViewScopeConsoleParseError {
            return failure(language.text("server.console.parse_error", error.message))
        } catch {
            return failure(language.text("server.console.parse_error", error.localizedDescription))
        }

        for selector in expression.keyPath + [expression.selector] where Self.isDenied(selector: selector) {
            return failure(language.text("server.console.denied_selector", selector))
        }

        guard ViewScopeConsoleInvokerBridge.isAvailable else {
            return failure(language.text("server.console.unavailable"))
        }

        // 依次求值 keyPath。
        var receiver: AnyObject = target
        for segment in expression.keyPath {
            let result = ViewScopeConsoleInvokerBridge.invoke(selector: segment, on: receiver, arguments: [])
            if let error = result.error {
                return failure(language.text("server.console.invocation_failed", error))
            }
            guard let object = result.object else {
                return failure(language.text("server.console.keypath_failed", segment))
            }
            receiver = object
        }

        // 转换参数。
        var arguments: [NSDictionary] = []
        for argument in expression.arguments {
            switch argument {
            case .number(let value):
                arguments.append(["kind": "number", "value": NSNumber(value: value)])
            case .bool(let value):
                arguments.append(["kind": "bool", "value": NSNumber(value: value)])
            case .null:
                arguments.append(["kind": "nil"])
            case .string(let value):
                arguments.append(["kind": "string", "value": value as NSString])
            case .color(let red, let green, let blue, let alpha):
                arguments.append(["kind": "color", "value": [red, green, blue, alpha].map { NSNumber(value: $0) } as NSArray])
            case .structValue(let values):
                arguments.append(["kind": "struct", "value": values.map { NSNumber(value: $0) } as NSArray])
            case .objectReference(let objectID):
                guard let object = resolveObjectReference(objectID, in: context) else {
                    return failure(language.text("server.console.unknown_object", objectID))
                }
                arguments.append(["kind": "object", "value": object])
            }
        }

        let result = ViewScopeConsoleInvokerBridge.invoke(selector: expression.selector, on: receiver, arguments: arguments)
        if let error = result.error {
            return failure(language.text("server.console.invocation_failed", error))
        }

        if result.isVoid {
            return ViewScopeConsoleInvokeResponsePayload(
                submittedExpression: request.expression,
                target: request.target,
                resultDescription: "void"
            )
        }
        guard let object = result.object else {
            return ViewScopeConsoleInvokeResponsePayload(
                submittedExpression: request.expression,
                target: request.target,
                resultDescription: result.valueDescription ?? "nil"
            )
        }

        let description = Self.describe(object)
        var returnedObject: ViewScopeConsoleTargetDescriptor?
        if Self.isValueObject(object) == false {
            let objectID = cacheObject(object)
            let className = NSStringFromClass(type(of: object))
            let displayName = ViewScopeClassNameFormatter.displayName(for: className)
            returnedObject = ViewScopeConsoleTargetDescriptor(
                reference: ViewScopeRemoteObjectReference(
                    captureID: context.captureID,
                    objectID: objectID,
                    kind: .returnedObject,
                    className: className,
                    address: objectID
                ),
                title: "<\(displayName): \(objectID)>",
                subtitle: displayName
            )
        }
        return ViewScopeConsoleInvokeResponsePayload(
            submittedExpression: request.expression,
            target: request.target,
            resultDescription: description,
            returnedObject: returnedObject
        )
    }

    /// 字符串、数字、NSValue 这类“值对象”只显示描述，不进入缓存。
    static func isValueObject(_ object: AnyObject) -> Bool {
        object is NSString || object is NSNumber || object is NSValue
    }

    /// 描述返回值。NSNumber 区分 CFBoolean 与数字（B11），其他对象通过 invoker 安全调用 `description`。
    static func describe(_ object: AnyObject) -> String {
        if let string = object as? NSString {
            return "\"\(string)\""
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        let result = ViewScopeConsoleInvokerBridge.invoke(selector: "description", on: object, arguments: [])
        if let text = result.object as? NSString {
            return String(text)
        }
        return "<\(NSStringFromClass(type(of: object))): \(ViewScopeNodeIdentity.address(of: object))>"
    }

    // MARK: 补全

    func completions(for target: AnyObject, prefix: String?) -> [ViewScopeConsoleCompletion] {
        Self.completions(for: target, prefix: prefix, limit: Self.completionLimit)
    }

    /// 列出目标类继承链（不含 NSObject 本身）的属性与实例方法；属性在前，按 prefix（不区分大小写）过滤。
    static func completions(for target: AnyObject, prefix: String?, limit: Int) -> [ViewScopeConsoleCompletion] {
        let normalizedPrefix = prefix?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var properties: [ViewScopeConsoleCompletion] = []
        var methods: [ViewScopeConsoleCompletion] = []
        var seenProperties = Set<String>()
        var seenMethods = Set<String>()

        func matches(_ name: String) -> Bool {
            normalizedPrefix.isEmpty || name.lowercased().hasPrefix(normalizedPrefix)
        }

        var currentClass: AnyClass? = object_getClass(target)
        while let targetClass = currentClass {
            if targetClass == NSObject.self || class_getSuperclass(targetClass) == nil {
                break
            }
            let className = ViewScopeClassNameFormatter.displayName(for: NSStringFromClass(targetClass))

            var propertyCount: UInt32 = 0
            if let propertyList = class_copyPropertyList(targetClass, &propertyCount) {
                for offset in 0 ..< Int(propertyCount) {
                    let property = propertyList[offset]
                    let name = String(cString: property_getName(property))
                    guard name.hasPrefix("_") == false,
                          matches(name),
                          isDenied(selector: name) == false,
                          seenProperties.insert(name).inserted else {
                        continue
                    }
                    let typeName = property_copyAttributeValue(property, "T").map { pointer -> String in
                        defer {
                            free(pointer)
                        }
                        return readableTypeName(String(cString: pointer))
                    } ?? "id"
                    let isReadOnly = property_copyAttributeValue(property, "R").map { pointer -> Bool in
                        free(pointer)
                        return true
                    } ?? false
                    properties.append(
                        ViewScopeConsoleCompletion(
                            name: name,
                            signature: "@property\(isReadOnly ? " (readonly)" : "") \(typeName) \(name)",
                            isProperty: true,
                            declaringClassName: className
                        )
                    )
                }
                free(propertyList)
            }

            var methodCount: UInt32 = 0
            if let methodList = class_copyMethodList(targetClass, &methodCount) {
                for offset in 0 ..< Int(methodCount) {
                    let method = methodList[offset]
                    let name = NSStringFromSelector(method_getName(method))
                    guard name.hasPrefix("_") == false,
                          name.hasPrefix(".") == false,
                          matches(name),
                          isDenied(selector: name) == false,
                          seenMethods.insert(name).inserted else {
                        continue
                    }
                    methods.append(
                        ViewScopeConsoleCompletion(
                            name: name,
                            signature: methodSignature(name: name, method: method),
                            isProperty: false,
                            declaringClassName: className
                        )
                    )
                }
                free(methodList)
            }

            currentClass = class_getSuperclass(targetClass)
        }

        properties.sort { $0.name < $1.name }
        methods.sort { $0.name < $1.name }
        return Array((properties + methods).prefix(limit))
    }

    private static func methodSignature(name: String, method: Method) -> String {
        let returnPointer = method_copyReturnType(method)
        let returnType = readableTypeName(String(cString: returnPointer))
        free(returnPointer)

        let parts = name.split(separator: ":", omittingEmptySubsequences: true)
        guard name.contains(":") else {
            return "- (\(returnType))\(name)"
        }
        var segments: [String] = []
        for (offset, part) in parts.enumerated() {
            var argumentType = "id"
            if let pointer = method_copyArgumentType(method, UInt32(offset + 2)) {
                argumentType = readableTypeName(String(cString: pointer))
                free(pointer)
            }
            segments.append("\(part):(\(argumentType))")
        }
        return "- (\(returnType))" + segments.joined(separator: " ")
    }

    /// 把类型编码转换为便于阅读的类型名。
    static func readableTypeName(_ encoding: String) -> String {
        var encoding = encoding
        while let first = encoding.first, "rnNoORV".contains(first) {
            encoding.removeFirst()
        }
        guard let first = encoding.first else {
            return "?"
        }
        switch first {
        case "@":
            if encoding == "@?" {
                return "block"
            }
            if encoding.hasPrefix("@\""), encoding.hasSuffix("\""), encoding.count > 3 {
                let name = encoding.dropFirst(2).dropLast()
                if name.hasPrefix("<") {
                    return "id\(name)"
                }
                return "\(name) *"
            }
            return "id"
        case "#":
            return "Class"
        case ":":
            return "SEL"
        case "v":
            return "void"
        case "B":
            return "BOOL"
        case "c":
            return "char"
        case "C":
            return "unsigned char"
        case "s":
            return "short"
        case "S":
            return "unsigned short"
        case "i":
            return "int"
        case "I":
            return "unsigned int"
        case "l":
            return "long"
        case "L":
            return "unsigned long"
        case "q":
            return "NSInteger"
        case "Q":
            return "NSUInteger"
        case "f":
            return "float"
        case "d":
            return "CGFloat"
        case "*":
            return "char *"
        case "{":
            let body = encoding.dropFirst()
            if let equal = body.firstIndex(of: "=") {
                return String(body[..<equal])
            }
            return "struct"
        case "^":
            if encoding.hasPrefix("^{CGColor") {
                return "CGColorRef"
            }
            return "void *"
        default:
            return encoding
        }
    }
}

// MARK: - ObjC 调用桥

/// 通过运行时调用 ObjC 层的 `ViewScopeConsoleInvoker`。
///
/// 采用 `NSClassFromString` + IMP 调用而不是直接引用符号：SwiftPM（独立模块）、CocoaPods（同一模块）、
/// Xcode 工程（无 umbrella 头）三种集成方式下都能工作；类符号由 Bootstrap 的锚点函数引用，保证不会被链接器裁掉。
enum ViewScopeConsoleInvokerBridge {
    struct Result {
        var object: AnyObject?
        var isVoid: Bool
        var valueDescription: String?
        var error: String?
    }

    private typealias InvokeFunction = @convention(c) (AnyObject, Selector, NSString, AnyObject, NSArray) -> Unmanaged<NSDictionary>?

    private static let selector = NSSelectorFromString("invokeSelectorNamed:onTarget:arguments:")

    private static func resolveFunction() -> (AnyClass, InvokeFunction)? {
        guard let invokerClass = NSClassFromString("ViewScopeConsoleInvoker"),
              let method = class_getClassMethod(invokerClass, selector) else {
            return nil
        }
        let implementation = method_getImplementation(method)
        return (invokerClass, unsafeBitCast(implementation, to: InvokeFunction.self))
    }

    static var isAvailable: Bool {
        resolveFunction() != nil
    }

    static func invoke(selector name: String, on target: AnyObject, arguments: [NSDictionary]) -> Result {
        guard let (invokerClass, function) = resolveFunction() else {
            return Result(object: nil, isVoid: false, valueDescription: nil, error: "ViewScopeConsoleInvoker is unavailable")
        }
        guard let dictionary = function(invokerClass, selector, name as NSString, target, arguments as NSArray)?.takeUnretainedValue() else {
            return Result(object: nil, isVoid: false, valueDescription: nil, error: "invoker returned no result")
        }
        if let error = dictionary["error"] as? String {
            return Result(object: nil, isVoid: false, valueDescription: nil, error: error)
        }
        let isVoid = (dictionary["isVoid"] as? NSNumber)?.boolValue ?? false
        let object = dictionary["object"].map { $0 as AnyObject }
        let description = dictionary["description"] as? String
        return Result(object: object, isVoid: isVoid, valueDescription: description, error: nil)
    }
}
