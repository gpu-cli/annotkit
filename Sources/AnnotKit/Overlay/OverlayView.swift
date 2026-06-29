import SwiftUI

/// The overlay's SwiftUI content, shared by the macOS and iOS hosts.
///
/// Interaction is driven entirely through SwiftUI hit-testing, which fixes the
/// two ways a global click monitor went wrong: a full-screen catcher (active
/// only in annotate mode, behind the chrome) receives hover and taps over the
/// app, while the toolbar and composer sit on top and consume their own clicks,
/// so tapping "Add note" can never re-select the element under the button. The
/// whole overlay is `accessibilityHidden` so the AX point query sees through it
/// to the app beneath.
struct OverlayView: View {
    @ObservedObject var session: AnnotationSession
    let onToggle: () -> Void
    let onFlush: () -> Void

    @State private var comment: String = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            catcher

            if let element = session.selected ?? session.hovered {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.12))
                    .frame(width: element.frame.width, height: element.frame.height)
                    .offset(x: element.frame.minX, y: element.frame.minY)
                    .allowsHitTesting(false)
            }

            if session.selected != nil {
                composer
            }

            toolbar
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Full-screen hover/tap surface, active only while annotating. Behind the
    /// chrome, so a tap on the toolbar/composer routes to those instead.
    @ViewBuilder
    private var catcher: some View {
        if session.mode == .annotating {
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase {
                        session.hover(atAXPoint: point)
                    }
                }
                .gesture(
                    SpatialTapGesture().onEnded { event in
                        session.select(atAXPoint: event.location)
                    }
                )
        } else {
            Color.clear.allowsHitTesting(false)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.selectionLabel ?? "Element")
                .font(.headline)
                .lineLimit(1)
            TextField("Describe the change", text: $comment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 5)
                .frame(width: 260)
            HStack {
                Button("Cancel") {
                    comment = ""
                    session.cancelSelection()
                }
                Spacer()
                Button("Add note") {
                    session.addNote(comment: comment)
                    comment = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 260)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 12)
        .offset(x: composerOffset.x, y: composerOffset.y)
    }

    private var composerOffset: CGPoint {
        guard let frame = session.selected?.frame else { return CGPoint(x: 24, y: 24) }
        return CGPoint(x: max(12, frame.minX), y: frame.maxY + 8)
    }

    private var toolbar: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 10) {
                    Button(action: onToggle) {
                        Label(
                            session.mode == .annotating ? "Annotating" : "Annotate",
                            systemImage: session.mode == .annotating ? "cursorarrow.rays" : "cursorarrow"
                        )
                    }
                    if !session.pending.isEmpty {
                        Text("\(session.pending.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                        Button("Save notes", action: onFlush)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8)
                .padding(20)
            }
        }
    }
}
