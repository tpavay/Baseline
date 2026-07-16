import CoreGraphics
import CoreImage
import Foundation
import Vision

enum ForegroundExtractionError: Error {
    case invalidArguments
    case unreadableImage
    case noForeground
}

guard CommandLine.arguments.count == 3 else {
    throw ForegroundExtractionError.invalidArguments
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = CIImage(contentsOf: inputURL) else {
    throw ForegroundExtractionError.unreadableImage
}

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(ciImage: image)
try handler.perform([request])

guard let observation = request.results?.first else {
    throw ForegroundExtractionError.noForeground
}

let maskBuffer = try observation.generateScaledMaskForImage(
    forInstances: observation.allInstances,
    from: handler
)
let mask = CIImage(cvPixelBuffer: maskBuffer)
let transparent = CIImage(color: .clear).cropped(to: image.extent)
let output = image.applyingFilter(
    "CIBlendWithMask",
    parameters: [
        kCIInputBackgroundImageKey: transparent,
        kCIInputMaskImageKey: mask,
    ]
)

let context = CIContext()
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
try context.writePNGRepresentation(
    of: output,
    to: outputURL,
    format: .RGBA8,
    colorSpace: colorSpace
)
