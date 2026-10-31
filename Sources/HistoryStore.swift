import Foundation
import SQLite3

struct ExportRecord: Identifiable, Sendable {
    let id: Int64
    let date: Date
    let relativePath: String
    let gamma: String
    let lut: String
    let elapsed: Double
    let success: Bool
    let outputPath: String
    let fileSize: Int64
    let error: String
}

final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    init() throws {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/DLogGrader", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("history.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "DLogGrader", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开导出记录数据库"] ) }
        let sql = """
        CREATE TABLE IF NOT EXISTS exports (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          date REAL NOT NULL, relative_path TEXT NOT NULL, gamma TEXT NOT NULL,
          lut TEXT NOT NULL, elapsed REAL NOT NULL, success INTEGER NOT NULL,
          output_path TEXT NOT NULL, file_size INTEGER NOT NULL, error TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_exports_dedupe ON exports(relative_path, file_size, success);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "DLogGrader", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法初始化导出记录数据库"] ) }
    }

    deinit { if let db { sqlite3_close(db) } }

    func hasSuccess(outputPath: String, hdr: Bool, archiveRoot: URL? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT relative_path,file_size,lut FROM exports WHERE output_path=? AND success=1 ORDER BY id DESC", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(outputPath, to: statement, at: 1)
        let output = URL(fileURLWithPath: outputPath)
        guard let actualSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else { return false }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard (string(statement, 2) == "HLG (shader)") == hdr else { continue }
            guard actualSize == sqlite3_column_int64(statement, 1) else { continue }
            if let archiveRoot, !FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent(string(statement, 0)).path) { continue }
            return true
        }
        return false
    }

    func insert(date: Date = Date(), relativePath: String, gamma: String, lut: String, elapsed: Double, success: Bool, outputPath: String, fileSize: Int64, error: String) {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        let sql = "INSERT INTO exports(date,relative_path,gamma,lut,elapsed,success,output_path,file_size,error) VALUES(?,?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        bind(relativePath, to: statement, at: 2)
        bind(gamma, to: statement, at: 3)
        bind(lut, to: statement, at: 4)
        sqlite3_bind_double(statement, 5, elapsed)
        sqlite3_bind_int(statement, 6, success ? 1 : 0)
        bind(outputPath, to: statement, at: 7)
        sqlite3_bind_int64(statement, 8, fileSize)
        bind(error, to: statement, at: 9)
        sqlite3_step(statement)
    }

    func all() -> [ExportRecord] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,date,relative_path,gamma,lut,elapsed,success,output_path,file_size,error FROM exports ORDER BY date DESC,id DESC", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [ExportRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(ExportRecord(
                id: sqlite3_column_int64(statement, 0), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                relativePath: string(statement, 2), gamma: string(statement, 3), lut: string(statement, 4),
                elapsed: sqlite3_column_double(statement, 5), success: sqlite3_column_int(statement, 6) == 1,
                outputPath: string(statement, 7), fileSize: sqlite3_column_int64(statement, 8), error: string(statement, 9)))
        }
        return rows
    }

    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    private func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: bytes)
    }
}
