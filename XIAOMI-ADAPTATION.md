# 小米 15 Pro / HyperOS 4 / Android 17 适配说明

本文档记录 `agent-mobile-use` 在 **小米 15 Pro（haotian / 2410DPN6CC）** 上的完整适配过程、
根因分析、修复内容与真机实测结果。

适配版本：`v4.7-xiaomi`（基于上游 v4.6）

---

## 1. 实测环境

| 维度 | 实测值 |
| :--- | :--- |
| 设备型号 | 小米 15 Pro（`2410DPN6CC`，代号 `haotian`，平台 `sun`） |
| 系统 | **Android 17**（`ro.build.version.release=17`，**SDK 37**） |
| 系统版本 | `OS4.0.0.14.XOBCNXM`（HyperOS 4 / OS4.0） |
| 安全补丁 | 2026-09-01 |
| Root 方案 | **FolkPatch（APatch 系，KernelPatch 115032）** |
| Hook 框架 | **LSPosed 2.2.0-it (7892)** + Zygisk Next 1.5.0 |
| 物理屏 | **1440 x 3200 @ 600 DPI** |
| 副屏 | 由守护脚本自动匹配为 1440x3200@600 |
| 内核 | 6.6.118-android15（aarch64） |

> 上游项目原实验环境是 ColorOS 16 / Android 16 / 1272x2800@560。两者的差异正是本次适配要解决的全部问题。

---

## 2. 核心问题与修复

### 2.1 BOOTCLASSPATH 硬编码导致 ART 直接 SIGABRT（阻断级）

**现象**：任何 `app_process` 调用（`vd tree` / `vd type` / 副屏守护进程）立即以退出码 134 中止，
stderr 只有一行 `Aborted`。

**根因**：`vd` 与 `run_daemon.sh` 里把 ColorOS 专属的 BOOTCLASSPATH 整个硬编码了进来，其中包含
在小米设备上**并不存在**的文件：

```
/system/framework/qcom.fmradio.jar
/system/framework/oplus-framework.jar
/system/framework/subsystem-framework.jar
```

Android 17 的 ART 对 boot classpath 做**硬校验**，条目缺失不是抛 Java 异常，而是直接 abort：

```
Check failed: !location.empty() BOOTCLASSPATH and DEXOATBOOTCLASSPATH must not be empty
```

同时原清单**遗漏了 17 项**小米必需的 jar，其中 `miui-framework.jar` 尤为关键 ——
系统需要的 `android/graphics/animation/RTAnimator` 类由它提供，缺失时表现为：

```
Native registration unable to find class 'android/graphics/animation/RTAnimator'; aborting...
```

**实测对比**（同一台设备）：

| classpath 来源 | 条目数 | 结果 |
| :--- | :--- | :--- |
| 原项目硬编码（ColorOS） | 51 | `SIGABRT`，`Aborted` |
| 设备真实（从 zygote 读取） | **65** | 正常运行 |

**修复**：新增 `ksu-module/bin/vd_env.sh`，按以下优先级解析并在**每项都做存在性校验**后才使用：

1. 从 zygote 的 `/proc/<pid>/environ` 读取系统真实 `BOOTCLASSPATH`
   （这是唯一能 100% 覆盖厂商定制 jar 的方式；实测含 8 个小米定制 jar）
2. 回退：扫描 `/apex/*/javalib` 与各 framework 目录动态拼装
3. 结果按「设备名_Android版本_增量版本」指纹缓存到 `/data/local/tmp/vd_bootclasspath.txt`，
   OTA 后指纹变化会自动失效重建

> `DEX2OATBOOTCLASSPATH` 单独处理：它是**编译期**子集，直接当运行期 classpath 用会丢掉
> `framework-*.jar`，因此两者分开解析。

### 2.2 `screencap` 参数语义错误（功能失效）

**现象**：`screencap -d <display_id>` 恒失败：

```
Failed to take take screenshot. Display Id '3' is not valid.
```

**根因**：API 30+ 的 `screencap -d` 接受的是 **SurfaceFlinger 的 64bit display token**，
而非逻辑 display id。原实现把逻辑 id（如 `3`）直接传进去。

**修复**：`vd screenshot` 改为从 `dumpsys SurfaceFlinger --display-id` 解析 token：

```
Display 11529215046647247235 (Virtual display): displayName="AgentVirtualDisplay"
```

实测截图恢复为 **1440x3200 全分辨率 PNG**（1.5 MB）。

> ⚠️ 注意：`input -d` 用的是**逻辑 display id**，与 `screencap -d` 的 token 语义完全不同。
> 两者混用是本项目在 API 30+ 上最容易踩的坑。

### 2.3 IME 策略反射失效导致 `vd type` 完全不可用（功能失效）

**现象**：`vd type` 恒返回 `{"ok":false,"mode":"unknown"}`，主屏键盘不受影响但副屏永不获得输入法。

**根因**（真机取证）：原实现走

```java
WindowManagerGlobal.getWindowManagerService().setDisplayImePolicy(id, 0)
```

在 Android 17 上必然失败，真实异常是：

```
java.lang.IllegalStateException: ApplicationSharedMemory not initialized
    at com.android.internal.os.ApplicationSharedMemory.getInstance(ApplicationSharedMemory.java:81)
    at android.view.WindowManagerGlobal.getWindowManagerService(WindowManagerGlobal.java:301)
```

API 37 给 `WindowManagerGlobal` 引入了 `ApplicationSharedMemory` 依赖，而 `app_process`
直接拉起的进程不会初始化它（那是 zygote / app 进程的职责）。

原代码只打印 `t.getMessage()`，而该异常在此路径下 message 为 `null`，
于是日志显示成 `Failed to set IME policy: null` —— 极易被误判为"方法不存在"。

**修复**：新增 `ImePolicyHelper`，绕开 `WindowManagerGlobal`：

```
ServiceManager.getService("window") -> IWindowManager$Stub.asInterface -> setDisplayImePolicy
```

并且**回读 `getDisplayImePolicy` 校验策略真正落地**，而不是"没抛异常就算成功"。

实测日志由：
```
[AgentDaemon] Warning: Failed to set IME policy: null
```
变为：
```
[AgentDaemon] Set Display 5 IME policy to LOCAL (0)
```

### 2.4 `ToolMain` 三处缺陷

#### a) 显示尺寸查询链恒返回 0x0

原实现反射 `DisplayManager(DisplayManagerGlobal)` 构造器 —— 该构造器在 Android 11/13/16/17
上**都不存在**（`DisplayManager` 只有 `DisplayManager(Context)`）。

后果不只是"尺寸显示为 0"：
* `tree` 头部恒为 `size=0x0`
* `withinScreen()` 因 `dispW <= 0` 直接 `return true` —— **全部几何过滤失效**
* `x_extent` / `y_extent` 判据失真

**修复**：改用 `DisplayManagerGlobal.getRealDisplay(int)`（不需要 Context）。实测对
display 0/3/4 均正确返回 `1440x3200`。

#### b) `UiAutomation.connect(0)` 压制其它无障碍服务

`connect` 的 flags 中 `0x1 = FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES`。传 `0` 时
`UiAutomationManager` 会停用其它所有 a11y 服务，直到 `disconnect`。

而 `vd_server` 习惯在同一窗口内临时启用伴随无障碍服务；WebView/Chromium 一旦判定
"没有 enabled a11y service" 就会拆掉渲染器无障碍树 —— 表现为 H5 页面里的搜索框
**直接从控件树上消失**，`type` 自然找不到目标。

**修复**：改为 `connect(0x1)`。仍被标记为 accessibility tool，但不再压制其它服务。

#### c) `type` 目标节点查找无任何兜底

原逻辑只认 `isFocused() && isEditable()` 同时成立。当搜索框"已点开但无障碍层未标 focused"
（Compose / Flutter / WebView / 厂商自绘控件很常见）时，`targetNode` 恒为 `null`，
Path 1 与 Path 2 **被整体跳过**（连"点一下再试"都不会发生），最终只回
`{"ok":false,"mode":"unknown"}` 且不给出任何原因。

**修复**：改为四级回退，并补充诊断计数：

1. `focused && editable` —— 语义最明确
2. `focused && 类名像输入框` —— 兼容 `isEditable()` 上报不准的控件
3. 任意 `editable` —— 单输入框页面足够用
4. 任意「类名像输入框」的节点

JSON 输出新增 `windows` / `nodes` / `editables` / `focused` 计数，让失败可自解释。

> 关键事实：`ACTION_SET_TEXT` **不要求节点持有焦点**。AOSP `TextView` 只要
> `BufferType.EDITABLE && isEnabled()` 就会挂上该 action。所以放宽目标选择是安全且有效的。

**实测结果**：

```json
{"ok":true,"display":5,"mode":"action_set_text","cost_ms":341,"target":"focused",
 "vid":"android:id/input","type":"android.widget.EditText",
 "before_text":"搜索系统设置项","verified_text":"小米15Pro适配测试ABC123"}
```

`mode` 由 `unknown` 变为 `action_set_text`，文本真实写入副屏搜索框。

### 2.5 安装脚本适配 FolkPatch / APatch

`customize.sh` 现在会：
* 探测并报告 Root 方案（`/data/adb/ap` → APatch/FolkPatch）
* 安装 APK 后对 LSPosed 作用域写入做**回读校验**（原版写完不校验，静默失败会让 Hook 完全不生效）
* 校验失败时打印明确的手工激活步骤
* 同步部署 `vd_env.sh` 并清理陈旧的 classpath 缓存（避免 OTA 后沿用旧 jar 列表）

### 2.6 构建工具链修复

* `build.sh` 不再硬编码 `/usr/lib/android-sdk`（Ubuntu 各版本布局不同，原版多数环境直接失败）
* `dx` 已废弃 → 改用 **r8/d8**
* 资源编译改用 **aapt2**（Debian 自带的 aapt v0.2 读不了 Android 14+ 的 `resources.arsc`，
  会报 `No resource identifier found for attribute 'xxx'`）
* Xposed API 改由编译期 stub 提供，运行时由 LSPosed 注入真实实现

---

## 3. 真机验证结果

### 3.1 已验证通过

| 功能 | 命令 | 结果 |
| :--- | :--- | :--- |
| 环境自检 | `vd doctor` | 65 项 BOOTCLASSPATH、8 个厂商 jar 全部识别、app_process 自检 OK |
| 启动副屏 | `vd start` | Display 创建成功，自动匹配 1440x3200@600 |
| 状态查询 | `vd status` | 正确显示 Display ID 与真实规格 |
| 控件树 | `vd tree` | 结构化输出（小米设置页 23 节点，含正确坐标） |
| 副屏截图 | `vd screenshot` | 1440x3200 全分辨率 PNG（1.5 MB） |
| 定向启动 | `vd launch com.android.settings` | 应用正确渲染到副屏 |
| 点击 | `vd tap` | 事件送达副屏，副屏应用真实响应 |
| 滑动 | `vd swipe` | 手势送达 |
| 按键 | `vd key` | 送达 |
| 文本注入 | `vd type` | **`mode=action_set_text`，文本真实写入并回读验证** |
| IME 隔离 | — | 副屏获得独立 IME，主屏 `mImeWindow=null` 不受影响 |
| HTTP 网关 | `GET /api/status` | 返回正确状态 JSON |
| HTTP 截图 | `GET /api/screenshot` | 返回副屏 JPEG |
| Web 界面 | `GET /` | 正常返回监控页 |
| 停止副屏 | `vd stop` | Display 注销、SurfaceFlinger 层消失、资源释放 |

### 3.2 代码层验证

用 `tools/dex_api_probe.py` 在真机的 `framework.jar` / `services.jar` / `miui-services.jar`
上逐个核验了 LSPosed Hook 目标 —— **9 个 Hook 点在 API 37 上全部存在**：

| Hook 目标 | 所在文件 | 状态 |
| :--- | :--- | :--- |
| `android.view.Display.canHostTasks` | framework.jar | 存在 |
| `com.android.server.display.LogicalDisplay.canHostTasksLocked` | services.jar | 存在 |
| `ActivityTaskSupervisor.isCallerAllowedToLaunchOnDisplay` | services.jar | 存在 |
| `ActivityTaskSupervisor.isCallerAllowedToLaunchOnTaskDisplayArea` | services.jar | 存在 |
| `ActivityTaskSupervisor.canPlaceEntityOnDisplay` | services.jar | 存在 |
| `ActivityRecord.canBeLaunchedOnDisplay` | services.jar | 存在 |
| `Task.canBeLaunchedOnDisplay` | services.jar | 存在 |
| `RootWindowContainer.canLaunchOnDisplay` | services.jar | 存在 |
| `DisplayManagerService.validatePackageName` | services.jar | 存在 |
| `InputMethodManagerService.computeImeDisplayIdForTarget` | services.jar | 存在 |

`tools/dex_api_probe.py` 是为适配新 ROM 而新增的工具：`javap` 无法读取 dex，
而跨厂商适配必须逐个核验反射目标是否存在。

```bash
# 列出某类的全部方法
python3 tools/dex_api_probe.py <framework.jar|services.jar> <类名关键字>
# 查看精确签名（含参数类型）
python3 tools/dex_api_probe.py --sig <jar> <类名关键字> [方法名关键字]
```

### 3.3 待验证（需重启）

LSPosed Hook 的**运行时**效果需要重启后才能确认（Hook 在 `system_server` 启动时注入）：

* 副屏应用启动时主屏焦点不被抢占
* IME 在不同 display 间的隔离行为
* Edge Glow 边缘光效与前台通知卡片

Hook APK 已重新编译、安装，LSPosed 作用域（`android` / `system` / `com.android.systemui`）
已写入数据库（经三表回读校验）。

---

## 4. 使用方法

```bash
# 环境自检（换机型/OTA 后先跑这个）
vd doctor

# 生命周期
vd start                 # 拉起副屏 + 3070 网关
vd status                # 查看状态与真实规格
vd stop                  # 销毁副屏，释放全部资源

# 感知与输入
vd tree                  # 副屏控件树（JSON，含中心坐标）
vd launch <包名>          # 定向在副屏启动应用
vd tap <x> <y>
vd swipe <x1> <y1> <x2> <y2> [ms]
vd key <keycode>         # 4=返回 3=主页 66=回车 67=退格
vd type "<文本>"          # 免 IME 弹窗注入（支持中文）
vd screenshot [路径]      # 副屏全分辨率 PNG
```

HTTP 网关（`http://127.0.0.1:3070`）：
`/`（Web 监控页）、`/api/status`、`/api/screenshot`、`/api/start`、`/api/stop`

---

## 5. 已知限制

1. **`vd type` 定位语义**：`type <display> <text>` 走的是"聚焦节点 → 四级回退"策略。
   若页面存在多个输入框，建议用 `vd tree` 找到带 `e`（editable）标记的节点，
   取其 `id=` 值后通过底层接口 `settext <display> id:<资源名> "<文本>"` 精确指定。
   注意 `tree` 打印的数字 id 与 `settext` 的数字 id **不同源**，不要混用。

2. **`/api/shell` 安全面**：vd_server 监听 `0.0.0.0:3070` 且 `/api/shell` 无鉴权，
   同网段可执行 root 命令。**建议仅在可信网络使用，或改为绑定 127.0.0.1。**
   （本次未改动此行为，以免影响上游设计；如需收紧可改 `vd-server-go/main.go` 的
   `ListenAndServe` 地址并加 token。）

3. **JPEG 帧缓存无 TTL**：`/api/screenshot` 在守护进程存活但停止出帧时可能返回旧帧。
   daemon 侧写入是 `tmp + rename` 原子操作，但异常退出会残留 `.tmp` 文件。

4. **副屏全分辨率开销**：1440x3200 每帧 RGBA 为 18.4 MB，ImageReader 双缓冲 + Bitmap
   约 55 MB 常驻，JPEG 编码有明显 CPU 开销。**建议不要长期挂着副屏**；
   在低配设备上可通过 `run_daemon.sh <宽> <高> <DPI>` 手动指定更小规格。

5. **多个副屏实例**：反复 `vd start` 若前一个守护进程未正常退出，可能残留多个
   `DaemonMain` 进程同时编码帧。`vd stop` 会清理；异常时可 `vd doctor` 查看。

---

## 6. 上游差异摘要

| 文件 | 变更 |
| :--- | :--- |
| `ksu-module/bin/vd_env.sh` | **新增** 跨厂商 BOOTCLASSPATH 解析器 |
| `ksu-module/system/bin/vd` | 接入 vd_env.sh、修复 screencap token、新增 `doctor`、文案去硬编码 |
| `ksu-module/bin/run_daemon.sh` | 接入 vd_env.sh、优先 Override size 探测分辨率 |
| `ksu-module/customize.sh` | FolkPatch/APatch 探测、LSPosed 作用域回读校验、部署 vd_env.sh |
| `ksu-module/module.prop` | 版本 → `v4.7-xiaomi` |
| `vd-tool-java/src/com/agent/ImePolicyHelper.java` | **新增** IME 策略绕行实现 |
| `vd-tool-java/src/com/agent/DaemonMain.java` | 改用 ImePolicyHelper |
| `vd-tool-java/src/com/agent/ToolMain.java` | 显示尺寸链、connect flags、type 四级回退、诊断计数 |
| `agent-hook-apk/build.sh` | 自动探测 SDK、d8、aapt2 流程 |
| `tools/dex_api_probe.py` | **新增** dex 类/方法/签名探针 |
| `vd-tool-java/bin/*.dex`、`ksu-module/bin/*.dex` | 重新编译 |
| `ksu-module/apk/agent_hook.apk` | 重新编译（API 37 平台） |

---

## 7. 复现构建

```bash
# 1. 依赖
apt-get install -y openjdk-17-jdk-headless aapt zipalign apksigner unzip
# android.jar: 从 dl.google.com 取 platform-37.0_r02.zip 解出 android-37.0/android.jar
# d8: maven.google.com 的 com/android/tools/r8 包
# aapt2: maven.google.com 的 com/android/tools/build/aapt2 包

# 2. 编译 Java 工具链
cd vd-tool-java && javac -source 8 -target 8 \
  -bootclasspath <android.jar> -cp <android.jar> \
  src/com/agent/*.java -d bin/classes
d8 --min-api 26 --output <out> bin/classes/com/agent/ToolMain*.class    # -> agent_tools.dex
d8 --min-api 26 --output <out> bin/classes/com/agent/DaemonMain*.class \
   bin/classes/com/agent/ImePolicyHelper*.class                         # -> agent_vd.dex

# 3. 编译 Hook APK（脚本已自动探测工具链）
cd agent-hook-apk && ./build.sh

# 4. 打包模块
cd ksu-module && ./pack.sh
```

---

## 8. 排障速查

| 现象 | 原因 | 处理 |
| :--- | :--- | :--- |
| `Aborted`（退出码 134） | BOOTCLASSPATH 含不存在条目 | `vd doctor` 看 BOOTCLASSPATH 段；删缓存 `rm /data/local/tmp/vd_bootclasspath.txt` 后重试 |
| `Display Id 'N' is not valid` | 把逻辑 id 当 SF token 传给 screencap | 已修复；确认用的是 `vd screenshot` 而非手写 screencap |
| `mode":"unknown"` | 未找到可编辑目标节点 | 已加四级回退；仍失败时看 JSON 的 `editables` / `nodes` 计数 |
| `Failed to set IME policy: null` | `WindowManagerGlobal` 在 API 37 不可用 | 已改用 ImePolicyHelper |
| `tree` 头部 `size=0x0` | 显示尺寸链失效 | 已改用 `DisplayManagerReal.getRealDisplay` |
| Hook 不生效 | LSPosed 作用域未配置 | 打开 LSPosed 管理器勾选模块与「系统框架」，重启 |
| 手机变卡 | 副屏全分辨率持续编码 | `vd stop`；确认无残留 `DaemonMain` 进程 |
