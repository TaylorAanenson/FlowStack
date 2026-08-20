//
//  FlowTransition.swift
//
//  Created by Zac White on 2/23/23.
//

import Foundation
import SwiftUI

extension EnvironmentValues {
    var opacityTransitionPercent: CGFloat {
        get { return self[OpacityTransitionKey.self] }
        set { self[OpacityTransitionKey.self] = newValue }
    }
}

private struct FlowSnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// True only while a flow link's contents are being rasterised into the
    /// transition snapshot (`FlowLink.createSnapshot`).
    ///
    /// The snapshot is taken by rendering the link's label into an offscreen
    /// hosting controller and calling `drawHierarchy`, which captures only
    /// what Core Animation can draw in process. Content that composites out
    /// of process -- a `WKWebView` playing video is the case this exists for
    /// -- comes back as a black rectangle, and that bitmap is what the reader
    /// sees for the length of the transition while the real link is held at
    /// zero opacity. A view that knows it has such content can watch this and
    /// draw its still image instead.
    var flowSnapshotRender: Bool {
        get { self[FlowSnapshotRenderKey.self] }
        set { self[FlowSnapshotRenderKey.self] = newValue }
    }
}

/// Live progress of the flow zoom, published to the presented destination
/// via `\.flowZoomGeometry`. The percent cannot be delivered through the
/// environment directly — environment writes inside the animatable
/// transition modifier never reach the transitioned content, and the
/// modifier is removed entirely once the transition settles — so it
/// travels in a shared reference box the zoom modifier writes every
/// animation frame. Sample it from an `onGeometryChange` on the
/// destination's root: the zoom animates the destination's layout, so the
/// height change is a per-frame trigger that fires exactly when this value
/// is fresh (and once more on settle, after the modifier's final write
/// of 1).
public struct FlowZoomGeometry: Equatable {
    let box: ZoomGeometryBox

    public static func == (lhs: FlowZoomGeometry, rhs: FlowZoomGeometry) -> Bool {
        lhs.box === rhs.box
    }

    /// Zoom progress: 0 = collapsed onto the anchor card, 1 = fully
    /// presented (clamped — the settle spring can overshoot 1 briefly)
    public var percent: CGFloat { min(1, max(0, box.percent)) }

    /// Opacity of the anchor snapshot FlowStack draws over the destination —
    /// it dissolves across the zoom's first fifth. A destination hero that
    /// renders at `1 - snapshotOpacity(at: percent)` crossfades with the
    /// snapshot exactly: the pair always sums to full opacity, so the
    /// handoff never flashes blank and never double-exposes.
    public static func snapshotOpacity(at percent: CGFloat) -> CGFloat {
        max(0, 1 - percent / 0.2)
    }
}

/// Shared by every copy of a presentation's PathContext. Identity-hashable
/// so PathContext keeps its synthesized conformances.
final class ZoomGeometryBox: Equatable, Hashable {
    var percent: CGFloat = 0

    static func == (lhs: ZoomGeometryBox, rhs: ZoomGeometryBox) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct FlowZoomGeometryKey: EnvironmentKey {
    static let defaultValue: FlowZoomGeometry? = nil
}

public extension EnvironmentValues {
    /// Present on destinations pushed through a FlowStack; nil elsewhere.
    var flowZoomGeometry: FlowZoomGeometry? {
        get { self[FlowZoomGeometryKey.self] }
        set { self[FlowZoomGeometryKey.self] = newValue }
    }
}

struct OpacityTransitionKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// An action that dismisses the current presented view.
public struct FlowDismissAction {
    var onDismiss: () -> Void = { }

    public func callAsFunction() {
        onDismiss()
    }
}

public extension EnvironmentValues {
    var flowDismiss: FlowDismissAction {
        get { return self[FlowDismissActionKey.self] }
        set { self[FlowDismissActionKey.self] = newValue }
    }
}

struct FlowDismissActionKey: EnvironmentKey {
    static let defaultValue: FlowDismissAction = .init()
}

extension AnyTransition {

    static func flowTransition(with context: PathContext) -> AnyTransition {
        AnyTransition.modifier(
            active: FlowPresentModifier(percent: 0, context: context),
            identity: FlowPresentModifier(percent: 1, context: context)
        )
    }

    struct OpacityPercentModifier: AnimatableModifier {
        var percent: Double

        var animatableData: Double {
            get { percent }
            set { percent = newValue }
        }

        func body(content: Content) -> some View {
            content
                .opacity(percent)
                .environment(\.opacityTransitionPercent, percent)
        }
    }

    static var opacityPercent: AnyTransition {
        AnyTransition.modifier(
            active: OpacityPercentModifier(percent: 0),
            identity: OpacityPercentModifier(percent: 1)
        )
    }

    struct FlowPresentModifier: Animatable, ViewModifier {
        var percent: CGFloat
        var context: PathContext

        @State var panOffset: CGPoint = .zero
        @State var isEnded: Bool = false
        @State private var isDisabled: Bool = false
        @State var isDismissing: Bool = false
        @State private var snapCornerRadiusZero: Bool = true
        @State private var availableSize: CGSize = .zero

        @Environment(\.colorScheme) private var colorScheme

        private var snapshotPercent: CGFloat {
            max(0, 1 - percent / 0.2)
        }

        @Environment(\.flowDismiss) var dismiss
        @Environment(\.flowTransaction) var transaction
        @Environment(\.horizontalSizeClass) var horizontalSizeClass

        private var activeSnapshot: UIImage? {
            context.snapshotDict[colorScheme] ?? context.snapshot
        }

        var cornerRadius: CGFloat { context.cornerRadius + ((UIScreen.displayCornerRadius ?? 20) - context.cornerRadius) * percent }

        var isPresentedFullscreen: Bool {
            horizontalSizeClass == .compact || availableSize.width - 2 * Constants.minVerticalPadding < Constants.maxWidth
        }

        var conditionalCornerRadius: CGFloat {
            if isPresentedFullscreen {
                if percent >= 1 {
                    if snapCornerRadiusZero {
                        return 0
                    } else {
                        return cornerRadius
                    }
                } else {
                    return cornerRadius
                }
            } else {
                return cornerRadius
            }
        }

        var cornerStyle: RoundedCornerStyle { percent > 0.5 ? .continuous : context.cornerStyle }

        var animatableData: CGFloat {
            get { percent }
            set { percent = newValue }
        }

        func zoomRect(with proxy: GeometryProxy, anchor: Anchor<CGRect>?, percent: CGFloat, pullOffset: CGPoint?) -> CGRect {
            let rect: CGRect
            if let anchor = anchor {
                rect = proxy[anchor]
            } else {
                rect = proxy.frame(in: .global)
                    .insetBy(dx: 50, dy: 100)
                    .offsetBy(dx: 0, dy: 0)
            }

            let pullPercent = (1 - (0.9 + (0.1 * (1 - min(1, max(0, (pullOffset ?? .zero).y / 200))))))

            let zoomRect = CGRect(
                x: (proxy.size.width / 2) * percent + rect.midX * (1 - percent) + (pullOffset ?? .zero).x / 3,
                y: (proxy.size.height / 2) * percent + rect.midY * (1 - percent) + (pullOffset ?? .zero).y / 3,
                width: rect.width + ((presentationSize(availableSize: proxy.size).width - rect.width) * max(0, percent) * (1 - pullPercent)),
                height: rect.height + ((presentationSize(availableSize: proxy.size).height - rect.height) * max(0, percent) * (1 - pullPercent))
            )

            return zoomRect
        }

        struct Constants {
            static let maxWidth: CGFloat = 706
            static let maxHeight: CGFloat = 998
            static let minVerticalPadding: CGFloat = 44
        }

        private func presentationSize(availableSize: CGSize) -> CGSize {

            if horizontalSizeClass == .regular && availableSize.width - 2 * Constants.minVerticalPadding >= Constants.maxWidth {
                let width = Constants.maxWidth
                let height = min(Constants.maxHeight, availableSize.height - Constants.minVerticalPadding * 2)
                return CGSize(width: width, height: height)
            } else {
                return availableSize
            }
        }

        func body(content: Content) -> some View {
            GeometryReader { proxy in
                let zoomRect = zoomRect(with: proxy, anchor: context.overrideAnchor ?? context.anchor, percent: percent, pullOffset: panOffset)
                let scaleRatio = context.shouldScaleHorizontally ? zoomRect.size.width / proxy.size.width : 1.0

                // Deposit the live percent where the destination can reach
                // it (see FlowZoomGeometry) — this body runs once per
                // animation frame with the interpolated value, and its final
                // evaluation before removal lands exactly on the identity
                // value, so the box reads 1 whenever the view is settled
                let _ = { context.zoomGeometryBox.percent = percent }()

                content
                    .onInteractiveDismissGesture(threshold: 80, isEnabled: !isDisabled, isDismissing: isDismissing, swipeUpToDismiss: context.swipeUpToDismiss, onDismiss: {
                        defer { isDismissing = true }
                        guard !isDisabled else { return }
                        dismiss()
                    }, onPan: { offset in
                        defer { self.isEnded = false }
                        guard !isDisabled else { return }
                        self.snapCornerRadiusZero = false
                        self.panOffset = offset
                    }, onEnded: { isDismissing in
                        // TODO: FS-34: Handle snap corner radius 0 on interactive dismiss cancel
                        withTransaction(transaction) {
                            panOffset = .zero
                            isEnded = true
                        }
                    })
                    .onPreferenceChange(InteractiveDismissDisabledKey.self) { isDisabled in
                        self.isDisabled = isDisabled
                    }
                    .preference(key: SizePreferenceKey.self, value: proxy.size)
                    .onPreferenceChange(SizePreferenceKey.self, perform: { value in
                        availableSize = value
                    })
                    .overlay(alignment: .top) {
                        if let image = activeSnapshot, percent < 1 {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .opacity(snapshotPercent)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: conditionalCornerRadius / scaleRatio, style: cornerStyle))
                    .shadow(color: context.shadowColor ?? .clear, radius: context.shadowRadius, x: context.shadowOffset.x, y: context.shadowOffset.y)
                    .frame(
                        width: context.shouldScaleHorizontally ? proxy.size.width : zoomRect.size.width,
                        height: zoomRect.size.height / scaleRatio
                    )
                    .scaleEffect(x: scaleRatio, y: scaleRatio, anchor: .center)
                    .transformEffect(.init(translationX: context.anchor == nil ? (1 - percent) * proxy.size.width : 0, y: 0))
                    .position(
                        x: zoomRect.origin.x,
                        y: zoomRect.origin.y
                    )
                    .opacity(context.anchor == nil ? percent : 1)
            }
            .ignoresSafeArea(.container, edges: .all)
        }
    }
}

struct SizePreferenceKey: PreferenceKey {
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }

    static var defaultValue: CGSize = .zero
}
