import SwiftUI

/// Full-screen transparent view that draws a 6px colored border along all four edges.
/// Hosted in a click-through NSWindow above all other windows.
struct BorderOverlayView: View {
    let state: FocusOverlayState
    private let thickness: CGFloat = 6

    var body: some View {
        let c = state.color.opacity(0.85)
        GeometryReader { _ in
            ZStack {
                Color.clear
                VStack { Rectangle().fill(c).frame(height: thickness); Spacer() }
                VStack { Spacer(); Rectangle().fill(c).frame(height: thickness) }
                HStack { Rectangle().fill(c).frame(width: thickness); Spacer() }
                HStack { Spacer(); Rectangle().fill(c).frame(width: thickness) }
            }
        }
        .animation(.easeInOut(duration: 0.6), value: state)
    }
}
