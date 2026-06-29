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
    var onMore: (() -> Void)?      // tap "…" → host shows its actions (Save/Forward/Share/Hide)

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
            if let onMore {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { onMore() }
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

