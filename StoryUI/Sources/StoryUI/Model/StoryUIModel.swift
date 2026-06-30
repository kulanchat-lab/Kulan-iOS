//
//  StoryUIMedia.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Foundation

public struct StoryUIModel: Identifiable, Hashable {
    public var id: String
    public var user: StoryUIUser
    public var isSeen: Bool = false
    public var isMine: Bool = false        // my own story → "…" menu shows Delete, not Hide Stories
    public var stories: [Story]

    public init(id: String = UUID().uuidString, user: StoryUIUser, isSeen: Bool = false, isMine: Bool = false, stories: [Story]) {
        self.id = id
        self.user = user
        self.isSeen = isSeen
        self.isMine = isMine
        self.stories = stories
    }
}
