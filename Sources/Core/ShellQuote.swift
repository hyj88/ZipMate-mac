import Foundation

enum ShellQuote {
    /// POSIX 单引号转义：安全包裹任意字符串
    static func q(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:@+,")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension ProcessRunner {

    /// 敏感值占位符：出现在参数列表中，由包装 shell 替换为环境变量引用
    static let secretToken = "__ZIPMATE_SECRET__"

    /// 已组装好的可执行命令
    struct Command {
        let executable: String
        let arguments: [String]
        let secret: String?
    }

    /// 生成「安全执行」的命令：
    /// argv 中只会出现 `$ZIPMATE_SECRET` 字面量，真实密码通过环境变量传递。
    /// 这样 `ps` / 活动监视器都看不到明文密码。
    static func secretSafeCommand(
        executable: String,
        arguments: [String],
        secret: String
    ) -> Command {
        var parts: [String] = ["exec " + ShellQuote.q(executable)]
        for a in arguments {
            if a == secretToken {
                parts.append("\"$" + secretEnvKey + "\"")
            } else {
                parts.append(ShellQuote.q(a))
            }
        }
        return Command(executable: ToolLocator.sh,
                       arguments: ["-c", parts.joined(separator: " ")],
                       secret: secret)
    }

    /// 普通（无密码）命令
    static func plainCommand(executable: String, arguments: [String]) -> Command {
        Command(executable: executable, arguments: arguments, secret: nil)
    }
}
