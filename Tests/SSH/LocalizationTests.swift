import Foundation
import XCTest
@testable import MacSSH

/// MacSSH 1.1 Phase 1：String Catalog 完整性与关键路径文案审计。
///
/// 任务书六十二 / 七十八：zh-Hans / en 必须有完整翻译，
/// 不允许 Missing / Untranslated / raw key 泄漏到生产 UI。
///
/// 断言策略（任务书七十九：不要为每个 string 写脆弱断言）：
/// 对关键 UI key 校验 zh-Hans / en 均非空、互不相同、且不等于 raw key；
/// 其余 key 由构建期 String Catalog 完整性（脚本生成全量翻译）与
/// 人工 UI Sweep 兜底。
final class LocalizationTests: XCTestCase {
    // MARK: - 关键 UI key：zh-Hans / en 均非空

    /// 任务书七十八：关键 UI key 在 zh-Hans 与 en 都必须非空。
    /// 覆盖设置、侧栏、终端、主机、传输、动作等核心入口。
    func testCriticalKeysHaveZhHansAndEnglishTranslations() {
        let criticalKeys: [String] = [
            "settings.language",
            "settings.title",
            "sidebar.local_terminal",
            "sidebar.hosts",
            "sidebar.transfers",
            "sidebar.settings",
            "hosts.title",
            "terminal.title",
            "transfers.title",
            "files.title",
            "action.connect",
            "action.cancel",
            "action.delete",
            "action.save",
            "action.close",
            "action.reconnect",
            "action.retry",
            "action.upload",
            "action.download",
            "transfer.state.transferring",
            "transfer.state.waiting",
            "transfer.state.completed",
            "transfer.state.failed",
        ]
        for key in criticalKeys {
            let zh = L10n.string(key, defaultValue: "", locale: AppLanguage.simplifiedChinese.locale)
            let en = L10n.string(key, defaultValue: "", locale: AppLanguage.english.locale)
            XCTAssertFalse(zh.isEmpty, "zh-Hans translation missing for key: \(key)")
            XCTAssertFalse(en.isEmpty, "en translation missing for key: \(key)")
        }
    }

    // MARK: - 关键 UI key：不泄漏 raw key 且 zh-Hans != en

    /// 任务书六十三：生产 UI 不得显示 raw key（如"settings.language"字面）。
    /// 同时 zh-Hans != en 用于发现"未翻译直接回退英文"的遗漏。
    func testCriticalKeysDoNotLeakRawKeys() {
        let criticalKeys: [String] = [
            "settings.title",
            "sidebar.hosts",
            "terminal.title",
            "transfers.title",
            "host_editor.hostname",
            "host_editor.username",
            "action.connect",
            "action.cancel",
            "action.delete",
            "action.save",
            "transfer.state.transferring",
            "transfer.state.waiting",
            "sftp.column.name",
            "sftp.column.size",
            "known_hosts.title",
            "host_key_changed.title",
            "host_trust.title",
        ]
        for key in criticalKeys {
            let zh = L10n.string(key, defaultValue: "", locale: AppLanguage.simplifiedChinese.locale)
            let en = L10n.string(key, defaultValue: "", locale: AppLanguage.english.locale)
            XCTAssertNotEqual(zh, key, "zh-Hans leaked raw key: \(key)")
            XCTAssertNotEqual(en, key, "en leaked raw key: \(key)")
            XCTAssertNotEqual(zh, en, "zh-Hans equals en for key \(key) — translation missing")
        }
    }

    // MARK: - 动态字符串插值

    /// 任务书四十：动态字符串必须使用可本地化 format。
    /// 验证 transfer.queue.waiting 的插值在 zh-Hans 与 en 都能正确渲染。
    func testFormatInterpolationRendersInBothLocales() {
        let zh = L10n.format(
            "transfer.queue.waiting",
            defaultValue: "%lld Waiting",
            locale: AppLanguage.simplifiedChinese.locale,
            arguments: Int64(3)
        )
        let en = L10n.format(
            "transfer.queue.waiting",
            defaultValue: "%lld Waiting",
            locale: AppLanguage.english.locale,
            arguments: Int64(3)
        )
        XCTAssertTrue(zh.contains("3"), "zh-Hans format missing argument: \(zh)")
        XCTAssertTrue(en.contains("3"), "en format missing argument: \(en)")
        XCTAssertNotEqual(zh, en, "queue summary not localized between zh-Hans and en")
    }

    /// 任务书四十：删除确认必须由可本地化 format 携带文件名，
    /// 禁止 `Text("Delete \(name)?")` 这类不可翻译拼接。
    func testDeleteConfirmationInterpolatesFileName() {
        let zh = L10n.format(
            "sftp.delete_named_title",
            defaultValue: "Delete “%@”?",
            locale: AppLanguage.simplifiedChinese.locale,
            arguments: "README.md"
        )
        let en = L10n.format(
            "sftp.delete_named_title",
            defaultValue: "Delete “%@”?",
            locale: AppLanguage.english.locale,
            arguments: "README.md"
        )
        XCTAssertTrue(zh.contains("README.md"), "zh-Hans must interpolate file name: \(zh)")
        XCTAssertTrue(en.contains("README.md"), "en must interpolate file name: \(en)")
        XCTAssertNotEqual(zh, en, "delete confirmation not localized between zh-Hans and en")
    }

    // MARK: - 错误文案本地化

    /// 任务书三十 / 六十二：错误信息必须本地化，zh-Hans / en 都非空且不同。
    func testErrorMessagesAreLocalizedForCriticalKeys() {
        let errorKeys: [String] = [
            "error.ssh.connection_lost",
            "error.ssh.authentication",
            "error.ssh.timeout",
            "error.ssh.host_key_changed",
            "error.sftp.subsystem",
            "error.sftp.permission_denied",
            "error.transfer.cancelled",
            "error.transfer.connection_lost",
            "error.transfer.remote_file_exists",
            "error.keychain.item_not_found",
            "error.remote.channel_open",
        ]
        for key in errorKeys {
            let zh = L10n.string(key, defaultValue: "", locale: AppLanguage.simplifiedChinese.locale)
            let en = L10n.string(key, defaultValue: "", locale: AppLanguage.english.locale)
            XCTAssertFalse(zh.isEmpty, "zh-Hans error missing: \(key)")
            XCTAssertFalse(en.isEmpty, "en error missing: \(key)")
            XCTAssertNotEqual(zh, en, "error not localized between zh-Hans and en: \(key)")
        }
    }

    // MARK: - 主机密钥警告翻译强度

    /// 任务书二十九：Host Key Changed 是安全文本，中英文都必须准确，
    /// 不得降低警告强度。这里断言关键警示词在两种语言里都出现。
    func testHostKeyChangedWarningCarriesStrongWording() {
        let titleZh = L10n.string(
            "host_key_changed.title",
            defaultValue: "",
            locale: AppLanguage.simplifiedChinese.locale
        )
        let titleEn = L10n.string(
            "host_key_changed.title",
            defaultValue: "",
            locale: AppLanguage.english.locale
        )
        XCTAssertTrue(titleZh.contains("更改"), "zh-Hans host key changed title must mention 更改: \(titleZh)")
        XCTAssertTrue(titleEn.lowercased().contains("changed"), "en host key changed title must mention changed: \(titleEn)")

        let replaceZh = L10n.string(
            "host_key_changed.replace",
            defaultValue: "",
            locale: AppLanguage.simplifiedChinese.locale
        )
        let replaceEn = L10n.string(
            "host_key_changed.replace",
            defaultValue: "",
            locale: AppLanguage.english.locale
        )
        XCTAssertTrue(replaceZh.contains("替换"), "zh-Hans replace must mention 替换: \(replaceZh)")
        XCTAssertTrue(replaceEn.lowercased().contains("replace"), "en replace must mention replace: \(replaceEn)")

        let forgetZh = L10n.string(
            "known_hosts.forget",
            defaultValue: "",
            locale: AppLanguage.simplifiedChinese.locale
        )
        XCTAssertFalse(forgetZh.isEmpty, "known_hosts.forget zh-Hans must not be empty")
    }

    // MARK: - 运行时文案按 Locale 切换（任务书七十三：不缓存）

    /// TransferError 的失败文案在 zh-Hans / en 下必须不同，
    /// 证明 Alert 文案不是启动时缓存的英文。
    func testTransferErrorMessageSwitchesWithLocale() {
        let zhCancelled = TransferError.cancelled.message(locale: AppLanguage.simplifiedChinese.locale)
        let enCancelled = TransferError.cancelled.message(locale: AppLanguage.english.locale)
        XCTAssertNotEqual(zhCancelled, enCancelled, "TransferError.cancelled must differ by locale")
        XCTAssertFalse(zhCancelled.isEmpty)
        XCTAssertFalse(enCancelled.isEmpty)

        let zhExists = TransferError.remoteFileExists.message(locale: AppLanguage.simplifiedChinese.locale)
        let enExists = TransferError.remoteFileExists.message(locale: AppLanguage.english.locale)
        XCTAssertNotEqual(zhExists, enExists, "TransferError.remoteFileExists must differ by locale")
    }

    /// TransferTask 状态文案按 Locale 切换（语言切换不取消 / 重置传输）。
    @MainActor
    func testTransferTaskStateDisplaySwitchesWithLocale() {
        let task = TransferTask(
            direction: .upload,
            sessionID: UUID(),
            sessionTitle: "Test",
            remotePath: "/tmp/test.bin",
            localName: "test.bin",
            localURL: URL(fileURLWithPath: "/tmp/test.bin")
        )
        let zh = task.stateDisplay(locale: AppLanguage.simplifiedChinese.locale)
        let en = task.stateDisplay(locale: AppLanguage.english.locale)
        XCTAssertNotEqual(zh, en, "stateDisplay must differ by locale")
        XCTAssertFalse(zh.isEmpty)
        XCTAssertFalse(en.isEmpty)
    }

    /// 认证方式显示名使用 localization key，不直接暴露 Swift enum rawValue
    /// （任务书二十七：rawValue 不应作为最终 UI 文案）。
    func testAuthenticationTypeUsesLocalizedDisplayLabels() {
        let zhPassword = L10n.string(
            "authentication.password",
            defaultValue: "",
            locale: AppLanguage.simplifiedChinese.locale
        )
        let enPassword = L10n.string(
            "authentication.password",
            defaultValue: "",
            locale: AppLanguage.english.locale
        )
        XCTAssertEqual(zhPassword, "密码")
        XCTAssertEqual(enPassword, "Password")

        let zhKey = L10n.string(
            "authentication.private_key",
            defaultValue: "",
            locale: AppLanguage.simplifiedChinese.locale
        )
        let enKey = L10n.string(
            "authentication.private_key",
            defaultValue: "",
            locale: AppLanguage.english.locale
        )
        XCTAssertEqual(zhKey, "私钥")
        XCTAssertEqual(enKey, "Private Key")

        // rawValue 不直接作为 UI 文案：中文标签 ≠ "password" / "privateKey"。
        XCTAssertNotEqual(zhPassword, AuthenticationType.password.rawValue)
        XCTAssertNotEqual(zhKey, AuthenticationType.privateKey.rawValue)
    }

    // MARK: - String Catalog 全量完整性（任务书六十二 / 一百）

    /// 全量审计：String Catalog 中的每一个 key 都必须在 zh-Hans 与 en
    /// 两个语言下都有非空翻译，且不等于 raw key（任务书六十二：不允许
    /// 大量 Missing / Untranslated；任务书六十三：不泄漏 raw key）。
    ///
    /// 这是"不为 500 个 string 写 500 条脆弱断言"的替代方案：
    /// 以 Catalog 自身为数据源做遍历审计，新增 key 自动纳入。
    func testCatalogKeysAllHaveCompleteTranslations() throws {
        let keys = try catalogKeys()
        XCTAssertGreaterThan(keys.count, 200, "Catalog key 数量异常少，资源可能未打包进 App")

        var missingZhHans: [String] = []
        var missingEnglish: [String] = []

        for key in keys {
            let zh = L10n.string(key, defaultValue: "", locale: AppLanguage.simplifiedChinese.locale)
            let en = L10n.string(key, defaultValue: "", locale: AppLanguage.english.locale)
            if zh.isEmpty || zh == key {
                missingZhHans.append(key)
            }
            if en.isEmpty || en == key {
                missingEnglish.append(key)
            }
        }

        XCTAssertTrue(
            missingZhHans.isEmpty,
            "zh-Hans 缺少翻译的 key: \(missingZhHans.sorted().joined(separator: ", "))"
        )
        XCTAssertTrue(
            missingEnglish.isEmpty,
            "en 缺少翻译的 key: \(missingEnglish.sorted().joined(separator: ", "))"
        )
    }

    /// 任务书一百：String Catalog 不得包含 obsolete / 垃圾 key。
    ///
    /// 生成脚本以字典写 JSON，duplicate key 天然不可能；这里校验每个
    /// Catalog key 都在源码中被引用过至少一次（覆盖参数传递、三元返回、
    /// `StaticString` 赋值、插值前缀等各种调用形式）。
    func testCatalogHasNoObsoleteKeys() throws {
        let referenced = try sourceReferencedKeys()
        let orphaned = try catalogKeys().subtracting(referenced)
        XCTAssertTrue(
            orphaned.isEmpty,
            "String Catalog 含源码未使用的 key: \(orphaned.sorted().joined(separator: ", "))"
        )
    }

    // MARK: - 审计工具

    /// 扫描 MacSSH 源码目录，提取全部 localization key。
    ///
    /// 采用宽松匹配：取出源码中所有 `xxx.yyy` 形态的字符串字面量，
    /// 因此参数传递、三元返回、`StaticString` 赋值、插值前缀、独立
    /// `return` 等各种调用形式都能被覆盖。
    ///
    /// 注意：这里只用于"Catalog key 是否被引过一次"的 obsolete 检查，
    /// 不用于翻译完整性检查（完整性直接以 Catalog 自身为数据源）。
    /// accessibilityIdentifier 的字符串不剔除——同一个字符串可能同时
    /// 用作 identifier 与 localization key（如 `settings.language`）。
    private func sourceReferencedKeys() throws -> Set<String> {
        let root = try repositoryRoot()
        let sourceDirectory = root.appendingPathComponent("MacSSH", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        // 宽松匹配："a.b"、"a.b.c" 等点分层级字面量。
        // key 后可跟引号结尾，也可跟空白 + 插值分隔符
        // （`Text("key \(value)")`——该形式下 key 以空白结束）。
        let dottedLiteral = try NSRegularExpression(
            pattern: #""([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)(?:"|\s)"#
        )

        var candidates: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(content.startIndex..., in: content)
            for match in dottedLiteral.matches(in: content, range: range) {
                if let keyRange = Range(match.range(at: 1), in: content) {
                    candidates.insert(String(content[keyRange]))
                }
            }
        }
        return candidates
    }

    /// 读取 Localizable.xcstrings 中定义的全部 key。
    private func catalogKeys() throws -> Set<String> {
        let root = try repositoryRoot()
        let catalogURL = root
            .appendingPathComponent("MacSSH", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard
            let dictionary = object as? [String: Any],
            let strings = dictionary["strings"] as? [String: Any]
        else {
            throw NSError(domain: "LocalizationTests", code: 2, userInfo: nil)
        }
        return Set(strings.keys)
    }

    /// 从测试文件位置反推仓库根目录（…/Tests/SSH/*.swift → 仓库根）。
    private func repositoryRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        // <root>/Tests/SSH/LocalizationTests.swift → 上溯 3 层
        var url = fileURL
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("MacSSH.xcodeproj").path
        ) else {
            throw NSError(domain: "LocalizationTests", code: 1, userInfo: nil)
        }
        return url
    }
}
