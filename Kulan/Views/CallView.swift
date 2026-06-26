import SwiftUI
import UIKit

// Full-screen in-app call UI — voice OR video, Instagram/FaceTime feel.
// Voice: blurred avatar backdrop, large avatar, Mute / Speaker / End.
// Video: full-screen remote feed, draggable local PiP, Mute / Camera / Flip / Speaker / End.
struct CallView: View {
    private var call = CallService.shared
    @State private var now = Date()
    @State private var dragY: CGFloat = 0
    @State private var controlsShown = true
    @State private var hideWork: DispatchWorkItem?
    @State private var pipOffset = CGSize.zero
    @State private var pipBase   = CGSize.zero
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Auto-hide chrome after 4 s during active video.
    private func scheduleHide() {
        hideWork?.cancel()
        guard call.isVideo, call.state == .active else { return }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.3)) { controlsShown = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
    private func revealControls() {
        withAnimation(.easeInOut(duration: 0.3)) { controlsShown = true }
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
        GeometryReader { geo in
            let safeTop    = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom

            ZStack {
                // Background / video layer.
                if call.isVideo { videoLayer(geo: geo) } else { voiceBackground }

                // Chrome overlay (header + centre info + controls).
                VStack(spacing: 0) {
                    // ── Header: minimize (left) · name+status (centre) · add-person/chat/flip (right) ──
                    HStack(alignment: .top) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { call.minimized = true }
                        } label: { headerCircle("chevron.down") }
                        .buttonStyle(CallControlStyle())

                        Spacer(minLength: 8)

                        VStack(spacing: 3) {
                            Text(call.otherName)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white).lineLimit(1)
                            HStack(spacing: 4) {
                                Image(systemName: "lock.fill").font(.system(size: 9))
                                Text(statusText).monospacedDigit()
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(.top, 2)

                        Spacer(minLength: 8)

                        VStack(spacing: 12) {
                            Button { } label: { headerCircle("person.badge.plus") }
                                .buttonStyle(CallControlStyle())
                            Button { } label: { headerCircle("message.fill") }
                                .buttonStyle(CallControlStyle())
                            if call.isVideo {
                                Button { call.switchCamera() } label: { headerCircle("arrow.triangle.2.circlepath") }
                                    .buttonStyle(CallControlStyle())
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, safeTop + 4)

                    Spacer()

                    // Voice: large centred avatar (the name now lives in the header, like WhatsApp).
                    if !call.isVideo {
                        AvatarView(name: call.otherName, photoUrl: call.otherPhotoUrl, size: 150)
                            .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                        Spacer()
                    }

                    // ── Controls ──
                    controls(safeBottom: safeBottom)
                }
                // Video: chrome auto-hides; tap anywhere to reveal.
                .opacity(call.isVideo && !controlsShown ? 0 : 1)
                .allowsHitTesting(call.isVideo ? controlsShown : true)
            }
            // Swipe-down-to-minimize: slide the whole card straight down, tracking the finger
            // 1:1 (FaceTime/Telegram). NO scaleEffect — scaling the Metal video layer makes it
            // zoom/distort, which was the bug. Just an offset + rounding + a gentle fade.
            .offset(y: dragY)
            .cornerRadius(dragY > 0 ? 38 : 0)
            .opacity(Double(max(0.6, 1 - dragY / 900)))
            .onReceive(ticker) { now = $0 }
            .onTapGesture { if call.isVideo { revealControls() } }
            .onChange(of: call.state) { _, s in if s == .active, call.isVideo { revealControls() } }
            .onAppear { if call.isVideo { scheduleHide() } }
            .animation(.easeInOut(duration: 0.3), value: call.isVideo)
            .animation(.easeInOut(duration: 0.25), value: call.state)
            .animation(.easeInOut(duration: 0.2), value: call.cameraOn)
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { v in dragY = max(0, v.translation.height) }
                    .onEnded { v in
                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.75)) {
                            if v.translation.height > 150 { call.minimized = true }
                            dragY = 0
                        }
                    }
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Voice background

    private var voiceBackground: some View {
        ZStack {
            if let ui = bgImage {
                Image(uiImage: ui).resizable().scaledToFill()
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.55))
            } else {
                LinearGradient(
                    colors: [Color(hex: 0x202028), .black],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Video layer

    // Remote feed full-screen + gradient scrims + draggable local PiP.
    private func videoLayer(geo: GeometryProxy) -> some View {
        let safeTop    = geo.safeAreaInsets.top
        let safeBottom = geo.safeAreaInsets.bottom

        return ZStack {
            Color.black.ignoresSafeArea()

            // Remote feed (or blurred avatar while waiting to connect).
            if let remote = call.remoteVideoTrack {
                VideoRendererView(track: remote).ignoresSafeArea()
            } else {
                voiceBackground
            }

            // Top + bottom scrims so chrome is legible.
            VStack {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: safeTop + 100)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: safeBottom + 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(controlsShown ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: controlsShown)

            // Local camera PiP — positioned safely below the Dynamic Island / notch.
            if call.cameraOn, let local = call.localVideoTrack {
                VideoRendererView(track: local, mirror: call.usingFrontCamera)
                    .frame(width: 108, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
                    .offset(pipOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                let w = pipBase.width  + v.translation.width
                                let h = pipBase.height + v.translation.height
                                let maxLeft = -(geo.size.width  - 108 - 28)
                                let maxDown =   geo.size.height - 300 - safeBottom
                                pipOffset = CGSize(
                                    width:  min(0,       max(maxLeft, w)),
                                    height: min(maxDown, max(0,       h))
                                )
                            }
                            .onEnded { _ in pipBase = pipOffset }
                    )
                    // Start in the top-right corner, safely below the Dynamic Island.
                    .padding(.top,     safeTop + 8)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func controls(safeBottom: CGFloat) -> some View {
        if call.isVideo {
            videoControls
                .padding(.bottom, safeBottom + 24)
        } else {
            voiceControls
                .padding(.bottom, safeBottom + 36)
        }
    }

    // ── Voice controls: More · Video · Speaker · Mute · End (frosted capsule, like WhatsApp) ──
    private var voiceControls: some View {
        HStack(spacing: 10) {
            controlButton(icon: "ellipsis", label: "More", highlighted: false, size: 54) { }
            controlButton(icon: "video.fill", label: "Video", highlighted: false, size: 54) { }   // switch-to-video (coming soon)
            controlButton(
                icon: call.isSpeaker ? "speaker.wave.2.fill" : "speaker.slash.fill",
                label: "Speaker", highlighted: call.isSpeaker, size: 54
            ) { call.toggleSpeaker() }
            controlButton(
                icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                label: call.isMuted ? "Unmute" : "Mute", highlighted: call.isMuted, size: 54
            ) { call.toggleMute() }
            endButton(size: 54)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
        }
    }

    // ── Video controls: More · Camera · Speaker · Mute · End (flip is in the header) ──
    private var videoControls: some View {
        HStack(spacing: 10) {
            controlButton(icon: "ellipsis", label: "More", highlighted: false, size: 54) { }
            controlButton(
                icon: call.cameraOn ? "video.fill" : "video.slash.fill",
                label: call.cameraOn ? "Camera" : "No Camera", highlighted: !call.cameraOn, size: 54
            ) { call.toggleCamera() }
            controlButton(
                icon: call.isSpeaker ? "speaker.wave.2.fill" : "speaker.slash.fill",
                label: "Speaker", highlighted: call.isSpeaker, size: 54
            ) { call.toggleSpeaker() }
            controlButton(
                icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                label: call.isMuted ? "Unmute" : "Mute", highlighted: call.isMuted, size: 54
            ) { call.toggleMute() }
            endButton(size: 54)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
        }
    }

    // Top-bar circular action button (native ultraThinMaterial, 44pt HIG target).
    private func headerCircle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
    }

    // A single round control button with a text label below.
    private func controlButton(icon: String, label: String, highlighted: Bool,
                               size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(highlighted ? .black : .white)
                    .frame(width: size, height: size)
                    .background(
                        highlighted
                            ? AnyShapeStyle(.white)
                            : AnyShapeStyle(Color.white.opacity(0.18)),
                        in: Circle()
                    )
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(CallControlStyle())
    }

    // Red hang-up button — always the same (no label needed, universal).
    private func endButton(size: CGFloat) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            CallKitManager.shared.end()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.red, in: Circle())
                // Invisible label so height matches sibling buttons.
                Text(" ")
                    .font(.system(size: 11))
                    .hidden()
            }
        }
        .buttonStyle(CallControlStyle())
    }
}

// MARK: - CallContainer

// Root-level wrapper: lives above every screen so an active call survives all navigation.
// Minimized → shows MiniCallBar at top; otherwise presents the full call screen.
struct CallContainer<Content: View>: View {
    @ViewBuilder var content: Content
    private var call: CallService { CallService.shared }

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
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { call.minimized = false }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .fullScreenCover(isPresented: Binding(
            get: { isActive && !call.minimized },
            set: { _ in }
        )) {
            CallView()
        }
    }
}

// MARK: - MiniCallBar

// WhatsApp/Signal-style 40pt green bar at the top when the call is minimized.
struct MiniCallBar: View {
    private var call: CallService { CallService.shared }
    @State private var now = Date()
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var statusText: String {
        switch call.state {
        case .active:
            if let start = call.connectedDate {
                let s = max(0, Int(now.timeIntervalSince(start)))
                return String(format: "%d:%02d", s / 60, s % 60)
            }
            return "Connected"
        case .outgoing:     return call.calleeRinging ? "Ringing…" : "Calling…"
        case .reconnecting: return "Reconnecting…"
        case .ended:        return "Call ended"
        default:            return ""
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: call.isVideo ? "video.fill" : "phone.fill")
                .font(.system(size: 13, weight: .bold))
            Text(call.otherName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(statusText)
                .font(.system(size: 13))
                .monospacedDigit()
                .opacity(0.9)
            Spacer(minLength: 6)
            Text("Tap to return")
                .font(.system(size: 12))
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Color.green)
        .onReceive(ticker) { now = $0 }
    }
}

// MARK: - CallControlStyle

// Press feedback: dips + dims on press, springs back.
struct CallControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
