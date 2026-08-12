import HoverCore
import HoverPlatform
import Observation
import SwiftUI

@MainActor @Observable
final class InstallCLIController {
    private let installCLI: InstallCLI?
    private let installer: any CLIWrapperInstalling

    var status: InstallCLIStatus = .notInstalled
    var isInstalling = false
    var errorMessage: String?

    init(
        installCLI: InstallCLI? = try? .live(),
        installer: any CLIWrapperInstalling = PrivilegedCLIWrapperInstaller()
    ) {
        self.installCLI = installCLI
        self.installer = installer
        refresh()
    }

    func refresh() {
        guard let installCLI else {
            status = .needsRepair
            errorMessage = InstallCLIError.unavailableBundleAsset.localizedDescription
            return
        }
        do {
            status = try installCLI.status()
            errorMessage = nil
        } catch {
            status = .needsRepair
            errorMessage = error.localizedDescription
        }
    }

    func install() async {
        guard let installCLI, !isInstalling else { return }
        isInstalling = true
        errorMessage = nil
        do {
            try await installCLI.install(using: installer)
            status = try installCLI.status()
        } catch {
            errorMessage = error.localizedDescription
        }
        isInstalling = false
    }
}

struct InstallCLIView: View {
    let isOnboarding: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var controller = InstallCLIController()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal")
                .font(.system(size: 34))
                .foregroundStyle(BrandColors.orange)

            VStack(spacing: 8) {
                Text(isOnboarding ? "Use Hover from the terminal" : "Install CLI")
                    .font(.title2.weight(.semibold))
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                if isOnboarding {
                    Button(controller.status == .installed ? "Done" : "Not now") {
                        dismiss()
                    }
                }

                if controller.status != .installed {
                    Button(actionTitle) {
                        Task { await controller.install() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isInstalling)
                }
            }

            if controller.isInstalling {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: isOnboarding ? 270 : 240)
        .onAppear { controller.refresh() }
    }

    private var actionTitle: String {
        if controller.isInstalling { return "Installing…" }
        if controller.errorMessage != nil { return "Try again" }
        return "Install"
    }

    private var statusMessage: String {
        switch controller.status {
        case .notInstalled, .needsRepair:
            return "Install hover in /usr/local/bin to use Agent Mode from any terminal."
        case .installed:
            return "The hover command is installed for this copy of Hover."
        case .foreign:
            return
                "A different hover command is installed. Hover can replace it if you choose Install."
        }
    }
}
