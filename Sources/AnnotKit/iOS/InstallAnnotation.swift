#if os(iOS)
import SwiftUI

/// SwiftUI convenience for iOS hosts: attach the annotation overlay to a view
/// tree. Dev-gated like ``Annotation/install(source:sink:)``.
///
///     ContentView()
///         #if DEBUG
///         .installAnnotation()
///         #endif
public extension View {
    func installAnnotation(sink: AnnotationSink? = nil) -> some View {
        onAppear { Annotation.install(sink: sink) }
    }
}
#endif
