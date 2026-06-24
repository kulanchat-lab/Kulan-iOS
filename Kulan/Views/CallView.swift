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
        case .incoming: return "Incoming call…"
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
            VStack(spacing: 0) {
                // Header (inside the safe area, not floating): a top-left back/minimize
                // chevron. Tapping it minimizes the call screen — it never ends the call.
                HStack {
                    Button { call.minimized = true } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)

                VStack(spacing: 14) {
                    Spacer().frame(height: 24)
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
                .padding(.horizontal)
            }
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
            Button { CallKitManager.shared.end() } label: {   // route end through CallKit
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

// Root-level call container: lives above every screen so an active call survives ALL
// navigation (open chats, chat list, settings — anywhere). When minimized it shows a
// top mini bar that PUSHES content down (not a floating overlay); otherwise it presents
// the full call screen. Call state lives in the CallService singleton, so nothing resets.
struct CallContainer<Content: View>: View {
    @ViewBuilder var content: Content
    private var call: CallService { CallService.shared }
    private var isActive: Bool { call.state == .outgoing || call.state == .active }

    var body: some View {
        VStack(spacing: 0) {
            if isActive && call.minimized {
                MiniCallBar()
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { call.minimized = false } }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .animation(.easeInOut(duration: 0.25), value: call.minimized)
        .animation(.easeInOut(duration: 0.25), value: call.state)
        // Full call screen presents above everything; dismissing = minimizing (state kept).
        .fullScreenCover(isPresented: Binding(
            get: { isActive && !call.minimized },
            set: { _ in }
        )) {
            CallView()
        }
    }
}

// WhatsApp / Signal-style mini call bar pinned at the top of the app (40pt). Shows the
// call status, contact name, live duration and a phone icon. Tap to reopen full screen.
struct MiniCallBar: View {
    private var call: CallService { CallService.shared }
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var statusText: String {
        switch call.state {
        case .active:
            if let start = call.connectedDate {
                let s = max(0, Int(now.timeIntervalSince(start)))
                return String(format: "%d:%02d", s / 60, s % 60)
            }
            return "Connected"
        case .outgoing:
            return call.calleeRinging ? "Ringing…" : "Calling…"
        default:
            return ""
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.fill").font(.system(size: 13, weight: .bold))
            Text(call.otherName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(statusText).font(.system(size: 13)).monospacedDigit().opacity(0.9)
            Spacer(minLength: 6)
            Text("Tap to return").font(.system(size: 12)).opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Color.green)
        .onReceive(ticker) { now = $0 }
    }
}
