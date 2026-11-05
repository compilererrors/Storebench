import CoreGraphics
import Foundation

public struct StorebenchDesign: Decodable, Sendable {
    public struct Appearance: Decodable, Sendable {
        public let id, title, description, scheme: String
        public let highContrast: Bool
        public let tokens, increasedTokens: [String: String]
    }
    public struct ContrastPair: Decodable, Sendable {
        public let foreground, background: String
        public let minimum: Double
    }
    public struct Section: Decodable, Sendable {
        public let key, label, icon, group: String
    }
    public struct Primitive: Decodable, Sendable {
        public let tag: String
        public let attributes: [String: String]

        public func path() throws -> CGPath {
            func number(_ name: String, default value: Double = 0) -> Double { Double(attributes[name] ?? "") ?? value }
            let path = CGMutablePath()
            switch tag {
            case "path": return try SVGIconPath.decode(attributes["d"] ?? "")
            case "circle", "ellipse":
                let x = number("cx"), y = number("cy"), rx = number(tag == "circle" ? "r" : "rx"), ry = number(tag == "circle" ? "r" : "ry")
                path.addEllipse(in: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry))
            case "rect":
                let rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
                path.addRoundedRect(in: rect, cornerWidth: number("rx"), cornerHeight: number("ry", default: number("rx")))
            case "line": path.move(to: CGPoint(x: number("x1"), y: number("y1"))); path.addLine(to: CGPoint(x: number("x2"), y: number("y2")))
            case "polyline", "polygon":
                let points = (attributes["points"] ?? "").split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
                guard points.count >= 4, points.count.isMultiple(of: 2) else { throw Failure.invalidIcon }
                path.move(to: CGPoint(x: points[0], y: points[1]))
                for index in stride(from: 2, to: points.count, by: 2) { path.addLine(to: CGPoint(x: points[index], y: points[index + 1])) }
                if tag == "polygon" { path.closeSubpath() }
            default: throw Failure.invalidIcon
            }
            return path
        }
    }
    public enum Failure: Error { case invalidIcon, missingToken }
    public let schemaVersion: Int
    public let tokens: [String: String]
    public let appearances: [Appearance]
    public let contrastPairs, increasedContrastPairs: [ContrastPair]
    public let layout: [String: Double]
    public let icons: [String: [Primitive]]
    public let sections: [Section]
    public let brandIcon, brandMark, wordmark: Data
    public static let shared: StorebenchDesign = {
        guard let url = Bundle.module.url(forResource: "design", withExtension: "json"),
              let value = try? JSONDecoder().decode(StorebenchDesign.self, from: Data(contentsOf: url)), value.schemaVersion == 1,
              Set(value.appearances.map(\.id)) == Set(AppearanceChoice.allCases.filter { $0 != .system }.map(\.rawValue)),
              value.appearances.allSatisfy({ AppearanceContrast.valid($0.tokens, pairs: $0.highContrast ? value.increasedContrastPairs : value.contrastPairs) && AppearanceContrast.valid($0.increasedTokens, pairs: value.increasedContrastPairs) }) else { preconditionFailure("Shared design resource is missing or fails its contrast contract.") }
        return value
    }()

    public func number(_ name: String) -> Double {
        guard let value = tokens[name] else { preconditionFailure("Shared design token is missing.") }
        if value.hasPrefix("var(--"), value.hasSuffix(")") { return number(String(value.dropFirst(6).dropLast())) }
        guard let number = Double(value.replacingOccurrences(of: "px", with: "")) else { preconditionFailure("Shared design token is not a number.") }
        return number
    }

    public func dimension(_ name: String) -> Double {
        guard let value = layout[name], value.isFinite, value >= 0 else { preconditionFailure("Shared layout measurement is missing.") }
        return value
    }
    public func colorToken(_ name: String, increasedContrast: Bool = false) -> String {
        guard let value = tokens[increasedContrast ? name + "-high" : name] ?? tokens[name], value.hasPrefix("#") else { preconditionFailure("Shared color token is missing.") }
        return value
    }
}

/// SVG endpoint arcs become cubic curves; no font or system-symbol substitution is involved.
private enum SVGIconPath {
    static func decode(_ source: String) throws -> CGPath {
        let expression = try NSRegularExpression(pattern: "[a-zA-Z]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+)(?:[eE][-+]?[0-9]+)?")
        let tokens = expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { String(source[Range($0.range, in: source)!]) }
        let path = CGMutablePath()
        var index = 0, command = "", previous = "", start = CGPoint.zero, point = CGPoint.zero, control = CGPoint.zero
        func take() throws -> Double {
            guard index < tokens.count, let value = Double(tokens[index]), value.isFinite else { throw StorebenchDesign.Failure.invalidIcon }
            index += 1; return value
        }
        func coordinate(relative: Bool, origin: CGPoint) throws -> CGPoint { CGPoint(x: try take() + (relative ? origin.x : 0), y: try take() + (relative ? origin.y : 0)) }
        while index < tokens.count {
            if tokens[index].first?.isLetter == true { command = tokens[index]; index += 1 }
            let relative = command == command.lowercased(), origin = point
            switch command.uppercased() {
            case "M": point = try coordinate(relative: relative, origin: origin); path.move(to: point); start = point; command = relative ? "l" : "L"
            case "L": point = try coordinate(relative: relative, origin: origin); path.addLine(to: point)
            case "H": point.x = try take() + (relative ? origin.x : 0); path.addLine(to: point)
            case "V": point.y = try take() + (relative ? origin.y : 0); path.addLine(to: point)
            case "C":
                let first = try coordinate(relative: relative, origin: origin); control = try coordinate(relative: relative, origin: origin); point = try coordinate(relative: relative, origin: origin)
                path.addCurve(to: point, control1: first, control2: control)
            case "S":
                let first = ["C", "S"].contains(previous) ? CGPoint(x: 2 * origin.x - control.x, y: 2 * origin.y - control.y) : origin
                control = try coordinate(relative: relative, origin: origin); point = try coordinate(relative: relative, origin: origin); path.addCurve(to: point, control1: first, control2: control)
            case "Q", "T":
                control = command.uppercased() == "Q" ? try coordinate(relative: relative, origin: origin) : (["Q", "T"].contains(previous) ? CGPoint(x: 2 * origin.x - control.x, y: 2 * origin.y - control.y) : origin)
                point = try coordinate(relative: relative, origin: origin); path.addQuadCurve(to: point, control: control)
            case "A":
                let rx = try take(), ry = try take(), angle = try take(), large = try take(), sweep = try take()
                guard [0, 1].contains(large), [0, 1].contains(sweep) else { throw StorebenchDesign.Failure.invalidIcon }
                point = try coordinate(relative: relative, origin: origin)
                arc(path, from: origin, to: point, rx: abs(rx), ry: abs(ry), rotation: angle, large: large == 1, sweep: sweep == 1)
            case "Z": path.closeSubpath(); point = start; command = ""
            default: throw StorebenchDesign.Failure.invalidIcon
            }
            previous = command.uppercased()
        }
        guard !path.isEmpty else { throw StorebenchDesign.Failure.invalidIcon }
        return path
    }

    private static func arc(_ path: CGMutablePath, from: CGPoint, to: CGPoint, rx initialRX: Double, ry initialRY: Double, rotation: Double, large: Bool, sweep: Bool) {
        guard from != to else { return }
        guard initialRX > 0, initialRY > 0 else { path.addLine(to: to); return }
        let phi = rotation * .pi / 180, cosine = cos(phi), sine = sin(phi)
        let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
        let x = cosine * dx + sine * dy, y = -sine * dx + cosine * dy
        let scale = max(1, sqrt(x * x / (initialRX * initialRX) + y * y / (initialRY * initialRY)))
        let rx = initialRX * scale, ry = initialRY * scale
        let denominator = rx * rx * y * y + ry * ry * x * x
        let factor = (large == sweep ? -1.0 : 1.0) * sqrt(max(0, (rx * rx * ry * ry - denominator) / denominator))
        let cx = factor * rx * y / ry, cy = -factor * ry * x / rx
        let center = CGPoint(x: cosine * cx - sine * cy + (from.x + to.x) / 2, y: sine * cx + cosine * cy + (from.y + to.y) / 2)
        let first = atan2((y - cy) / ry, (x - cx) / rx), last = atan2((-y - cy) / ry, (-x - cx) / rx)
        var delta = last - first
        if sweep && delta < 0 { delta += 2 * .pi }; if !sweep && delta > 0 { delta -= 2 * .pi }
        let count = max(1, Int(ceil(abs(delta) / (.pi / 2)))), step = delta / Double(count)
        func position(_ t: Double) -> CGPoint { CGPoint(x: center.x + cosine * rx * cos(t) - sine * ry * sin(t), y: center.y + sine * rx * cos(t) + cosine * ry * sin(t)) }
        func tangent(_ t: Double) -> CGPoint { CGPoint(x: -cosine * rx * sin(t) - sine * ry * cos(t), y: -sine * rx * sin(t) + cosine * ry * cos(t)) }
        for segment in 0..<count {
            let a = first + Double(segment) * step, b = a + step, k = 4 / 3 * tan(step / 4)
            let p = position(a), q = position(b), v = tangent(a), w = tangent(b)
            path.addCurve(to: segment == count - 1 ? to : q, control1: CGPoint(x: p.x + k * v.x, y: p.y + k * v.y), control2: CGPoint(x: q.x - k * w.x, y: q.y - k * w.y))
        }
    }
}
