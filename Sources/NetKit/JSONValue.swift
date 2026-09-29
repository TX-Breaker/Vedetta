import Foundation

/// Tolerant accessors for loosely-typed device JSON (numbers may arrive as strings and vice versa).
public enum JSONAccess {
    public static func dict(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
    public static func array(_ any: Any?) -> [Any]? { any as? [Any] }

    public static func int(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces)) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }

    public static func double(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public static func string(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let i as Int: return String(i)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Follows a key path through nested dictionaries.
    public static func value(_ root: Any?, _ path: String...) -> Any? {
        var cur = root
        for k in path { cur = (cur as? [String: Any])?[k] }
        return cur
    }

    /// TP-Link style lists: `[{"name_1": {...}}, {"name_2": {...}}]` → inner dictionaries.
    public static func flattenKeyedList(_ any: Any?) -> [[String: Any]] {
        guard let list = any as? [Any] else {
            if let d = any as? [String: Any] { return d.values.compactMap { $0 as? [String: Any] } }
            return []
        }
        var out: [[String: Any]] = []
        for item in list {
            guard let d = item as? [String: Any] else { continue }
            let inner = d.values.compactMap { $0 as? [String: Any] }
            if inner.count == d.count, !inner.isEmpty { out.append(contentsOf: inner) } else { out.append(d) }
        }
        return out
    }
}
