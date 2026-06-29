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
    let onUserChanged: ((String) -> Void)?   // fires the current bucket id on open + each page change
    let onItemSeen: ((String) -> Void)?      // fires each individual story id as it becomes visible
    let onDrag: ((CGFloat) -> Void)?         // swipe-down amount (so the host can hide its overlays)

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
        onProfile: ((StoryUIUser) -> Void)? = nil,
        onUserChanged: ((String) -> Void)? = nil,
        onItemSeen: ((String) -> Void)? = nil,
        onDrag: ((CGFloat) -> Void)? = nil
    ) {
        self.stories = stories
        self.selectedIndex = selectedIndex
        self._isPresented = isPresented
        self.userClosure = userClosure
        self.onProfile = onProfile
        self.onUserChanged = onUserChanged
        self.onItemSeen = onItemSeen
        self.onDrag = onDrag
    }
    
    public var body: some View {
        if isPresented {
            // Explicit CGFloat math — avoids Release WMO's "ambiguous operator '/'" on Int literals.
            // Tuned to feel like WhatsApp/IG: backdrop fades (not the card), real shrink, fast corner
            // ramp, finger-follow on both axes.
            let down: CGFloat = max(0, drag.height)
            // full width slide down, corners round as you pull, chats list shows behind (cover is clear).
            let corner: CGFloat = min(44, down * 0.5)
            // UIKit pager owns left/right (cube). The down dismiss pan lives on the pager's scroll with
            // require(toFail:), so cube and dismiss can never run together (Signal's mechanism).
            StoryPager(
                viewModel: viewModel,
                isPresented: $isPresented,
                userClosure: userClosure,
                onProfile: onProfile,
                onItemSeen: onItemSeen,
                onDragChanged: { dy in drag = CGSize(width: 0, height: dy); onDrag?(dy) },
                onDragEnded: { ty, vy in
                    if ty > 130 || vy > 500 {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            drag.height = UIScreen.main.bounds.height
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { isPresented = false }
                    } else {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.66)) { drag = .zero }
                        onDrag?(0)
                    }
                }
            )
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .offset(y: down)
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.currentStoryUser) { new in onUserChanged?(new) }   // mark each viewed bucket
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
