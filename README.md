#  MinmalSQLite – a tiny Swift Concurrency friendly SQLite package

This is my tiny SQLite package which works well in a Swift Concurrency environment and has a 
straightforward implementation. It has just enough for me.

## Example

It goes about like this to use it. 

```swift
    let db = try MinimalSQLite.SQLDatabase(at: yourDatabaseURL)
    try await db.transaction {
        try await db.execute("insert into names (first, last) values (?, ?)", 
                             parameters: ["Arthur", "Dent"])
        let rows : [(String,String)] = try await db.query("select first,last from names")
    }
```

## TODO

- The docc docs are not working right in Xcode around the ReadTransaction functions.  Looks like it is getting some other ReadTransaction somewhere else.


