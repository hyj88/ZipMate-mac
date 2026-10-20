import Foundation

// 命令行自测入口：swiftc 编译后以 `--selftest` 参数运行
let args = CommandLine.arguments
if args.contains("--selftest") {
    print(SelfTest.report())
    exit(0)
}
print("请以 GUI 模式启动：open ZipMate.app")
