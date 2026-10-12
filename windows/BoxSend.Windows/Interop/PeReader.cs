using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace BoxSend.Windows.Interop
{

/// <summary>
/// 从 PE 文件头读导出/导入表。打包脚本（build.ps1 用 Add-Type 编同一份源码）和界面的启动
/// 报错共用一套解析：Windows 上「核心库加载不了」的原因永远写在导入表里，猜是猜不出来的。
/// 只写 C# 6 能过的写法——PowerShell Add-Type 的语言版本比 csproj 里设的 latest 严。
/// </summary>
public static class PeReader
{
    /// <summary>按名导出的符号名。导出表缺失时返回空数组。</summary>
    public static string[] Exports(string path)
    {
        byte[] b;
        int dir;
        if (!TryDir(path, 0, out b, out dir)) return new string[0];
        List<string> list = new List<string>();
        int count = ReadU16ish(ReadU32(b, dir + 24));
        int names = RvaToFile(b, ReadU32(b, dir + 32));
        if (names < 0) return new string[0];
        for (int i = 0; i < count; i++)
        {
            string s = ReadAscii(b, RvaToFile(b, ReadU32(b, names + i * 4)));
            if (s != null) list.Add(s);
        }
        return list.ToArray();
    }

    /// <summary>直接导入的 DLL 名，大小写照文件里的写法。导入表缺失时返回空数组。</summary>
    public static string[] Imports(string path)
    {
        byte[] b;
        int dir;
        // 数据目录第 1 项是导入表（第 0 项是导出表）
        if (!TryDir(path, 1, out b, out dir)) return new string[0];
        List<string> list = new List<string>();
        for (int guard = 0; guard < 128; guard++, dir += 20)
        {
            int nameRva = ReadU32(b, dir + 12);
            if (nameRva == 0) break;
            string s = ReadAscii(b, RvaToFile(b, nameRva));
            if (s != null) list.Add(s);
        }
        return list.ToArray();
    }

    /// <summary>
    /// 在 dirs 里全都找不到的导入项。系统 downlevel 转发桩（api-ms-win-* / ext-ms-*）不算，
    /// 带 UCRT 的 Windows 上一律有。界面用它把「找不到指定模块」说成「缺 xxx.dll」。
    /// </summary>
    public static string[] MissingDependencies(string path, string[] dirs)
    {
        List<string> miss = new List<string>();
        foreach (string m in Imports(path))
        {
            if (IsDownlevelApi(m)) continue;
            bool found = false;
            foreach (string dir in dirs)
            {
                if (string.IsNullOrEmpty(dir)) continue;
                if (File.Exists(Path.Combine(dir, m))) { found = true; break; }
            }
            if (!found && !miss.Contains(m)) miss.Add(m);
        }
        return miss.ToArray();
    }

    /// <summary>UCRT / Windows 自带的 downlevel API 转发桩</summary>
    public static bool IsDownlevelApi(string dllName)
    {
        return HasPrefix(dllName, "api-ms-win-") || HasPrefix(dllName, "ext-ms-");
    }

    private static bool HasPrefix(string a, string prefix)
    {
        return a != null && a.Length > prefix.Length &&
               a.Substring(0, prefix.Length).Equals(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private static int ReadU16ish(int v) { return v < 0 || v > 65535 ? 0 : v; }

    private static int ReadU32(byte[] b, int at)
    {
        return at >= 0 && at + 4 <= b.Length ? BitConverter.ToInt32(b, at) : 0;
    }

    // 定位第 index 项数据目录，直接给出它指向的表在文件里的偏移
    private static bool TryDir(string path, int index, out byte[] bytes, out int tableAt)
    {
        bytes = new byte[0]; tableAt = -1;
        byte[] b;
        try { b = File.ReadAllBytes(path); } catch { return false; }
        bytes = b;
        if (b.Length < 0x40 || b[0] != 0x4d || b[1] != 0x5a) return false;   // 连 MZ 头都不是
        int pe = ReadU32(b, 0x3c);
        if (pe < 0 || pe > b.Length - 24) return false;
        int opt = pe + 24;
        // 数据目录起点：PE32+ 在可选头 +112，PE32 在 +96
        int dirs = opt + (BitConverter.ToUInt16(b, opt) == 0x20b ? 112 : 96);
        int entry = dirs + index * 8;
        if (entry + 4 > b.Length || ReadU32(b, entry) == 0) return false;
        tableAt = RvaToFile(b, ReadU32(b, entry));
        return tableAt >= 0 && tableAt + 40 <= b.Length;
    }

    private static int RvaToFile(byte[] b, int rva)
    {
        if (rva <= 0 || b.Length < 0x40) return -1;
        uint r = (uint)rva;
        int pe = ReadU32(b, 0x3c);
        int nsec = BitConverter.ToUInt16(b, pe + 6);
        int sec = pe + 24 + BitConverter.ToUInt16(b, pe + 20);
        for (int i = 0; i < nsec; i++)
        {
            int s = sec + i * 40;
            if (s + 40 > b.Length) return -1;
            uint va = ReadU32At(b, s + 12);
            uint vsize = ReadU32At(b, s + 8);
            uint rawSize = ReadU32At(b, s + 16);
            uint raw = ReadU32At(b, s + 20);
            if (r >= va && r < va + Math.Max(vsize, rawSize)) return (int)(raw + (r - va));
        }
        return -1;
    }

    private static uint ReadU32At(byte[] b, int at)
    {
        return at >= 0 && at + 4 <= b.Length ? BitConverter.ToUInt32(b, at) : 0u;
    }

    private static string ReadAscii(byte[] b, int at)
    {
        // 越界就回空串：两个调用点都只收非空名字，返回 null 反而要在外面多判一次
        if (at < 0 || at >= b.Length) return "";
        int e = at;
        while (e < b.Length && b[e] != 0) e++;
        return Encoding.ASCII.GetString(b, at, e - at);
    }
}

/// <summary>
/// 按 Win32 语义加载 DLL 并查导出符号。打包脚本用它做冒烟，界面启动时用它把
/// 「找不到指定模块」说清楚。
/// </summary>
public static class NativeProbe
{
    [System.Runtime.InteropServices.DllImport("kernel32", SetLastError = true,
        CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr LoadLibraryEx(string path, IntPtr reserved, uint flags);

    [System.Runtime.InteropServices.DllImport("kernel32", SetLastError = true,
        CharSet = System.Runtime.InteropServices.CharSet.Ansi)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    private static readonly bool OnWindows =
        System.Runtime.InteropServices.RuntimeInformation.IsOSPlatform(
            System.Runtime.InteropServices.OSPlatform.Windows);

    /// <summary>0x8 = LOAD_WITH_ALTERED_SEARCH_PATH：依赖按 DLL 自己所在目录找，和双击时一样</summary>
    public static IntPtr Load(string path)
    {
        // 非 Windows 上没有 kernel32（mac 侧的 ABI 冒烟也走这里），交给 .NET 的通用加载器
        if (!OnWindows) return System.Runtime.InteropServices.NativeLibrary.Load(path);
        return LoadLibraryEx(path, IntPtr.Zero, 0x8);
    }

    /// <summary>导出符号地址，0 = 没有这个导出</summary>
    public static long Addr(IntPtr module, string name)
    {
        return GetProcAddress(module, name).ToInt64();
    }

    public static int Win32Error()
    {
        return System.Runtime.InteropServices.Marshal.GetLastWin32Error();
    }
}
}
