// Reference watchOS views — shared design language for the standalone watch target.
// Compiled only on watchOS so the iOS app doesn't pull in WKInterfaceDevice.
import SwiftUI

#if os(watchOS)
// Intentionally empty: the watch target provides its own self-contained app in
// `LiftLogWatch/LiftLogWatchApp.swift`. Keeping a watchOS-only stub avoids accidentally
// shipping iOS-incompatible APIs while leaving room for future shared subviews.
#endif
