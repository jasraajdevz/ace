//
//  AceWidgetBundle.swift
//  AceWidget
//
//  The extension's entry point.
//
//  Kept in its own file with nothing else in it, because `@main` is exclusive:
//  the command-line verification build (see DECISIONS.md D1) compiles the rest
//  of this folder alongside a `main.swift`, and two entry points in one module
//  don't compile. Splitting the attribute out means every other widget file
//  still gets type-checked without Xcode.
//

import SwiftUI
import WidgetKit

@main
struct AceWidgetBundle: WidgetBundle {
    var body: some Widget {
        AceWidget()
    }
}
