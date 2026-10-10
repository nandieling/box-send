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
   默认**自带 .NET 运行时**，用户机器上什么都不用装。实测 161 MB / 465 个文件，
   `xz -9e` 压完 47 MB，安装包最终大约就是这个量级（mac 版 `.app` 是 7.4 MB，差距全在 .NET 运行时本体）。
   嫌大就加 `-FrameworkDependent` 换回框架依赖：成品 1 MB 内，代价是用户得先装 .NET 8 桌面运行时。
   （WPF 不支持裁剪，`PublishTrimmed` 用不上，这块体积省不动。）
4. `-Setup` 时调 Inno Setup，产出 `windows\installer\Output\BoxSend-<版本>-win-x64.exe`。
   版本号从核心库 `Sources\BoxSendKit\Util\Version.swift` 读（写进未入库的 `installer\version.inc`），
   安装包名、exe 属性里的版本、界面右上角显示的版本永远是同一个数，只在 `Version.swift` 里改一次。
   想让安装向导说中文，把 `ChineseSimplified.isl` 放进 `windows/installer/Languages/`，脚本会自动改用例。

安装完的数据在 `%APPDATA%\BoxSend`（配置、cookies、状态），卸载时保留，重装自动接着用。

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
