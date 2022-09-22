import SwiftUI
import VLCUI

struct OverlayView: View {

    @ObservedObject
    var viewModel: ContentViewModel

    var body: some View {
        VStack {
            HStack(spacing: 5) {
                Text(viewModel.positiveTimeLabel)

                Capsule()
                    .frame(width: 10, height: 2)

                Text(viewModel.negativeTimeLabel)
            }

            HStack {
                Button {
                    viewModel.eventSubject.send(.jumpBackward(15))
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 28, weight: .regular, design: .default))
                }
                .buttonStyle(.plain)

                Button {
                    if viewModel.playerState == .playing {
                        viewModel.eventSubject.send(.pause)
                    } else {
                        viewModel.eventSubject.send(.play)
                    }
                } label: {
                    Group {
                        if viewModel.playerState == .playing {
                            Image(systemName: "pause.circle.fill")
                        } else {
                            Image(systemName: "play.circle.fill")
                        }
                    }
                    .font(.system(size: 28, weight: .heavy, design: .default))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.eventSubject.send(.jumpForward(15))
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 28, weight: .regular, design: .default))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
