import AppKit
import SwiftUI

struct KeyCap: View {
    let label: String

    private var isWide: Bool { label.count > 2 }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(BrandColors.welcomeKeyCapText)
            .frame(minWidth: isWide ? nil : 22, minHeight: 22)
            .padding(.horizontal, isWide ? 8 : 0)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(BrandColors.welcomeKeyCapFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(BrandColors.welcomeKeyCapBorder, lineWidth: 0.5)
            }
    }
}

struct ShortcutRow<Keys: View>: View {
    let title: String
    @ViewBuilder let keys: () -> Keys

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(BrandColors.welcomeLabel)
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                keys()
            }
        }
        .font(.system(size: 13))
    }
}

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 44) {
                logo

                VStack(spacing: 8) {
                    ShortcutRow(title: "Start Recording") {
                        KeyCap(label: "⌘")
                        KeyCap(label: "6")
                    }

                    ShortcutRow(title: "Stop Recording") {
                        KeyCap(label: "⌘")
                        KeyCap(label: "7")
                    }
                }
                .frame(width: 200)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.welcomeBackground)
    }

    @ViewBuilder
    private var logo: some View {
        if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
                // Tone the white logo down to a darker grey against the black bg.
                .colorMultiply(BrandColors.welcomeLogo)
        }
    }
}
