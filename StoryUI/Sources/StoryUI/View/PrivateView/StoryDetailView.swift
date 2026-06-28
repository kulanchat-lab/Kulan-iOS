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
    @State private var isAdvancing: Bool = false   // guard the segment-end double-advance

    private var messageViewPosition: CGFloat {
        return -keyboardManager.currentHeight
    }
    
    private var emojiViewPosition: CGFloat {
        return (messageViewPosition * 1.5)
    }
    
    var body: some View {
        
        GeometryReader { proxy in
            let index = getCurrentIndex()
            let story = model.stories[index]
            ZStack {
                if model.stories.count > index {
                    VStack(spacing: 8) {
                        getStoryView(with: index, story: story)
                            .overlay(
                                tapStory()
                                    .offset(
                                        y: story.config.storyType != .plain()
                                        ? -Constant.MessageView.height : .zero
                                    )
                            )
                        messageView(with: index)
                    }
                }
                getEmojiView(story: story)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay(
                getUserInfoAndProgressBar(with: index)
                ,alignment: .top
            )
            .rotation3DEffect(
                getAngle(proxy: proxy),
                axis: (x: 0, y: 1, z: 0),
                anchor: proxy.frame(in: .global).minX > 0 ? .leading : .trailing,
                perspective: 2.5
            )
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
                ForEach(model.stories.indices) { index in
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
        let rotation: CGFloat = 45
        let progress = proxy.frame(in: .global).minX / proxy.size.width
        let degrees = rotation * progress
        return Angle(degrees: degrees)
    }
    
    func resetProgress() {
        timerProgress = 0
        isAdvancing = false
        isPaused = false   // safety: never carry a stuck pause across a user switch (R1 freeze fix)
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
        // Pause sources: emoji-fly animation (isTimerRunning), hold-to-pause (isPaused),
        // and composing a reply (keyboard open) — any of them freezes the segment + progress.
        guard !isTimerRunning, !isPaused, !keyboardManager.isKeyboardOpen else { return }
        
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
            updateStory(direction: .previous)
        } else {
            timerProgress = CGFloat(Int(timerProgress - 1))
        }
    }
    
    func start(index: Int) {
        if !model.stories[index].isReady {
            model.stories[index].isReady = true
        }
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
        return min(Int(timerProgress), model.stories.count - 1)
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
