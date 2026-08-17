# Progress

- 目标：发布 CCS 0.6.4，修复 OpenAI 首次登录引导和损坏凭据恢复，并增加无敏感信息的 Codex 诊断命令。
- 1. `ccs codex use openai` 现在区分 `missing` 与 `invalid`，缺少官方 CLI 时给出 `brew install codex`，并始终给出 `ccs codex login`。
- 2. `ccs codex list` 与 `show` 统一报告 `missing`、`invalid`、`chatgpt` 和 `apikey`，空文件不会再显示为已保存认证。
- 3. `ccs codex login` 在任何迁移写入前检查 Codex CLI，并能以事务和退出 trap 恢复文件、目录或损坏 JSON 形态的认证路径。
- 4. 原生登录取消或写入半截认证后，现有全局认证、OpenAI 快照、活动配置和 current 链接均会回滚。
- 5. 新增只读 `ccs codex doctor`，报告依赖路径、活动 provider、认证状态和迁移状态，不显示 API key 或 OAuth token，也不会初始化 `~/.codex`。
- 6. 健康的第三方 provider 保持独立，不会被 doctor 建议切换到 OpenAI；认证 ready 但迁移 pending 时会明确建议运行 `ccs codex list`。
- 7. 五组隔离测试、Bash 语法、定向 ShellCheck 与 `git diff --check` 全部通过。
- 8. 独立只读发布审查发现并复核了目录形态凭据恢复与 pending migration 建议两个边界问题，修复后的成功、失败和无残留路径均已验证。
- 验证边界：本次没有重新触发真实账号的浏览器 OAuth；官方 Codex CLI 委托接口保持不变，登录成功与失败由隔离 fixture 覆盖。
