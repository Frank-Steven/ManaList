/**
 * 极简串行闸（P2-4）：推理端点会调用本地/远程模型，多设备或手动请求
 * 并发会打满模型进程。这里把并发限制在 maxConcurrent，超出排队；队列满时立刻
 * 抛 GateBusyError，由 HTTP 层转成 429 —— 宁可让客户端稍后重试，也不无界排队。
 *
 * v3（design-v3 §6.3）：SerialGate 保持单闸语义；GatePool 按模型 id 分闸——
 * 不同后端（模型配置）可并行，同一后端仍串行。
 */
export class GateBusyError extends Error {
  readonly code = "GATE_BUSY";

  constructor(message = "服务正忙，请稍后重试") {
    super(message);
    this.name = "GateBusyError";
  }
}

export class SerialGate {
  private active = 0;

  private readonly waiting: Array<() => void> = [];

  constructor(
    private readonly maxConcurrent = 1,
    private readonly maxQueue = 8,
  ) {}

  get activeCount(): number {
    return this.active;
  }

  get queuedCount(): number {
    return this.waiting.length;
  }

  private acquire(): Promise<void> {
    if (this.active < this.maxConcurrent) {
      this.active++;
      return Promise.resolve();
    }
    if (this.waiting.length >= this.maxQueue) {
      return Promise.reject(new GateBusyError());
    }
    return new Promise<void>((resolve) => this.waiting.push(resolve));
  }

  private release(): void {
    const next = this.waiting.shift();
    if (next) {
      // 槽位直接交接给队首，active 不变
      next();
      return;
    }
    this.active--;
  }

  /** 取得一个槽位，返回释放函数；由调用方在响应结束时调用。 */
  async acquireSlot(): Promise<() => void> {
    await this.acquire();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.release();
    };
  }

  /** 包裹一次执行（测试与内部调用用）。 */
  async run<T>(fn: () => Promise<T>): Promise<T> {
    const release = await this.acquireSlot();
    try {
      return await fn();
    } finally {
      release();
    }
  }
}

/**
 * 按 key（模型 id）分闸的闸池（v3）：每个 key 一个独立 SerialGate，
 * 不同 key 并行、同 key 串行；排队上限由各自的 SerialGate 保证。
 */
export class GatePool {
  private readonly gates = new Map<string, SerialGate>();

  constructor(
    private readonly maxConcurrent = 1,
    private readonly maxQueue = 8,
  ) {}

  gateFor(key: string): SerialGate {
    let gate = this.gates.get(key);
    if (!gate) {
      gate = new SerialGate(this.maxConcurrent, this.maxQueue);
      this.gates.set(key, gate);
    }
    return gate;
  }

  /** 取得指定 key 的一个槽位，返回释放函数；由调用方在响应结束时调用。 */
  acquireSlot(key: string): Promise<() => void> {
    return this.gateFor(key).acquireSlot();
  }
}
