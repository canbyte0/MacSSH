import Foundation

// MARK: - 工具名与静态注册表（任务书 §30/§31）

/// B2 注册的四个工具名。
///
/// 注册表是**静态枚举**：禁止 dynamic reflection、禁止任意字符串 →
/// selector 派发（§31）。未知名字 → `AgentToolError.unknownTool`。
enum AgentToolName: String, Sendable, CaseIterable, Equatable {
    case getTerminalContext = "get_terminal_context"
    case getCurrentDirectory = "get_current_directory"
    case listDirectory = "list_directory"
    case readFile = "read_file"

    /// 变更风险轴（§11/§30）：本阶段全部 readOnly。
    var risk: AgentToolRisk { .readOnly }

    /// 数据披露轴（§11/§30）。
    var dataAccessPolicy: AgentDataAccessPolicy {
        switch self {
        case .getTerminalContext, .getCurrentDirectory:
            return .sessionContext
        case .listDirectory, .readFile:
            return .scopedFileRead
        }
    }

    /// Remote 会话支持性（§32/§52）：B3 起 Remote 文件读取改走
    /// `AgentRemoteReadOnlyFileService`（origin session 的现有已认证
    /// SSHConnection + 既有 SFTP 子系统），四个工具全部支持 Remote；
    /// 注册表保留这道闸门，供未来新增工具显式声明（未声明者一律
    /// `unsupportedForSession`，绝不默认放行）。
    var supportsRemoteSession: Bool {
        switch self {
        case .getTerminalContext, .getCurrentDirectory, .listDirectory, .readFile:
            return true
        }
    }
}

/// 静态注册表（§31）。B2 不把它传给 Provider，只供内部派发与测试。
enum AgentToolRegistry: Sendable {
    static let all: [AgentToolName] = AgentToolName.allCases

    static func lookup(_ name: String) -> AgentToolName? {
        AgentToolName(rawValue: name)
    }
}

// MARK: - 调用（任务书 §34）

/// 一次工具调用（vendor-neutral：参数本阶段只有路径）。
struct AgentToolCall: Sendable, Equatable {
    let name: String
    let arguments: [String: String]

    init(name: String, arguments: [String: String] = [:]) {
        self.name = name
        self.arguments = arguments
    }

    init(_ name: AgentToolName, arguments: [String: String] = [:]) {
        self.name = name.rawValue
        self.arguments = arguments
    }

    var path: String? { arguments["path"] }
}

// MARK: - 结果（任务书 §21/§25）

enum AgentDirectoryEntryKind: String, Sendable, Equatable {
    case file
    case directory
    case symbolicLink
    case other

    /// 排序 rank：固定顺序，与 locale 无关（§22）。
    var sortRank: Int {
        switch self {
        case .directory: return 0
        case .symbolicLink: return 1
        case .file: return 2
        case .other: return 3
        }
    }
}

/// 目录条目（§21）。symlink 用 `lstat` 判定，保留「条目本身是链接」的
/// 信息——安全 containment 用 canonicalization（跟随链接），展示层类型
/// 信息不因此丢失。
struct AgentDirectoryEntry: Sendable, Equatable {
    let name: String
    let kind: AgentDirectoryEntryKind
    /// 普通文件的字节大小；目录 / 链接 / 其它为 nil（不跟随链接取大小）。
    let sizeBytes: UInt64?
}

struct AgentDirectoryListing: Sendable, Equatable {
    /// canonical 绝对路径（B1 resolver 产出）。
    let canonicalPath: String
    /// 截断后的条目（≤ 500，§22）。
    let entries: [AgentDirectoryEntry]
    /// 条目数超过 500（§22）。
    let truncated: Bool
    /// 截断前的总条目数。
    let totalEntryCount: Int
}

struct AgentFileContent: Sendable, Equatable {
    let text: String
    /// 返回内容少于文件完整内容（§25）。
    let truncated: Bool
    let bytesReturned: Int
    /// 文件完整大小（fstat 可得时）。
    let originalSize: UInt64?
}

/// 结构化的工具结果（§18：绝不拼成自然语言 blob 再解析）。
enum AgentToolResult: Sendable, Equatable {
    case terminalContext(AgentTerminalContext)
    case currentDirectory(AgentCurrentDirectoryResult)
    case directoryListing(AgentDirectoryListing)
    case fileContent(AgentFileContent)
}
