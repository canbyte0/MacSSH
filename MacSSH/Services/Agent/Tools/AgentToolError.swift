import Foundation

/// Phase 10D Agent 工具错误的统一分类（任务书 10D-B1 §20）。
///
/// 本阶段只建立错误分类，不实现任何工具执行。除路径解析器产出的
/// 少数 case 外，其余 case（fileTooLarge / binaryUnsupported 等）尚无
/// 产生方——这是预期状态：任务书明确允许先定义尚未使用的分类，
/// 但禁止为它们编写虚假实现。
///
/// 设计约束：不带关联值。错误语义必须是可判等的纯分类（测试可硬
/// 断言），上下文细节由调用方日志补充，绝不把敏感路径内容塞进错误
/// 对象传播给模型。
enum AgentToolError: Error, Equatable, Sendable {
    /// 目标终端会话已结束或不可寻址。
    case sessionUnavailable
    /// 工具参数非法（空路径、`~user` 形式、非 file scheme 的 OSC 7 URL 等）。
    case invalidArguments
    /// 没有权威 cwd，无法解析相对路径。
    ///
    /// 绝不 fallback 到 HOME、App 进程 cwd 或 FileManager 默认目录
    /// （任务书 §13：cwd 不可用时唯一正确结果是失败）。
    case cwdUnavailable
    /// 解析后的 canonical 路径越出 `AgentReadScope` 允许根。
    case outsideAllowedReadScope
    /// 工具名不在静态注册表内（§31：绝不是 dynamic dispatch 失败）。
    case unknownTool
    /// 该会话类型不支持此工具（§32/§51：Remote 文件工具一律拒绝）。
    case unsupportedForSession
    /// readScope 绑定的 sessionID 与请求的 sessionID 不一致（§33/§34 P1）。
    case scopeSessionMismatch
    /// 目标路径不存在（存在性验证由下一层执行，本层只保证不因
    /// 不存在而绕过 symlink containment）。
    case pathNotFound
    /// 文件系统权限拒绝。
    case permissionDenied
    /// 目标存在但不是普通文件。
    case notAFile
    /// 目标存在但不是目录。
    case notADirectory
    /// 目标超过读取大小上限。
    case fileTooLarge
    /// 目标是二进制内容，拒绝以文本形式返回给模型。
    case binaryUnsupported
    /// 用户或系统取消了操作。
    case cancelled
    /// 非预期内部错误（symlink 环、规范化解算失败等）。
    case internalFailure
}
