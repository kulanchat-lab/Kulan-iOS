//
//  SwiftUIView.swift
//
//
//  Created by Tolga İskender on 1.05.2022.
//

import SwiftUI
import AVKit

struct StoryDetailView: View {
    // MARK: Public Properties
    @ObservedObject var viewModel: StoryViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State var model: StoryUIModel
    @Binding var isPresented: Bool
    
    @State var timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()   // 20fps for a smooth bar
    @State var timerProgress: CGFloat = 0

    
    let userClosure: UserCompletionHandler?
    var onProfile: ((StoryUIUser) -> Void)?
    var onItemSeen: ((String) -> Void)?
    var showMore: Bool = false   // show the header "…" dropdown menu (buttons post notifications to the host)
    var isDismissing: Bool = false   // true while swiping down to close → cube fold off (no skew)
    @State private var lastSeenItem: String = ""

    // MARK: Private Properties
    @StateObject private var keyboardManager = KeyboardManager()   // own it once (was re-created each re-init)
    @State private var state: MediaState = .notStarted
    @State private var player = AVPlayer()
    @State private var animate = false
    @State private var selectedEmoji = ""
    @State private var startAnimate = false
    @State private var isTimerRunning: Bool = false
    @State private var isAnimationStarted: Bool = false
    @State private var isTapDisabled: Bool = false
    @State private var showEmoji: Bool = true
    @State private var isPaused: Bool = false   // hold-to-pause
    @State private var hostPaused: Bool = false // app froze it while showing a sheet (e.g. viewers list)
    @State private var isAdvancing: Bool = false   // guard the segment-end double-advance
    @State private var isFolding: Bool = false   // true while this page is mid-cube-fold (pause timer)
    @State private var captionExpanded: Bool = false   // Telegram: tap the caption to expand past 3 lines

    private var messageViewPosition: CGFloat {
        return -keyboardManager.currentHeight
    }
    
    private var emojiViewPosition: CGFloat {
        return (messageViewPosition * 1.5)
    }
    
    var body: some View {
        
        GeometryReader { proxy in
            let index = getCurrentIndex()
            ZStack {
                // Empty bucket (all items expired/removed) -> render nothing instead of indexing [-1] (crash).
                if index < model.stories.count {
                    let story = model.stories[index]
                    VStack(spacing: 8) {
                        getStoryView(with: index, story: story)
                            // Full-bleed: fill the WHOLE card top-to-bottom (no centered rounded card, which
                            // left a black strip above the progress bars). The aspect-fit photo + blurred
                            // backdrop now cover the entire screen, like WhatsApp.
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(
                                tapStory()
                                    .offset(
                                        y: story.config.storyType != .plain()
                                        ? -Constant.MessageView.height : .zero
                                    )
                            )
                            // Telegram-style caption: overlaid on the media (never baked into the photo,
                            // which clipped it), bottom-left over a soft gradient, tap to expand.
                            // (iOS 14 overlay form — the library deploys to iOS 14, no trailing-closure overlay.)
                            .overlay(captionView(story.caption), alignment: .bottom)
                            // Top dark scrim (mirror of the bottom caption gradient) so the username, avatar
                            // and close button stay readable on white/bright photos. Black at the very top
                            // fading to clear; behind the header, no touches.
                            .overlay(topScrim, alignment: .top)
                        messageView(with: index)
                    }
                    getEmojiView(story: story)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay(
                getUserInfoAndProgressBar(with: index)
                    .opacity(isPaused ? 0 : 1)                       // fade chrome out while holding (IG/WhatsApp)
                    .animation(.linear(duration: 0.2), value: isPaused)
                ,alignment: .top
            )
            .rotation3DEffect(
                getAngle(proxy: proxy),
                axis: (x: 0, y: 1, z: 0),
                anchor: proxy.frame(in: .global).minX > 0 ? .leading : .trailing,
                perspective: 2.5
            )
            // report how far this page is from centre so the timer can pause mid-fold
            .preference(key: StoryFoldKey.self, value: proxy.frame(in: .global).minX)
        }
        .onPreferenceChange(StoryFoldKey.self) { minX in
            let folding = abs(minX) > 2     // off-centre = mid-fold (or off-screen): freeze the timer
            if folding != isFolding { isFolding = folding }
        }
        .onChange(of: viewModel.currentStoryUser) { newValue in
            NotificationCenter.default.post(name: .stopVideo, object: nil)
            resetProgress()
            playVideo()
        }
        .onReceive(timer) { _ in
            startProgress()
        }
        .onChange(of: isAnimationStarted ? isAnimationStarted : false) { state in
            configureProgress(with: state)
            isTimerRunning = state
        }
        .onChange(of: keyboardManager.isKeyboardOpen) { open in
            open ? pauseVideo() : playVideo()   // composing a reply pauses; resumes on dismiss
        }
        .onChange(of: scenePhase) { phase in
            // Pause when the app leaves the foreground; resume on return (the timer also
            // naturally suspends with the run loop, this coordinates video too).
            if phase == .active { isPaused = false; playVideo() }
            else { isPaused = true; pauseVideo() }
        }
        // Host shows/hides a sheet over the viewer (viewers list, share, menu) → freeze/resume.
        .onReceive(NotificationCenter.default.publisher(for: .pauseStory)) { _ in
            hostPaused = true; pauseVideo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resumeStory)) { _ in
            hostPaused = false; if !keyboardManager.isKeyboardOpen { playVideo() }
        }
    }
}

// MARK: Private Configuration
private extension StoryDetailView {
    
    @ViewBuilder
    func getStoryView(with index: Int, story: Story) -> some View {
        switch story.config.mediaType {
        case .image:
            ImageView(imageURL: story.mediaURL) {
                start(index: index)
            }
            .onAppear {
                resetAVPlayer()
            }
        case .video:
            VideoView(
                videoURL: story.mediaURL,
                state: $state,
                player: player
            ) { media, duration in
                model.stories[index].duration = duration
                start(index: index)
                state = media
            }
            .onChange(of: state) { _ in
                playVideo()
            }
        }
    }
    
    @ViewBuilder
    func getEmojiView(story: Story) -> some View {
        let index = getCurrentIndex()
        switch story.config.storyType {
        case .message(_, let emojis, _):
            if let emojis, showEmoji {
                VStack {
                    Spacer()
                    EmojiView(
                        story: getStory(with: index),
                        emojiArray: emojis,
                        startAnimating: $startAnimate,
                        selectedEmoji: $selectedEmoji,
                        userClosure: userClosure
                    )
                    .animation(messageViewPosition == 0 ? .none : .easeOut, value: messageViewPosition)
                    .offset(y: emojiViewPosition)
                    .opacity(messageViewPosition == 0 ? 0 : 1)
                }
                
                if startAnimate {
                    EmojiReactionView(
                        dissmis: $startAnimate,
                        isAnimationStarted: $isAnimationStarted,
                        emoji: selectedEmoji
                    )
                }
                
            }
        case .plain:
            Divider()
        }
    }
    
    @ViewBuilder
    func getUserInfoAndProgressBar(with index: Int) -> some View {
        let date = getStory(with: index).date
        let name = model.user.name
        let image = model.user.image
        VStack {
            HStack(spacing: Constant.progressBarSpacing) {
                ForEach(model.stories.indices, id: \.self) { index in
                    ProgressBarView(
                        timerProgress: timerProgress,
                        index: index
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            UserView(
                image: image,
                name: name,
                date: date,
                onProfile: { onProfile?(model.user) },
                showMore: showMore,
                isPresented: $isPresented
            )
        }
    }
    
    @ViewBuilder
    func messageView(with index: Int) -> some View {
        let story = getStory(with: index)
        
        MessageView(
            story: story,
            showEmoji: $showEmoji,
            userClosure: userClosure
        )
        .padding()
        .animation(messageViewPosition == 0 ? .none : .easeOut, value: messageViewPosition)
        .offset(y: messageViewPosition)
    }

    // Top dark scrim: black (50%) at the very top fading to clear, so the header (username, avatar, X)
    // stays readable on white/bright stories. Mirrors the bottom caption gradient.
    var topScrim: some View {
        LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 130)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }

    // Telegram StoryContentCaptionComponent: 16pt regular white text with a soft shadow, left-aligned,
    // 16pt side padding, sitting over a 128pt black gradient (0 → 80%). Collapsed to 3 lines; tap to expand.
    @ViewBuilder
    func captionView(_ text: String) -> some View {
        if !text.isEmpty {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 128)
                    .allowsHitTesting(false)
                Text(text)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.25), radius: 4)
                    .multilineTextAlignment(.leading)
                    .lineLimit(captionExpanded ? nil : 3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .contentShape(Rectangle())
                    .onTapGesture {   // tap expands/collapses; consumes the tap so it doesn't advance the story
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { captionExpanded.toggle() }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
        }
    }

    @ViewBuilder
    func tapStory() -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(.black.opacity(0.01))
                    .frame(width: geo.size.width / 3)   // left third = back (IG: smaller back zone)
                    .onTapGesture { tapPreviousStory() }
                Rectangle()
                    .fill(.black.opacity(0.01))
                    .onTapGesture { tapNextStory() }     // right two-thirds = next
            }
            // Hold to pause (IG/Snap). onLongPressGesture's onPressingChanged pauses on press-down
            // and resumes on release; crucially, a horizontal swipe exceeds maximumDistance and
            // CANCELS the press (→ resume) so the TabView can still page between users (R2 fix —
            // a minimumDistance:0 drag stole the touch from the pager).
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 10, perform: {}, onPressingChanged: { pressing in
                if pressing {
                    guard !keyboardManager.isKeyboardOpen else { return }
                    isPaused = true; pauseVideo()
                } else {
                    isPaused = false; playVideo()
                }
            })
        }
    }
    
    func getAngle(proxy: GeometryProxy) -> Angle {
        // StoryUI library's cube (tiskender2/StoryUI): angle = 45° × (minX / width). Combined with the
        // pager's horizontal slide + the .leading/.trailing anchor + perspective 2.5, this IS the cube —
        // pure SwiftUI, no UIKit transform feedback (so no shake/black).
        let progress = proxy.frame(in: .global).minX / proxy.size.width
        return Angle(degrees: 45 * progress)
    }
    
    func resetProgress() {
        timerProgress = 0
        isAdvancing = false
        isPaused = false   // safety: never carry a stuck pause across a user switch (R1 freeze fix)
        // Clear every pause latch too, or a new bucket can start permanently frozen (stuck-state bug).
        isTimerRunning = false
        isAnimationStarted = false
        isFolding = false
        captionExpanded = false   // collapse the caption when moving to another story
    }
    
    func getPreviousStory() {
        
        if let first = viewModel.stories.first, first.id != model.id {

            let bundleIndex = viewModel.stories.firstIndex { currentBundle in
                return model.id == currentBundle.id
            } ?? 0
            
            withAnimation {
                viewModel.currentStoryUser = viewModel.stories[bundleIndex - 1].id
            }
        } else {
            let index = getCurrentIndex()
            let story = getStory(with: index)
            if story.config.mediaType == .video {
                NotificationCenter.default.post(name: .stopAndRestartVideo, object: nil)
            }
            resetProgress()   // restart the current segment (image OR video) — was a no-op for images
        }
        return
    }
    
    func getNextStory() {
        let index = getCurrentIndex()
        let story = getStory(with: index)
        
        if let last = model.stories.last, last.id == story.id {
            if let lastBundle = viewModel.stories.last, lastBundle.id == model.id {
                withAnimation {
                    dissmis()
                }
            } else {
                let bundleIndex = viewModel.stories.firstIndex { currentBundle in
                    return model.id == currentBundle.id
                } ?? 0
                
                withAnimation {
                    viewModel.currentStoryUser = viewModel.stories[bundleIndex + 1].id
                }
            }
        }
    }
    
    func startProgress() {
        // Report the ACTUAL current item as seen (per-item, not the whole bucket) — drives accurate
        // view receipts + "Seen by". Runs before the pause guard so it fires the moment an item shows.
        if viewModel.currentStoryUser == model.id {
            let cur = getStory(with: getCurrentIndex())
            if cur.id != lastSeenItem { lastSeenItem = cur.id; onItemSeen?(cur.id) }
        }
        // Pause sources: emoji-fly animation (isTimerRunning), hold-to-pause (isPaused),
        // and composing a reply (keyboard open) — any of them freezes the segment + progress.
        guard !isTimerRunning, !isPaused, !hostPaused, !isFolding, !isDismissing, !keyboardManager.isKeyboardOpen else { return }
        
        let index = getCurrentIndex()
        let story = getStory(with: index)
        
        if viewModel.currentStoryUser == model.id {
            if !model.isSeen {
                model.isSeen = true
            }
            if timerProgress < CGFloat(model.stories.count) {
                if story.isReady {
                    getProgressBarFrame(duration: story.duration)
                }
            } else if !isAdvancing {
                isAdvancing = true   // fire the user-advance once, not every 0.1s tick
                updateStory()
            }
        }
    }
    
    func updateStory(direction: StoryDirectionEnum = .next) {
        if direction == .previous {
            getPreviousStory()
        } else {
            getNextStory()
        }
    }
    
    func tapNextStory() {
        if keyboardManager.isKeyboardOpen { keyboardManager.dismiss(); return }   // tap closes keyboard, resumes
        configureTapScreen()
        guard !isTapDisabled else { return }
        if (timerProgress + 1) > CGFloat(model.stories.count) {
            //next user
            guard !isAdvancing else { return }   // don't double-advance if the auto-timer is crossing over too
            isAdvancing = true
            updateStory()
        } else {
            //next Story
            timerProgress = CGFloat(Int(timerProgress + 1))
        }
    }
    
    func tapPreviousStory() {
        if keyboardManager.isKeyboardOpen { keyboardManager.dismiss(); return }   // tap closes keyboard, resumes
        configureTapScreen()
        guard !isTapDisabled else { return }
        if (timerProgress - 1) < 0 {
            guard !isAdvancing else { return }
            isAdvancing = true
            updateStory(direction: .previous)
        } else {
            timerProgress = CGFloat(Int(timerProgress - 1))
        }
    }
    
    func start(index: Int) {
        if !model.stories[index].isReady {
            model.stories[index].isReady = true
        }
        prefetchNext(after: index)   // warm the next photo so advancing is instant
    }

    // Predictive prefetch: pull the next item's image into URLCache (what ImageLoader reads from),
    // so tapping/auto-advancing to it shows instantly. One ahead — caching handles the rest.
    private func prefetchNext(after index: Int) {
        let next = index + 1
        guard next < model.stories.count,
              model.stories[next].config.mediaType == .image,
              let url = URL(string: model.stories[next].mediaURL),
              URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil else { return }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data, let response else { return }
            URLCache.shared.storeCachedResponse(.init(response: response, data: data), for: URLRequest(url: url))
        }.resume()
    }
    
    func getProgressBarFrame(duration: Double) {
        let calculatedDuration = viewModel.getVideoProgressBarFrame(duration: duration)
        timerProgress += (0.005 / calculatedDuration)   // halved to match the 0.05s tick (same segment duration)
    }
    
    func dissmis() {
        isPresented = false
        NotificationCenter.default.post(name: .replaceCurrentItem, object: nil)
    }
    
    func getCurrentIndex() -> Int {
        return max(0, min(Int(timerProgress), model.stories.count - 1))   // never -1 on an empty bucket
    }
    
    func getStory(with index: Int) -> Story {
        return model.stories[index]
    }
    
    func resetAVPlayer() {
        Task {
            player.pause()
        }
        player = AVPlayer()
    }
    
    func pauseVideo() {
        player.pause()
    }
    
    func playVideo() {
        // Never resume under a sheet or the reply keyboard, and never index an empty bucket.
        guard !model.stories.isEmpty, !hostPaused, !keyboardManager.isKeyboardOpen else { return }
        let index = getCurrentIndex()
        let currentUser = viewModel.currentStoryUser == model.id
        let video = model.stories[index].config.mediaType == .video
        let isReady = state == .ready || state == .started
        
        if isReady, currentUser, video {
            player.automaticallyWaitsToMinimizeStalling = false
            Task {
                player.play()
            }
        }
    }
    
    func configureTapScreen() {
        switch (keyboardManager.isKeyboardOpen, isAnimationStarted) {
        case (true, _):
            isTapDisabled = true
        case (false, true):
            isTapDisabled = true
        default:
            isTapDisabled = false
        }
    }
    
    func configureProgress(with state: Bool) {
        let index = getCurrentIndex()
        let story = model.stories[index]
        let mediaType = story.config.mediaType
        if state, mediaType == .video {
            pauseVideo()
        } else if !state, mediaType == .video {
            guard viewModel.currentStoryUser == model.id else { return }
            playVideo()
        }
    }
}

// reports a page's horizontal offset from centre so the timer can pause mid-fold.
struct StoryFoldKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
