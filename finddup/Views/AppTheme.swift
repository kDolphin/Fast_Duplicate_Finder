import SwiftUI

/// Shared visual tokens — system blue brand (no purple).
enum AppTheme {
    /// Primary brand: macOS system blue (adapts light/dark).
    static let brand = Color(nsColor: .systemBlue)
    static let brandSoft = Color(nsColor: .systemBlue).opacity(0.10)
    
    /// One page fill for sidebar + detail.
    static let page = Color(nsColor: .textBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let chrome = Color(nsColor: .textBackgroundColor)
    
    static let rowHover = Color.primary.opacity(0.04)
    static let hairline = Color.primary.opacity(0.07)
    static let separator = Color.primary.opacity(0.08)
    
    static let metricBlue = Color(nsColor: .systemBlue)
    static let metricGreen = Color(nsColor: .systemGreen)
    static let metricGray = Color(nsColor: .secondaryLabelColor)
    
    /// Packages: teal, not purple
    static let package = Color(nsColor: .systemTeal)
    static let review = Color(nsColor: .systemOrange)
    static let keep = Color(nsColor: .systemGreen)
    static let danger = Color(nsColor: .systemRed)
    
    static let groupRowHeight: CGFloat = 34
    static let memberRowHeight: CGFloat = 30
    static let corner: CGFloat = 10
    static let cornerSmall: CGFloat = 8
    static let topBarHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 240
    static let sidebarMinWidth: CGFloat = 200
    static let windowMinWidth: CGFloat = 1080
    static let windowMinHeight: CGFloat = 700
}

struct BrandMark: View {
    var size: CGFloat = 28
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(AppTheme.brand)
                .frame(width: size, height: size)
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

struct StatusChip: View {
    let title: String
    let color: Color
    
    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}
