import SwiftUI
import UIKit

/// View modifier to disable keyboard adjustment
struct DisableKeyboardAdjustment: ViewModifier {
  func body(content: Content) -> some View {
    content
      .onAppear {
        UITextField.appearance().keyboardAppearance = .dark
      }
  }
}

extension View {
  /// Apply this modifier to prevent views from adjusting position when keyboard appears
  func disableKeyboardAdjustment() -> some View {
    self.modifier(DisableKeyboardAdjustment())
  }
} 