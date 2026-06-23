import SwiftUI

// Full-screen voice-call UI (in-app). CallKit/VoIP push (ring when closed) is a
// later follow-up; this covers in-app outgoing / incoming / active calls.
struct CallView: View {
    private var call = CallService.shared

    private var statusText: String {
        switch call.state {
        case .outgoing: return "Calling…"
        case .incoming: return "Incoming call"
        case .active:   return "Connected"
        case .ended:    return "Call ended"
        case .idle:     return ""
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                AvatarView(name: call.otherName, photoUrl: call.otherPhotoUrl, size: 120)
                Text(call.otherName).font(.title.weight(.bold)).foregroundStyle(.white)
                Label("End-to-end encrypted", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
                Text(statusText).font(.headline).foregroundStyle(.white.opacity(0.85)).padding(.top, 4)
                Spacer()
                controls.padding(.bottom, 50)
            }
            .padding()
        }
    }

    @ViewBuilder private var controls: some View {
        if call.state == .incoming {
            HStack(spacing: 70) {
                circle("phone.down.fill", .red) { call.hangUp() }
                circle("phone.fill", .green) { call.answer() }
            }
        } else {
            circle("phone.down.fill", .red) { call.hangUp() }
        }
    }

    private func circle(_ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 70, height: 70)
                .background(color, in: Circle())
        }
    }
}
