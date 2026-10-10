# Windows 版怎么编

界面是原生 WPF（.NET 8），核心逻辑直接用 macOS 那套 Swift 代码，编成 `boxsend.dll` 由界面进程内加载。
在 Windows 上一键到底：

```powershell
.\windows\build.ps1            # 出绿色版目录 windows\publish\
.\windows\build.ps1 -Setup     # 再打成 windows\installer\Output\BoxSend-x.y.z-win-x64.exe
```

## 前置

| 用途 | 装什么 |
| --- | --- |
| 编核心库 | Swift for Windows 工具链 <https://www.swift.org/install/windows/> |
| 编界面 | .NET 8 SDK |
| 打安装包 | Inno Setup 6.3 及以上（可选，不装就交付 `publish\` 目录） |

装完 Swift 工具链要**重开一个终端**再跑脚本。Windows 平台的 Swift 标准库不在工具链里，而在
`…\Platforms\Windows.platform\Developer\SDK\Windows.sdk`，安装器是靠写用户环境变量 `SDKROOT`
把这条路告诉 `swiftc` 的；不换终端就读不到，报法是
`unable to load standard library for target 'x86_64-unknown-windows-msvc'`。
脚本检测到 `SDKROOT` 缺失会先提醒一句；真编译失败时它会自动导一次 VS 开发者环境
（`INCLUDE` / `LIB` / `WindowsSdkDir`）再试一次，因为 MSVC 头文件的路径也只在开发者环境里。
CI 里这两样由 workflow 负责：`SDKROOT` 从注册表读出来写进 `GITHUB_ENV`，PATH 写进 `GITHUB_PATH`。

## 这个脚本做了四件事

1. `swift build -c release --product boxsend`
   产物名跨平台统一叫 `boxsend`（Windows 得 `boxsend.dll`，macOS 得 `libboxsend.dylib`），
   和 C# 侧 `DllImport("boxsend")` 的解析规则对齐，打包不用改名。
2. 把 `boxsend.dll` 连同一批 Swift 运行时 DLL（`swiftCore.dll` / `Foundation.dll` / `dispatch.dll` /
   ICU / curl 等，从工具链 `usr\bin` 按模式扫）拷进 `BoxSend.Windows\native\`，csproj 会整目录带进输出。
   不同工具链版本文件名有出入，漏拷时 Windows 会直接报缺哪个 DLL，照名补进 `native\` 即可；
   权威判据是导入表：`dumpbin /dependents boxsend.dll`。
   顺带从 `System32` 拷一份 `vcruntime140.dll` 之类做随包部署——Swift 运行时是 MSVC 编的，
   干净的 Win11 上少了它会双击没反应，而自包含的 .NET 只带它自己那份 `_cor3`。
3. `dotnet publish -c Release -r win-x64 --self-contained true`
   默认**自带 .NET 运行时**，用户机器上什么都不用装。CI 上实测 `publish\` 188 MB / 480 个文件
   （含 Swift 运行时；大头是 PresentationFramework / System.Private.CoreLib / WinForms 那几块），
   LZMA2 压完安装包约为其三分之一（mac 版 `.app` 是 7.4 MB，差距全在运行时本体）。
   嫌大就加 `-FrameworkDependent` 换回框架依赖：成品 1 MB 内，代价是用户得先装 .NET 8 桌面运行时。
   （WPF 不支持裁剪，`PublishTrimmed` 用不上，这块体积省不动。）
4. `-Setup` 时调 Inno Setup，产出 `windows\installer\Output\BoxSend-<版本>-win-x64.exe`。
   版本号从核心库 `Sources\BoxSendKit\Util\Version.swift` 读（写进未入库的 `installer\version.inc`），
   安装包名、exe 属性里的版本、界面右上角显示的版本永远是同一个数，只在 `Version.swift` 里改一次。
   想让安装向导说中文，把 `ChineseSimplified.isl` 放进 `windows/installer/Languages/`，脚本会自动改用例。

安装完的数据在 `%APPDATA%\BoxSend`（配置、cookies、状态），卸载时保留，重装自动接着用。

## 用 GitHub Actions 出包（不用本机装工具链）

`.github/workflows/release.yml` 里两个作业并行：macOS 出 `.app`、Windows 出安装包，
版本号同一个来源（`Sources/BoxSendKit/Util/Version.swift`）。

| 怎么触发 | 结果 |
| --- | --- |
| 推 tag（仓库现在的 tag 形如 `1.1`） | 两个包直接挂到该 tag 的 Release |
| Actions 页面手动运行 | 只构建，产物留在 Runs 页可下载，不发版；下方 `平台` 选 `windows` 就只出安装包 |
| 提 PR / 推 main | 只跑两平台的测试 |

手动运行：Actions 页左侧选 `打包` → 右侧「Run workflow」→ 选分支/tag 与平台 → 绿色按钮。
产物在该次运行的 Summary 页底部「Artifacts」里下载（安装包文件名形如 `BoxSend-1.1-win-x64.exe`）。

Windows 作业会自己下载安装器装 Swift 工具链（runner 没预装，Windows 那侧官方只发 `.exe`，没有 zip；
runner 是 Server 镜像、里面也没有 winget，所以走 curl 直连，两 GB 十几秒就下来了）。
换版本改 workflow 顶部 `env.SWIFT_WINDOWS`，同时把 `SWIFT_WINDOWS_SHA256` 换成
winget 清单（`microsoft/winget-pkgs` 里 `Swift.Toolchain/<版本>/`）那份新值；
下载地址 404 就把它旁边那个 `SWIFT_WINDOWS_URL` 填成完整地址。Inno Setup 已预装就复用，没有就静默装一个。

官方那个 `.exe` 是 **WiX Burn bundle**（winget 清单里 `InstallerType: burn`、`Scope: user`），
只认 `/quiet /norestart /log <文件>`。别照 Inno 那套写 `/VERYSILENT`：burn 不认的参数等于没传，
它会弹出向导等人在界面上点，CI 上没人点就一直挂着到超时。安装装到 runner 用户的
`%LOCALAPPDATA%\Programs\Swift` 下（Toolchains 与 Runtimes 两份，都要进 PATH），不提权、不会有 UAC 弹窗。

还剩一处要对：核心库在 Windows 上的测试结果（先用 `ALLOW_WINDOWS_TEST_FAILURE: "true"` 放行，
跑绿之后改成 `false` 让它变成硬门禁）。

## 目录

```
windows/
  build.ps1                Windows 打包脚本
  make_icon.py             从 build/AppIcon.iconset 生成 boxsend.ico（与 mac 图标同源）
  BoxSend.Windows/         WPF 界面工程（六页 + 托盘 + 主题）
    native/                核心库与 Swift 运行时（脚本填入，不入库）
  installer/boxsend.iss    Inno Setup 脚本
  abi-probe/               C ABI 冒烟测试，可在 macOS/Linux 上跑
```

## 不上 Windows 也能验的东西

核心契约和 P/Invoke 声明在 mac 上就能对拍：

```bash
swift test                                        # 核心库回归（含无头服务契约测试）
swift build                                       # 产出 .build/debug/libboxsend.dylib
dotnet run --project windows/abi-probe            # 用 WPF 同一份 P/Invoke 声明加载真库跑一遍
```

`abi-probe` 覆盖：版本/快照结构、建组、加站、组限速继承、改名撞号、目标站、配置补丁落盘、
事件游标、错误传递。它绿了，至少说明跨语言边界本身没问题，剩下的都是 Windows 上的界面与运行时表现。

图标改了就在 mac 上重新生成，别手改：

```bash
python3 windows/make_icon.py
```
