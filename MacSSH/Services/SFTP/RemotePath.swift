import Foundation

/// 远端 SFTP 路径的纯文本语义（任务书：绝不使用本地 FileManager 语义）。
///
/// 规则：
/// - 绝对路径，根为 `"/"`；`parent("/") == "/"`；
/// - `join` 永不产生 `//`（例如 `join("/", child:) == "/child"`）；
/// - 规范化只做去空段与去尾部斜杠，不解释远端符号链接，
///   也不假设本地文件系统行为。
enum RemotePath {
    static let root = "/"

    /// 规范化：空 / 纯斜杠 → `"/"`；折叠重复斜杠并去掉尾部斜杠。
    /// 例：`""→"/"`、`"//etc"→"/etc"`、`"/a//b/"→"/a/b"`。
    static func normalized(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            return root
        }
        return root + components.joined(separator: "/")
    }

    /// 父目录：`"/a/b"→"/a"`、`"/a"→"/"`、`"/"→"/"`。
    static func parent(of path: String) -> String {
        let components = normalized(path)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else {
            return root
        }
        return root + components.dropLast().joined(separator: "/")
    }

    /// 安全拼接子项名称（来自服务器列举，已过滤 `.` / `..`；
    /// 防御性地再处理一次，绝不向上跳）。
    /// `join("/", "etc") == "/etc"`；`join("/a", "b") == "/a/b"`（无 `//`）。
    static func join(_ base: String, child: String) -> String {
        guard !child.isEmpty, child != "." else {
            return normalized(base)
        }
        guard child != ".." else {
            return parent(of: base)
        }
        let normalizedBase = normalized(base)
        if normalizedBase == root {
            return normalized(root + child)
        }
        return normalized(normalizedBase + "/" + child)
    }

    /// 是否为根目录（Parent 按钮禁用判断）。
    static func isRoot(_ path: String) -> Bool {
        normalized(path) == root
    }
}
