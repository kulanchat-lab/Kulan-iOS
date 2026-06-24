import SwiftUI
import UIKit

// Full-screen in-app voice-call UI (native iOS-call feel): blurred contact-photo
// backdrop, big avatar, live duration timer, glass Mute / Speaker / End controls.
// Incoming ringing is handled by the system (CallKit); this is the active/outgoing
// in-app screen.
struct CallView: View {
    private var call = CallService.shared
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var statusText: String {
        switch call.state {
        case .outgoing: return call.calleeRinging ? "Ringing…" : "Calling…"
        case .active:   return durationText
        case .ended:    return "Call ended"
        default:        return ""
        }
    }

    private var durationText: String {
        guard let start = call.connectedDate else { return "Connected" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var bgImage: UIImage? {
        guard let url = call.otherPhotoUrl, !url.isEmpty else { return nil }
        return DecryptedImageCache.shared.object(forKey: url as NSString)
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 14) {
                Spacer().frame(height: 64)
                AvatarView(name: call.otherName, photoUrl: call.otherPhotoUrl, size: 132)
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                Text(call.otherName)
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                Text(statusText)
                    .font(.headline).foregroundStyle(.white.opacity(0.85)).monospacedDigit()
                Label("End-to-end encrypted", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                Spacer()
                controls.padding(.bottom, 48)
            }
            .padding()
        }
        .onReceive(ticker) { now = $0 }
    }

    private var background: some View {
        ZStack {
            if let ui = bgImage {
                Image(uiImage: ui).resizable().scaledToFill()
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.55))
            } else {
                LinearGradient(colors: [Color(hex: 0x202028), .black], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private var controls: some View {
        HStack(spacing: 26) {
            controlButton(call.isMuted ? "mic.slash.fill" : "mic.fill", on: call.isMuted) { call.toggleMute() }
            controlButton(call.isSpeaker ? "speaker.wave.2.fill" : "speaker.fill", on: call.isSpeaker) { call.toggleSpeaker() }
            Button { call.hangUp() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 26)).foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(.red, in: Circle())
            }
        }
    }

    private func controlButton(_ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 66, height: 66)
                .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
    }
}
