//
//  swiftdata_shim.swift
//  Ace — verification harness only. NOT part of the app.
//
//  A stand-in for the parts of SwiftData that `Ace/Data/` touches.
//
//  Why this exists: SwiftData's *framework* is available on macOS, but its
//  `@Model` macro is implemented by a compiler plugin that ships inside Xcode.
//  With no Xcode on this machine, anything annotated `@Model` can only be
//  parsed, never type-checked (DECISIONS.md D1) — which left `Models.swift`,
//  `Stores.swift`, `SessionRecorder.swift` and `ShareImporter.swift` as the
//  only meaty logic in the project without a real compile behind it.
//
//  `Tools/typecheck-data.py` copies those files, mechanically strips the macro
//  attributes, and compiles them against this shim. The result is a genuine
//  type-check of the code that matters: every property access, every method
//  signature, every generic constraint.
//
//  WHAT THIS DOES NOT PROVE: that the real macro expands the way the shim
//  models it, or that the schema is valid at runtime. It proves the *code
//  around* SwiftData is correct, which is where the bugs actually live.
//
//  The shim deliberately mirrors the real API signatures exactly. A shim that
//  accepts more than the real thing would hide errors, which is worse than
//  having no shim at all.
//

import Foundation

// MARK: - PersistentModel

/// The real protocol has a large set of macro-generated requirements. Type
/// checking only needs it to exist and to be class-bound.
protocol PersistentModel: AnyObject, Observable {}

// MARK: - ModelContext

/// Mirrors the subset of `ModelContext` the app uses. Every signature matches
/// the real one, including `throws` and generic constraints.
final class ModelContext {

    func insert<T: PersistentModel>(_ model: T) {}

    func delete<T: PersistentModel>(_ model: T) {}

    /// Bulk delete. Generic over a *concrete* type — which is exactly why
    /// `SettingsView.resetAll` can't loop over `[any PersistentModel.Type]`.
    func delete<T: PersistentModel>(model: T.Type,
                                    where predicate: Predicate<T>? = nil,
                                    includeSubclasses: Bool = true) throws {}

    func save() throws {}

    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] { [] }
}

// MARK: - FetchDescriptor

struct FetchDescriptor<T: PersistentModel> {
    var predicate: Predicate<T>?
    var sortBy: [SortDescriptor<T>]
    var fetchLimit: Int?

    init(predicate: Predicate<T>? = nil, sortBy: [SortDescriptor<T>] = []) {
        self.predicate = predicate
        self.sortBy = sortBy
    }
}

// MARK: - Container

struct Schema {
    init(_ models: [any PersistentModel.Type], version: Schema.Version = .init(1, 0, 0)) {}

    struct Version {
        init(_ major: Int, _ minor: Int, _ patch: Int) {}
    }
}

struct ModelConfiguration {
    init(schema: Schema? = nil, isStoredInMemoryOnly: Bool = false) {}
}

final class ModelContainer {
    init(for schema: Schema, configurations: ModelConfiguration...) throws {}
    init(for types: any PersistentModel.Type..., configurations: ModelConfiguration...) throws {}
}

// MARK: - SwiftUI integration
//
// The three pieces of SwiftData that reach into SwiftUI. Signatures mirror the
// real ones exactly — a shim that accepts more than the framework would hide
// errors rather than find them.

import SwiftUI

/// `@Query` — the property wrapper that fetches models into a view.
@propertyWrapper
struct Query<Element: PersistentModel> {

    var wrappedValue: [Element] { [] }

    init() {}

    /// `@Query(sort: \StudySource.createdAt, order: .reverse)`
    init<Value>(sort keyPath: KeyPath<Element, Value>,
                order: SortOrder = .forward,
                animation: Animation? = nil) where Value: Comparable {}

    init(filter: Predicate<Element>? = nil,
         sort descriptors: [SortDescriptor<Element>] = [],
         animation: Animation? = nil) {}
}

extension EnvironmentValues {
    /// `@Environment(\.modelContext)`
    var modelContext: ModelContext { ModelContext() }
}

extension Scene {
    /// `.modelContainer(container)` on the `WindowGroup`.
    func modelContainer(_ container: ModelContainer) -> some Scene { self }
}

extension View {
    func modelContainer(_ container: ModelContainer) -> some View { self }
}
