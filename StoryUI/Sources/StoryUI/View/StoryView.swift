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
            // full width slide, no shrink. corners round as you pull. chats list shows behind (cover is clear).
            let corner: CGFloat = min(44, down * 0.5)
            ZStack {
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
                .background(Color.black)                    // solid card slides as one unit
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .offset(y: down)                            // straight down, full width
            }
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // UIKit dismiss (Signal mechanism): a direction-locked DOWN pan on the pager's own scroll
            // view, with scroll.panGestureRecognizer.require(toFail:) so cube (sideways) and dismiss
            // (down) are mutually exclusive at recognition time. No SwiftUI gesture fighting the TabView.
            .background(
                CubeDismissPan(
                    onChanged: { dy in
                        drag = CGSize(width: 0, height: max(0, dy))
                        onDrag?(drag.height)
                    },
                    onEnded: { ty, vy in
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

// Finds the TabView's own paging UIScrollView and attaches a direction-locked DOWN pan to it, then
// scroll.panGestureRecognizer.require(toFail:) that pan (Signal's StoryInteractiveTransitionCoordinator
// mechanism). Result: a downward drag dismisses, a sideways drag folds the cube, never both.
struct CubeDismissPan: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void   // translation.y, velocity.y

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { context.coordinator.attach(from: v) }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.pan == nil { DispatchQueue.main.async { context.coordinator.attach(from: uiView) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let parent: CubeDismissPan
        weak var pan: DirectionalPanGestureRecognizer?
        weak var scroll: UIScrollView?
        init(_ parent: CubeDismissPan) { self.parent = parent }

        func attach(from probe: UIView) {
            guard pan == nil else { return }
            // climb up from the probe; the first ancestor whose subtree has a scroll view is the
            // pager's host (the chat-list scroll lives in a higher/other hierarchy).
            var ancestor: UIView? = probe.superview
            var hops = 0
            var found: UIScrollView?
            while let a = ancestor, hops < 8 {
                if let s = Self.findScroll(in: a) { found = s; break }
                ancestor = a.superview; hops += 1
            }
            guard let sv = found else { return }
            scroll = sv
            let g = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handle(_:)))
            g.delegate = self
            sv.addGestureRecognizer(g)
            sv.panGestureRecognizer.require(toFail: g)
            pan = g
        }

        static func findScroll(in v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView { return s }
            for sub in v.subviews { if let s = findScroll(in: sub) { return s } }
            return nil
        }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let t = g.translation(in: v)
            switch g.state {
            case .changed: parent.onChanged(max(0, t.y))
            case .ended, .cancelled: parent.onEnded(t.y, g.velocity(in: v).y)
            default: break
            }
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { false }
    }
}
