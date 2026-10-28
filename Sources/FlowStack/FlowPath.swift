//
//  FlowPath.swift
//
//  Created by Zac White on 2/16/23.
//

import Foundation
import SwiftUI

extension CGRect: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(minX)
        hasher.combine(minY)
        hasher.combine(width)
        hasher.combine(height)
    }
}

extension CGPoint: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}

struct PathContext: Equatable, Hashable {
    var anchor: Anchor<CGRect>?
    var overrideAnchor: Anchor<CGRect>?

    /// Shared across copies of this context — the zoom modifier writes the
    /// resolved transition geometry here for the destination to read (see
    /// FlowZoomGeometry)
    var zoomGeometryBox = ZoomGeometryBox()

    var snapshot: UIImage?
    var snapshotDict: [ColorScheme: UIImage] = [:]
    var linkDepth: Int = 0

    var cornerRadius: CGFloat = 0
    var cornerStyle: RoundedCornerStyle = .circular

    var shadowRadius: CGFloat = 0
    var shadowColor: Color?
    var shadowOffset: CGPoint = .zero

    var shouldShowSkrim: Bool = true
    var shouldScaleHorizontally: Bool = true

    var swipeUpToDismiss: Bool = false

    /// Set on a split pane's presentation that's about to be replaced: it
    /// fades under its successor instead of zooming back to its link
    var leavesBeneathReplacement: Bool = false

    /// Where the link is now, while this is presented (see LiveLinkBox)
    var liveLink = LiveLinkBox()
}

/// The link a presentation zooms back into, as it is now rather than as it
/// was at the tap. The anchor and snapshot above are taken when the link is
/// tapped, which only holds while the presentation covers the link: beside
/// a split pane the list stays in use, so the link can scroll, or be laid
/// out wider when the screen opens out, before the presentation closes.
/// The link writes here while its value is presented. Shared by every copy
/// of the context, like ZoomGeometryBox, so those writes need no path write.
final class LiveLinkBox: Equatable, Hashable {
    struct Anchors {
        /// The link's bounds
        var anchor: Anchor<CGRect>?
        /// Where its `flowAnimationAnchor` sits inside those bounds. Kept as
        /// a frame in the link, not an anchor: a link covered by its
        /// presentation is drawn as an empty stand-in, which has no
        /// animation anchor in it, while the link's own bounds still move
        var overrideFrame: CGRect?
    }

    /// Nil until the link reports in after presenting
    var anchors: Anchors?
    /// Retaken when the link changes size; empty until then
    var snapshotDict: [ColorScheme: UIImage] = [:]

    static func == (lhs: LiveLinkBox, rhs: LiveLinkBox) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct FlowElement: Equatable, Hashable {
    var value: (any (Equatable & Hashable))
    var context: PathContext?
    var index: Int

    static func == (lhs: FlowElement, rhs: FlowElement) -> Bool {
        lhs.value.hashValue == rhs.value.hashValue &&
        _mangledTypeName(type(of: lhs.value)) == _mangledTypeName(type(of: rhs.value)) &&
        lhs.index == rhs.index
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(_mangledTypeName(type(of: value)))
        hasher.combine(index)
    }
}

/// A type-erased list of data representing the content of a flow stack.
public struct FlowPath: Equatable, Hashable {

    var elements: [FlowElement]

    public init() {
        elements = []
    }

    var isEmpty: Bool {
        elements.isEmpty
    }

    /// The number of elements in the flow path.
    public var count: Int {
        elements.count
    }

    func contains<P>(_ element: P, atLevel level: Int?) -> Bool where P: Hashable {
        return self.element(presenting: element, atLevel: level) != nil
    }

    /// The element presenting `value` from a link at `level` (any level
    /// when nil)
    func element<P>(presenting value: P, atLevel level: Int?) -> FlowElement? where P: Hashable {
        elements.last { $0 == FlowElement(value: value, context: $0.context, index: level ?? $0.index) }
    }

    /// Removes the specified number of elements from the end of the flow path.
    /// - Parameter count: The number of elements to remove from the collection. Count must be greater than or equal to zero and must not exceed the number of elements in the flow path.
    public mutating func removeLast(_ count: Int = 1) {
        guard !isEmpty else { return }
        elements.removeLast(count)
    }

    mutating func append<P>(_ newElement: P, context: PathContext?) where P: Hashable {
        self.elements.append(.init(value: newElement, context: context, index: elements.count))
    }

    /// Marks every element to leave beneath whatever replaces it (see
    /// `PathContext.leavesBeneathReplacement`)
    mutating func markForReplacement() {
        for index in elements.indices {
            var context = elements[index].context ?? PathContext()
            context.leavesBeneathReplacement = true
            elements[index].context = context
        }
    }

    /// Adds a new element at the end of the flow path.
    /// - Parameters:
    ///   - newElement: The element to append to the flow path.
    public mutating func append<P>(_ newElement: P) where P: Hashable {
        self.append(newElement, context: nil)
    }

    /// Adds a method to tell flow path to use the correct snapshot for the currently set colorScheme
    /// - Parameters:
    ///    - colorScheme: The new color scheme to be used for snapshots
    public mutating func updateSnapshots(from colorScheme: ColorScheme) {
        for i in elements.indices {
            guard var context = elements[i].context else { continue }
            if let newSnapshot = context.snapshotDict[colorScheme] {
                context.snapshot = newSnapshot
                elements[i].context?.snapshot = context.snapshot
            }
        }
    }
}

struct FlowPathKey: EnvironmentKey {
    static let defaultValue: Binding<FlowPath>? = .constant(FlowPath())
}

public extension EnvironmentValues {
    var flowPath: Binding<FlowPath>? {
        get { self[FlowPathKey.self] }
        set { self[FlowPathKey.self] = newValue }
    }
}
