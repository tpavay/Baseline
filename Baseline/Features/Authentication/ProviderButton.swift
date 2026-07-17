import SwiftUI

/// Shared Apple/Google sign-in button used by the standalone auth gate and the onboarding
/// auth step.
struct ProviderButton: View {
    enum Icon {
        case sfSymbol(String)
        case googleG
    }

    let title: String
    let icon: Icon
    let foreground: Color
    let background: Color
    var border: Color?
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if isLoading {
                        ProgressView().tint(foreground)
                    } else {
                        switch icon {
                        case .sfSymbol(let name):
                            Image(systemName: name).font(.system(size: 18, weight: .medium))
                        case .googleG:
                            Image("GoogleIcon").resizable().scaledToFit()
                        }
                    }
                }
                .frame(width: 22, height: 22)

                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(border ?? .clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isLoading ? 0.55 : 1)
        .accessibilityLabel(title)
    }
}
