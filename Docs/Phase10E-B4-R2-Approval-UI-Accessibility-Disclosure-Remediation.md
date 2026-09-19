# MacSSH 1.1 — Phase 10E-B4-R2

## Approval UI State + Accessibility + Disclosure Remediation

日期：2026-09-13  
仓库：`/Users/msl/msl_coding/MacSSH`  
分支：`feature/macssh-1.1-agent-command-execution`  
基线 HEAD：`73038d61b9f2b22b027e3748d06600984186a29a`

## 1. 阶段结论

**Decision: FAIL / BLOCKED**

R2 指定的代码修复、静态契约和目标 XCTest 均通过，未观察到新的 P1/P2 代码失败；但本阶段要求的完整测试全集和真实 Approval Card GUI/Accessibility smoke 仍未完成：当前运行环境的 Keychain/DetachedSignatures 条件导致完整测试在既有凭据测试处停滞，且本机没有已配置的 Provider/API Key fixture，无法安全地启动真实 Provider → `run_command` → Approval Card 流程。根据阶段门禁，不能将本阶段标记为 PASS。

本阶段已停止在 R2，未进入 10E-C，未提交、未 push、未 merge、未 tag。

## 2. UI 预览与授权边界

- 已先生成 Approval Card 的 awaitingApproval/running 预览图。
- 用户已明确回复“确认”后才修改 UI 源码。
- 未创建或保存测试 API Key，未触碰 SSH key、`authorized_keys` 或真实远程主机。
- 保留工作树中已有的 B1–B4 改动和未相关文件；没有执行清理、回滚或覆盖操作。

## 3. R2 实施内容

### 3.1 Running State 修复（P2-1）

修改：`MacSSH/Services/Agent/AgentViewModel.swift`

`approvalCoordinator.claimExecution(...)` 成功后，先同步发布 `running` 状态，再调用 Local/Remote executor。因而在 `posix_spawn` 或 SSH exec side effect 发生前：

- Activity 已从 `awaitingApproval` 进入 `running`；
- Approve/Deny 操作已从 UI 移除；
- Stop 仍可取消 running task；
- executor 的最终 stdout/stderr/exit status 会继续覆盖 transient running result。

Approval authority 仍由 coordinator 持有；UI 只负责触发 approve/deny，不拥有执行授权。

### 3.2 Accessibility 修复（P2-2）

修改：`MacSSH/Features/Agent/AgentToolCardView.swift`

- 外层卡片从 `.accessibilityElement(children: .combine)` 改为 `.contain`，保留卡片容器语义，不把卡片合并成一个 AXPress decision。
- Approve 和 Deny 保留为独立可聚焦、可操作的 AX controls。
- 两个按钮均有本地化 accessibility label、hint 和稳定 identifier：
  - `agent.command.approve`
  - `agent.command.deny`
- card、Approve、Deny 的稳定 identifier 分别为：
  - `agent.tool_card`
  - `agent.command.approve`
  - `agent.command.deny`
- 只有 `awaitingApproval` 显示 Approve/Deny；`running`、success、failure、cancelled 均不显示决策按钮。

### 3.3 Disclosure 修复（P2-3）

修改：`Scripts/gen_localizable.py`，然后执行生成器更新 `MacSSH/Resources/Localizable.xcstrings`。

Agent 空状态和 API Key help 现在明确说明：

- Agent 可以读取终端上下文和当前目录中的文件；
- 命令可以执行，但每条命令都需要用户明确批准；
- 命令运行在独立的 non-interactive process；
- 不会直接输入当前 interactive Terminal；
- 文案没有宣称超出实现范围的 sandbox/权限保证。

同时为 Approve/Deny 增加了本地化 accessibility hint。`.xcstrings` 未手工编辑。

## 4. Tool Surface / Authority 检查

本阶段仍保持五个只读或受控工具：

1. `list_files`
2. `read_file`
3. `list_directory`
4. `read_terminal_context`
5. `run_command`

`send_to_terminal` 未注册；没有新增任意写文件、任意 SSH shell、后台 daemon 或绕过 Approval Coordinator 的 mutation tool。Local/Remote executor 仍由 coordinator 的一次性 claim/redeem authority 保护，重复 approve、replay 和并发消费由既有 B4/10E-B 状态机约束。

## 5. 测试与构建证据

### 5.1 R2 目标 XCTest

最终目标运行日志：`/tmp/macssh-phase10e-b4r2-targeted-final.log`

| Test suite | total | failed |
|---|---:|---:|
| `AgentCommandApprovalConcurrencyTests` | 8 | 0 |
| `AgentCommandApprovalCoordinatorTests` | 29 | 0 |
| `AgentToolLoopTests` | 26 | 0 |
| `LocalizationTests` | 23 | 0 |
| **合计** | **86** | **0** |

新增/覆盖的 R2 核心断言包括：

- executor 尚未完成时，批准后的 Activity 已先发布 `running`；
- `running` 时不显示 Approve/Deny；
- Stop 可取消 running command，且 Provider 不会继续推进下一轮；
- 中英文 disclosure 不再包含“不会执行任何命令”或等价错误文案；
- Accessibility hierarchy 使用 `.contain`，Approve/Deny identifier 保持独立。

### 5.2 Debug / Release 构建

- Debug build-for-testing：`/tmp/MacSSH-Phase10E-B4R2-Debug`
  - 结果：`** TEST BUILD SUCCEEDED **`
- Release build：`/tmp/MacSSH-Phase10E-B4R2-Release`
  - 结果：`** BUILD SUCCEEDED **`
- 对应构建日志中的 production `warning:` 计数：0。
- `git diff --check`：通过。
- staged diff：空。

### 5.3 完整测试全集

R2 请求提供的 B4 baseline 为：1130 discovered、1129 executed、989 passed、140 skipped、0 failed、1 external exclusion。R2 新增至少 4 个测试，但当前没有把新增测试简单并入 baseline 伪造最终全集计数。

本次 fresh full-suite 尝试：

- 首次在 `AgentCredentialServiceTests.testDeleteRemovesKey` 停滞；
- 单独 no-parallel 重跑仍在同一测试停滞；
- 跳过凭据相关测试后，继续在既有 `DeepSeekResponsesProviderTests.testFreshDeepSeekDefaultRequestUsesV4Flash` 处停滞；
- 日志均出现 `logging-persist ... /private/var/db/DetachedSignatures ... No such file or directory`；等待超过 60 秒后按安全方式中止，未把环境停滞计为测试 assertion failure。

因此完整 universe 的最终 discovered/executed/passed/skipped/failed 计数仍为 **pending**，不是 PASS 证据。

## 6. GUI / Accessibility smoke

### 已完成

使用 fresh Release app：`/tmp/MacSSH-Phase10E-B4R2-Release/Build/Products/Release/MacSSH.app`

- Agent 空状态 GUI 已验证：新文案显示“独立的非交互进程”“不会直接输入当前交互式 Terminal”“每条命令都需要明确批准”。旧的“Agent 无法执行命令”含义已消失。
- Settings 页面 API Key help 已验证同样的 disclosure。
- Accessibility tree 可读到完整空状态文案，Send button 在未配置 Provider 时保持 disabled。

### 未完成 / 阻塞

- 真实 Approval Card 的 awaitingApproval/running AX smoke：**NOT RUN**。
- 原因：当前本机没有已配置的本地 Provider/API Key fixture；为完成 smoke 而写入假凭据会产生不必要的敏感持久化状态，因此未执行。
- 真实 `run_command("sleep 8")` GUI path：**NOT RUN**。
- 真实 remote SSH live exec：**NOT RUN**；没有获得可安全使用的远程 fixture。
- 作为替代证据，R2 静态 AX 契约测试和 86 个目标 XCTest 已通过。

## 7. R2 文件范围

本阶段直接修改的文件：

- `MacSSH/Features/Agent/AgentToolCardView.swift`
- `MacSSH/Services/Agent/AgentViewModel.swift`
- `Scripts/gen_localizable.py`
- `MacSSH/Resources/Localizable.xcstrings`
- `Tests/SSH/AgentToolLoopTests.swift`
- `Tests/SSH/LocalizationTests.swift`

本报告是新增的阶段交付物。工作树中其它 B1–B4 文件和报告均为既有未提交工作，不在本 R2 报告中重新归属。

## 8. Findings / Gate

- P1：0 observed in executed R2 paths。
- P2：0 observed in executed R2 paths；R2 指定的三个 P2 remediation 已实现并由目标测试覆盖。
- P3 / external blockers：完整 test universe 的 Keychain/DetachedSignatures 环境阻塞；缺少可授权的 Provider/API Key fixture，导致真实 Approval Card AX smoke 和 remote live exec pending。
- Git gate：无 staged content；未 commit、未 push、未 merge、未 tag。

**最终状态：FAIL / BLOCKED。** 待提供稳定 Keychain/测试运行环境和不含真实敏感凭据的 Provider fixture 后，重新执行完整测试全集、Approval Card GUI/AX smoke，再进行阶段复核。10E-C 不在本次授权范围内。
