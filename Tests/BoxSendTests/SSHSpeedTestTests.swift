import XCTest
@testable import BoxSendKit

/// 转种服务器 SSH 测速：脚本形状、ssh 参数、curl 输出解析，以及配置读写
final class SSHSpeedTestTests: XCTestCase {
    private var keyPath: String!

    override func setUpWithError() throws {
        keyPath = NSTemporaryDirectory() + "boxsend-test-key-\(UUID().uuidString)"
        try Data("k".utf8).write(to: URL(fileURLWithPath: keyPath))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: keyPath)
        super.tearDown()
    }

    /// Windows 自带的 OpenSSH 客户端不读 `SSH_ASKPASS`，核心在 Windows 上直接拒绝密码登录。
    /// 这三条验的是 askpass 那条路，Windows 上改成验「拒得干脆」然后跳过。
    private func requireAskPassSupport() throws {
        #if os(Windows)
        XCTAssertThrowsError(try SSHSpeedTest.launch(config(auth: .password), script: "x")) {
            XCTAssertTrue($0.localizedDescription.contains("密钥登录"), $0.localizedDescription)
        }
        throw XCTSkip("Windows 上密码登录由核心直接拒绝（系统 OpenSSH 不读 SSH_ASKPASS）")
        #else
        return
        #endif
    }

    /// 桩 ssh 是个 /bin/sh 脚本，Windows 上没有能直接执行的 sh，这几条只在类 UNIX 上跑；
    /// Windows 侧另有一条用真 ssh 的用例覆盖「起进程 + 报错成人话」
    private func requireShellStub() throws {
        #if os(Windows)
        throw XCTSkip("桩 ssh 是 sh 脚本，Windows 上起不来")
        #else
        return
        #endif
    }

    private func config(auth: SSHConfig.Auth = .key, key: String? = nil) -> SSHConfig {
        var c = SSHConfig(host: "10.0.0.5", port: 22022, user: "seed", auth: auth,
                          keyPath: key ?? keyPath!, password: "sekr3t")
        c.enabled = true
        return c
    }

    // MARK: - 输出解析

    func testParsesCurlSpeedLines() {
        let out = """
        Warning: Permanently added '10.0.0.5' (ED25519) to the list of known hosts.
        BS_HOST=vps-2 (Linux 6.1 x86_64)
        BS_UNAME=Linux 6.1.0 x86_64
        20971520
        25165824
        """
        let speeds = SSHSpeedTest.parseSpeedMBps(out)
        XCTAssertEqual(speeds.count, 2)
        XCTAssertEqual(speeds[0], 20, accuracy: 0.001)
        XCTAssertEqual(speeds[1], 24, accuracy: 0.001)
    }

    func testIgnoresNoiseLines() {
        let out = """
        BS_HOST=vps
        curl: (28) Operation timed out
        0
        BS_ERR_UPLOAD
        1024
        """
        XCTAssertEqual(SSHSpeedTest.parseSpeedMBps(out).count, 2)   // 0 也算一行，由调用方滤掉
        XCTAssertEqual(SSHSpeedTest.parseSpeedMBps(out)[1], 0.0009765625, accuracy: 0.0001)
    }

    func testServerInfoFromMarkerLines() {
        let out = "BS_HOST=vps-2\nBS_UNAME=Linux 6.1.0 x86_64\n20971520\n"
        XCTAssertEqual(SSHSpeedTest.parseServerInfo(out), "vps-2（Linux 6.1.0 x86_64）")
        XCTAssertEqual(SSHSpeedTest.parseServerInfo("BS_HOST=vps-2\n"), "vps-2")
        XCTAssertEqual(SSHSpeedTest.parseServerInfo("nothing here"), "")
    }

    /// 不设判定线：结果只负责把每一轮的速度摆出来，转不转由人看
    func testResultTextSummarisesEveryRound() {
        let r = SSHSpeedTest.Result(peakMBps: 19.4, rounds: [18.1, 19.4],
                                    probeURL: SSHConfig.defaultProbeURL, serverInfo: "vps-1")
        XCTAssertEqual(r.roundsText, "18.1、19.4")
        XCTAssertTrue(r.summaryLine.contains("上传速度 19.4 MB/s"))
        XCTAssertTrue(r.summaryLine.contains("18.1、19.4"))
        XCTAssertTrue(r.summaryLine.contains("vps-1"))
    }

    // MARK: - 远程脚本

    func testSpeedScriptShape() {
        let script = SSHSpeedTest.speedScript(probeURL: "https://example.com/up", testMB: 32, rounds: 3,
                                              maxSecondsPerRound: 90)
        XCTAssertTrue(script.contains("BS_HOST="))
        XCTAssertTrue(script.contains("command -v curl"))
        XCTAssertTrue(script.contains("dd if=/dev/zero"))
        XCTAssertTrue(script.contains("bs=1048576 count=32"))
        XCTAssertTrue(script.contains("-lt 3"))
        XCTAssertTrue(script.contains("--max-time 90"))
        XCTAssertTrue(script.contains("%{speed_upload}"))
        XCTAssertTrue(script.contains("'https://example.com/up'"))
        XCTAssertTrue(script.contains("rm -f \"$bs_f\""))     // 测完删临时文件，不在服务器上留一堆垃圾
    }

    func testSpeedScriptQuotesOddURL() {
        let script = SSHSpeedTest.speedScript(probeURL: "https://x/up?a='b", testMB: 8)
        XCTAssertTrue(script.contains(#"'https://x/up?a='\''b'"#))
    }

    // MARK: - ssh 参数

    func testKeyAuthLaunch() throws {
        let launch = try SSHSpeedTest.launch(config(), script: "echo hi")
        XCTAssertTrue(launch.arguments.contains("BatchMode=yes"))
        XCTAssertTrue(launch.arguments.contains { $0.hasPrefix("PreferredAuthentications=publickey") })
        XCTAssertTrue(launch.arguments.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertEqual(launch.arguments[safeIndex: launch.arguments.firstIndex(of: "-p")! + 1], "22022")
        XCTAssertTrue(launch.arguments.contains("-i"))
        XCTAssertTrue(launch.arguments.contains(keyPath!))
        XCTAssertEqual(launch.arguments.last, "echo hi")
        XCTAssertTrue(launch.arguments.contains("seed@10.0.0.5"))
        XCTAssertNil(launch.temporaryDirectory)
    }

    /// ssh 客户端只认 ssh_config 里的键：传了 sshd 专用的（MaxAuthTries）会整条命令直接失败
    func testOnlyClientSideSSHOptionsArePassed() throws {
        try requireAskPassSupport()
        for cfg in [config(), config(auth: .password)] {
            let launch = try SSHSpeedTest.launch(cfg, script: "x")
            for bad in ["MaxAuthTries", "LoginGraceTime", "PermitRootLogin"] {
                XCTAssertFalse(launch.arguments.contains { $0.hasPrefix(bad + "=") }, bad)
            }
            XCTAssertTrue(launch.arguments.contains("NumberOfPasswordPrompts=1"))
        }
    }

    func testMissingKeyFileFailsBeforeSpawningSSH() {
        XCTAssertThrowsError(try SSHSpeedTest.launch(config(key: "/nonexistent/id_ed25519"), script: "x")) { e in
            XCTAssertTrue(e.localizedDescription.contains("私钥"))
        }
    }

    func testPasswordAuthUsesAskPassAndKeepsSecretOutOfArgv() throws {
        try requireAskPassSupport()
        let launch = try SSHSpeedTest.launch(config(auth: .password), script: "echo hi")
        XCTAssertTrue(launch.arguments.contains("BatchMode=no"))
        XCTAssertFalse(launch.arguments.contains(where: { $0.contains("sekr3t") }))   // 密码不进命令行
        XCTAssertEqual(launch.environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertTrue((launch.environment["SSH_ASKPASS"] ?? "").hasSuffix("askpass.sh"))
        let dir = try XCTUnwrap(launch.temporaryDirectory)
        defer { launch.cleanup() }
        let written = try String(contentsOf: dir.appendingPathComponent("pass"), encoding: .utf8)
        XCTAssertEqual(written, "sekr3t\n")
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("pass").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int32Value, 0o600)
        XCTAssertTrue(launch.environment.keys.contains("BS_SSH_PASSFILE"))
    }

    func testPasswordAskPassFileIsRemovedAfterCleanup() throws {
        try requireAskPassSupport()
        let launch = try SSHSpeedTest.launch(config(auth: .password), script: "x")
        let dir = try XCTUnwrap(launch.temporaryDirectory)
        launch.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testIncompleteConfigIsRejected() {
        XCTAssertThrowsError(try SSHSpeedTest.launch(SSHConfig(host: "", user: ""), script: "x"))
    }

    // MARK: - 测速流程（桩执行）

    /// 服务器端像样地跑完：两轮 20 / 24 MB/s
    func testRunTestTakesPeakRound() throws {
        var seen: SSHSpeedTest.Launch?
        let stub: SSHSpeedTest.Exec = { launch, _ in
            seen = launch
            return "BS_HOST=vps-9\nBS_UNAME=Linux 6.6 x86_64\n20971520\n25165824\n"
        }
        let r = try SSHSpeedTest.runTest(config(), exec: stub)
        XCTAssertEqual(r.peakMBps, 24, accuracy: 0.001)
        XCTAssertEqual(r.rounds.count, 2)
        XCTAssertEqual(r.serverInfo, "vps-9（Linux 6.6 x86_64）")
        XCTAssertEqual(r.roundsText, "20.0、24.0")
        XCTAssertEqual(seen?.arguments.last?.contains("--data-binary"), true)
    }

    func testThrottledServerIsFlagged() throws {
        let stub: SSHSpeedTest.Exec = { _, _ in "BS_HOST=vps\n6291456\n6291456\n" }   // 6 MB/s
        let r = try SSHSpeedTest.runTest(config(), exec: stub)
        XCTAssertEqual(r.peakMBps, 6, accuracy: 0.001)
    }

    func testMissingCurlOnServerBecomesReadableError() {
        let stub: SSHSpeedTest.Exec = { _, _ in "BS_HOST=vps\nBS_NOCURL\n" }
        XCTAssertThrowsError(try SSHSpeedTest.runTest(config(), exec: stub)) { e in
            XCTAssertTrue(e.localizedDescription.contains("curl"), e.localizedDescription)
        }
    }

    func testUploadFailureBecomesReadableError() {
        let stub: SSHSpeedTest.Exec = { _, _ in "BS_HOST=vps\nBS_ERR_UPLOAD\n" }
        XCTAssertThrowsError(try SSHSpeedTest.runTest(config(), exec: stub)) { e in
            XCTAssertTrue(e.localizedDescription.contains("上传失败"), e.localizedDescription)
        }
    }

    /// 慢到一轮没传完就被 curl 掐掉：已经有速度数字，就不能算「测速失败」
    func testPartialRoundStillCountsAsMeasured() throws {
        let stub: SSHSpeedTest.Exec = { _, _ in "BS_HOST=vps\n3145728\nBS_ERR_UPLOAD\n" }   // 3 MB/s + 一轮超时
        let r = try SSHSpeedTest.runTest(config(), exec: stub)
        XCTAssertEqual(r.peakMBps, 3, accuracy: 0.001)
        XCTAssertEqual(r.rounds.count, 1)   // 超时那轮没数字，只剩测到的一轮
    }

    func testNoSpeedDataIsAnError() {
        let stub: SSHSpeedTest.Exec = { _, _ in "BS_HOST=vps\n0\n" }
        XCTAssertThrowsError(try SSHSpeedTest.runTest(config(), exec: stub))
    }

    func testSSHFailureStringsMapped() {
        let cases: [(String, String)] = [
            ("seed@10.0.0.5: Permission denied (publickey).", "登录被拒"),
            ("ssh: connect to host 10.0.0.5 port 22: Connection refused", "端口没有监听"),
            ("ssh: Could not resolve hostname vps: nodename nor servname", "域名解析失败"),
            ("ssh: connect to host 10.0.0.5 port 22: Operation timed out", "连接超时"),
            ("Unable to negotiate with 10.0.0.5: no matching host key type", "host key"),
        ]
        for (out, needle) in cases {
            let reason = SSHSpeedTest.failureReason(out) ?? ""
            XCTAssertTrue(reason.contains(needle), "\(out) -> \(reason)")
        }
        // ssh 正常退出时输出里本来就有一行行测速数字，只能按脚本标记判失败
        XCTAssertNil(SSHSpeedTest.markerFailure("BS_HOST=vps\n20971520\n"))
        XCTAssertTrue((SSHSpeedTest.failureReason("") ?? "").contains("没有任何输出"))
    }

    // MARK: - 真起进程（桩 ssh）

    /// 造一个假 ssh：吃掉所有参数，只扮演服务器把预先准备好的输出吐出来
    private func stubSSH(body: String, status: Int32 = 0) throws -> String {
        let dir = NSTemporaryDirectory() + "bs-stub-ssh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bodyPath = dir + "/out"
        try body.write(toFile: bodyPath, atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        cat '\(bodyPath)'
        exit \(status)
        """
        let path = dir + "/ssh"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    func testRunTestThroughRealProcess() throws {
        try requireShellStub()
        let saved = SSHSpeedTest.sshPath
        SSHSpeedTest.sshPath = try stubSSH(body: "BS_HOST=stub-vps\nBS_UNAME=Linux 6.6 x86_64\n20971520\n26214400\n")
        defer { SSHSpeedTest.sshPath = saved }
        let r = try SSHSpeedTest.runTest(config())
        XCTAssertEqual(r.peakMBps, 25, accuracy: 0.001)
        XCTAssertTrue(r.serverInfo.hasPrefix("stub-vps（Linux 6.6 x86_64）"))
        XCTAssertEqual(r.roundsText, "20.0、25.0")
    }

    func testSSHExitCodeBecomesReadableErrorThroughRealProcess() throws {
        try requireShellStub()
        let saved = SSHSpeedTest.sshPath
        SSHSpeedTest.sshPath = try stubSSH(body: "seed@10.0.0.5: Permission denied (publickey).\n", status: 255)
        defer { SSHSpeedTest.sshPath = saved }
        XCTAssertThrowsError(try SSHSpeedTest.runTest(config())) { e in
            XCTAssertTrue(e.localizedDescription.contains("\u{767B}\u{5F55}\u{88AB}\u{62D2}"), e.localizedDescription)
        }
    }

    func testCheckConnectionOnlyNeedsTheOKMarker() throws {
        try requireShellStub()
        let saved = SSHSpeedTest.sshPath
        SSHSpeedTest.sshPath = try stubSSH(body: "BS_HOST=stub-vps\nBS_UNAME=Linux 6.6 x86_64\nBS_OK\n")
        defer { SSHSpeedTest.sshPath = saved }
        XCTAssertTrue(try SSHSpeedTest.checkConnection(config()).hasPrefix("stub-vps"))
    }

    /// Windows 覆盖：拿系统自带的真 ssh 连一个必然没人监听的端口，
    /// 把「起进程、合流收输出、把 ssh 的抱怨翻成人话」这段在 Windows 上真跑一遍
    func testRealSSHClientReportsRefusedPort() throws {
        #if os(Windows)
        guard FileManager.default.isExecutableFile(atPath: Platform.defaultSSHPath) else {
            throw XCTSkip("这台机器上没有系统 OpenSSH 客户端")
        }
        let saved = SSHSpeedTest.sshPath
        SSHSpeedTest.sshPath = Platform.defaultSSHPath
        defer { SSHSpeedTest.sshPath = saved }
        var cfg = SSHConfig(host: "127.0.0.1", port: 1, user: "nobody")
        cfg.timeoutSeconds = 5
        cfg.keyPath = ""   // 空 = 让 ssh 自己挑密钥：CI 机器上可不一定有 ~/.ssh/id_ed25519
        XCTAssertThrowsError(try SSHSpeedTest.checkConnection(cfg)) { e in
            // 通常是「端口没有监听：SSH 没开或端口填错」；万一机器上有别的东西占着 1 端口，
            // 也会翻成认证/超时那类人话，不该是「测速没取到数据」这种没头没尾的
            let why = e.localizedDescription
            XCTAssertTrue(["端口", "超时", "不可达", "认证", "断开", "登录被拒"]
                              .contains(where: { why.contains($0) }), why)
        }
        #else
        throw XCTSkip("mac / Linux 侧由 sh 桩覆盖")
        #endif
    }

    // MARK: - 配置读写

    func testOldConfigWithoutSSHStillDecodes() throws {
        let cfg = try roundTrip(AppConfig.template())
        XCTAssertNil(cfg.ssh)
    }

    func testSSHSectionRoundTrips() throws {
        var c = AppConfig.template()
        var s = SSHConfig(host: "vps.example.com", port: 2222, user: "ubuntu", auth: .password)
        s.enabled = true
        s.testMB = 128
        c.ssh = s
        let back = try roundTrip(c)
        XCTAssertEqual(back.ssh, s)
        XCTAssertTrue(back.ssh?.precheckActive == true)
    }

    /// 手改过的配置只写了几个字段时，其余走默认值，不能整份配置读不出来
    func testPartialSSHSectionFallsBackToDefaults() throws {
        let data = try JSONEncoder().encode(AppConfig.template())
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["ssh"] = ["host": "1.2.3.4", "user": "root", "auth": "password"]
        let decoded = try JSONDecoder().decode(AppConfig.self, from: try JSONSerialization.data(withJSONObject: obj))
        var s = try XCTUnwrap(decoded.ssh)
        XCTAssertEqual(s.host, "1.2.3.4")
        XCTAssertEqual(s.auth, .password)
        XCTAssertEqual(s.port, 22)
        XCTAssertEqual(s.testMB, 64)
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(s.precheckActive)
        s.enabled = true
        XCTAssertTrue(s.precheckActive)
    }

    /// 只勾了开关但没填地址：不算配好，界面上的测速按钮该灰
    func testEnabledButUnconfiguredDoesNotPrecheck() {
        var s = SSHConfig()
        s.enabled = true
        XCTAssertFalse(s.isConfigured)
        XCTAssertFalse(s.precheckActive)
    }

    func testWildValuesAreClamped() {
        var s = SSHConfig(host: "h", port: 0, user: "u", testMB: 0, timeoutSeconds: 999)
        XCTAssertEqual(s.resolvedPort, 22)
        XCTAssertEqual(s.resolvedTestMB, 4)
        XCTAssertEqual(s.resolvedTimeout, 60)
        s.probeURL = "   "
        XCTAssertEqual(s.resolvedProbeURL, SSHConfig.defaultProbeURL)
        XCTAssertEqual(SSHConfig(host: "h", port: 99999, user: "u").resolvedPort, 22)
    }
    private func roundTrip(_ cfg: AppConfig) throws -> AppConfig {
        let data = try JSONEncoder().encode(cfg)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }
}

private extension Array {
    subscript(safeIndex i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
