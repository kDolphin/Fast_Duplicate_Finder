import SwiftUI

struct ScanningView: View {
    let progress: String
    let progressPercent: Double
    let currentPhase: String
    let phaseProgress: String
    let estimatedTimeRemaining: TimeInterval
    
    private var formattedTimeRemaining: String {
        if estimatedTimeRemaining <= 0 { return "" }
        let total = Int(estimatedTimeRemaining.rounded())
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        return "duration.seconds".localized(max(seconds, 1))
    }
    
    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.12), lineWidth: 10)
                    .frame(width: 120, height: 120)
                
                Circle()
                    .trim(from: 0, to: min(max(progressPercent, 0.02), 1))
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.35), value: progressPercent)
                
                VStack(spacing: 2) {
                    Text("\(Int(progressPercent * 100))%")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            
            VStack(spacing: 10) {
                Text(currentPhase)
                    .font(.title3.weight(.semibold))
                
                Text(progress)
                    .font(.body)
                    .foregroundStyle(.secondary)
                
                Text(phaseProgress.isEmpty ? " " : phaseProgress)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 16)
                    .frame(maxWidth: 420)
                
                HStack(spacing: 6) {
                    if !formattedTimeRemaining.isEmpty {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text("scan.time.remaining".localized(formattedTimeRemaining))
                            .font(.caption)
                    } else {
                        Text(" ").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 16)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.page)
        .focusable(false)
    }
}

struct ErrorView: View {
    let message: String
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
            }
            
            VStack(spacing: 8) {
                Text("error.title".localized)
                    .font(.title3.weight(.semibold))
                
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.page)
        .focusable(false)
    }
}

struct NoResultsView: View {
    var cancelled: Bool = false
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill((cancelled ? Color.orange : Color.green).opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: cancelled ? "stop.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(cancelled ? .orange : .green)
            }
            
            VStack(spacing: 8) {
                Text((cancelled ? "results.scan.cancelled.title" : "results.no.duplicates").localized)
                    .font(.title3.weight(.semibold))
                
                Text((cancelled ? "results.scan.cancelled.message" : "results.all.unique").localized)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.page)
        .focusable(false)
    }
}
