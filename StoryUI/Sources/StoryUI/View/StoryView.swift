//
//  StoryView.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 28.04.2022.
//

import SwiftUI
import AVFoundation

public struct StoryView: View {
    
    @StateObject private var viewModel = StoryViewModel()
    @Binding private var isPresented: Bool
    
    // Private properties
    private var stories: [StoryUIModel]
    private var selectedIndex: Int
 
    // Public properties
    let userClosure: UserCompletionHandler?
    let onProfile: ((StoryUIUser) -> Void)?

    @State private var drag: CGSize = .zero   // swipe-down-to-dismiss

    /// Stories and isPresented required, selectedIndex is optional default: 0
    /// - Parameters:
    ///   - stories: all stories to show
    ///   - selectedIndex: current story index selected by user
    ///   - isPresented: to hide and show for closing storyView
    ///   - onProfile: tap a story's avatar/name header → that user's profile
    public init(
        stories: [StoryUIModel],
        selectedIndex: Int = 0,
        isPresented: Binding<Bool>,
        userClosure: UserCompletionHandler? = nil,
        onProfile: ((StoryUIUser) -> Void)? = nil
    ) {
        self.stories = stories
        self.selectedIndex = selectedIndex
        self._isPresented = isPresented
        self.userClosure = userClosure
        self.onProfile = onProfile
    }
    
    public var body: some View {
        if isPresented {
            let down = max(0, drag.height)
            ZStack {
                Color.black.ignoresSafeArea().opacity(1 - min(down, 300) / 600)
                TabView(selection: $viewModel.currentStoryUser) {
                    ForEach(viewModel.stories) { model in
                        StoryDetailView(
                            viewModel: viewModel,
                            model: model,
                            isPresented: $isPresented,
                            userClosure: userClosure,
                            onProfile: onProfile
                        )
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .scaleEffect(1 - min(down, 300) / 1400)     // shrink as you pull down
                .clipShape(RoundedRectangle(cornerRadius: down > 0 ? 28 : 0, style: .continuous))
                .offset(y: down)
                .opacity(1 - min(down, 300) / 500)          // fade to reveal what's underneath
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Swipe DOWN anywhere to dismiss; release past 100pt pops, otherwise springs back.
            // simultaneousGesture + vertical-dominance check so horizontal paging still works.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        if v.translation.height > 0, v.translation.height > abs(v.translation.width) {
                            drag = v.translation
                        }
                    }
                    .onEnded { v in
                        if v.translation.height > 100 {
                            withAnimation(.easeOut(duration: 0.2)) { isPresented = false }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = .zero }
                        }
                    }
            )
            .onAppear { startStory() }
            .onDisappear { stopVideo() }
        }
    }
    
    private func startStory() {
        guard !stories.isEmpty else { return }

        viewModel.stories = stories

        let index = stories.indices.contains(selectedIndex) ? selectedIndex : .zero
        let storyUser = stories[index]

        viewModel.currentStoryUser = storyUser.id

        if !storyUser.stories.isEmpty {
            viewModel.stories[index].isSeen = true
        }
    }

    private func stopVideo() {
        NotificationCenter.default.post(name: .stopVideo, object: nil)
        NotificationCenter.default.removeObserver(self)
    }
}
