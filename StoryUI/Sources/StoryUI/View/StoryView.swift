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
            let screenH: CGFloat = UIScreen.main.bounds.height
            let down: CGFloat = max(0, drag.height)
            let progress: CGFloat = min(1, down / (screenH * 0.5))
            let bgOpacity: Double = Double(1 - 0.85 * progress)   // black backdrop dims
            let cardScale: CGFloat = 1 - 0.18 * progress          // visible shrink (floor ~0.82)
            let cardOpacity: Double = Double(1 - 0.05 * progress) // card stays ~opaque (no ghosting)
            // Telegram/IG: the story card is ALWAYS rounded (not just during swipe). Grows as you pull.
            let restCorner: CGFloat = 32
            let corner: CGFloat = down > 0 ? min(42, max(restCorner, down * 0.7)) : restCorner
            ZStack {
                Color.black.ignoresSafeArea().opacity(bgOpacity)
                TabView(selection: $viewModel.currentStoryUser) {
                    ForEach(viewModel.stories) { model in
                        StoryDetailView(
                            viewModel: viewModel,
                            model: model,
                            isPresented: $isPresented,
                            userClosure: userClosure,
                            onProfile: onProfile,
                            onItemSeen: onItemSeen,
                            isDismissing: down > 0
                        )
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .scaleEffect(cardScale, anchor: .center)    // shrink as you pull down
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .offset(y: down)       // close goes STRAIGHT DOWN (Telegram) — no sideways drift
                .opacity(cardOpacity)
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
                            onDrag?(drag.height)   // let the host fade its overlays out
                        }
                    }
                    .onEnded { v in
                        // Commit on distance OR a downward flick (predictedEnd = velocity proxy).
                        let flick: CGFloat = v.predictedEndTranslation.height
                        if v.translation.height > 130 || flick > 500 {
                            withAnimation(.easeOut(duration: 0.22)) { isPresented = false }
                        } else {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { drag = .zero }
                        }
                        onDrag?(0)   // reset (overlays fade back if it springs back)
                    }
            )
            .onChange(of: viewModel.currentStoryUser) { new in onUserChanged?(new) }   // mark each viewed bucket (iOS14 single-arg onChange — pkg min is iOS14)
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
