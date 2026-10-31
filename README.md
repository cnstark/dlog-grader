# DLogGrader

macOS 15+ 菜单栏应用，用于扫描 DJI Pocket 视频、识别 D-Log / D-Log M / D-Log2 元数据、按需归档原片，并导出 SDR (Rec.709) 和 HDR (HLG) HEVC 视频。两种导出可同时开启，界面为中文。

## 构建

需要 Apple Silicon Mac、Xcode Command Line Tools（Swift 6）、`ffmpeg`。无需 Xcode 工程或第三方 Swift 包。

```sh
bash build.sh
```

产物为 `dist/DLogGrader.app`。脚本按 macOS 15、arm64 编译，写入 `LSUIElement=YES`，并进行 ad-hoc 签名。可通过 Finder 打开该应用。此仓库不包含 ffmpeg 或 DJI 官方 LUT；请自行安装并配置。

## 首次使用

1. 安装 ffmpeg，并在“设置”中确认路径（默认 `/opt/homebrew/bin/ffmpeg`）。
2. 首次使用必须先在“设置”中选择现有的监视目录，并为已开启的功能分别配置归档、SDR 导出和 HDR 导出目录。上述目录均无默认值；缺失或不存在时会标红提示，扫描和处理会暂停。LUT 目录也无默认值，可选择现有目录供应用自动匹配，或在下方逐条指定 LUT 文件。
3. “归档原片”“导出 SDR (Rec.709)”“导出 HDR (HLG)”默认都开启，可独立关闭；关闭的路径选择行会置灰。SDR 需为三种 Log 曲线指定官方 `.cube` 文件，或将其放入 LUT 目录自动匹配。D-Log2 的 vivid/普通及 size65/size33 偏好仅用于 SDR。HDR 不需要 LUT，只处理 D-Log2；D-Log 和 D-Log M 的 HDR 显示“不支持”，仍可导出 SDR。
4. 点击菜单栏图标，选择“立即扫描”。在“查看媒体信息…”检查曲线、规格及 SDR/HDR 各自状态；双击媒体行可查看完整 ffmpeg 元数据。点击“开始处理 (N)”后，每条素材依次执行 SDR、HDR，成功后归档原片。处理期间可点击“停止处理”取消。

自动扫描默认开启，间隔 5 分钟。自动扫描完成后会自行开始处理；手动“立即扫描”只更新媒体列表。关闭自动扫描会取消正在进行的扫描或导出。导出失败会删除当前不完整文件，原片留在监视目录；先前成功的另一种导出保留。三个功能开关全关时仍可扫描，“开始处理”禁用。

## 目录与记录

监视目录必选。SDR 与 HDR 成片分别写入各自的导出目录，并保留监视目录下的子目录结构；MP4 原片导出为同名 MP4，MOV 原片导出为同名主文件名的 MP4。所有已开启且适用的导出成功后，开启归档时才把原片移到归档目录的相对路径。目标文件已存在且有对应模式的成功记录、输出文件大小吻合时复用；若无记录或大小不符则跳过并显示原因，不覆盖。归档关闭时，去重只要求成功记录和输出文件大小吻合；归档开启时，扫描还要求归档原片存在。部分导出成功而未归档时，下次处理可复用已成功的成片。

旧版使用 SDR/HDR 二选一、先归档再导出，成片放在监视目录；新版改为独立开关及目录，旧的导出格式偏好不再使用。现有 SQLite 记录无需迁移：LUT 路径标识 SDR，`HLG (shader)` 标识 HDR，记录仍可读取并在输出路径相同、文件大小吻合时参与去重。

导出记录位于 `~/Library/Application Support/DLogGrader/history.sqlite`，包含时间、源相对路径、曲线、LUT、耗时、结果与输出路径。偏好设置保存在 UserDefaults。

## 源码结构

- `Sources/Main.swift`：菜单栏入口与窗口管理
- `Sources/AppModel.swift`：扫描调度、处理状态与通知
- `Sources/Scanner.swift`：递归枚举媒体文件
- `Sources/MetadataReader.swift`：ffmpeg 元数据解析
- `Sources/Exporter.swift`：ffmpeg LUT 导出与进度解析
- `Sources/MetalLUTExporter.swift`、`Sources/LUTKernel.metal`、`Sources/HDRKernel.metal`：GPU 10-bit 导出与 SDR/HDR Metal kernel
- `Tests/gpu-smoke.sh`、`Tests/GPUSmoke.swift`：GPU 命令行自测
- `Sources/HistoryStore.swift`：SQLite 导出记录
- `Sources/SettingsStore.swift`：偏好设置和 LUT 匹配
- `Sources/ProcessRunner.swift`：可取消的外部进程执行
- `Sources/Views.swift`：中文界面

## GPU 导出与验证

“设置 → 处理 → GPU 加速导出”默认开启，仅影响 SDR。SDR GPU 路径用 AVAssetReader 解码为 ARGB2101010、Metal 3D 纹理按 `.cube` 的 DOMAIN 和三线性插值调色，再交给 AVAssetWriter 的 HEVC Main10 编码器。帧时间戳沿用源视频，色彩标签为 Rec.709。SDR GPU 失败时会尝试 ffmpeg LUT 路径；关闭开关可直接使用 ffmpeg。

HDR 强制使用 Metal，不使用 `.cube` LUT，也不降级到 ffmpeg。色彩链路为：

```text
D-Log2 10-bit RGB → 解析式反曲线 → 场景线性相机 RGB
  → D65 色度矩阵 → 线性 BT.2020 RGB → × 0.265
  → 高光软滚降与向亮度轴色域压缩 → BT.2100 HLG OETF
  → 10-bit TPDF 抖动 → HEVC Main10 / BT.2020 + HLG + BT.2020nc
```

两种导出均以 50 Mbps 编码，音轨由 ffmpeg `-c copy` 从原片封装到最终 MP4。HDR 的 DJI gamma 元数据为 `Rec.2100 HLG`，SDR 为 `Rec.709`。取消会停止当前的读写器或音频封装进程。已知限制：HDR 仅支持 D-Log2；D-Log 与 D-Log M 的 HDR 状态显示“不支持”，SDR 仍可正常处理。相机色域基色来自 DCTL 实测估计值，极端色彩可能因压缩而改变饱和度。

构建脚本优先用 `xcrun metal` 和 `xcrun metallib` 生成 app 内的两个 `.metallib`。只有 Command Line Tools、缺少这两个离线工具时，脚本会将两个 `.metal` 文件放入 Resources，应用通过 Metal API 在运行时编译。

在有 Metal 设备及 HEVC Main10 编码能力的 Mac 上，可用一段带音轨的 10-bit 源片和实际 LUT 运行命令行自测：

```sh
bash Tests/gpu-smoke.sh '/路径/含空格的源片.mov' '/路径/size65.cube' '/路径/输出.mp4'
bash Tests/gpu-smoke.sh '/路径/D-Log2源片.mov' --hdr '/路径/HDR输出.mp4'
```

脚本会构建 app、执行真实 GPU 导出，并用 `ffprobe` 打印编码、profile、像素格式、尺寸、帧率和色彩标签。应看到 HEVC `Main 10`、`yuv420p10le` 和源片相同的尺寸/帧率；HDR 还会断言 `bt2020`、`arib-std-b67`、`bt2020nc`。再用 `ffprobe -show_streams` 确认源音轨存在。建议 SDR 用 size65 与 size33 各测一次，并用含中文、空格及 SMB 路径的源文件验证路径处理。若当前机器没有可用 Metal 设备，CLI 会报错；应用仅在 SDR 模式自动降级到 ffmpeg。
