# showup 项目分析报告

- **日期**：2026-10-21（当晚追加第 6 节：修正已实施）
- **对象**：`showup` — macOS 定时置顶工具（`sudo showup -a Safari -t 8:00,12:00,...`）
- **方法**：逐行阅读 19 个源文件 + 10 个测试文件（3737 行 Swift）、README/TECH-DEBT/Makefile/5 个探针脚本/CI；分析全部 76 个提交（2026-10-17 → 10-21）；实测 `swift build` 与 `swift test`。
- **实测结果**：**构建通过；126 个测试 / 14 个 suite 全绿**（修正后同样 126 个：删 3 条 `leadSplit` 测试、新增 4 条回归测试）。（注：本环境需 `swift build --disable-sandbox`，因 SwiftPM 内部 `sandbox-exec` 被沙箱阻止；这是运行环境限制，非项目缺陷——用户机器上 `.build/debug/showup` 早已存在即证。）

---

## 0. 结论摘要

| 维度 | 评价 |
| --- | --- |
| 设计文档质量 | **极高**。README 是一份带实测证据的设计论文，每个决策都附着一次失败的度量 |
| 实现完成度 | **高**。README 描述的行为几乎全部落地，无半成品 |
| 实现正确性 | **主路径全部正确**（126 测试 + 逐行对照）；边界原有 3 处小偏差（I1–I3），其中 I1/I2 **当晚已修并配回归测试**，I3 判定为不值得改 |
| 测试覆盖 | 核心逻辑充分；`--no-ring`×音量、午夜 wrap 边界**当晚已补**，DST 仍无覆盖（已记债务 I4） |
| 技术债务 | TECH-DEBT.md 记录的 9 项**全部属实**（逐条复核）；本文另发现 4 项未记录的（O1–O4），其中 O1–O3 **当晚已清** |
| 总体判断 | **可以交付使用**。修正后 P1 级问题已清零；剩余的是技术债务与两处刻意不修的判断（I3、I4），理由见第 6 节 |

---

## 1. 设计要求的深入理解

### 1.1 这个程序到底在解决什么

一句话：**在用户选择的时刻把 App 带到前台；若机器在睡眠，则先把人和机器带回来。**

真正的难题不是"定时"（`pmset` 一行搞定），而是：**睡眠中的 Mac 报告的时间和醒着的 Mac 一样**。一次计划唤醒落地时，机器可能（a）一直没睡，（b）睡了并被 RTC 唤醒成 DarkWake（屏幕不亮，没人能听见），（c）睡了并被完全唤醒。时钟无法区分三者，因此整个程序的核心是**取证**：问内核、问键盘空闲计数器、问登录状态，然后在两条完全不同的"程序"之间分支。

### 1.2 设计公理（从 README 与代码中提炼的不变式）

| # | 公理 | 机制（代码位置） |
| --- | --- | --- |
| A1 | **窗口宁晚勿早**（Late is possible, early is not）：窗口永不早于时刻。注意与"提前唤醒"不矛盾——唤醒必须早于时刻，提前量正是为此而设；不可早的只是上窗那一刻 | `holdUntilTheTime`（Scheduler.swift:178）按机器时钟累计 elapsed；`run` 用 `effects.now()` 而非计划时间推进循环（Scheduler.swift:24），漂移不可积累 |
| A2 | **无人则不上场** | `ShowOutcome.notShown(reason:)`（Models.swift:70）：没人应答 / 登录未完成 → 根本不 `open` |
| A3 | **先人后钟** | `rouse` 内顺序：alarm answered → `waitForTheLogin` → `holdUntilTheTime` → `surface`（Scheduler.swift:96-106）。激活活不过锁屏回来，所以登录必须先于时钟 |
| A4 | **内核优先于日志** | `PowerNotifications`（IORegisterForSystemPower）说话时独自裁决；`WakeKind`/pmset 日志仅在内核不注册时兜底（Scheduler.swift:240-263） |
| A5 | **提前量唤醒** | 白天 60s / 夜间（22:00–06:59）300s，`leadFor(hour:)`（Schedule.swift:26）；唤醒定在时间之前，工作发生在窗口内 |
| A6 | **机器自己的数字，不问不猜** | 空闲计时器 `pmset -g custom` + `-g ps`（PowerSettings.swift）；睡眠证据用键盘空闲计数器冻结检测（SleepDetection.swift:50） |
| A7 | **偏噪不偏静** | unknown / unreadable / 忙碌机器 → 一律响铃（SleepDetection.swift:21、WakeKind.swift:30、Alarm.swift:136）。漏响是最差失败 |
| A8 | **不留尾巴** | 每次 schedule 前先 cancel（ScheduledWake.swift:36）；SIGINT/TERM/HUP 退出时收回（Showup.swift:57）；启动时报告已存在的武装唤醒 |
| A9 | **短步睡眠** | 10s 步进对墙钟（Effects.swift:88）：单调时钟在睡眠时停走，一步之长就是误差上界 |
| A10 | **日志可复盘** | 每次运行一个 `/var/log/showup<epoch>.log`，`O_NOFOLLOW`；每次唤醒记录它被判决所依据的数字（Scheduler.swift:85） |

### 1.3 架构：三层 + 一个边界（组件图）

```
┌─────────────────────────────────────────────────────────────┐
│ Sources/showup/            Showup.swift（唯一 @main）        │
│   parseCLI → Command │ printSchedule │ usage │ 信号处理      │
└──────────────────────────┬──────────────────────────────────┘
                           │ 依赖
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Sources/ShowupCore/        纯逻辑（无进程派生、无 macOS）     │
│  Time  Models  CLI  Schedule  SleepDetection  WakeKind      │
│  PowerSettings  PowerCycle  Alarm  Scheduler  ShowError     │
│                         │                                   │
│                    ┌────▼─────┐                             │
│                    │ Effects  │ ◄── 唯一的边界（15 个       │
│                    │(15 闭包) │     @Sendable 钩子）        │
│                    └────┬─────┘                             │
│                    ┌────▼─────┐                             │
│                    │AlarmEff- │ ◄── 闹钟自己的小边界        │
│                    │ects 协议 │     (now/keyboard/play/sleep)│
│                    └──────────┘                             │
└──────────────────────────▲──────────────────────────────────┘
                           │ 实现
┌──────────────────────────┴──────────────────────────────────┐
│ Sources/ShowupMac/         平台边界（每条命令 + 每个解析器）  │
│  LiveEffects（Effects.live）  Mac（命令与解析）               │
│  Session（consoleUID/idle/login/CoreAudio）                  │
│  ScheduledWake（IOPMSchedulePowerEvent）                     │
│  PowerNotifications（IORegisterForSystemPower）              │
│  Log（/var/log, O_NOFOLLOW）                                 │
└──────────────────────────┬──────────────────────────────────┘
                           │ 调用
                           ▼
        IOKit.pwr_mgt │ CoreAudio │ CoreGraphics │ SystemConfiguration
        /usr/bin: pmset scutil lsappinfo open(launchctl asuser) afplay
```

测试通过 `FakeMachine`（Tests/ShowupTests/TestDoubles.swift）实现同一个 `Effects`，这就是调度循环可测的唯一原因。

### 1.4 核心类型模型（类图）

```
Config ──1..*──> TimeOfDay          Wake ──> TimeOfDay + delay:Int
(app, times, ring, dryRun)         (at, delay)

Command (enum): show(Config) | showSchedule(Config) | help
Step (enum):    surfaced(wake:Wake, showed:ShowOutcome) | idle

ShowOutcome:  launched | surfaced | failed(String) | notShown(reason:)
AlarmOutcome: rung(rings:) | failed(rings:) | silent(reason:)

SleepEvidence (enum) ◄── sleepEvidence(idleBefore:Int?, idleAfter:Int?, elapsed:Int)
   awake | inputArrived | slept | unreadable      wokeTheUser = self ∉ {awake, inputArrived}

WakeKind (enum) ◄── newestWake(log:now:requestedAt:)
   full | dark | unknown           （requestedAt 的 DarkWake 修正：rtcWakeToleranceSeconds=20）

PowerCycle (struct): willSleep × hasPoweredOn ──> completedFullWake
PowerSettings (struct): source, displaySleepMinutes, systemSleepMinutes, powerNap
                        ──> idleWindowSeconds:Int?（较小者，nil=永不自睡）
IdleWindowReport (struct): summary + warnings（warnings 恒空，见债务#1）

AlarmOptions (between:5, playFailures:40, budget:Int?)
AlarmEffects (protocol): now | keyboardIdleSeconds | play | sleep
   ──> alarmRing(...) ──> AlarmOutcome

Effects (struct, 15 闭包): now currentDate sleep scheduleWake idleSeconds
   show alarm outputVolume setOutputVolume powerSettings wakeKind
   powerCycle loginFinished log warn

ShowError (enum): 参数类 7 例 + 系统类 3 例，跨层保持语义
```

### 1.5 一次 wake 的完整生命周期（时序图，Program 2 路径）

```
run ──▶ step(config, from: instant)
   │
   ├─ nextWake(times, from:now) ──────────────▶ Wake(at, delay)   [已过时刻＝明天]
   ├─ started = now()
   ├─ wait  = clamp(delay + now − started, 0 … 86399)              ◄─ I2 见第 3 节
   ├─ ahead = max(0, wait − leadFor(at.hour))                       ◄─ A5
   ├─ requestedAt = (started + ahead) mod 86400
   ├─ scheduleWake(ahead) ──▶ IOPMSchedulePowerEvent                ◄─ A8：先 cancel 再排
   ├─ idleBefore = idleSeconds()
   ├─ sleepSeconds(ahead) ──▶ 10s 步进（墙钟）                      ◄─ A9
   ├─ elapsed = secondsBetween(started, now())
   ├─ idleAfter  = idleSeconds()
   ├─ evidence  = sleepEvidence(...) ──▶ log（带全部数字）          ◄─ A6/A10
   │
   ├─ evidence.wokeTheUser == false ────────────────────────┐
   │                                                         │
   └─ true ──▶ rouse(config, requestedAt)                    │
         ├─ powerCycle()?  ── 有 ──▶ completedFullWake?       │
         │                    否 ──▶ .notRung ───────────────┤
         │                    无 ──▶ wakeKind(requestedAt)   │
         │                            dark ──▶ .notRung ─────┤   ◄─ A4
         │                            unknown/full ──▶ 继续   │
         ├─ checkAudible()        （<30 警告）                │   ◄─ I1：-q 时也执行
         ├─ config.ring?                                           │
         │     否 ──▶ log "--no-ring" ──▶ .notRung ─────────┤
         │     是 ──▶ window = powerSettings()?.idleWindowSeconds  │   ◄─ A6
         │            raiseToBeHeard()  （<20 抬到 20，只升不降）  │
         │            alarm(window) ──▶ .rung | .failed | .silent   │   ◄─ A7
         │                 .rung ──▶ .answered                     │
         │                 .failed ──▶ .nobodyCame ──▶ notShown ───┘   ◄─ A2
         │                 .silent ──▶ .notRung ──────────────────┤
         │                                                        │
         ├─ .answered ──▶ waitForTheLogin()  ◄─ A3：先登录后时钟   │
         │                    scutil kCGSessionLoginDoneKey        │
         │                    超 budget ──▶ notShown("login...") ─┘  ◄─ A2
         └─────────────────▶ holdUntilTheTime(since:started, wait:)   ◄─ A1
                            surface(app) ──▶ launchctl asuser + open -a
```

### 1.6 睡眠证据判定表（SleepDetection.swift:50）

| idleBefore → idleAfter | advanced | elapsed 内 | 判决 | 响铃？ |
| --- | --- | --- | --- | --- |
| 5 → 8 | +3 | 353s | `.slept`（计数器冻结） | 是 |
| 5 → 358 | +353 | 353s | `.awake`（跟上墙钟） | 否 |
| 900 → 0 | 负 | 任意 | `.inputArrived`（只有输入会倒退） | 否 |
| 400 → 410 | +10 | 14400s | `.slept`（连打 4 小时代码＝冻结，误报成本仅一次铃） | 是 |
| nil / nil | — | 任意 | `.unreadable` | 是 |

容差 `awakeToleranceSeconds = 10`（一个睡眠步进 + 计数器自身抖动）。

### 1.7 设计演变：git 历史里的六次摇摆（理解当前设计的钥匙）

每个最终决定都背着一次**被度量的失败**，这是本项目最值得保护的资产：

| 决定 | 摇摆路径（提交） | 最终立场的依据 |
| --- | --- | --- |
| RTC 唤醒 | 加（547990d pmset）→ 删（7c06b76）→ 加回（f4acf04 IOPMSchedulePowerEvent + 退出收回） | 删因 `scheduledby=pmset` 无法区分归属；加回时发现 6 个残留武装唤醒 |
| 登录等待 | 加（Gleam 期 120s 轮询）→ 删（d31aaa6 "this program can never need"）→ 加回（1c16986） | 删除依据：锁屏时 scutil 仍报 UID 501；加回依据：闹钟首键可能是密码首字母，激活活不过解锁 |
| caffeinate | 加（fdf9c3e）→ pmset+caffeinate -u（34012bf）→ 删（cb32404）→ 再删（4d0828d） | Apple Silicon 上读不回显示状态，断言不可验证＝断言不存在 |
| 响铃时机 | 后台响铃+立即显示（923e9cf）→ 铃止才显示（766d874）→ 且等到时刻（47e8669） | 实测：目标时刻 launch 进锁屏会话，解锁后前台什么都没有 |
| 睡眠检测 | 电源日志形状（254871b/d475d7c）→ 空闲计数器（054aeca）→ 内核通知（f5369e1） | 日志是 powerd 异步写的，问的瞬间它可能还没写；内核不可能输给 powerd |
| 语言 | Gleam/Erlang（e91d8ff）→ Swift（163e8e7） | 直接调用 IOKit/CoreAudio 的需求 |

---

## 2. 文档中尚存需澄清的表述问题

按严重度排序。**结论：都不影响使用，但都会误导下一位读者。**

### D1（中）"sudo 只为一件东西需要"与 README 自相矛盾

- README 开头：*"The `sudo` is needed for exactly one thing: asking the power-management system to wake the Mac"*，并称 *"Everything else — reading the sleep evidence, ringing, surfacing the app — works as your normal user."*
- 但 README 自己的日志节承认：*"Run without sudo and the file cannot be created"*（`/var/log` 需 root）。
- 且置顶路径是 `launchctl asuser <uid> open -a`（Session.swift:83），`asuser` 提权到另一 uid 实践中需要 root——"surfacing works as your normal user" **未经测量，很可能不成立**。
- **需澄清**：把 "exactly one thing" 改为实测过的清单（至少含：RTC 调度 + 写 /var/log；置顶待测）。

### D2（中）`slept_during` —— Python 时代的幽灵钩子

- README "Design implications for future developers" 第 3 条：*"the two hooks you need are `slept_during` … and `show`"*。
- 全文 grep：`slept_during` **只出现在 README**，Swift 里不存在；对应物是 `idleSeconds` + `sleepEvidence`（纯函数）。
- **需澄清**：该节按 Swift 名字重写，或明确标注为旧版（Python）接口名。

### D3（中）三处 "runs on its own queue" 过期注释

闹钟自 766d874（10-19 13:30）起已改为**同步阻塞**在 `rouse` 内，但以下注释仍描述 Gleam 时代的后台队列模型：

1. `Alarm.swift:26-27`（`AlarmEffects` 协议文档："It runs on its own queue"）
2. `Scheduler.swift:35-38`（`Step.surfaced` 文档："it runs on its own queue and reports by logging"）
3. `TestDoubles.swift:180-181`（`waitForAlarm` 文档："The alarm runs on its own queue, so a test has to let it be dispatched"）

后果：读者会误判线程模型（`Effects.alarm` 是同步调用，不涉及跨队列传递）。

### D4（低）`.unreadable` 的文档还停在 ioreg 时代

`SleepDetection.swift:15`：*"`ioreg` could not be read, so nothing is known"*。实际计数器自 f4acf04 起是 `CGEventSource.secondsSinceLastEventType`（Session.swift:54-64）。同文件的 `report(...)` 字符串已更新（"the idle counter could not be read"），仅案例注释残留。

### D5（低）TECH-DEBT.md 的行号已漂移

文件声明 *"nothing here has been changed"*（写于 a67fa36，10-20 16:34），但其后 47e8669 与 1c16986 大改 Scheduler.swift，4/8 项的行号引用失效：

| 债务项 | 记录行号 | 当前实际 |
| --- | --- | --- |
| #2 `Step.idle` | Scheduler.swift:36 | :41 |
| #5 `isRunning` | Mac.swift:54 | :70 |
| #6 `Step.surfaced` | Scheduler.swift:34 | :39 |
| #7 `defaultPlayFailures` | Alarm.swift:30 | :41 |

（#1/#3/#4/#8 行号仍准确。**九项债务的实质内容逐条复核全部属实。**）

### D6（低）DST（夏令时）只字未提

调度器自己的算术假设一天恒为 86400 秒（`secondsSinceMidnight` / `secondsBetween` / 各处 `% secondsPerDay`）。`pmsetDatetime` 委托给 `Calendar`（安全），但 `nextWake` 与 `holdUntilTheTime` 没有。夏令时切换日等待可能差一小时。**需给一个立场**：支持 / 明确不支持 / 已知限制。

### D7（低）`24:00` 与 `0:00` 是同一个唤醒，文档未说

`parseTime` 把 `24:00` 归一化为 `00:00`（Time.swift:83），因此 `-t 24:00,0:00` 去重后只剩一个，且无法把"前一天 24 点"和"当天 0 点"排成两个。README 只把 24:00 称作 "midnight"，未提别名关系。

### D8（低）Program 1 的 "no waiting" 措辞过头

README 两程序节称 Program 1 *"No sound, no waiting, no ceremony"*，但后文提前量节明确 *"a machine that was up the whole time waits out the whole lead"*。前者指无**登录**等待，读起来像完全不等待。建议改为 "no login wait, no sound"。

### D9（低）"early" 一词承载两个相反含义，易被读反

README:229 的小节标题是 *"Waking early, so the window is punctual"*——**提前唤醒是设计赖以成立的手段**，内核必须被要求早于时刻醒来；而 README:249 与 :251-252 说的是**窗口** *never goes up before the required time* / *early is not [possible]*。同一个词在一处是必需动作、在另一处是缺陷，且两节相距二十余行。

**这不是纯修辞问题**：把 *"early is not"* 读成"不要早醒"会直接推导出"按时刻唤醒内核"这一被 README:231-234 明确否定的做法（那样每次都会晚）。建议在 :249 处把主语点明，如 "The window never goes up before the required time — but the wake itself is scheduled *earlier* than the time, deliberately"。

> 附注：本报告初稿曾把 A1 命名为"永不禁早"，正是踩了这个坑——该词不在 README、代码或任何提交中，是分析者的坏压缩，已改为"窗口宁晚勿早"。

### D10（低）"Raise the window" 与实现做的不是同一件事

README:90 用 *"Raise the window"* 描述 Program 1 的动作，而 README:480 说明实现是 `open -a <app>`：它**激活应用**，把应用的窗口带到最前并给焦点，但不指定*哪一个*窗口——哪个窗口最前由应用自己决定，跟你点 Dock 图标一样。

- **若需求就是"把应用带到前台"**：两者一致，无需改动。
- **若需求是"在多个窗口里指定抬起某一个"**：这是一个**真实的功能缺口**，需要 Accessibility API（`AXRaise`）并请求辅助功能权限，那是另一套更重的实现，且与 README:483 "No permission needs to be granted" 直接冲突。
- 已在 README:480 后补一段把这点写明（✅ 当晚已改，见 6.7）。**待你确认需求口径。**

---

## 3. 实现偏离、过度编程与缺漏

### 3.1 偏离设计要求（行为与不变式冲突）

#### I1（P1）`--no-ring` 仍会警告"你听不到闹钟"　✅ 当晚已修，见 6.1

- **位置**：Scheduler.swift:265 `checkAudible(effects)` 在 :267 `if config.ring` **之前**。
- **现象**：`showup -a Mail -t 9:00 -q` 且音量 13 时，日志出现 `the alarm plays at the speaker volume, which is 13 - you will not hear it`——但 `-q` 下根本没有闹钟会响。
- **为何漏网**：`noRingNeverTouchesTheSpeaker`（SchedulerTests.swift:110）只断言了 `volumeWasSetTo == []` 和 `alarmCount == 0`，未断言 warnings。
- **修法**：`checkAudible` 移入 `if config.ring` 分支；补一条测试。

#### I2（P2）"窗口不可早于时刻"在两处边界被击穿　✅ 当晚已修，见 6.2

- **(a) 钳位差一**：Scheduler.swift:63 `min(wake.delay + (now - started), secondsPerDay - 1)`。`nextWake` 在"时刻正好是现在"时返回 `delay == 86400`，被钳成 86399 → 次日同一时刻**早 1 秒**上窗（随后自行重同步，只错一次）。钳位应为 `secondsPerDay` 或直接改为对 `at` 比较而非对 delay 钳位。
- **(b) 午夜不 wrap**：同行的 `now - started` 是裸差。两次读钟跨越午夜时该项 ≈ −86400，`wait` 被极端扭曲（要么钳到 0 立即上窗，要么接近整天）。两次读钟间隔仅微秒，触发概率极低，但公式确实不 wrap-safe。建议用 `secondsBetween(started, now)` 或直接用 `currentDate()` 的绝对差。

#### I3（P3）闹钟预算不计播放耗时

Alarm.swift:82 `elapsed += options.between` 只累计间隔等待，不含 `afplay` 播放本身（每次约 1–2s）。20 分钟预算下最严重可超支约 30%。**有兜底**：下一轮 `waited()` 发现机器睡了即 `.failed`（Alarm.swift:98,114-119），所以只是账面失真，非行为错误。**处置：不修**——账面数字不影响任何行为，改它要给 `AlarmOptions` 加一个播放耗时的输入，代价大于收益。

#### I4（P3，修 I2 时新发现）时钟是"时刻"，而时刻一年里有两次不单调

`holdUntilTheTime`（Scheduler.swift:190）与 `secondsBetween`（Time.swift:44）都假设时钟只向前走。

- **春快拨**（02:00 → 03:00）：两次相邻读钟相差一小时而实际没过时间 → 累计出一小时 elapsed → **窗口提前一小时上窗**，正面击穿 A1。
- **秋回拨**（02:00 → 01:00）：读钟倒退，wrap 修正加上一整天 → 窗口晚约 23 小时。

只有跨 02:00 的 hold 受影响，一年最多两晚。唤醒本身交给 `pmset` 时用的是日历项（`pmsetDatetime` 走 `Calendar`），那一边是对的；错的只是计数。**处置：记为技术债务（TECH-DEBT 第 10 项）而非修复**——修法是换时钟模型（`now` 在 `nextWake`、`requestedAt`、日志里都是"时刻"），任何修法都得先回答"`Effects.now()` 在那两晚到底该是什么意思"。

### 3.2 过度编程 / 死代码（TECH-DEBT 之外的新发现）

#### O1（P1）`leadSplit`：死代码，且与在用的实现语义相反，却被测试固定　✅ 当晚已删，见 6.3

- **位置**：Schedule.swift:19-24。生产零调用（grep 确认：只有测试引用）。
- 调度器内联的是 `ahead = max(0, wait - leadFor(...))`（Scheduler.swift:68）；`leadSplit` 在 `delay < lead` 时返回 `ahead = delay`，内联版返回 **0**。两者在子提前量情形下**相反**。
- ScheduleTests.swift:64-74 三条测试精确地固定着这个死函数的行为——包括那条与实现相反的分支。
- **处置二选一**：删函数 + 三条测试；或让 Scheduler 改用它（但先决定子提前量情形哪个语义是对的：现在=0 还是现在=delay）。

#### O2（P2）测试替身里的死成员　✅ 当晚已清，见 6.4

`TestDoubles.swift` 中从未被读写：`desktopPolls`（:40）、`loginSeconds`（:43）、`touchKeyboard()`（:172）。

#### O3（P2）`waitForAlarm` 信号量是后台闹钟时代的残留　✅ 当晚已清，见 6.4

`FakeMachine.alarmRan` 信号量 + `waitForAlarm()`（TestDoubles.swift:67,181）为"闹钟在自有队列异步跑"而建；如今 `effects.alarm` 同步执行，每个 `waitForAlarm()` 都是空转。10 处调用点可删（连带信号量）。

#### O4（P3）`Step.surfaced` 的两个载荷都被丢弃

TECH-DEBT #6 记录 `showed` 无人读（仅 1 条测试断言）；`wake` 同样如此——`run` 里 `_ = wake`（Scheduler.swift:25）。若要留载荷，至少让 `run` 消费其一；否则退化成无载荷枚举。

### 3.3 缺漏（防护与仓库卫生）

| # | 缺漏 | 后果 |
| --- | --- | --- |
| M1 | 无 `--no-ring` × 低音量测试；无"`-q` 时跳过 checkAudible"测试 | I1 因此漏网 |
| M2 | 无午夜边界测试（`step`/`holdUntilTheTime`/`nextWake` 的 wrap）；无 DST 测试 | I2、D6 因此漏网 |
| M3 | `Scripts/lock-state-probe.sh` **未被 git 跟踪**（`git status` 显示 `??`），且 README/Makefile/CI 均无引用 | 孤儿产物：要么提交并在 README 与 login-state-probe.sh 并列引用，要么删除 |
| M4 | README "Design implications" 仍按 Python 端口命名（D2），API 表与模块表则已准确 | 新旧命名混排 |

### 3.4 逐模块正确性评分

| 模块 | 评分 | 依据 |
| --- | --- | --- |
| Time.swift（解析/时钟） | A− | 全形式覆盖；小瑕疵：`Int("+8")`/`-0` 会被接受为合法小时 |
| Schedule.swift | B+ | `nextWake`/`upcoming` 逻辑与测试全对；`leadSplit` 死码（O1） |
| SleepDetection.swift | A | 纯函数，四案例全测，README 数字逐位复现；注释残留 ioreg（D4） |
| WakeKind.swift | B | 对真实日志逐行验证通过；90s 窗口无实测（债务#8）；整条路仅兜底（债务#9） |
| PowerSettings.swift | A− | verbatim 双电源输出测试；`warnings` 恒空（债务#1） |
| Alarm.swift | B+ | 按键判定链测试充分；默认值无实测（债务#7）；预算账面（I3） |
| **Scheduler.swift** | **A−** | 主路径零缺陷；I1/I2 两处边界；死载荷（O4） |
| CLI.swift | A | 11 种错误路径全测；两种 flag 形式全覆盖 |
| ShowupMac（边界） | B+ | API 替换有根因分析；`isRunning` 每唤一次进程（债务#5）；`loginFinished` 保守方向正确 |
| 测试体系 | A− | 126 全绿；边界盲区 M1/M2 |

---

## 4. 与 TECH-DEBT.md 的核对结论

逐条复核 9 项，**全部属实且均未修复**（TECH-DEBT 写于 a67fa36 后仅新增未消减）：

1. `IdleWindowReport.warnings` 恒空 — **属实**（PowerSettings.swift:154）
2. `Step.idle` 不可达 — **属实**（CLI.swift:41 保证 times 非空）
3. `SleepEvidence.unreadable` 需全天无输入两次 — **属实**（Session.swift:62 的门槛）
4. `PowerNotifications.deinit` 永不执行 — **属实**（:42 `static let`）
5. `isRunning` 每唤一进程只为一词之差 — **属实**（Mac.swift:70-73）
6. `showed` 载荷无人读 — **属实**，且 `wake` 同样（O4）
7. `defaultPlayFailures = 40` 无实测 — **属实**
8. `wakeEvidenceWindowSeconds = 90` 无实测 — **属实**
9. 整个电源日志唤醒路仅服务于内核不注册 — **属实**（PowerNotifications.swift:42；本机实测注册成功）

**新增未记录项**：O1–O4（第 3.2 节）、I1–I4（第 3.1 节）、M1–M4（第 3.3 节）、D3–D10（第 2 节）。其中 I4 是修 I2 时新发现的，见 6.5。

---

## 5. 处理优先级与实施状态

以下事项**已于 2026-10-21 当晚全部实施并验证**（详见第 6 节）。保留此表是为了记录判断，不是因为还有事要做。

| 优先级 | 事项 | 工作量 | 状态 |
| --- | --- | --- | --- |
| **P1** | I1：`checkAudible` 移入 ring 分支 + 补测试 | 极小 | ✅ 已修 |
| **P1** | O1：删除 `leadSplit` 及其 3 条测试 | 小 | ✅ 已删 |
| **P1** | M1：补 `--no-ring`×音量、午夜 wrap 两组测试 | 小 | ✅ 已补（另加"时刻正好是现在"一组） |
| **P2** | I2：去掉 `secondsPerDay - 1` 钳位；`now - started` 改 wrap-safe | 小 | ✅ 已修（顺手删掉了整个钳位，见 6.2） |
| **P2** | D1/D2/D3/D4：sudo 清单、幽灵钩子、queue 注释、ioreg 注释 | 小 | ✅ 已改 |
| **P2** | D5：复核 TECH-DEBT 行号；把新发现补登进去 | 小 | ✅ 已重写（实际漂移比初判更多：1/2/5/6/7/9 项的行号都动了，不只是 4/8） |
| **P2** | O2/O3：清理测试替身死成员与信号量 | 小 | ✅ 已清 |
| **P3** | M3：处置孤儿脚本 lock-state-probe.sh | 极小 | ✅ 已在 README 与 login-state-probe.sh 并列引用；**文件本身仍未 `git add`**（未提交，见 6.6） |
| **P3** | D6/D7/D8/D9/D10：DST、24:00、"no waiting"、"early" 双主语、窗口 vs 应用 | 极小 | ✅ 已改 |
| **P3** | I3：预算计入播放耗时 | 极小 | ❌ 未做（账面失真，有兜底，不值得改） |
| **P3** | M2 的 DST 测试 | 小 | ❌ 未做——改为记录为技术债务（I4），理由见 6.5 |

---

## 6. 本轮已实施的修正（2026-10-21 晚）

每条修正都配了一条**在没有该修正时会失败的测试**，已逐条反向验证过：把旧公式临时放回去，4 条新测试全部变红。

### 6.1 I1：`checkAudible` 只在会响的时候运行

`Sources/ShowupCore/Scheduler.swift`——`checkAudible(effects)` 从 `if config.ring` 之前移入分支内部，并注明理由：`--no-ring` 下根本没有声音，一个对不存在的声音发出的警告是空警告。

新增 `noRingDoesNotWarnAboutASpeakerItWillNotUse`（音量 13 + `-q`），并给已有的 `noRingNeverTouchesTheSpeaker` 补上 `!didWarn("you will not hear it")` 断言。两条在旧代码下均失败。

### 6.2 I2：`wait` 的计算整个重写，钳位就此消失

原文 `max(0, min(wake.delay + (now - started), secondsPerDay - 1))` 有两个毛病，而它们是同一个毛病的两面：`now - started` 是裸差，跨午夜时 ≈ −86400；`secondsPerDay - 1` 的钳位本来就是为了兜这个差，却把"时刻正好是现在"（`nextWake` 返回 `delay == 86400`）削成 86399，于是次日早 1 秒上窗。

改成：

```swift
let wait = max(0, wake.delay - secondsBetween(now, started))
```

三个性质同时到位：

- **wrap-safe**：`secondsBetween(now, started)` 把两次读钟当"时刻"而非"数值"，跨午夜的两次读钟读出真实的 1–2 秒，而不是大半天。
- **不需要钳位**：`wake.delay ∈ (0, 86400]`，修正项只减不增，所以 `wait` 天然 ≤ 86400；`max(0, …)` 管下界。差一错误随钳位一起消失。
- **语义更直**：`wait` 就是"从机器现在的钟到目标时刻还有多少秒"，`wake.delay` 提供目标，修正项只负责把"调用方的读钟"换算成"机器此刻的读钟"。

新增 `aWaitThatStraddlesMidnightIsNotAWholeDay`（读钟跨午夜 → 立即上窗，不再傻等一天）与 `aTimeWhoseMomentIsExactlyNowWaitsTheWholeDay`（时刻正好是现在 → 老老实实等一整天的 09:00，而不是 08:59:59）。两条在旧代码下均失败。

### 6.3 O1：`leadSplit` 连函数带测试删除

`Schedule.swift` 里的 `leadSplit` 生产零调用，且与调度器内联的 `max(0, wait - leadFor(hour:))` 在"等待短于提前量"时语义相反（它返回 `ahead = delay`，内联版返回 0）。内联版才是 README 提前量表描述的行为（"a machine that was up the whole time waits out the whole lead"），所以删的是死函数和固定它的三条测试，留下 `leadFor`。

### 6.4 O2/O3：测试替身清账

- 删除死成员 `desktopPolls`、`loginSeconds`、`touchKeyboard()`。
- 删除 `alarmRan` 信号量与 `waitForAlarm()` 及全部 10 处调用。这是"闹钟在自有队列异步跑"时代的残留；现在 `effects.alarm` 同步执行，那 10 次等待全是空转——其中 6 个测试断言"没有闹钟响"，信号量永远不会被 signal，各自阻塞满 5 秒超时。它们并行跑，所以测试阶段总耗时 5.0 秒，几乎全是这个等待；删掉后 **0.32 秒**。这是本次修正里唯一一处"顺手量出来的收益"。

### 6.5 新发现 I4：时钟是"时刻"，而时刻不单调（未修，记为债务）

修 I2 时发现的：`holdUntilTheTime`（`Scheduler.swift:190`）和 `secondsBetween`（`Time.swift:44`）都假设时钟只向前走。一年里它有两次不：

- **春快拨**：02:00 直接变 03:00，两次相邻读钟相差一小时而实际没过时间 → 累计出一小时的 elapsed → **窗口提前一小时上窗**，正面击穿 A1。
- **秋回拨**：02:00 变回 01:00，读钟倒退 → wrap 修正加上一整天 → 窗口晚约 23 小时。

只有跨 02:00 的 hold 受影响，一年最多两晚。**没有修**，因为修法是换时钟模型（`now` 在 `nextWake`、`requestedAt`、日志里都是"时刻"），不是给某个循环打补丁；任何修法都得先回答"`Effects.now()` 在那两晚到底该是什么意思"。已作为第 10 项写入 `TECH-DEBT.md`，README 的"提前量唤醒"节也补了一段说明。

### 6.6 M3：`lock-state-probe.sh` 不再是无引用孤儿

已在 README 的 `login-state-probe.sh` 处并列引用它，并说明它回答的是更窄的问题（锁屏与已登录之间，哪个信号在动——正是 `waitForTheLogin` 依赖的那个区分）。**文件本身仍未 `git add`**：工作区还有 6 个已改文件未提交，是否提交、何时提交由你决定；要收进去的话 `git add Scripts/lock-state-probe.sh` 即可。

### 6.7 文档修正一览

| # | 位置 | 改动 |
| --- | --- | --- |
| D1 | README 开头 | "sudo 只为一件事需要" → 两件（调度唤醒 + 建 `/var/log` 日志），并说明其余部分以普通用户身份做、置顶走 `launchctl asuser` 进控制台用户会话 |
| D2 | README "Design implications" 第 3 条 | 幽灵钩子 `slept_during` → 实际接口（`idleSeconds` 读两次由 `sleepEvidence` 定夺，`powerCycle`/`wakeKind` 为另两个见证，`show` 上窗） |
| D3 | `Scheduler.swift`、`Effects.swift`、`Alarm.swift` 三处注释 | "闹钟在自有队列" → 同步执行；`AlarmEffects` 的理由改为"阻塞调用者是故意的，所以不能要别的东西" |
| D4 | `SleepDetection.swift:15` | "`ioreg` could not be read" → "the idle counter could not be read"（ioreg 早已不用） |
| D5 | TECH-DEBT.md | 重写：9 项行号全部重新核对（1/2/5/6/7/9 项都漂了，不只是初判的 4/8），第 6 项按现状改写，新增第 10 项（I4），末尾加"已解决"表 |
| D6 | README 提前量节 | 新增 DST 段：两晚的时钟不单调，上窗会一晚早一小时、一晚晚 23 小时；唤醒本身交给 `pmset` 的日历项是对的，计数不对 |
| D7 | README Usage | `24:00` 与 `0:00` 是同一时刻的两种拼写，`-t 24:00,0:00` 去重后是一条 |
| D8 | README Program 1 | "Raise the window… No sound, no waiting" → "Bring the app to the front… No sound, no login wait"，并注明时钟仍然被把住——那是时间本身，不是对谁的等待 |
| D9 | README 提前量节 | 点明"必须早的是唤醒，不可以早的只是上窗"，并把 DST 漏洞接在这句话后面 |
| D10 | README "How it works" | 补明 `open -a` 做的是"激活应用"，哪个窗口最前由应用自己决定；要指定某一个窗口需要辅助功能权限，而这里不需要 |

### 6.8 模块评分的修正

| 模块 | 原评分 | 现评分 | 原因 |
| --- | --- | --- | --- |
| Scheduler.swift | A− | **A** | I1/I2 两处边界已修并各配回归测试；死载荷改为无绑定匹配 |
| Schedule.swift | B+ | **A** | `leadSplit` 死码已删 |
| 测试体系 | A− | **A** | M1 已补；替身清账后测试阶段 5.0s → 0.32s |

---

## 附录：实测方法

```sh
swift build --disable-sandbox      # 本环境必需；用户机器上 swift build 即可
swift test --disable-sandbox \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
# → Test run with 126 tests in 14 suites passed after 0.32 seconds.
#   （清理 waitForAlarm 信号量之前是 5.03 秒，差额全是 6 个测试各自的 5 秒超时）
```

*报告完。所有结论可复查：每条均给出 `文件:行号` 或提交号。*
