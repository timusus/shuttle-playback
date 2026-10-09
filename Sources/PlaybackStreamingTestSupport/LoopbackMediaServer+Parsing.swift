import Foundation

extension LoopbackMediaServer {

    /// A complete error or redirect answer: `extra` header lines, then an empty body, or the HTML
    /// page when ``htmlErrorBodies`` is set (and `withPage` allows it).
    func errorAnswer(status: Int, extra: String = "", withPage: Bool = true) -> Data {
        lock.lock()
        let page = withPage && _htmlErrorBodies
        let lower = _lowercasesHeaders
        lock.unlock()
        let html = Data("<!DOCTYPE html><html><body><h1>\(status)</h1><p>Something went wrong.</p></body></html>".utf8)
        var header = "HTTP/1.1 \(status) Answer\r\n\(extra)"
        if page { header += "Content-Type: text/html; charset=utf-8\r\n" }
        header += "Content-Length: \(page ? html.count : 0)\r\nConnection: close\r\n\r\n"
        var out = Data((lower ? Self.lowercasingNames(header) : header).utf8)
        if page { out.append(html) }
        return out
    }

    /// `header` with each field name lower-cased; the status line and values are untouched.
    static func lowercasingNames(_ header: String) -> String {
        header.components(separatedBy: "\r\n").enumerated().map { index, line in
            guard index > 0, let colon = line.firstIndex(of: ":") else { return line }
            return line[..<colon].lowercased() + line[colon...]
        }.joined(separator: "\r\n")
    }

    /// `(status, location)` for `/redirect-<status>-<location>/...`, else nil.
    static func redirectSpec(_ path: String) -> (Int, RedirectLocation)? {
        guard let first = path.split(separator: "/").first, first.hasPrefix("redirect-") else { return nil }
        let parts = first.split(separator: "-")
        guard parts.count == 3, let status = Int(parts[1]), let location = RedirectLocation(rawValue: String(parts[2])) else { return nil }
        return (status, location)
    }

    /// The `Host` header's value, or nil when the request carries none.
    static func parseHost(_ head: String) -> String? {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("host:") {
            return line.dropFirst("host:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The request target of `GET /path HTTP/1.1`, query and all.
    static func parsePath(_ head: String) -> String {
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        return parts.count > 1 ? String(parts[1]) : "/"
    }

    /// `n` for `/redirect/<n>/...`, else nil.
    static func redirectHop(_ path: String) -> Int? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "redirect" else { return nil }
        return Int(parts[1])
    }

    /// The value of header `name` (lowercase), or nil when the request carries none.
    static func parseHeader(_ head: String, _ name: String) -> String? {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("\(name):") {
            return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The start of a `Range` header as sent, before any clamping; nil when there is none.
    static func rawRangeStart(_ head: String) -> Int64? {
        guard let spec = parseHeader(head, "range")?.split(separator: "=").last else { return nil }
        return Int64(spec.split(separator: "-", omittingEmptySubsequences: false).first ?? "")
    }

    /// `bytes=a-b`, `bytes=a-`, or no header at all (the whole body).
    static func parseRange(_ head: String, total: Int64) -> ClosedRange<Int64> {
        let whole: ClosedRange<Int64> = 0...max(total - 1, 0)
        guard let line = head.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("range:")
        }) else { return whole }
        guard let spec = line.split(separator: "=").last else { return whole }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int64(bounds.first ?? "") else { return whole }
        let end = bounds.count > 1 ? Int64(bounds[1]) : nil
        let clampedStart = min(max(start, 0), max(total - 1, 0))
        let clampedEnd = min(end ?? (total - 1), total - 1)
        guard clampedEnd >= clampedStart else { return clampedStart...clampedStart }
        return clampedStart...clampedEnd
    }
}
