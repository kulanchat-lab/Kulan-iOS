//
//  UserView.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 29.04.2022.
//

import SwiftUI

struct UserView: View {

    var image: String
    var name: String
    var date: String
    var onProfile: (() -> Void)?   // tap the avatar+name block → that user's profile
    var showMore: Bool = false     // show the "…" dropdown menu; its buttons post notifications the host runs
    var isMine: Bool = false       // my own story → last item is Delete, not Hide Stories

    @Binding var isPresented: Bool

    var body: some View {
        HStack(spacing: Constant.UserView.hStackSpace) {
            // Tappable header block (avatar 38pt + name 14pt + timestamp 12pt) → profile.
            HStack(spacing: Constant.UserView.hStackSpace) {
                CacheAsyncImage(urlString: image)   // 38×38 circle
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(date)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onProfile?() }

            Spacer()

            // "…" sits directly left of the X, same row, so they auto-align (no guessed padding).
            if showMore {
                Menu {
                    Button { NotificationCenter.default.post(name: .init("storyActionSave"), object: nil) }
                        label: { Label("Save", systemImage: "square.and.arrow.down") }
                    Button { NotificationCenter.default.post(name: .init("storyActionForward"), object: nil) }
                        label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    Button { NotificationCenter.default.post(name: .init("storyActionShare"), object: nil) }
                        label: { Label("Share", systemImage: "square.and.arrow.up") }
                    if isMine {
                        Button(role: .destructive) { NotificationCenter.default.post(name: .init("storyActionDelete"), object: nil) }
                            label: { Label("Delete", systemImage: "trash") }
                    } else {
                        Button { NotificationCenter.default.post(name: .init("storyActionHide"), object: nil) }
                            label: { Label("Hide Stories", systemImage: "archivebox") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }

            // 18pt glyph (was 24, looked oversized) in a 44×44 invisible touch target.
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: .replaceCurrentItem, object: nil)
                    isPresented = false
                }
        }
        .padding(.horizontal)
    }
}

