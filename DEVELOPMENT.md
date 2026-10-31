# 开发说明

面向用户的安装、使用与算法说明见 [README.md](README.md)。项目是 Swift 6、SwiftUI/AppKit 菜单栏应用，直接由脚本编译；没有 Xcode 工程或第三方 Swift 包。

## 模块架构

| 模块 | 职责 |
| --- | --- |
| `Scanner` | 递归枚举监视目录内的 MP4/MOV，排除隐藏文件及配置的归档、导出目录，计算相对路径。 |
| `MetadataReader` | 运行 `ffmpeg -i`，解析 `ColorGammaSxS`、时长、分辨率、位深和帧率，保留原始输出。 |
| `Exporter` | SDR 的 ffmpeg `lut3d` 导出、HEVC VideoToolbox 编码、音轨复制与进度解析；也是 SDR GPU 失败时的回退。 |
| `MetalLUTExporter` | SDR GPU LUT 与 HDR HLG 共用的帧读写、Metal 调度、HEVC Main10 编码、音轨重封装；分别加载 `LUTKernel.metal`、`HDRKernel.metal`。 |
| `HistoryStore` | SQLite 导出记录；`lut` 字段用“手动 · ”区分手动导出，并按输出路径、模式、文件大小及可选归档原片检查监控目录模式的成功记录。 |
| `SettingsStore` | UserDefaults 持久化监控目录自动流程的格式、导出目录、监视与归档目录、LUT 指定与自动匹配，以及通用运行选项；手动导出的批次选择不写入设置。 |
| `ProcessRunner` | 外部进程的异步执行、输出收集与取消，用于元数据读取、ffmpeg 导出和音轨封装。 |

`AppModel.swift` 调度手动选择后的异步元数据读取、扫描、并发处理、状态、通知和监控目录模式导出后的归档。手动导出是基础流程：多选 MP4/MOV 后，由 `ManualExportDraft` 在对话框内收集 SDR/HDR、单个批次 LUT 与输出目录；确认后以独立来源条目进入同一导出队列。成片以 `_SDR` / `_HDR` 后缀直接写入所选目录根下，冲突文件名加序号，不归档原片，也不读取自动流程的格式、LUT 或导出目录预设。设置中的目录、格式及 LUT 配置属于进阶的监控目录自动处理。`Main.swift` 建立菜单栏入口与窗口；`Views.swift` 实现中文界面。HDR 曲线与参数在 `Sources/HDRKernel.metal`，SDR LUT 采样在 `Sources/LUTKernel.metal`。

## 构建

需要 macOS 15+、Apple Silicon、Xcode Command Line Tools（Swift 6）及 ffmpeg。在仓库根目录运行：

```sh
bash build.sh
```

脚本用 `swiftc` 按 `arm64-apple-macosx15.0` 编译 `Sources/*.swift`，生成 `dist/DLogGrader.app`；写入 `LSUIElement=YES` 的 `Info.plist`，最后 ad-hoc 签名。若存在 `xcrun metal` 和 `xcrun metallib`，两个 shader 离线编译成应用内的 `.metallib`；仅有 Command Line Tools 而缺少离线工具时，脚本复制 `.metal` 源文件到 Resources，由应用运行时通过 Metal API 编译。脚本会重建 `dist/DLogGrader.app`。

## GPU 冒烟验证

在具备 Metal 设备和 HEVC Main10 编码能力的 Mac 上，准备真实 10-bit 源片及 SDR LUT：

```sh
bash Tests/gpu-smoke.sh '/路径/源片.mov' '/路径/size65.cube' '/路径/SDR输出.mp4'
bash Tests/gpu-smoke.sh '/路径/D-Log2源片.mov' --hdr '/路径/HDR输出.mp4'
```

脚本先运行 `bash build.sh`，再编译并执行 `Tests/GPUSmoke.swift`，最后调用固定路径 `/opt/homebrew/bin/ffprobe` 打印编码、profile、像素格式、尺寸、帧率和色彩标签；`/opt/homebrew/bin/ffmpeg` 也须可用。HDR 模式会断言 `bt2020`、`arib-std-b67`、`bt2020nc`。预期是 HEVC Main 10、10-bit、与源片相同的尺寸和帧率；若源片带音轨，可用 `ffprobe -show_streams` 核对。此脚本执行真实 GPU 导出，不是纯单元测试。

## 发布

`.github/workflows/release.yml` 在推送 `v*` tag 时自动触发，也支持手动运行。GitHub Actions 在 `macos-15` 上执行 `bash build.sh`，检查可执行文件、`Info.plist` 和签名，打包 `DLogGrader.zip`、生成 SHA-256 校验文件，并创建 Release 或更新同名 Release 的附件。安装包采用 ad-hoc 签名，流程不包含 notarization。

## 代码风格约定

- 沿用 Swift 6 严格并发检查：UI 状态放在 `@MainActor`，后台任务及回调明确跨任务边界。
- 保持模块职责单一；外部命令经 `ProcessRunner` 传参数数组，不拼接 shell 命令。只对 ffmpeg 滤镜语法作必要转义。
- 扫描、导出、封装应可取消；失败时清理不完整输出，并保留明确的状态与错误。
- 用户可见文案用中文，代码标识符用英文；新增设置同时考虑默认值、持久化、界面状态和处理资格。
- 修改色彩链路时在 shader 中标明坐标、常数与变换顺序，并以真实素材检查 10-bit 输出和色彩标签。
