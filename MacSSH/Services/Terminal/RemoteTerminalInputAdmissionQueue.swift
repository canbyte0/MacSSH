import Foundation

/// 同步接纳普通终端输入，并按接纳顺序送进 SSHConnection 已有的输入 FIFO。
/// `Target` 在生产环境是不可变的 SSHInteractiveInputEndpoint；测试使用合成端点。
final class RemoteTerminalInputAdmissionQueue<Target: Sendable>: @unchecked Sendable {
    typealias Writer = @Sendable (Target, [UInt8]) async -> SSHInteractiveInputWriteResult
    typealias FailureHandler = @Sendable (UInt64, UInt64) -> Void

    private struct Item: Sendable {
        let sequence: UInt64
        let generation: UInt64
        let target: Target
        let bytes: [UInt8]
    }

    private let lock = NSLock()
    private let writer: Writer
    private var onFailure: FailureHandler
    private let maxQueuedBytes: Int
    private var target: Target?
    private var generation: UInt64 = 0
    private var failedGeneration: UInt64?
    private var nextSequence: UInt64 = 0
    private var queuedBytes = 0
    private var items: [Item] = []
    private var draining = false
    private var drainTask: Task<Void, Never>?

    init(
        maxQueuedBytes: Int = 4 * 1024 * 1024,
        writer: @escaping Writer,
        onFailure: @escaping FailureHandler = { _, _ in }
    ) {
        self.maxQueuedBytes = maxQueuedBytes
        self.writer = writer
        self.onFailure = onFailure
    }

    /// Service 初始化完成后安装失败通知；读取与替换均受同一把锁保护。
    func setFailureHandler(_ handler: @escaping FailureHandler) {
        lock.lock()
        onFailure = handler
        lock.unlock()
    }

    /// 延迟切回 MainActor 时再核对失败代次，避免旧失败误伤新连接。
    func isFailedGeneration(_ admittedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failedGeneration == admittedGeneration
    }

    /// 更换 authority 时原子撤销旧代次的待发送项。已在途的写入仍携带旧 target。
    @discardableResult
    func install(_ newTarget: Target) -> UInt64 {
        lock.lock()
        let oldTask = drainTask
        generation &+= 1
        failedGeneration = nil
        target = newTarget
        items.removeAll()
        queuedBytes = 0
        draining = false
        drainTask = nil
        let installedGeneration = generation
        lock.unlock()
        oldTask?.cancel()
        return installedGeneration
    }

    /// 与 delegate 回调处于同一同步调用栈；锁内分配序号并冻结 target。
    /// 因而 A 的 enqueue 返回先于 B 开始时，A 必定位于 B 前面。
    @discardableResult
    func enqueue(_ bytes: [UInt8]) -> UInt64? {
        guard !bytes.isEmpty else { return nil }
        lock.lock()
        guard let target else {
            lock.unlock()
            return nil
        }
        nextSequence &+= 1
        let sequence = nextSequence
        let admittedGeneration = generation
        guard bytes.count <= maxQueuedBytes - queuedBytes else {
            let oldTask = invalidateLocked(failedFrom: admittedGeneration)
            lock.unlock()
            oldTask?.cancel()
            reportFailure(admittedGeneration, sequence)
            return nil
        }
        items.append(Item(
            sequence: sequence,
            generation: admittedGeneration,
            target: target,
            bytes: bytes
        ))
        queuedBytes += bytes.count
        if !draining {
            draining = true
            // 唯一 drain 在锁内登记；并发 enqueue 不会创建第二个投递 Task。
            drainTask = Task { [weak self] in
                await self?.drain(admittedGeneration)
            }
        }
        lock.unlock()
        return sequence
    }

    /// stop / reconnect / shell exit 的同步屏障：后续 delegate 输入不可再入旧代。
    func clear() {
        lock.lock()
        let oldTask = invalidateLocked()
        lock.unlock()
        oldTask?.cancel()
    }

    deinit {
        drainTask?.cancel()
    }

    /// 只能持锁调用；返回旧任务，供解锁后取消。
    private func invalidateLocked(failedFrom: UInt64? = nil) -> Task<Void, Never>? {
        let oldTask = drainTask
        generation &+= 1
        failedGeneration = failedFrom
        target = nil
        items.removeAll()
        queuedBytes = 0
        draining = false
        drainTask = nil
        return oldTask
    }

    /// 回调在锁外执行，避免 Service 的生命周期动作与 admission 互锁。
    private func reportFailure(_ failedGeneration: UInt64, _ sequence: UInt64) {
        lock.lock()
        let handler = onFailure
        lock.unlock()
        handler(failedGeneration, sequence)
    }

    private func drain(_ admittedGeneration: UInt64) async {
        while true {
            guard let item = takeNext(for: admittedGeneration) else { return }

            // 每项必须得到 acknowledged-prefix 结算，才允许后项进入 actor FIFO。
            // 失败或部分写入绝不假装成功，也不重试到新 Shell。
            let result = await writer(item.target, item.bytes)
            guard result.isSuccess else {
                if invalidateIfCurrent(item.generation) {
                    reportFailure(item.generation, item.sequence)
                }
                return
            }
        }
    }

    /// 同步锁域不得横跨 await；每次只取一项并释放锁后执行网络写入。
    private func takeNext(for expectedGeneration: UInt64) -> Item? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return nil }
        guard !items.isEmpty else {
            draining = false
            drainTask = nil
            return nil
        }
        let item = items.removeFirst()
        queuedBytes -= item.bytes.count
        return item
    }

    private func invalidateIfCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        _ = invalidateLocked(failedFrom: expectedGeneration)
        return true
    }
}
