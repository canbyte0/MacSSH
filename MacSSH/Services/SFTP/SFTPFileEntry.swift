import Foundation

/// 单个远端文件 / 目录的元数据快照（Phase 9 只读）。
///
/// 字段全部由服务器在目录列举时随 `LIBSSH2_SFTP_ATTRIBUTES` 返回，
/// 并按 `flags` 决定存在性——绝不额外发起 N+1 次 stat，
/// 也绝不解析 `longentry` 文本。
struct SFTPFileEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case regularFile
        case symlink
        case other
    }

    /// 文件名（UTF-8 解码；服务器返回的原始字节，不做本地路径语义）。
    let name: String

    /// 类型；`permissions` 缺失时为 `.other`。
    let kind: Kind

    /// 字节大小；服务器未提供（flags 无 SIZE）时为 nil。
    let sizeBytes: UInt64?

    /// 修改时间；服务器未提供（flags 无 ACMODTIME）时为 nil。
    let modifiedAt: Date?

    /// POSIX 权限位；服务器未提供（flags 无 PERMISSIONS）时为 nil。
    let permissions: UInt32?

    /// 数字属主 / 属组（服务器通常不回显名称；仅展示数字）。
    let ownerUID: UInt32?
    let ownerGID: UInt32?

    /// 同目录内文件名唯一，可作稳定标识。
    var id: String { name }

    var isDirectory: Bool { kind == .directory }
    var isSymlink: Bool { kind == .symlink }

    /// 权限列（`ls` 风格 10 字符，如 `drwxr-xr-x`）；缺失时 "—"。
    var permissionsDisplay: String {
        guard let permissions else {
            return "—"
        }
        return Self.formatPermissions(permissions, kind: kind)
    }

    /// 大小列；目录显示 "—"，缺失显示 "—"。
    var sizeDisplay: String {
        guard kind != .directory, let sizeBytes else {
            return "—"
        }
        return Self.formatByteCount(sizeBytes)
    }

    /// 修改时间列；缺失显示 "—"。
    var modifiedDisplay: String {
        guard let modifiedAt else {
            return "—"
        }
        return Self.modifiedFormatter.string(from: modifiedAt)
    }

    private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func formatPermissions(_ mode: UInt32, kind: Kind) -> String {
        let typeChar: Character
        switch kind {
        case .directory:
            typeChar = "d"
        case .symlink:
            typeChar = "l"
        case .regularFile:
            typeChar = "-"
        case .other:
            typeChar = "?"
        }

        var text = String(typeChar)
        let shifts: [(shift: UInt32, setuidLike: Bool)] = [
            (shift: 6, setuidLike: true), // owner
            (shift: 3, setuidLike: false), // group
            (shift: 0, setuidLike: false), // other
        ]
        for entry in shifts {
            let bits = (mode >> entry.shift) & 0o7
            text.append(bits & 0o4 != 0 ? "r" : "-")
            text.append(bits & 0o2 != 0 ? "w" : "-")
            if bits & 0o1 != 0 {
                // setuid/setgid/sticky 位置（owner/group/other）。
                switch entry.shift {
                case 6:
                    text.append(mode & 0o4000 != 0 ? "s" : "x")
                case 3:
                    text.append(mode & 0o2000 != 0 ? "s" : "x")
                default:
                    text.append(mode & 0o1000 != 0 ? "t" : "x")
                }
            } else {
                switch entry.shift {
                case 6:
                    text.append(mode & 0o4000 != 0 ? "S" : "-")
                case 3:
                    text.append(mode & 0o2000 != 0 ? "S" : "-")
                default:
                    text.append(mode & 0o1000 != 0 ? "T" : "-")
                }
            }
        }
        return text
    }

    private static func formatByteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
