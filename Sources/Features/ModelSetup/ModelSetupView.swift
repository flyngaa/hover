import HoverCore
import SwiftUI

/// The first thing a new user sees while the transcription model installs.
/// Auto-starts the download, shows one overall progress bar, and offers Retry
/// on failure. Success dismisses into the normal app with no Continue step —
/// there is no skip.
struct ModelSetupView: View {
    @Environment(ModelSetupController.self) private var modelSetup

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Text("Installing the transcription model")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(BrandColors.welcomeLabel)
                    .multilineTextAlignment(.center)

                Text("Data never leaves your machine.")
                    .font(.system(size: 13))
                    .foregroundStyle(BrandColors.welcomeLabel.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 360)

            statusSection
                .frame(maxWidth: 320)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(BrandColors.welcomeBackground)
        .onAppear {
            modelSetup.startIfNeeded()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch modelSetup.status {
        case .notNeeded:
            EmptyView()
        case .running(let fraction):
            VStack(spacing: 10) {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
                    .tint(BrandColors.orange)
                Text(progressLabel(fraction))
                    .font(.system(size: 12))
                    .foregroundStyle(BrandColors.welcomeLabel.opacity(0.7))
                    .monospacedDigit()
            }
        case .failed(let message):
            VStack(spacing: 14) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(BrandColors.welcomeLabel)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    modelSetup.retry()
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.orange)
            }
        }
    }

    private func progressLabel(_ fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        return "\(percent)%"
    }
}
