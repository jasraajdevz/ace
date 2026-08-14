//
//  swiftdata_shim.swift
//  Ace — verification harness only. NOT part of the app.
//
//  A *working* in-memory stand-in for the parts of SwiftData that Ace uses.
//
//  Why this exists: SwiftData's framework is available on macOS, but its
//  `@Model` macro is implemented by a compiler plugin that ships inside Xcode.
//  With no Xcode on this machine, anything annotated `@Model` could originally
//  only be parsed (DECISIONS.md D1). `Tools/gen/harness_data.py` strips those
//  attributes and compiles the result against this file.
//
//  It started as a type-check-only shim. It is now a real store — `insert`
//  actually inserts, `fetch` actually returns and sorts, `delete` actually
//  removes — which means the persistence *logic* can be executed rather than
//  merely compiled: does `fetchOrCreate` create exactly once, does XP land on
//  the record, is a level-up detected, does the demo content install twice.
//
//  WHAT THIS PROVES: that Ace's own code around SwiftData is correct.
//  WHAT IT DOES NOT PROVE: anything about SwiftData itself. Relationship
//  inverse maintenance, cascade deletes, `@Attribute(.unique)` enforcement,
//  faulting and migration are all real-framework behaviour that this
//  deliberately does not emulate — so the checks never assert on them.
//
//  Every signature mirrors the real API exactly, including `throws` and generic
//  constraints. A shim that accepted more than the framework does would hide
//  errors, which is worse than having no shim at all.
//

import Foundation

// MARK: - PersistentModel

/// The real protocol has a large set of macro-generated requirements. The
/// harness only needs it to exist, be class-bound, and be observable.
protocol PersistentModel: AnyObject, Observable {}

// MARK: - ModelContext

/// An in-memory model store.
///
/// Objects are held per concrete type. That's enough to make `fetch` meaningful
/// while staying honest about what isn't modelled — there is no object graph
/// here, so nothing cascades.
final class ModelContext {

    /// Insertions, keyed by type name.
    private var storage: [String: [AnyObject]] = [:]

    /// Counters the harness asserts on, so a test can prove `save()` was
    /// actually reached rather than assuming it.
    private(set) var saveCount = 0
    private(set) var insertCount = 0
    private(set) var deleteCount = 0

    init() {}

    private func key<T>(_ type: T.Type) -> String { String(describing: type) }

    // MARK: Mutating

    func insert<T: PersistentModel>(_ model: T) {
        // Re-inserting the same object is a no-op in SwiftData; mirror that,
        // otherwise a double-insert would silently double every fetch.
        var bucket = storage[key(T.self), default: []]
        guard !bucket.contains(where: { $0 === model }) else { return }
        bucket.append(model)
        storage[key(T.self)] = bucket
        insertCount += 1
    }

    func delete<T: PersistentModel>(_ model: T) {
        guard var bucket = storage[key(T.self)] else { return }
        let before = bucket.count
        bucket.removeAll { $0 === model }
        storage[key(T.self)] = bucket
        if bucket.count != before { deleteCount += 1 }
    }

    /// Bulk delete. Generic over a *concrete* type — which is precisely why
    /// `SettingsView.resetAll` cannot loop over `[any PersistentModel.Type]`,
    /// and why the shim must keep that constraint.
    func delete<T: PersistentModel>(model: T.Type,
                                    where predicate: Predicate<T>? = nil,
                                    includeSubclasses: Bool = true) throws {
        let removed = storage[key(T.self)]?.count ?? 0
        storage[key(T.self)] = []
        deleteCount += removed
    }

    func save() throws {
        saveCount += 1
    }

    // MARK: Reading

    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        var results = (storage[key(T.self)] as? [T]) ?? []
        for comparator in descriptor.sortBy.reversed() {
            results = results.sorted(using: comparator)
        }
        if let limit = descriptor.fetchLimit, results.count > limit {
            results = Array(results.prefix(limit))
        }
        return results
    }

    /// Harness-only convenience: how many of a type are stored.
    func count<T: PersistentModel>(of type: T.Type) -> Int {
        storage[key(type)]?.count ?? 0
    }

    /// Harness-only: wipe everything, for a fresh test.
    func removeAll() {
        storage.removeAll()
        saveCount = 0
        insertCount = 0
        deleteCount = 0
    }
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
    let models: [any PersistentModel.Type]

    init(_ models: [any PersistentModel.Type], version: Schema.Version = .init(1, 0, 0)) {
        self.models = models
    }

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
// The three pieces of SwiftData that reach into SwiftUI.

import SwiftUI

/// `@Query` — the property wrapper that fetches models into a view.
///
/// Returns empty in the harness: `@Query` only has meaning inside a live view
/// hierarchy, and nothing here renders one. Its purpose in the shim is to make
/// the screens type-check.
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
    func modelContainer(_ container: ModelContainer) -> some Scene { self }
}

extension View {
    func modelContainer(_ container: ModelContainer) -> some View { self }
}
