import CoreGraphics
import Testing
@testable import Baseline

struct SVGPathParserTests {
    @Test func parsesThePrototypeCommandSetAndCompactArcFlags() throws {
        let path = try #require(
            SVGPathParser.parse("M10 10c5 0 10 5 10 10q5 5 10 0a5 5 0 0110 0l4 6z")
        )

        #expect(path.isEmpty == false)
        #expect(path.boundingRect.width > 30)
        #expect(path.boundingRect.height > 10)
    }

    @Test func supportsRelativeMoveCommandsUsedByTheBackFigure() throws {
        let path = try #require(SVGPathParser.parse("M20 20m5 5l10 0l0 10z"))

        #expect(path.boundingRect == CGRect(x: 25, y: 25, width: 10, height: 10))
    }
}
