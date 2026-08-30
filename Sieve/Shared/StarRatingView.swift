import SwiftUI

struct StarRatingView: View {
    var rating: Int
    var onChange: ((Int) -> Void)? = nil
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(i <= rating ? Color.yellow : Color.secondary.opacity(0.5))
                    .onTapGesture { onChange?(i == rating ? 0 : i) }
            }
        }
        .allowsHitTesting(onChange != nil)
    }
}
