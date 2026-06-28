//
//  SwiftUIView.swift
//
//
//  Created by Tolga İskender on 3.06.2023.
//

import SwiftUI

struct MessageView: View {
    
    // MARK: Public Properties
    var story: Story
    
    @Binding var showEmoji: Bool
    let userClosure: UserCompletionHandler?
    
    // MARK: Private Properties
    @State private var text: String = ""
    @State private var likeButtonTapped: Bool = false
    @State private var clearText: Bool = false
   
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                switch story.config.storyType {
                case .plain(let config):
                    HStack {
                        Spacer()
                        buttonViewBuilder(config)
                    }
                case .message(let config, _, let placeholder):
                    messageViewBuilder(config, placeholder)
                }
            }
        }
    }
}

private extension MessageView {
    var onCommitAction: () -> Void {
        return {
            guard !text.isEmpty else {
                return
            }
            clearText.toggle()
            userClosure?(story, text, nil, false)
        }
    }
    
    
    var likeButton: some View  {
        Button {
            likeButtonTapped.toggle()
            userClosure?(story, text, nil, likeButtonTapped)
        } label: {
            Image(systemName: likeButtonTapped ? Constant.MessageView.likeImageTapped : Constant.MessageView.likeImage)
                .font(.title2)
                .foregroundColor(likeButtonTapped ? .red : .white)
            
        }
    }
    
    @ViewBuilder
    func buttonViewBuilder(_ config: StoryInteractionConfig?) -> some View {
        if let config {
            HStack(spacing: 16) {
                if config.showLikeButton {
                    likeButton
                }
            }
            .frame(height: Constant.MessageView.height)
        } else {
            EmptyView()
        }
    }
    
    
    func messageViewBuilder(_ config: StoryInteractionConfig?, _ placeholder: String) -> some View {
        HStack(spacing: 16) {
            TextField("",
                      text: $text,
                      onCommit: onCommitAction)
            .placeholder(when: text.isEmpty, view: {
                Text(placeholder).foregroundColor(.white)
            })
            .onChange(of: text, perform: { newValue in
                showEmoji = newValue.isEmpty
            })
            .onChange(of: clearText, perform: { newValue in
                text = ""
                showEmoji = newValue
            })
            .onChange(of: story, perform: { newValue in
                likeButtonTapped = newValue.isLiked
            })
            .foregroundColor(.white)
            .frame(height: Constant.MessageView.height)
            .padding(Constant.MessageView.padding)
            .background(Capsule().fill(.black.opacity(0.3)))   // filled pill, more native than a bare stroke
            .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))

            // Send button appears once you've typed (heart shows when empty) — was Return-key only.
            if text.isEmpty {
                buttonViewBuilder(config)
            } else {
                Button(action: onCommitAction) {
                    Image(systemName: "paperplane.fill").font(.title2).foregroundColor(.white)
                }
            }
        }
    }
}

struct MessageView_Previews: PreviewProvider {
    static var previews: some View {
        MessageView(story: Story(mediaURL: "", date: "", config: StoryConfiguration(mediaType: .image)), showEmoji: .constant(true), userClosure: nil)
    }
}

