//
//  Transaction.swift
//  MinimalSQLite
//
//  Created by Jim Studt on 5/19/26.
//

enum TransactionBeginMode: Sendable {
    case deferred
    case immediate
    case exclusive

    var sql: String {
        switch self {
        case .deferred: return "DEFERRED"
        case .immediate: return "IMMEDIATE"
        case .exclusive: return "EXCLUSIVE"
        }
    }
}

public protocol Transaction: Actor {
    var connection: MinimalSQLite.SQLDatabase.Connection { get }
}

/// A read-only transaction actor.
///
/// `ReadTransaction` exposes query APIs but intentionally does not expose
/// `execute` APIs, so writes are rejected at compile time in read-only
/// transactions.
public actor ReadTransaction: Transaction {
    public let connection: MinimalSQLite.SQLDatabase.Connection

    init(connection: MinimalSQLite.SQLDatabase.Connection) {
        self.connection = connection
    }
}

/// A read-write transaction actor.
///
/// `WriteTransaction` exposes both query APIs and `execute` APIs. Use this type
/// inside `SQLDatabase.readwrite(_:)` when a unit of work needs to modify the
/// database.
public actor WriteTransaction: Transaction {
    public let connection: MinimalSQLite.SQLDatabase.Connection

    init(connection: MinimalSQLite.SQLDatabase.Connection) {
        self.connection = connection
    }
}
