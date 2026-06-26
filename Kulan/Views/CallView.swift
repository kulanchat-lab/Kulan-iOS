import SwiftUI
import UIKit

// Full-screen in-app voice-call UI (native iOS-call feel): blurred contact-photo
// backdrop, big avatar, live duration timer, glass Mute / Speaker / End controls.
// Incoming ringing is handled by the system (CallKit); this is the active/outgoing
// in-app screen.
struct CallView: View {
    private var call = CallService.shared
    @State private var now = Date()
    @State private var dragY: CGFloat = 0   // live finger offset for swipe-down-to-minimize
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var statusText: String {
        switch call.state {
        case .outgoing:     return call.calleeRinging ? "Ringing…" : "Calling…"
        case .incoming:     return "Incoming call…"
        case .active:       return durationText
        case .reconnecting: return "Reconnecting…"
        case .ended:        return endedText
        default:            return ""
        }
    }

    // Final label, by why the call ended.
    private var endedText: String {
        switch call.endReason {
        case .declined, .busy: return "Declined"
        case .failed:          return "Call failed"
        case .missed:          return "No answer"
        default:               return "Call ended"
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
            if call.isVideo { videoLayer } else { background }
            VStack(spacing: 0) {
                // Header (inside the safe area, not floating): a top-left back/minimize
                // chevron. Tapping it minimizes the call screen — it never ends the call.
                HStack {
                    Button { withAnimation(.easeInOut(duration: 0.25)) { call.minimized = true } } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            // Solid contrasting fill (not translucent material) so the arrow
                            // is reliably visible on ANY backdrop — bright photo or dark gradient.
                            .background(Color.black.opacity(0.4), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(CallControlStyle())
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)

                VStack(spacing: 14) {
                    Spacer().frame(height: 24)
                    if !call.isVideo {
                        AvatarView(name: call.otherName, photoUrl: call.otherPhotoUrl, size: 132)
                            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                    }
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
        // Premium swipe-down-to-minimize (FaceTime/iMessage feel): the whole call screen
        // shrinks, rubber-bands down, rounds its corners and fades — dissolving into the
        // pill. fullScreenCover blocks the native swipe, so we drive it ourselves.
        .scaleEffect(dynamicScale, anchor: .center)
        .offset(y: dragY > 0 ? dragY * 0.8 : 0)              // rubber-banding
        .cornerRadius(dragY > 0 ? 38 : 0)                    // round as it shrinks
        .opacity(Double(max(0.45, 1 - dragY / 600)))         // fade out toward the pill
        .onReceive(ticker) { now = $0 }
        // Runs alongside the control buttons, so taps still work.
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { v in dragY = max(0, v.translation.height) }
                .onEnded { v in
                    // Interactive spring = responsive, organic settle.
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.75)) {
                        if v.translation.height > 150 { call.minimized = true }  // far enough -> minimize
                        dragY = 0                                                // else snap back
                    }
                }
        )
    }

    // Whole screen scales toward an 80% floor as you pull down — the premium shrink feel.
    private var dynamicScale: CGFloat {
        dragY > 0 ? max(0.80, 1 - dragY / 1000) : 1
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

    // Video mode: remote feed full-screen, local camera as a draggable-corner PiP.
    private var videoLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let remote = call.remoteVideoTrack {
                VideoRendererView(track: remote).ignoresSafeArea()
            } else {
                background   // until the remote video arrives, show the blurred avatar
            }
            if call.cameraOn, let local = call.localVideoTrack {
                VideoRendererView(track: local, mirror: call.usingFrontCamera)
                    .frame(width: 112, height: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.3), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .padding(.top, 56).padding(.trailing, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: call.isVideo ? 16 : 26) {
            controlButton(call.isMuted ? "mic.slash.fill" : "mic.fill", on: call.isMuted) { call.toggleMute() }
            if call.isVideo {
                controlButton(call.cameraOn ? "video.fill" : "video.slash.fill", on: !call.cameraOn) { call.toggleCamera() }
                controlButton("arrow.triangle.2.circlepath.camera.fill", on: false) { call.switchCamera() }
            }
            controlButton(call.isSpeaker ? "speaker.wave.2.fill" : "speaker.fill", on: call.isSpeaker) { call.toggleSpeaker() }
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                CallKitManager.shared.end()   // route end through CallKit
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 26)).foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(.red, in: Circle())
            }
            .buttonStyle(CallControlStyle())
        }
    }

    private func controlButton(_ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()   // tactile tap
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 66, height: 66)
                .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(Color.white.opacity(0.16)), in: Circle())
        }
        .buttonStyle(CallControlStyle())
    }
}

// Root-level call container: lives above every screen so an active call survives ALL
// navigation (open chats, chat list, settings — anywhere). When minimized it shows a
// top mini bar that PUSHES content down (not a floating overlay); otherwise it presents
// the full call screen. Call state lives in the CallService singleton, so nothing resets.
struct CallContainer<Content: View>: View {
    @ViewBuilder var content: Content
    private var call: CallService { CallService.shared }
    // Keep the call screen up through reconnection and the brief end state.
    private var isActive: Bool {
        switch call.state {
        case .outgoing, .active, .reconnecting, .ended: return true
        default: return false
        }
    }

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
        // NO app-wide implicit animation here: wrapping `content` in .animation made the
        // whole chat view warp/distort whenever call state changed. Only the mini bar
        // animates now (its own .transition + withAnimation at the toggle sites), so the
        // call screen slides up as a clean native cover over a perfectly still chat view.
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
        case .reconnecting:
            return "Reconnecting…"
        case .ended:
            return "Call ended"
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

// Press feedback for call control buttons: dips + dims on press, springs back.
struct CallControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
