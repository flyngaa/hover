import SwiftUI

enum BrandColors {
    /// Logo orange (#E8420C)
    static let orange = Color(red: 232 / 255, green: 66 / 255, blue: 12 / 255)

    static let welcomeBackground = Color.black
    /// Dims the (white) logo on the welcome screen to a softer, darker grey
    /// so it doesn't sit so starkly against the black background.
    static let welcomeLogo = Color(white: 0.45)
    static let welcomeLabel = Color(white: 0.52)
    static let welcomeKeyCapFill = Color(white: 0.14)
    static let welcomeKeyCapBorder = Color(white: 0.22)
    static let welcomeKeyCapText = Color(white: 0.58)
}
