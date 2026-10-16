# Windows 版怎么编

界面是原生 WPF（.NET 8），核心逻辑直接用 macOS 那套 Swift 代码，编成 `boxsend-core.dll` 由界面进程内加载。
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
| 打安装包 | Inno Setup 6.5 及以上（可选，不装就交付 `publish\` 目录）。6.3 起才认 `x64compatible`，简体中文向导要 6.5 |

装完 Swift 工具链要**重开一个终端**再跑脚本。Windows 平台的 Swift 标准库不在工具链里，而在
`…\Platforms\Windows.platform\Developer\SDK\Windows.sdk`，安装器是靠写用户环境变量 `SDKROOT`
把这条路告诉 `swiftc` 的；不换终端就读不到，报法是
`unable to load standard library for target 'x86_64-unknown-windows-msvc'`。
脚本检测到 `SDKROOT` 缺失会先提醒一句；真编译失败时它会自动导一次 VS 开发者环境
（`INCLUDE` / `LIB` / `WindowsSdkDir`）再试一次，因为 MSVC 头文件的路径也只在开发者环境里。
CI 里这两样由 workflow 负责：`SDKROOT` 从注册表读出来写进 `GITHUB_ENV`，PATH 写进 `GITHUB_PATH`。

## 这个脚本做了四件事

1. `swift build -c release --product boxsend-core`
   Windows 得 `boxsend-core.dll`，macOS 得 `libboxsend-core.dylib`，和 C# 侧 `DllImport` 的名字对齐。
   名字带 `-core` 不是讲究：Windows 文件名不分大小写，核心库若叫 `boxsend.dll` 就和 WPF 那份
   托管程序集 `BoxSend.dll` 撞成一个，界面加载到的是自己那份托管程序集（它是合法 PE，能加载，
   只是没有导出符号），报「Unable to find an entry point named 'boxsend_create'」。
2. 从 `boxsend-core.dll` 的导入表出发，一层层把依赖闭包拷进 `BoxSend.Windows\native\`。
   不按文件名猜：Swift 运行时的 DLL 名跟着版本变，6.4 就有 `swift_Concurrency.dll` /
   `swift_StringProcessing.dll` / `swiftDispatch.dll` 三个不在任何通配里，装到用户机器上表现为
   「Unable to load DLL 'boxsend-core' or one of its dependencies」。解析用 `Interop\PeReader.cs`
   （界面和脚本编同一份），VC++ 运行库取 VS 里那份官方支持随包部署的集合（连
   `msvcp140_codecvt_ids.dll` 这些卫星 DLL 一起）——Swift 运行时是 MSVC 编的，而自包含的 .NET
   只带它自己那份 `_cor3`。
   只拷真被导入的那几个，不整目录扫——顺手扫过一次，多带了 `msvcp140d.dll` 那堆 debug 版 CRT，白搭 4 MB。
   csproj 里那份 `None Include="native\**\*"` 带 `Link` 把目录拍平：这些 DLL 之间的依赖是运行期
   动态加载的，Windows 只在「exe 所在目录 + PATH」里找，留在 `native\` 子目录里的表现是
   「装上了但起不来」。
3. `dotnet publish -c Release -r win-x64 --self-contained true`
   默认**自带 .NET 运行时**，用户机器上什么都不用装。CI 上实测 `publish\` 188 MB / 480 个文件
   （含 Swift 运行时；大头是 PresentationFramework / System.Private.CoreLib / WinForms 那几块），
   LZMA2 压完安装包约为其三分之一（mac 版 `.app` 是 7.4 MB，差距全在运行时本体）。
   嫌大就加 `-FrameworkDependent` 换回框架依赖：成品 1 MB 内，代价是用户得先装 .NET 8 桌面运行时。
   （WPF 不支持裁剪，`PublishTrimmed` 用不上，这块体积省不动。）
4. `-Setup` 时调 Inno Setup，产出 `windows\installer\Output\BoxSend-<版本>-win-x64.exe`。
   版本号从核心库 `Sources\BoxSendKit\Util\Version.swift` 读（写进未入库的 `installer\version.inc`），
   安装包名、exe 属性里的版本、界面右上角显示的版本永远是同一个数，只在 `Version.swift` 里改一次。
   安装向导是简体中文：语言文件已随仓库带在 `installer/Languages/ChineseSimplified.isl`
   （抄自 `jrsoftware/issrc` 标签 `is-6_7_1` 的 `Unofficial/`，补了 UTF-8 BOM——没 BOM 时编译器按机器
   ANSI 码页读，英文 runner 上中文全成问号）。`.iss` 里带 `#if FileExists`，文件不在就退回英文。

安装完的数据在 `%APPDATA%\BoxSend`（配置、cookies、状态），卸载时保留，重装自动接着用。

## 双击没反应时看哪儿

界面是双击启动的 WinExe，没有控制台，异常要是发生在弹框之前就连框都没有。每一步都往
`%LOCALAPPDATA%\BoxSend\startup.log` 追加一行：卡在「核心库：正在创建」就是核心库没回来，
停在「核心库：就绪」之后就是界面的事，连一行都没有就是进程压根没起来（看事件查看器的
应用程序日志）。界面线程的未处理异常现在也会弹框并把细节写进同一个文件。
窗口关掉是收进托盘（跟 mac 版一致），此时再双击图标会把原来那个实例的窗口叫出来，不再只弹一句「已在运行」。

## 用 GitHub Actions 出包（不用本机装工具链）

`.github/workflows/release.yml` 里两个作业并行：macOS 出 `.app`、Windows 出安装包，
版本号同一个来源（`Sources/BoxSendKit/Util/Version.swift`）。

| 怎么触发 | 结果 |
| --- | --- |
| 推 tag（仓库现在的 tag 形如 `1.2`） | 两个包直接挂到该 tag 的 Release |
| Actions 页面手动运行 | 只构建，产物留在 Runs 页可下载，不发版；下方 `平台` 选 `windows` 就只出安装包 |
| 提 PR / 推 main | 只跑两平台的测试 |

手动运行：Actions 页左侧选 `打包` → 右侧「Run workflow」→ 选分支/tag 与平台 → 绿色按钮。
产物在该次运行的 Summary 页底部「Artifacts」里下载（安装包文件名形如 `BoxSend-1.2-win-x64.exe`）。

Windows 作业会自己下载安装器装 Swift 工具链（runner 没预装，Windows 那侧官方只发 `.exe`，没有 zip；
runner 是 Server 镜像、里面也没有 winget，所以走 curl 直连，两 GB 十几秒就下来了）。
换版本改 workflow 顶部 `env.SWIFT_WINDOWS`，同时把 `SWIFT_WINDOWS_SHA256` 换成
winget 清单（`microsoft/winget-pkgs` 里 `Swift.Toolchain/<版本>/`）那份新值；
下载地址 404 就把它旁边那个 `SWIFT_WINDOWS_URL` 填成完整地址。Inno Setup 已预装就复用，没有就静默装一个。

`dotnet publish` 的还原单独一步并带 `~/.nuget/packages` 缓存：自包含发布要拉上百 MB 的 win-x64
运行时包，这一步卡在网络上时整步可以半小时不出一个字，分开跑才能从计时行看出卡在哪。

官方那个 `.exe` 是 **WiX Burn bundle**（winget 清单里 `InstallerType: burn`、`Scope: user`），
只认 `/quiet /norestart /log <文件>`。别照 Inno 那套写 `/VERYSILENT`：burn 不认的参数等于没传，
它会弹出向导等人在界面上点，CI 上没人点就一直挂着到超时。安装装到 runner 用户的
`%LOCALAPPDATA%\Programs\Swift` 下（Toolchains 与 Runtimes 两份，都要进 PATH），不提权、不会有 UAC 弹窗。

两条 Windows 独有的坑，都已经变成构建期闸门：

- **导出表**。COFF 的导出表只认 `.drectve` / `.def` 两种自动写法，Swift 的 `@_cdecl` 都不走，
  它只保证符号名。`Package.swift` 给 `BoxSendBridge` 按名字逐个加了 `-Xlinker /EXPORT:`。
- **依赖闭包与加载路径**。核心库和它的运行时 DLL 必须和 `BoxSend.exe` 同目录，见上面第 2 条；
  CI 上工具链目录一直在 PATH 里，漏拷的 DLL 会被 PATH 兜住，所以打包前还有一道
  `Test-BoxSendClosure`：成品里每个 DLL 的导入项要么在成品里、要么是 Windows 自带，缺就不过。

四条闸门（导出表、拍平、闭包、真调一次）都在打包脚本里，界面启动时也会把缺的依赖名报进
对话框。最后那条最要紧：导出表齐全、`LoadLibrary` 也过，照样可能起不来——Swift 运行时里
有一批 DLL 是运行期按名字自己 `LoadLibrary` 的（`libcurl` 那类），导入表里看不见，闭包拷贝
拷不到它们，而 CI 上工具链目录一直在 PATH 里，缺了也看不出来。所以真调那一步把 PATH 只留
系统目录（模拟干净机器），并且整步跑在后台作业里：`boxsend_create` 240 秒不返回就判死，
并把核心库自己记的进度（`Trace.mark` 那些行）打出来。核心库内部走到哪儿，界面上那行
「核心库：正在创建」后面就是答案。这些坑 mac 上一个都看不出来。

核心库在 Windows 上的测试已经跑绿：366 条全过、16 条跳过（要真站点的 live 用例，以及要本机
`openssl` / `zip` 造输入的那几条），`ALLOW_WINDOWS_TEST_FAILURE` 已改成 `false`，测试不过就
不许出包。mac 端是 367 条（Windows 少一条造 JPEG 的用例，见上）。

## 目录

```
windows/
  build.ps1                Windows 打包脚本
  make_icon.py             从 build/AppIcon.iconset 生成 boxsend.ico（与 mac 图标同源）
  BoxSend.Windows/         WPF 界面工程（六页 + 托盘 + 主题）
    native/                核心库与 Swift 运行时（脚本填入，不入库）
  installer/boxsend.iss    Inno Setup 脚本
  installer/Languages/     安装向导的简体中文消息
  abi-probe/               C ABI 冒烟测试，可在 macOS/Linux 上跑
```

## 不上 Windows 也能验的东西

核心契约和 P/Invoke 声明在 mac 上就能对拍：

```bash
swift test                                        # 核心库回归（含无头服务契约测试）
swift build                                       # 产出 .build/debug/libboxsend-core.dylib
dotnet run --project windows/abi-probe            # 用 WPF 同一份 P/Invoke 声明加载真库跑一遍
```

`abi-probe` 覆盖：版本/快照结构、建组、加站、组限速继承、改名撞号、目标站、配置补丁落盘、
事件游标、错误传递。它绿了，至少说明跨语言边界本身没问题，剩下的都是 Windows 上的界面与运行时表现。

图标改了就在 mac 上重新生成，别手改：

```bash
python3 windows/make_icon.py
```
