import SwiftUI

/// Reference render for the App Icon — not shipped in any navigation path.
/// Hand this to a designer or feed the description below to an image tool:
///
/// > A 1024×1024 app icon on pure black (#0A0A0A). Centered: a radiant burst
/// > of fine light rays emanating from a single point, rendered in a warm
/// > white-to-gold vertical gradient, evoking phosphorescence. No text in the
/// > icon itself. Minimal, premium, high-contrast — Darkroom meets Apple
/// > Photos. Subtle bloom around the core; rays thin and precise, not chunky.
struct IconPreviewView: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04)

            radiantBurst
                .frame(width: 360, height: 360)

            VStack {
                Spacer()
                Text("Phosphor")
                    .font(.system(size: 64, weight: .bold, design: .default))
                    .foregroundStyle(wordmarkGradient)
                    .padding(.bottom, 80)
            }
        }
        .frame(width: 512, height: 512)
        .clipShape(RoundedRectangle(cornerRadius: 96, style: .continuous))
    }

    private var radiantBurst: some View {
        ZStack {
            ForEach(0..<24, id: \.self) { i in
                Capsule()
                    .fill(rayGradient)
                    .frame(width: 4, height: 170)
                    .offset(y: -85)
                    .rotationEffect(.degrees(Double(i) / 24 * 360))
            }
            Circle()
                .fill(coreGradient)
                .frame(width: 96, height: 96)
                .blur(radius: 18)
            Circle()
                .fill(.white)
                .frame(width: 40, height: 40)
                .blur(radius: 4)
        }
    }

    private var rayGradient: LinearGradient {
        LinearGradient(
            colors: [.white, Color(red: 1.0, green: 0.82, blue: 0.45), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var coreGradient: RadialGradient {
        RadialGradient(
            colors: [.white, Color(red: 1.0, green: 0.85, blue: 0.5)],
            center: .center,
            startRadius: 0,
            endRadius: 48
        )
    }

    private var wordmarkGradient: LinearGradient {
        LinearGradient(
            colors: [.white, Color(red: 1.0, green: 0.85, blue: 0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview {
    IconPreviewView()
}
