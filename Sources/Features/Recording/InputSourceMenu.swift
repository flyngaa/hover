import HoverCore
import SwiftUI

struct InputSourceMenu: View {
    @Environment(RecordingModel.self) private var recording

    var body: some View {
        Menu {
            ForEach(InputSource.allCases) { source in
                Button {
                    recording.inputSource = source
                } label: {
                    if recording.inputSource == source {
                        Label(source.label, systemImage: "checkmark")
                    } else {
                        Text(source.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .foregroundStyle(.white)
                Text(recording.inputSource.label)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .toolbarPill()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.primary)
        .disabled(!recording.canConfigureRecording)
        .help("Which audio to transcribe")
    }
}
