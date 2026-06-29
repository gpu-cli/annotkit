import SwiftUI

/// The overlay's SwiftUI content, shared by the macOS and iOS hosts: a highlight
/// over the hovered/selected element, a note composer when an element is
/// selected, and a floating toolbar. The overlay covers the primary screen; for
/// the MVP an element's top-left frame maps directly to the view's top-left
/// space (multi-display placement is cli-a99qm.4.2).
struct OverlayView: View {
    @ObservedObject var session: AnnotationSession
    let onToggle: () -> Void
    let onFlush: () -> Void

    @State private var comment: String = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

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
