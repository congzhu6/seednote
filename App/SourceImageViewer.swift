import SwiftUI
import UIKit

/// Presents the complete source image inside the sheet's available viewport.
struct SourceImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .accessibilityLabel(L("Source image", "来源图片"))
                    .accessibilityIdentifier("sourceImagePreview")
            }
            // NavigationStack and the sheet supply the safe-area-aware bounds.
            // Padding stays inside those bounds; neither axis is unbounded.
            .padding(16)
            .background(Theme.paper)
            .navigationTitle(L("Source image", "来源图片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done", "完成")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("closeSourceImage")
                }
            }
        }
    }
}
