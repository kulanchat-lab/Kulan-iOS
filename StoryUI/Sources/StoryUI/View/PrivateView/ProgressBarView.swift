//
//  ProgressView.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 29.04.2022.
//

import SwiftUI

struct ProgressBarView: View {
    var timerProgress: CGFloat
    var index: Int
    
    var body: some View {
        GeometryReader { proxy in
            
            let width = proxy.size.width
            let progress = timerProgress - CGFloat(index)
            let perfectProgress = min(max(progress, 0), 1)
            
            Capsule()
                .fill(.gray.opacity(0.5))
                .overlay (
                    Capsule()
                        .fill(.white)
                        .frame(width: width * perfectProgress)
                        .animation(.linear(duration: 0.08), value: perfectProgress)   // > the 0.05s tick → steps overlap into smooth, gap-free motion
                    ,alignment: .leading
                )
        }.frame(height: Constant.progressBarHeight)
    }
}
