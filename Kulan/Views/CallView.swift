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
    @State private var controlsShown = true // video: auto-hide; tap to reveal (FaceTime feel)
    @State private var hideWork: DispatchWorkItem?
    @State private var pipOffset = CGSize.zero      // draggable local-camera PiP
    @State private var pipBase = CGSize.zero
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Auto-hide the controls a few seconds after they appear (video calls only).
    private func scheduleHide() {
        hideWork?.cancel()
        guard call.isVideo, call.state == .active else { return }
        let work = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.3)) { controlsShown = false } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
    private func revealControls() {
        withAnimation(.easeInOut(duration: 0.25)) { controlsShown = true }
        scheduleHide()
    }

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
                // Header: minimize chevron. On video, the name + encrypted duration sit inline.
                HStack(spacing: 12) {
                    Button { withAnimation(.easeInOut(duration: 0.25)) { call.minimized = true } } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.black.opacity(0.4), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(CallControlStyle())
                    if call.isVideo {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(call.otherName).font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white).lineLimit(1)
                            HStack(spacing: 5) {
                                Image(systemName: "lock.fill").font(.system(size: 9))
                                Text(statusText).monospacedDigit()
                            }
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)

                if !call.isVideo {
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
                    }
                    .padding(.horizontal)
                } else {
                    Spacer()
                }

                controls.padding(.bottom, call.isVideo ? 28 : 48)
            }
            // Video: the chrome (header + controls) auto-hides; tap anywhere brings it back.
            .opacity(call.isVideo && !controlsShown ? 0 : 1)
            .allowsHitTesting(call.isVideo ? controlsShown : true)
        }
        // Premium swipe-down-to-minimize (FaceTime/iMessage feel): the whole call screen
        // shrinks, rubber-bands down, rounds its corners and fades — dissolving into the
        // pill. fullScreenCover blocks the native swipe, so we drive it ourselves.
        .scaleEffect(dynamicScale, anchor: .center)
        .offset(y: dragY > 0 ? dragY * 0.8 : 0)              // rubber-banding
        .cornerRadius(dragY > 0 ? 38 : 0)                    // round as it shrinks
        .opacity(Double(max(0.45, 1 - dragY / 600)))         // fade out toward the pill
        .onReceive(ticker) { now = $0 }
        .onTapGesture { if call.isVideo { revealControls() } }                       // tap to reveal chrome
        .onChange(of: call.state) { _, s in if s == .active, call.isVideo { revealControls() } }
        .onAppear { if call.isVideo { scheduleHide() } }
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

    // Video mode: remote feed full-screen, soft gradient scrims, draggable rounded PiP.
    private var videoLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let remote = call.remoteVideoTrack {
                VideoRendererView(track: remote).ignoresSafeArea()
            } else {
                background   // until the remote video arrives, show the blurred avatar
            }
            // Top + bottom scrims keep the name + controls legible over any video.
            VStack {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 210)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(controlsShown ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: controlsShown)

            if call.cameraOn, let local = call.localVideoTrack {
                VideoRendererView(track: local, mirror: call.usingFrontCamera)
                    .frame(width: 108, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
                    .offset(pipOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { pipOffset = CGSize(width: pipBase.width + $0.translation.width,
                                                            height: pipBase.height + $0.translation.height) }
                            .onEnded { _ in pipBase = pipOffset }
                    )
                    .padding(.top, 56).padding(.trailing, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var controls: some View {
        let s: CGFloat = call.isVideo ? 54 : 66
        return HStack(spacing: call.isVideo ? 14 : 22) {
            controlButton(call.isMuted ? "mic.slash.fill" : "mic.fill", on: call.isMuted, size: s) { call.toggleMute() }
            if call.isVideo {
                controlButton(call.cameraOn ? "video.fill" : "video.slash.fill", on: !call.cameraOn, size: s) { call.toggleCamera() }
                controlButton("arrow.triangle.2.circlepath.camera.fill", on: false, size: s) { call.switchCamera() }
            }
            controlButton(call.isSpeaker ? "speaker.wave.2.fill" : "speaker.fill", on: call.isSpeaker, size: s) { call.toggleSpeaker() }
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                CallKitManager.shared.end()   // route end through CallKit
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: s * 0.38)).foregroundStyle(.white)
                    .frame(width: s, height: s)
                    .background(.red, in: Circle())
            }
            .buttonStyle(CallControlStyle())
        }
        .padding(.horizontal, call.isVideo ? 14 : 0)
        .padding(.vertical, call.isVideo ? 10 : 0)
        .background {
            if call.isVideo {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
            }
        }
    }

    private func controlButton(_ icon: String, on: Bool, size: CGFloat = 66, _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()   // tactile tap
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size * 0.36))
                .foregroundStyle(on ? .black : .white)
                .frame(width: size, height: size)
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
