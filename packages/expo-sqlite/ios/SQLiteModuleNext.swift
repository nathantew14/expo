// Copyright 2015-present 650 Industries. All rights reserved.

import ExpoModulesCore
import sqlite3

private typealias Row = [String: Any]
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

public final class SQLiteModuleNext: Module {
  // Store unmanaged (SQLiteModuleNext, Database) pairs for sqlite callbacks,
  // will release the pair when `closeDatabase` is called.
  private var contextPairs = [Unmanaged<AnyObject>]()

  private var cachedDatabases = [NativeDatabase]()
  private var cachedStatements = [NativeStatement]()
  private var hasListeners = false

  public func definition() -> ModuleDefinition {
    Name("ExpoSQLiteNext")

    Events("onDatabaseChange")

    OnStartObserving {
      hasListeners = true
    }

    OnStopObserving {
      hasListeners = false
    }

    OnDestroy {
      cachedStatements.forEach {
        sqlite3_finalize($0.pointer)
      }
      cachedStatements.removeAll()
      cachedDatabases.forEach {
        closeDatabase($0)
      }
      cachedDatabases.removeAll()
    }

    AsyncFunction("deleteDatabaseAsync") { (dbName: String) in
      try deleteDatabase(dbName: dbName)
    }
    Function("deleteDatabaseSync") { (dbName: String) in
      try deleteDatabase(dbName: dbName)
    }

    // swiftlint:disable:next closure_body_length
    Class(NativeDatabase.self) {
      Constructor { (dbName: String, options: OpenDatabaseOptions) -> NativeDatabase in
        guard let path = pathForDatabaseName(name: dbName) else {
          throw DatabaseException()
        }

        // Try to find opened database for fast refresh
        for database in cachedDatabases where database.dbName == dbName && database.openOptions == options && !options.useNewConnection {
          return database
        }

        var db: OpaquePointer?
        if sqlite3_open(path.absoluteString, &db) != SQLITE_OK {
          throw DatabaseException()
        }

        let database = NativeDatabase(db, dbName: dbName, openOptions: options)
        cachedDatabases.append(database)
        return database
      }

      AsyncFunction("initAsync") { (database: NativeDatabase) in
        initDb(database: database)
      }
      Function("initSync") { (database: NativeDatabase) in
        initDb(database: database)
      }

      AsyncFunction("isInTransactionAsync") { (database: NativeDatabase) -> Bool in
        return sqlite3_get_autocommit(database.pointer) == 0
      }
      Function("isInTransactionSync") { (database: NativeDatabase) -> Bool in
        return sqlite3_get_autocommit(database.pointer) == 0
      }

      AsyncFunction("closeAsync") { (database: NativeDatabase) in
        closeDatabase(database)
        if let index = cachedDatabases.firstIndex(of: database) {
          cachedDatabases.remove(at: index)
        }
      }
      Function("closeSync") { (database: NativeDatabase) in
        closeDatabase(database)
        if let index = cachedDatabases.firstIndex(of: database) {
          cachedDatabases.remove(at: index)
        }
      }

      AsyncFunction("execAsync") { (database: NativeDatabase, source: String) in
        try exec(database: database, source: source)
      }
      Function("execSync") { (database: NativeDatabase, source: String) in
        try exec(database: database, source: source)
      }

      AsyncFunction("prepareAsync") { (database: NativeDatabase, statement: NativeStatement, source: String) in
        try prepareStatement(database: database, statement: statement, source: source)
      }
      Function("prepareSync") { (database: NativeDatabase, statement: NativeStatement, source: String) in
        try prepareStatement(database: database, statement: statement, source: source)
      }
    }

    // swiftlint:disable:next closure_body_length
    Class(NativeStatement.self) {
      Constructor {
        return NativeStatement()
      }

      AsyncFunction("arrayRunAsync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [Any]) -> [String: Int] in
        return try arrayRun(statement: statement, database: database, bindParams: bindParams)
      }
      Function("arrayRunSync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [Any]) -> [String: Int] in
        return try arrayRun(statement: statement, database: database, bindParams: bindParams)
      }

      AsyncFunction("objectRunAsync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [String: Any]) -> [String: Int] in
        return try objectRun(statement: statement, database: database, bindParams: bindParams)
      }
      Function("objectRunSync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [String: Any]) -> [String: Int] in
        return try objectRun(statement: statement, database: database, bindParams: bindParams)
      }

      AsyncFunction("arrayGetAsync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [Any]) -> Row? in
        return try arrayGet(statement: statement, database: database, bindParams: bindParams)
      }
      Function("arrayGetSync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [Any]) -> Row? in
        return try arrayGet(statement: statement, database: database, bindParams: bindParams)
      }

      AsyncFunction("objectGetAsync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [String: Any]) -> Row? in
        return try objectGet(statement: statement, database: database, bindParams: bindParams)
      }
      Function("objectGetSync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [String: Any]) -> Row? in
        return try objectGet(statement: statement, database: database, bindParams: bindParams)
      }

      AsyncFunction("arrayGetAllAsync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [Any]) -> [Row] in
        return try arrayGetAll(statement: statement, database: database, bindParams: bindParams)
      }
      Function("arrayGetAllSync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [Any]) -> [Row] in
        return try arrayGetAll(statement: statement, database: database, bindParams: bindParams)
      }

      AsyncFunction("objectGetAllAsync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [String: Any]) -> [Row] in
        return try objectGetAll(statement: statement, database: database, bindParams: bindParams)
      }
      Function("objectGetAllSync") { (statement: NativeStatement, database: NativeDatabase, bindParams: [String: Any]) -> [Row] in
        return try objectGetAll(statement: statement, database: database, bindParams: bindParams)
      }

      AsyncFunction("resetAsync") { (statement: NativeStatement, database: NativeDatabase) in
        try reset(statement: statement, database: database)
      }
      Function("resetSync") { (statement: NativeStatement, database: NativeDatabase) in
        try reset(statement: statement, database: database)
      }

      AsyncFunction("finalizeAsync") { (statement: NativeStatement, database: NativeDatabase) in
        try finalize(statement: statement, database: database)
      }
      Function("finalizeSync") { (statement: NativeStatement, database: NativeDatabase) in
        try finalize(statement: statement, database: database)
      }
    }
  }

  private func pathForDatabaseName(name: String) -> URL? {
    guard let fileSystem = appContext?.fileSystem else {
      return nil
    }

    let directory = URL(string: fileSystem.documentDirectory)?.appendingPathComponent("SQLite")
    fileSystem.ensureDirExists(withPath: directory?.absoluteString)

    return directory?.appendingPathComponent(name)
  }

  private func initDb(database: NativeDatabase) {
    if database.openOptions.enableCRSQLite {
      crsqlite_init_from_swift(database.pointer)
    }
    if database.openOptions.enableChangeListener {
      addUpdateHook(database)
    }
  }

  private func exec(database: NativeDatabase, source: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let ret = sqlite3_exec(database.pointer, source, nil, nil, &error)
    if ret != SQLITE_OK, let error = error {
      let errorString = String(cString: error)
      sqlite3_free(error)
      throw SQLiteErrorException(errorString)
    }
  }

  private func prepareStatement(database: NativeDatabase, statement: NativeStatement, source: String) throws {
    if sqlite3_prepare_v2(database.pointer, source, Int32(source.count), &statement.pointer, nil) != SQLITE_OK {
      throw SQLiteErrorException(convertSqlLiteErrorToString(database))
    }
    cachedStatements.append(statement)
  }

  private func arrayRun(statement: NativeStatement, database: NativeDatabase, bindParams: [Any]) throws -> [String: Int] {
    for (index, param) in bindParams.enumerated() {
      try bindStatementParam(statement: statement, with: param, at: Int32(index + 1))
    }
    let ret = sqlite3_step(statement.pointer)
    if ret != SQLITE_ROW && ret != SQLITE_DONE {
      throw SQLiteErrorException(convertSqlLiteErrorToString(database))
    }
    return [
      "lastInsertRowid": Int(sqlite3_last_insert_rowid(database.pointer)),
      "changes": Int(sqlite3_changes(database.pointer))
    ]
  }

  private func objectRun(statement: NativeStatement, database: NativeDatabase, bindParams: [String: Any]) throws -> [String: Int] {
    for (name, param) in bindParams {
      let index = sqlite3_bind_parameter_index(statement.pointer, name.cString(using: .utf8))
      if index > 0 {
        try bindStatementParam(statement: statement, with: param, at: index)
      }
    }
    let ret = sqlite3_step(statement.pointer)
    if ret != SQLITE_ROW && ret != SQLITE_DONE {
      throw SQLiteErrorException(convertSqlLiteErrorToString(database))
    }
    return [
      "lastInsertRowid": Int(sqlite3_last_insert_rowid(database.pointer)),
      "changes": Int(sqlite3_changes(database.pointer))
    ]
  }

  private func arrayGet(statement: NativeStatement, database: NativeDatabase, bindParams: [Any]) throws -> Row? {
    for (index, param) in bindParams.enumerated() {
      try bindStatementParam(statement: statement, with: param, at: Int32(index + 1))
    }
    let ret = sqlite3_step(statement.pointer)
    if ret == SQLITE_ROW {
      return try getRow(statement: statement)
    }
    if ret != SQLITE_DONE {
      throw SQLiteErrorException(convertSqlLiteErrorToString(database))
    }
    return nil
  }

  private func objectGet(statement: NativeStatement, database: NativeDatabase, bindParams: [String: Any]) throws -> Row? {
    for (name, param) in bindParams {
      let index = sqlite3_bind_parameter_index(statement.pointer, name.cString(using: .utf8))
      if index > 0 {
        try bindStatementParam(statement: statement, with: param, at: index)
      }
    }
    let ret = sqlite3_step(statement.pointer)
    if ret == SQLITE_ROW {
      return try getRow(statement: statement)
    }
    if ret != SQLITE_DONE {
      throw SQLiteErrorException(convertSqlLiteErrorToString(database))
    }
    return nil
  }

  private func arrayGetAll(statement: NativeStatement, database: NativeDatabase, bindParams: [Any]) throws -> [Row] {
    for (index, param) in bindParams.enumerated() {
      try bindStatementParam(statement: statement, with: param, at: Int32(index + 1))
    }
    var rows: [Row] = []
    while true {
      let ret = sqlite3_step(statement.pointer)
      if ret == SQLITE_ROW {
        rows.append(try getRow(statement: statement))
        continue
      } else if ret == SQLITE_DONE {
        break
      }
      throw SQLiteErrorException(convertSqlLiteErrorToString(database))
    }
    return rows
  }

  private func objectGetAll(statement: NativeStatement, database: NativeDatabase, bindParams: [String: Any]) throws -> [Row] {
    for (name, param) in bindParams {
      let index = sqlite3_bind_parameter_index(statement.pointer, name.cString(using: .utf8))
      if index > 0 {
        try bindStatementParam(statement: statement, with: param, at: index)
      }
    }
    var rows: [Row] = []
    while true {
      let ret = sqlite3_step(statement.pointer)
      if ret == SQLITE_ROW {
        rows.append(try getRow(statement: statement))
        continue
      } else if ret == SQLITE_DONE {
        break
      }
      throw SQLiteErrorException(convertSqlLiteErrorToString(database))
    }
    return rows
  }

  private func reset(statement: NativeStatement, database: NativeDatabase) throws {
    if sqlite3_reset(statement.pointer) != SQLITE_OK {
      throw SQLiteErrorException(convertSqlLiteErrorToString(database))
    }
  }

  private func finalize(statement: NativeStatement, database: NativeDatabase) throws {
    if sqlite3_finalize(statement.pointer) != SQLITE_OK {
      throw SQLiteErrorException(convertSqlLiteErrorToString(database))
    }
    if let index = cachedStatements.firstIndex(of: statement) {
      cachedStatements.remove(at: index)
    }
  }

  private func convertSqlLiteErrorToString(_ db: NativeDatabase) -> String {
    let code = sqlite3_errcode(db.pointer)
    let message = String(cString: sqlite3_errmsg(db.pointer), encoding: .utf8) ?? ""
    return "Error code \(code): \(message)"
  }

  private func closeDatabase(_ db: NativeDatabase) {
    if db.openOptions.enableCRSQLite {
      sqlite3_exec(db.pointer, "SELECT crsql_finalize()", nil, nil, nil)
    }
    sqlite3_close(db.pointer)

    if let index = contextPairs.firstIndex(where: {
      guard let pair = $0.takeUnretainedValue() as? (SQLiteModuleNext, NativeDatabase) else {
        return false
      }
      if pair.1.sharedObjectId != db.sharedObjectId {
        return false
      }
      $0.release()
      return true
    }) {
      contextPairs.remove(at: index)
    }
  }

  private func deleteDatabase(dbName: String) throws {
    for database in cachedDatabases where database.dbName == dbName {
      throw DeleteDatabaseException(dbName)
    }

    guard let path = pathForDatabaseName(name: dbName) else {
      throw Exceptions.FileSystemModuleNotFound()
    }

    if !FileManager.default.fileExists(atPath: path.absoluteString) {
      throw DatabaseNotFoundException(dbName)
    }

    do {
      try FileManager.default.removeItem(atPath: path.absoluteString)
    } catch {
      throw DeleteDatabaseFileException(dbName)
    }
  }

  private func addUpdateHook(_ database: NativeDatabase) {
    let contextPair = Unmanaged.passRetained(((self, database) as AnyObject))
    contextPairs.append(contextPair)
    // swiftlint:disable:next multiline_arguments
    sqlite3_update_hook(database.pointer, { obj, action, dbName, tableName, rowId in
      guard let obj,
        let tableName,
        let pair = Unmanaged<AnyObject>.fromOpaque(obj).takeUnretainedValue() as? (SQLiteModuleNext, NativeDatabase) else {
        return
      }
      let selfInstance = pair.0
      let database = pair.1
      let dbFilePath = sqlite3_db_filename(database.pointer, dbName)
      if selfInstance.hasListeners, let dbName, let dbFilePath {
        selfInstance.sendEvent("onDatabaseChange", [
          "dbName": String(cString: UnsafePointer(dbName)),
          "dbFilePath": String(cString: UnsafePointer(dbFilePath)),
          "tableName": String(cString: UnsafePointer(tableName)),
          "rowId": rowId,
          "typeId": SQLAction.fromCode(value: action)
        ])
      }
    },
    contextPair.toOpaque())
  }

  private func getRow(statement: NativeStatement) throws -> Row {
    var row = Row()
    let columnCount = sqlite3_column_count(statement.pointer)
    for i in 0..<Int(columnCount) {
      let columnName = String(cString: sqlite3_column_name(statement.pointer, Int32(i)))
      row[columnName] = try getColumnValue(statement: statement, at: Int32(i))
    }
    return row
  }

  private func getColumnValue(statement: NativeStatement, at index: Int32) throws -> Any {
    let instance = statement.pointer
    let type = sqlite3_column_type(instance, index)

    switch type {
    case SQLITE_INTEGER:
      return sqlite3_column_int(instance, index)
    case SQLITE_FLOAT:
      return sqlite3_column_double(instance, index)
    case SQLITE_TEXT:
      guard let text = sqlite3_column_text(instance, index) else {
        throw InvalidConvertibleException("Null text")
      }
      return String(cString: text)
    case SQLITE_BLOB:
      guard let blob = sqlite3_column_blob(instance, index) else {
        throw InvalidConvertibleException("Null blob")
      }
      let size = sqlite3_column_bytes(instance, index)
      return Data(bytes: blob, count: Int(size))
    case SQLITE_NULL:
      return NSNull()
    default:
      throw InvalidConvertibleException("Unsupported column type: \(type)")
    }
  }

  private func bindStatementParam(statement: NativeStatement, with param: Any, at index: Int32) throws {
    let instance = statement.pointer
    switch param {
    case Optional<Any>.none:
      sqlite3_bind_null(instance, index)
    case let param as NSNull:
      sqlite3_bind_null(instance, index)
    case let param as Int:
      sqlite3_bind_int(instance, index, Int32(param))
    case let param as Double:
      sqlite3_bind_double(instance, index, param)
    case let param as String:
      sqlite3_bind_text(instance, index, param, Int32(param.count), SQLITE_TRANSIENT)
    case let param as Data:
      param.withUnsafeBytes {
        sqlite3_bind_blob(instance, index, $0.baseAddress, Int32(param.count), SQLITE_TRANSIENT)
      }
    case let param as Bool:
      sqlite3_bind_int(instance, index, param ? 1 : 0)
    default:
      throw InvalidConvertibleException("Unsupported parameter type: \(type(of: param))")
    }
  }
}
