import Foundation

/// Tiny namespace-agnostic XML DOM (element names are local names without prefixes).
public final class XNode: @unchecked Sendable {
    public let name: String
    public var attributes: [String: String]
    public var children: [XNode] = []
    public var text: String = ""
    public weak var parent: XNode?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public func child(_ name: String) -> XNode? { children.first { $0.name == name } }
    public func children(_ name: String) -> [XNode] { children.filter { $0.name == name } }

    /// Follows a path of local names (e.g. "Body", "GetProfilesResponse").
    public func path(_ names: String...) -> XNode? {
        var cur: XNode? = self
        for n in names { cur = cur?.child(n) }
        return cur
    }

    /// Depth-first search for all descendants with the given local name.
    public func descendants(_ name: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.descendants(name))
        }
        return out
    }

    public func first(_ name: String) -> XNode? {
        for c in children {
            if c.name == name { return c }
            if let f = c.first(name) { return f }
        }
        return nil
    }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func attribute(_ localName: String) -> String? {
        if let v = attributes[localName] { return v }
        return attributes.first { $0.key.split(separator: ":").last.map(String.init) == localName }?.value
    }
}

public enum XMLTree {
    public static func parse(_ data: Data) -> XNode? {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { return delegate.root }
        return delegate.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let e = XNode(name: local, attributes: attributeDict)
            e.parent = stack.last
            stack.last?.children.append(e)
            if root == nil { root = e }
            stack.append(e)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}

extension String {
    var xmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
