import Darwin
import Foundation
import Security

enum CredentialStore {
    private static let filename = "wind-api-key"
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    static func read() throws -> String? {
        guard let directory = try openDirectory(create: false) else { return nil }
        defer { close(directory) }
        let file = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw StorageError.read
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, isOwnedFile(info), info.st_mode & 0o7777 == 0o600, hasNoSharedACL(file) else {
            throw StorageError.permissions
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        guard let data = try? handle.readToEnd(),
              let value = String(data: data, encoding: .utf8), isValid(value) else { throw StorageError.read }
        return value
    }

    static func save(_ key: String) throws {
        guard isValid(key), let directory = try openDirectory(create: true) else { throw StorageError.save }
        defer { close(directory) }
        var previous = stat()
        if fstatat(directory, filename, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
            guard isOwnedFile(previous) else { throw StorageError.permissions }
        } else if errno != ENOENT {
            throw StorageError.save
        }

        let temporary = ".wind-api-key-" + UUID().uuidString
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw StorageError.save }
        defer {
            close(file)
            unlinkat(directory, temporary, 0)
        }
        try restrictAccess(to: file, mode: 0o600)
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        do { try handle.write(contentsOf: Data(key.utf8)) } catch { throw StorageError.save }
        guard fsync(file) == 0, renameat(directory, temporary, directory, filename) == 0 else {
            throw StorageError.save
        }
    }

    // Only the explicit migration action invokes Security.framework.
    static func migrateFromKeychain() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.winddesk.menubar",
            kSecAttrAccount as String: "alice-market-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), isValid(key) else {
            throw StorageError.migration
        }
        try save(key)
        return key
    }

    private static func isValid(_ key: String) -> Bool {
        !key.isEmpty && !key.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    private static func isOwnedFile(_ info: stat) -> Bool {
        info.st_uid == geteuid() && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
    }

    // Keep all operations relative to verified descriptors. Renaming a path or
    // replacing it with a symlink cannot redirect an open directory descriptor.
    private static func openDirectory(create: Bool) throws -> Int32? {
        var parent = open(FileManager.default.homeDirectoryForCurrentUser.path, directoryFlags)
        guard parent >= 0 else { throw StorageError.permissions }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid() else { throw StorageError.permissions }
        for component in ["Library", "Application Support"] {
            let child = openat(parent, component, directoryFlags)
            guard child >= 0 else { throw StorageError.permissions }
            close(parent)
            parent = child
            guard fstat(parent, &info) == 0, info.st_uid == geteuid() else { throw StorageError.permissions }
        }

        if create && mkdirat(parent, "WindDesk", mode_t(0o700)) != 0 && errno != EEXIST {
            throw StorageError.save
        }
        let folder = openat(parent, "WindDesk", directoryFlags)
        guard folder >= 0 else {
            if !create && errno == ENOENT { return nil }
            throw StorageError.permissions
        }
        do {
            guard fstat(folder, &info) == 0, info.st_uid == geteuid() else { throw StorageError.permissions }
            if create {
                try restrictAccess(to: folder, mode: 0o700)
            } else if info.st_mode & 0o7777 != 0o700 || !hasNoSharedACL(folder) {
                throw StorageError.permissions
            }
            return folder
        } catch {
            close(folder)
            throw error
        }
    }

    private static func hasNoSharedACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }

    private static func restrictAccess(to descriptor: Int32, mode: mode_t) throws {
        // Remove inherited macOS sharing ACLs before any credential bytes are written.
        guard let acl = acl_init(0) else { throw StorageError.permissions }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0, fchmod(descriptor, mode) == 0 else {
            throw StorageError.permissions
        }
    }

    private enum StorageError: LocalizedError {
        case read, save, permissions, migration

        var errorDescription: String? {
            switch self {
            case .read: "无法读取本地密钥，请重新保存 Wind API Key。"
            case .save: "无法保存本地密钥，请检查当前用户的文件写入权限。"
            case .permissions: "本地密钥目录或文件的所有者、类型或访问权限不符合要求。"
            case .migration: "未能读取旧钥匙串中的密钥。你也可以直接输入 API Key。"
            }
        }
    }
}
