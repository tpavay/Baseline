import CoreGraphics
import SwiftUI

enum SVGPathParser {
    static func parse(_ source: String) -> Path? {
        var scanner = Scanner(source)
        let path = CGMutablePath()
        var command: UInt8?

        while scanner.isAtEnd == false {
            if let next = scanner.readCommand() {
                command = next
            }
            guard let activeCommand = command else {
                scanner.advance()
                continue
            }

            switch activeCommand {
            case 77, 109:
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { return nil }
                let point = activeCommand == 109
                    ? offset(path.currentPoint, x: x, y: y)
                    : point(x: x, y: y)
                path.move(to: point)
                command = activeCommand == 109 ? 108 : 76

            case 76, 108:
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { return nil }
                let point = activeCommand == 108
                    ? offset(path.currentPoint, x: x, y: y)
                    : point(x: x, y: y)
                path.addLine(to: point)

            case 67, 99:
                guard let x1 = scanner.readNumber(), let y1 = scanner.readNumber(),
                      let x2 = scanner.readNumber(), let y2 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber()
                else { return nil }
                let origin = path.currentPoint
                let relative = activeCommand == 99
                path.addCurve(
                    to: relative ? offset(origin, x: x, y: y) : point(x: x, y: y),
                    control1: relative ? offset(origin, x: x1, y: y1) : point(x: x1, y: y1),
                    control2: relative ? offset(origin, x: x2, y: y2) : point(x: x2, y: y2)
                )

            case 81, 113:
                guard let x1 = scanner.readNumber(), let y1 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber()
                else { return nil }
                let origin = path.currentPoint
                let relative = activeCommand == 113
                path.addQuadCurve(
                    to: relative ? offset(origin, x: x, y: y) : point(x: x, y: y),
                    control: relative ? offset(origin, x: x1, y: y1) : point(x: x1, y: y1)
                )

            case 65, 97:
                guard let radiusX = scanner.readNumber(), let radiusY = scanner.readNumber(),
                      let rotation = scanner.readNumber(), let largeArc = scanner.readFlag(),
                      let sweep = scanner.readFlag(), let x = scanner.readNumber(),
                      let y = scanner.readNumber()
                else { return nil }
                let origin = path.currentPoint
                let endpoint = activeCommand == 97
                    ? offset(origin, x: x, y: y)
                    : point(x: x, y: y)
                addArc(
                    to: path,
                    from: origin,
                    endpoint: endpoint,
                    radiusX: radiusX,
                    radiusY: radiusY,
                    rotation: rotation,
                    largeArc: largeArc,
                    sweep: sweep
                )

            case 90, 122:
                path.closeSubpath()
                command = nil

            default:
                return nil
            }
        }

        return Path(path)
    }

    private static func offset(_ point: CGPoint, x: Double, y: Double) -> CGPoint {
        CGPoint(x: point.x + CGFloat(x), y: point.y + CGFloat(y))
    }

    private static func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private static func addArc(
        to path: CGMutablePath,
        from start: CGPoint,
        endpoint end: CGPoint,
        radiusX inputRadiusX: Double,
        radiusY inputRadiusY: Double,
        rotation: Double,
        largeArc: Bool,
        sweep: Bool
    ) {
        var radiusX = CGFloat(abs(inputRadiusX))
        var radiusY = CGFloat(abs(inputRadiusY))
        guard radiusX > 0, radiusY > 0, start != end else {
            path.addLine(to: end)
            return
        }

        let phi = CGFloat(rotation) * .pi / 180
        let cosine = cos(phi)
        let sine = sin(phi)
        let deltaX = (start.x - end.x) / 2
        let deltaY = (start.y - end.y) / 2
        let transformedX = cosine * deltaX + sine * deltaY
        let transformedY = -sine * deltaX + cosine * deltaY
        let scale = transformedX * transformedX / (radiusX * radiusX)
            + transformedY * transformedY / (radiusY * radiusY)
        if scale > 1 {
            let multiplier = sqrt(scale)
            radiusX *= multiplier
            radiusY *= multiplier
        }

        let radiusXSquared = radiusX * radiusX
        let radiusYSquared = radiusY * radiusY
        let numerator = max(
            radiusXSquared * radiusYSquared
                - radiusXSquared * transformedY * transformedY
                - radiusYSquared * transformedX * transformedX,
            0
        )
        let denominator = max(
            radiusXSquared * transformedY * transformedY
                + radiusYSquared * transformedX * transformedX,
            .leastNonzeroMagnitude
        )
        let direction: CGFloat = largeArc == sweep ? -1 : 1
        let coefficient = direction * sqrt(numerator / denominator)
        let centerXPrime = coefficient * radiusX * transformedY / radiusY
        let centerYPrime = coefficient * -radiusY * transformedX / radiusX
        let centerX = cosine * centerXPrime - sine * centerYPrime + (start.x + end.x) / 2
        let centerY = sine * centerXPrime + cosine * centerYPrime + (start.y + end.y) / 2

        let startVector = CGPoint(
            x: (transformedX - centerXPrime) / radiusX,
            y: (transformedY - centerYPrime) / radiusY
        )
        let endVector = CGPoint(
            x: (-transformedX - centerXPrime) / radiusX,
            y: (-transformedY - centerYPrime) / radiusY
        )
        let startAngle = atan2(startVector.y, startVector.x)
        var angleDelta = vectorAngle(from: startVector, to: endVector)
        if sweep == false, angleDelta > 0 { angleDelta -= 2 * .pi }
        if sweep, angleDelta < 0 { angleDelta += 2 * .pi }

        let segmentCount = max(Int(ceil(abs(angleDelta) / (.pi / 2))), 1)
        let segmentDelta = angleDelta / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let firstAngle = startAngle + CGFloat(index) * segmentDelta
            let secondAngle = firstAngle + segmentDelta
            let alpha = 4.0 / 3.0 * tan(segmentDelta / 4.0)
            let first = ellipsePoint(
                angle: firstAngle,
                centerX: centerX,
                centerY: centerY,
                radiusX: radiusX,
                radiusY: radiusY,
                cosine: cosine,
                sine: sine
            )
            let second = ellipsePoint(
                angle: secondAngle,
                centerX: centerX,
                centerY: centerY,
                radiusX: radiusX,
                radiusY: radiusY,
                cosine: cosine,
                sine: sine
            )
            let firstDerivative = ellipseDerivative(
                angle: firstAngle,
                radiusX: radiusX,
                radiusY: radiusY,
                cosine: cosine,
                sine: sine
            )
            let secondDerivative = ellipseDerivative(
                angle: secondAngle,
                radiusX: radiusX,
                radiusY: radiusY,
                cosine: cosine,
                sine: sine
            )
            path.addCurve(
                to: second,
                control1: CGPoint(x: first.x + alpha * firstDerivative.x, y: first.y + alpha * firstDerivative.y),
                control2: CGPoint(x: second.x - alpha * secondDerivative.x, y: second.y - alpha * secondDerivative.y)
            )
        }
    }

    private static func vectorAngle(from first: CGPoint, to second: CGPoint) -> CGFloat {
        atan2(first.x * second.y - first.y * second.x, first.x * second.x + first.y * second.y)
    }

    private static func ellipsePoint(
        angle: CGFloat,
        centerX: CGFloat,
        centerY: CGFloat,
        radiusX: CGFloat,
        radiusY: CGFloat,
        cosine: CGFloat,
        sine: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: centerX + cosine * radiusX * cos(angle) - sine * radiusY * sin(angle),
            y: centerY + sine * radiusX * cos(angle) + cosine * radiusY * sin(angle)
        )
    }

    private static func ellipseDerivative(
        angle: CGFloat,
        radiusX: CGFloat,
        radiusY: CGFloat,
        cosine: CGFloat,
        sine: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: -cosine * radiusX * sin(angle) - sine * radiusY * cos(angle),
            y: -sine * radiusX * sin(angle) + cosine * radiusY * cos(angle)
        )
    }
}

private struct Scanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ source: String) {
        bytes = Array(source.utf8)
    }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func advance() {
        if isAtEnd == false { index += 1 }
    }

    mutating func readCommand() -> UInt8? {
        skipSeparators()
        guard isAtEnd == false, isLetter(bytes[index]) else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func readNumber() -> Double? {
        skipSeparators()
        guard isAtEnd == false else { return nil }
        let start = index
        if bytes[index] == 43 || bytes[index] == 45 { index += 1 }
        while isAtEnd == false, isDigit(bytes[index]) { index += 1 }
        if isAtEnd == false, bytes[index] == 46 {
            index += 1
            while isAtEnd == false, isDigit(bytes[index]) { index += 1 }
        }
        if isAtEnd == false, (bytes[index] == 69 || bytes[index] == 101) {
            index += 1
            if isAtEnd == false, (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
            while isAtEnd == false, isDigit(bytes[index]) { index += 1 }
        }
        guard index > start else { return nil }
        return Double(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    mutating func readFlag() -> Bool? {
        skipSeparators()
        guard isAtEnd == false, (bytes[index] == 48 || bytes[index] == 49) else { return nil }
        defer { index += 1 }
        return bytes[index] == 49
    }

    private mutating func skipSeparators() {
        while isAtEnd == false, [9, 10, 13, 32, 44].contains(bytes[index]) { index += 1 }
    }

    private func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
    private func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }
}
