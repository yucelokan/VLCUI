#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension CGSize {

    static func aspectFill(aspectRatio: CGSize, minimumSize: CGSize) -> CGSize {
        // Guard against division by zero
        guard aspectRatio.width > 0, aspectRatio.height > 0 else {
            return minimumSize
        }
        
        var result = minimumSize
        let widthRatio = minimumSize.width / aspectRatio.width
        let heightRatio = minimumSize.height / aspectRatio.height

        if heightRatio > widthRatio {
            result.width = minimumSize.height / aspectRatio.height * aspectRatio.width
        } else if widthRatio > heightRatio {
            result.height = minimumSize.width / aspectRatio.width * aspectRatio.height
        }

        return result
    }

    func scale(other: CGSize) -> CGFloat {
        // Guard against division by zero
        guard other.width > 0, other.height > 0 else {
            return 1
        }
        
        if height > other.height {
            return height / other.height
        } else {
            return width / other.width
        }
    }
}
