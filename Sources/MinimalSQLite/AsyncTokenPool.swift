//
//  AsyncToken.swift
//  MinimalSQLite
//
//  Created by Jim Studt on 5/19/26.
//

/// An async token pool that hands out one available token per operation.
///
/// `AsyncToken` is initialized with a set of tokens. Each call to `with(_:)`
/// removes one token from the available set, runs the operation with exclusive
/// ownership of that token, and returns the token to either the next waiter or
/// the available set when the operation finishes.
actor AsyncTokenPool<T: Hashable & Sendable> {
    private var defined: Set<T>
    private var available: Set<T>
    private var waiters: [CheckedContinuation<T, Never>] = []

    init(_ tokens: Set<T>) {
        self.defined = tokens
        self.available = tokens
    }

    /// Runs an async operation with one token from the pool.
    func with<R>(_ operation: @Sendable (T) async throws -> R) async rethrows -> R {
        let token = await acquire()
        defer { release(token) }
        return try await operation(token)
    }

    func removeToken() async -> T? {
        if defined.isEmpty {
            return nil
        }
        let token = await acquire()
        defined.remove(token)
        return token
    }
    func removeAllTokens() async -> [T] {
        var tokens: [T] = []
        while let token = await removeToken() {
            tokens.append(token)
        }
        return tokens
    }
    private func acquire() async -> T {
        if let token = available.popFirst() {
            return token
        }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release(_ token: T) {
        if waiters.isEmpty {
            available.insert(token)
        } else {
            waiters.removeFirst().resume(returning: token)
        }
    }
}
