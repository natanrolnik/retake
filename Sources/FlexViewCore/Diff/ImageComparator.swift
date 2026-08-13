//
//  ImageComparator.swift
//  flexview
//
//  Created by Natan Rolnik on 13-08-2026.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageComparison: Sendable, Equatable {
    public var changedPixels: Int
    public var totalPixels: Int
    public var sizeChanged: Bool

    public var changedPercentage: Double {
        totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels) * 100
    }
}

public enum ImageComparator {
    public enum Error: Swift.Error, CustomStringConvertible {
        case cannotDecode(URL)
        case cannotAllocateContext
        case cannotEncodePNG(URL)

        public var description: String {
            switch self {
            case .cannotDecode(let url): "Could not decode an image at \(url.path)."
            case .cannotAllocateContext: "Could not allocate a bitmap context for comparison."
            case .cannotEncodePNG(let url): "Could not write a PNG to \(url.path)."
            }
        }
    }

    /// Compares two PNGs pixel by pixel and, optionally, writes a delta image.
    ///
    /// Images of different sizes are compared on a shared canvas sized to fit both, with
    /// each anchored top-left. Area covered by only one of them counts as changed.
    ///
    /// - Parameter pixelThreshold: per-channel delta (0-255) below which two pixels are
    ///   considered equal. Absorbs antialiasing jitter; 0 means exact equality.
    @discardableResult
    public static func compare(
        base baseURL: URL,
        head headURL: URL,
        pixelThreshold: UInt8 = 0,
        writingDiffTo diffURL: URL? = nil
    ) throws -> ImageComparison {
        let baseImage = try decode(baseURL)
        let headImage = try decode(headURL)

        let width = max(baseImage.width, headImage.width)
        let height = max(baseImage.height, headImage.height)
        let sizeChanged = baseImage.width != headImage.width || baseImage.height != headImage.height

        let basePixels = try rasterize(baseImage, width: width, height: height)
        let headPixels = try rasterize(headImage, width: width, height: height)

        var changedPixels = 0
        var diffPixels = diffURL == nil ? [] : [UInt8](repeating: 0, count: width * height * 4)

        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            var isDifferent = false
            for channel in 0..<4 where !isDifferent {
                let delta = basePixels[offset + channel].absoluteDifference(to: headPixels[offset + channel])
                if delta > pixelThreshold { isDifferent = true }
            }
            if isDifferent { changedPixels += 1 }

            guard diffURL != nil else { continue }
            if isDifferent {
                // Magenta, fully opaque: reads clearly over both light and dark previews.
                diffPixels[offset] = 255
                diffPixels[offset + 1] = 0
                diffPixels[offset + 2] = 255
                diffPixels[offset + 3] = 255
            } else {
                // Unchanged area stays as a washed out version of head, for context.
                for channel in 0..<3 {
                    let value = Int(headPixels[offset + channel])
                    diffPixels[offset + channel] = UInt8(255 - (255 - value) / 4)
                }
                diffPixels[offset + 3] = headPixels[offset + 3]
            }
        }

        if let diffURL {
            try writePNG(pixels: diffPixels, width: width, height: height, to: diffURL)
        }

        return ImageComparison(
            changedPixels: changedPixels,
            totalPixels: width * height,
            sizeChanged: sizeChanged
        )
    }

    private static func decode(_ url: URL) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw Error.cannotDecode(url)
        }
        return image
    }

    /// Draws an image into a fixed size RGBA8 buffer, anchored top-left.
    private static func rasterize(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let success: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            // CoreGraphics draws from the bottom-left, so offset upward to anchor top-left.
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: height - image.height,
                    width: image.width,
                    height: image.height
                )
            )
            return true
        }
        guard success else { throw Error.cannotAllocateContext }
        return pixels
    }

    private static func writePNG(pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        var pixels = pixels
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            return context.makeImage()
        }
        guard
            let image,
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw Error.cannotEncodePNG(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.cannotEncodePNG(url)
        }
    }
}

private extension UInt8 {
    func absoluteDifference(to other: UInt8) -> UInt8 {
        self > other ? self - other : other - self
    }
}
