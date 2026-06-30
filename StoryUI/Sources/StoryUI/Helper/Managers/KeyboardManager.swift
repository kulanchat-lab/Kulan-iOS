//
//  KeyboardManager.swift
//  
//
//  Created by Tolga İskender on 4.06.2023.
//

import Foundation
import UIKit

final class KeyboardManager: ObservableObject {
    
    @Published private(set) var currentHeight: CGFloat = 0
    @Published private(set) var isKeyboardOpen = false
    @Published private(set) var animationDuration: Double = 0.25   // ride the keyboard's own timing (no lag)

    private var notificationCenter: NotificationCenter
    
    init(center: NotificationCenter = .default) {
        notificationCenter = center
        notificationCenter.addObserver(
            self, 
            selector: #selector(keyBoardWillShow(notification:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(keyBoardWillHide(notification:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
    
    func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil, 
            for: nil
        )
    }
    
    deinit {
        notificationCenter.removeObserver(self)
    }
    
    @objc func keyBoardWillShow(notification: Notification) {
        if let keyboardSize = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            animationDuration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            currentHeight = keyboardSize.height - UIApplication.bottomSafeAreaHeight
            isKeyboardOpen = true
        }
    }

    @objc func keyBoardWillHide(notification: Notification) {
        animationDuration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        isKeyboardOpen = false
        currentHeight = 0
    }
}
