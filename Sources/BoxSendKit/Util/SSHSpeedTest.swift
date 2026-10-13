import Foundation

/// 转种服务器的 SSH 登录信息与「批量转种前上传测速」参数。
///
/// 部分 VPS 24 小时上传流量到 2T 后会静默把上行压到 20 MB/s 左右，批量转种时表现为
/// 全站发种变慢、下载器长时间卡 0%。这里在跑批次前先到服务器上往公网推一块测试数据，
/// 然后把实测速度弹窗报出来，转不转由人决定（软件不替用户设自动判定线）。
public struct SSHConfig: Codable, Equatable {
    /// 登录方式：密钥（BatchMode 免密，不弹任何框）或密码（临时 askpass 代填）
    public enum Auth: String, Codable {
        case key
        case password
    }

    /// 默认测速接收端：Cloudflare 的测速上传口，收任意 POST Body，不计流量账单
    public static let defaultProbeURL = "https://speed.cloudflare.com/__up"

    /// 批量转种前是否先测速（地址与用户名填全了才会真的去测）
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var user: String
    public var auth: Auth
    /// 私钥路径，可写 ~（留空 = 交给 ssh 自己挑默认密钥 / ssh-agent）
    public var keyPath: String
    public var password: String
    /// 测速上传地址（POST 任意接收端都行，换成自己的地址也可以）
    public var probeURL: String
    /// 每轮上传的测试数据量（MB）
    public var testMB: Int
    /// SSH 连接超时（秒）
    public var timeoutSeconds: Int

    public init(enabled: Bool = false, host: String = "", port: Int = 22, user: String = "",
                auth: Auth = .key, keyPath: String = "~/.ssh/id_ed25519", password: String = "",
                probeURL: String = SSHConfig.defaultProbeURL, testMB: Int = 64,
                timeoutSeconds: Int = 15) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.keyPath = keyPath
        self.password = password
        self.probeURL = probeURL
        self.testMB = testMB
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, host, port, user, auth, keyPath, password, probeURL, testMB, timeoutSeconds
    }

    /// 逐字段宽松解码：老配置没有这段、或以后加了新字段都不至于整份配置读不出来
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys, _ fallback: String) -> String {
            (try? c.decodeIfPresent(String.self, forKey: key)) ?? fallback
        }
        func int(_ key: CodingKeys, _ fallback: Int) -> Int {
            (try? c.decodeIfPresent(Int.self, forKey: key)) ?? fallback
        }
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        host = text(.host, "").trimmingCharacters(in: .whitespacesAndNewlines)
        port = int(.port, 22)
        user = text(.user, "").trimmingCharacters(in: .whitespacesAndNewlines)
        auth = SSHConfig.Auth(rawValue: text(.auth, "key").lowercased()) ?? .key
        keyPath = text(.keyPath, "~/.ssh/id_ed25519")
        password = text(.password, "")
        probeURL = text(.probeURL, SSHConfig.defaultProbeURL)
        testMB = int(.testMB, 64)
        timeoutSeconds = int(.timeoutSeconds, 15)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(user, forKey: .user)
        try c.encode(auth, forKey: .auth)
        try c.encode(keyPath, forKey: .keyPath)
        try c.encode(password, forKey: .password)
        try c.encode(probeURL, forKey: .probeURL)
        try c.encode(testMB, forKey: .testMB)
        try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 地址与用户名都填了才算配好
    public var isConfigured: Bool { !trimmedHost.isEmpty && !trimmedUser.isEmpty }

    /// 这一批转种前要不要跑限速检查：开关开着且配置填全
    public var precheckActive: Bool { enabled && isConfigured }

    /// 登录目标（提示文案用）
    public var loginTarget: String { trimmedUser + "@" + trimmedHost }

    /// 端口留空/填错时回落 22
    public var resolvedPort: Int { (1...65535).contains(port) ? port : 22 }

    /// 私钥路径展开 ~
    public var expandedKeyPath: String {
        let p = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? p : (p as NSString).expandingTildeInPath
    }

    /// 测速地址留空时走默认接收端
    public var resolvedProbeURL: String {
        let v = probeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? SSHConfig.defaultProbeURL : v
    }

    /// 单轮测试数据量：限制在 4~512 MB（太小测不准，太大白跑流量）
    public var resolvedTestMB: Int { min(max(testMB, 4), 512) }

    /// 连接超时：限制在 3~60 秒
    public var resolvedTimeout: Int { min(max(timeoutSeconds, 3), 60) }

    /// 弹窗与说明里提到的那条经验线：部分服务器被限速后会落到这个量级，仅作参考
    public static let throttlingHintMBps: Double = 20
}

/// 用系统自带的 ssh 客户端连一次转种服务器，在服务器上量一次公网上传速度。
///
/// 不引第三方 SSH 库：`/usr/bin/ssh` 到处都在，密钥登录走 `BatchMode=yes`，
/// 密码登录临时造一个 askpass 脚本代填密码（密码只进子进程的环境变量与 0600 临时文件，
/// 不进命令行参数，免得同机别的用户 `ps` 一下就看见）。
public enum SSHSpeedTest {
    /// ssh 可执行文件路径（按平台取系统自带的客户端；单测换成桩脚本验证起进程那段）
    public static var sshPath = Platform.defaultSSHPath

    /// 一次 ssh 调用的完整参数；`temporaryDirectory`（密码登录才有）用完必须 `cleanup()`
    public struct Launch {
        public var arguments: [String]
        /// 追加到继承环境之上的变量
        public var environment: [String: String]
        public var temporaryDirectory: URL?

        public func cleanup() {
            if let d = temporaryDirectory { try? FileManager.default.removeItem(at: d) }
        }
    }

    public struct Result: Equatable {
        /// 两轮里最快的那一轮（MB/s）：第一轮要吃 TLS 握手与 TCP 慢启动，取峰值更接近真实带宽
        public var peakMBps: Double
        /// 每一轮的测量值（MB/s，已滤掉 0）
        public var rounds: [Double]
        public var probeURL: String
        /// 服务器上读到的主机名 / 内核（成功文案里带上，确认连的是那台机器）
        public var serverInfo: String

        /// 每一轮速度的文案（"63.4、65.1"）
        public var roundsText: String { rounds.map { SSHSpeedTest.speedText($0) }.joined(separator: "、") }

        /// 结果一句话：测速后交给用户判断，软件不替用户设限
        public var summaryLine: String {
            var text = "上传速度 \(SSHSpeedTest.speedText(peakMBps)) MB/s"
            if rounds.count > 1 { text += "（\(roundsText) MB/s）" }
            if !serverInfo.isEmpty { text += "  @ \(serverInfo)" }
            return text
        }
    }

    /// 执行出口：真机走 `execute`，单测注入桩输出
    public typealias Exec = (Launch, TimeInterval) throws -> String

    // MARK: - 测速后给用户看的文案

    /// 测速完的弹窗文案：不设判定线，只把速度报出来，由用户决定这一批转不转
    public static func gateText(_ r: Result, loginTarget: String) -> (title: String, message: String) {
        let who = r.serverInfo.isEmpty ? loginTarget : r.serverInfo
        return ("服务器上传实测 \(speedText(r.peakMBps)) MB/s",
                "\(who)：\(r.summaryLine)。\n"
                + "部分服务器 24 小时上传流量到 2T 后会把上行压到 \(Int(SSHConfig.throttlingHintMBps)) MB/s 左右，"
                + "速度掉到这个量级及以下时批量转种会整体变慢。是否开始转种？")
    }

    /// 测速本身失败（连不上、服务器没 curl 等）的弹窗文案
    public static func gateFailure(_ why: String, loginTarget: String) -> (title: String, message: String) {
        ("服务器测速没做成",
         "\(loginTarget) 测速失败：\(why)\n"
         + "可以到「下载器」页的「转种服务器」卡片里检查 SSH 设置，也可以先跳过这次检查直接转种。")
    }

    // MARK: - 远程脚本

    /// 服务器端测速脚本：报一下机器身份 -> 写一块测试数据 -> 连传 N 轮，每轮输出一行字节/秒
    public static func speedScript(probeURL: String, testMB: Int, rounds: Int = 2,
                                   maxSecondsPerRound: Int = 120) -> String {
        let quoted = "'" + probeURL.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let n = min(max(testMB, 1), 1024)
        let r = min(max(rounds, 1), 5)
        let t = min(max(maxSecondsPerRound, 5), 600)
        return """
        echo "BS_HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null)"
        echo "BS_UNAME=$(uname -srm 2>/dev/null)"
        command -v curl >/dev/null 2>&1 || { echo BS_NOCURL; exit 3; }
        bs_f=/tmp/boxsend-speed.$$
        dd if=/dev/zero of="$bs_f" bs=1048576 count=\(n) >/dev/null 2>&1 || { echo BS_ERR_TMP; rm -f "$bs_f"; exit 4; }
        bs_i=0
        while [ "$bs_i" -lt \(r) ]; do
          bs_i=$((bs_i + 1))
          curl -sS -o /dev/null -H 'Expect:' --data-binary "@$bs_f" --max-time \(t) \
        -w '%{speed_upload}\\n' \(quoted) 2>/dev/null || echo BS_ERR_UPLOAD
        done
        rm -f "$bs_f"
        """
    }

    // MARK: - 拼 ssh 参数

    /// 组装 ssh 命令行与环境变量（密码登录会留下临时 askpass 目录，调用方负责 cleanup）
    public static func launch(_ cfg: SSHConfig, script: String) throws -> Launch {
        guard cfg.isConfigured else { throw BoxSendError.badInput("SSH 没填服务器地址或用户名") }
        #if os(Windows)
        // Windows 自带的 OpenSSH 客户端不读 SSH_ASKPASS，密码只能用户自己敲，改成密钥登录
        if cfg.auth == .password {
            throw BoxSendError.badInput("Windows 上请用密钥登录（先在 C:\\Windows\\System32\\OpenSSH 下"
                + " ssh-keygen 生成密钥，再把公钥放到服务器 ~/.ssh/authorized_keys）")
        }
        #endif
        var args = [
            "-o", "BatchMode=" + (cfg.auth == .key ? "yes" : "no"),
            "-o", "PreferredAuthentications=" + (cfg.auth == .key ? "publickey" : "password,keyboard-interactive"),
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=\(cfg.resolvedTimeout)",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=4",
            "-p", String(cfg.resolvedPort),
        ]
        var env = ["LC_ALL": "C", "LANG": "C"]
        var tmp: URL?

        switch cfg.auth {
        case .key:
            let key = cfg.expandedKeyPath
            if !key.isEmpty {
                guard FileManager.default.fileExists(atPath: key) else {
                    throw BoxSendError.badInput("找不到私钥文件 \(key)")
                }
                args += ["-i", key, "-o", "IdentitiesOnly=yes"]
            }
        case .password:
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("boxsend-ssh-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            tmp = dir
            let passFile = dir.appendingPathComponent("pass")
            try Data((cfg.password + "\n").utf8).write(to: passFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passFile.path)
            let askpass = dir.appendingPathComponent("askpass.sh")
            try "#!/bin/sh\ncat \"$BS_SSH_PASSFILE\"\n".write(to: askpass, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
            // OpenSSH 8.4+ 用 SSH_ASKPASS_REQUIRE=force；更老的版本只在有 DISPLAY 时才肯用 askpass
            env["SSH_ASKPASS"] = askpass.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
            env["BS_SSH_PASSFILE"] = passFile.path
        }

        args += [cfg.loginTarget, script]
        return Launch(arguments: args, environment: env, temporaryDirectory: tmp)
    }

    // MARK: - 执行

    /// 真机执行：跑 /usr/bin/ssh，超时就终止并报错，返回 stdout+stderr 合流
    public static func execute(_ launch: Launch, timeout: TimeInterval) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw BoxSendError.badInput("系统里没有 \(sshPath)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sshPath)
        p.arguments = launch.arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in launch.environment { env[k] = v }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw BoxSendError.badInput("启动 ssh 失败：\(error.localizedDescription)")
        }

        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.value = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + max(timeout, 1)) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 3)
            throw BoxSendError.badInput("服务器没响应（\(Int(timeout)) 秒超时）")
        }
        p.waitUntilExit()
        let text = String(data: box.value, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw BoxSendError.badInput(failureReason(text) ?? "ssh 退出码 \(p.terminationStatus)")
        }
        return text
    }

    /// 批量转种前的测速：连上服务器，往公网推两轮测试数据，取峰值
    public static func runTest(_ cfg: SSHConfig, exec: Exec? = nil, rounds: Int = 2) throws -> Result {
        let probe = cfg.resolvedProbeURL
        // 单轮上限按「慢到 0.5 MB/s」估：真被限速到只剩一点时也要测得出来，
        // 宁可多等一会儿，也别把「慢」误报成「测速失败」
        let perRound = min(600, max(45, cfg.resolvedTestMB * 2 + 20))
        let script = speedScript(probeURL: probe, testMB: cfg.resolvedTestMB,
                                 rounds: rounds, maxSecondsPerRound: perRound)
        let launch = try launch(cfg, script: script)
        defer { launch.cleanup() }
        let run = exec ?? { try execute($0, timeout: $1) }
        let rounds_ = min(max(rounds, 1), 5)
        let out = try run(launch, Double(min(420, cfg.resolvedTimeout + perRound * rounds_ + 20)))
        let speeds = parseSpeedMBps(out).filter { $0 > 0 }
        // 有一轮测到数就用：curl 撞到 --max-time 时也会把已达成的速度打出来，
        // 那种「慢到传完前就超时」正是我们要抓的限速，不能只因为带了 BS_ERR_UPLOAD 就报失败
        guard let peak = speeds.max() else {
            if let why = markerFailure(out) { throw BoxSendError.badInput(why) }
            throw BoxSendError.badInput("测速没取到数据：" + String(out.prefix(160)))
        }
        return Result(peakMBps: peak, rounds: speeds, probeURL: probe, serverInfo: parseServerInfo(out))
    }

    /// 只做连通性验证：不传数据，能跑通 `true` 就算连上
    public static func checkConnection(_ cfg: SSHConfig, exec: Exec? = nil) throws -> String {
        let script = "echo BS_HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null); "
            + "echo BS_UNAME=$(uname -srm 2>/dev/null); echo BS_OK"
        let launch = try launch(cfg, script: script)
        defer { launch.cleanup() }
        let run = exec ?? { try execute($0, timeout: $1) }
        let out = try run(launch, Double(cfg.resolvedTimeout + 15))
        guard out.contains("BS_OK") else { throw BoxSendError.badInput("服务器返回异常：" + String(out.prefix(120))) }
        return parseServerInfo(out)
    }

    // MARK: - 解析

    /// curl 的 `%{speed_upload}` 行（字节/秒）-> MB/s；只认整行是一个数字的行
    public static func parseSpeedMBps(_ output: String) -> [Double] {
        var out: [Double] = []
        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil,
                  let bytes = Double(line) else { continue }
            out.append(bytes / 1_048_576)
        }
        return out
    }

    /// 测速脚本自己打点的失败标记 -> 人话。ssh 正常退出时只看这个：
    /// 输出里本来就有一行行的测速数字，不能拿「最后一行」当错误原因。
    public static func markerFailure(_ output: String) -> String? {
        if output.contains("BS_NOCURL") { return "服务器上没有 curl，测速用不了（装一个 curl 或改用别机）" }
        if output.contains("BS_ERR_TMP") { return "服务器上写不了 /tmp 临时文件，测速用不了" }
        if output.contains("BS_ERR_UPLOAD") { return "服务器上上传失败：测速地址不通或被防火墙挡了" }
        return nil
    }

    /// ssh 这一趟为什么没成：先看脚本标记，再看 ssh 自己的报错
    public static func failureReason(_ output: String) -> String? {
        if let m = markerFailure(output) { return m }
        let low = output.lowercased()
        let known: [(String, String)] = [
            ("permission denied", "登录被拒：用户名、私钥或密码不对"),
            ("too many authentication failures", "认证次数过多：密钥或密码不对"),
            ("host key verification failed", "known_hosts 里这台机器的 host key 变了"),
            ("no route to host", "地址不可达"),
            ("could not resolve hostname", "域名解析失败：地址填错了"),
            ("connection refused", "端口没有监听：SSH 没开或端口填错"),
            ("operation timed out", "连接超时：地址或防火墙问题"),
            ("connection closed by", "连接被服务器断开：多半认证没过"),
            ("broken pipe", "连接中断"),
        ]
        for (needle, msg) in known where low.contains(needle) { return msg }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "ssh 没有任何输出" }
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String((lines.last ?? "").prefix(160))
    }

    /// 从 BS_HOST / BS_UNAME 拼一句「主机名（系统）」
    public static func parseServerInfo(_ output: String) -> String {
        func value(_ key: String) -> String? {
            guard let r = output.range(of: key + "=") else { return nil }
            let rest = output[r.upperBound...]
            let line = rest.prefix { $0 != "\n" && $0 != "\r" }
            let v = line.trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        let host = value("BS_HOST")
        let uname = value("BS_UNAME")
        if let h = host, let u = uname { return "\(h)（\(u)）" }
        return host ?? uname ?? ""
    }

    /// 速度文案（63.42 -> "63.4"）
    public static func speedText(_ mbps: Double) -> String {
        String(format: mbps >= 10 ? "%.1f" : "%.2f", mbps)
    }
}

private final class OutputBox {
    var value = Data()
}
