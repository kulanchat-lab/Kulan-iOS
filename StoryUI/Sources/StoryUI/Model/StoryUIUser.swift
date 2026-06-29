//
//  User.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 1.05.2022.
//

import Foundation

public struct StoryUIUser: Identifiable, Hashable {
    public var id: String
    public var name: String
    public var image: String
    public var isMine: Bool   // my own story → the "…" menu shows Delete instead of Hide Stories

    public init(id: String = UUID().uuidString, name: String, image: String, isMine: Bool = false) {
        self.id = id
        self.name = name
        self.image = image
        self.isMine = isMine
    }
}
