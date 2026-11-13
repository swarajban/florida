import Foundation
import GRDB
import GRDBSQLite

extension AppDatabase {
    static func sharedConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            guard !db.configuration.readonly else { return }
            var flag: Int32 = 1
            let code = sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, &flag)
            guard code == SQLITE_OK else { throw DatabaseError(resultCode: ResultCode(rawValue: code)) }
        }
        return configuration
    }

    static func protectSharedFiles(at path: String) throws {
        #if os(iOS)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        for file in [directory, path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: file) {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: file)
        }
        #endif
    }
}
