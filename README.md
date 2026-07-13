# 长篇工坊

长篇工坊是一个最低支持 iOS 16、面向中文长篇小说创作的本地 AI Agent 工具。它采用 SwiftUI + UIKit，直接访问用户自己的 OpenAI Chat Completions 兼容 HTTPS 接口，不建设账号或云端服务。

作品默认进入 Agent 对话：用户可以用多轮聊天确认设定，再让 Agent 调用规划、生成、审稿、修订、事实提取和质量门禁工具。原有编辑部式工作区保留为手动模式。AI 结果不会静默覆盖历史正文，也不承诺作品一定签约、上架或产生收入。

## 已实现

- 只填写作品名即可开始，题材、平台、卖点、主角和篇幅由 Agent 在对话中逐步确认
- 默认 Agent 对话与二级手动工作台；写作、规划、资料、质检四个原工作区完整保留
- 监督模式在方案、执行范围和章节定稿等里程碑确认
- Pass 模式按当前章、连续若干章或当前卷自动执行；质量门禁通过后才批准，到范围即停止
- Agent 任务、步骤、调用预算、审批和对话持久化；进入后台暂停，回到应用后从安全步骤恢复
- 严格 JSON 工具协议和工具白名单，不依赖服务商专有 Function Calling
- 作品库、TXT/Markdown 导入、`.novelproj` v1/v2 工程备份与恢复
- UIKit 长文本编辑器，中文输入、自动保存、查找替换、撤销重做、专注模式
- 故事圣经、卷纲、章卡、人物、世界规则、时间线、伏笔和连续性事实台账
- 多模型配置与策划、写作、审稿、改稿、记忆提取角色分工
- OpenAI Chat Completions 兼容普通请求和 SSE 流式请求
- 429/5xx 退避、请求取消、部分正文保留和达到输出上限后的重叠续写
- 创意三选一、故事圣经候选、卷纲候选、章纲二选一、章节生成
- 情节、连续性、文字、平台四类审稿，以及最近十章跨章回归审稿
- 本地字数、元话语、禁用词、异常标点、重复句/段和参考文本重合扫描
- 质量门禁、人工覆盖理由、候选事实冲突检查、批准后正式入账
- 段落级版本差异、整版采用、选段改写、生成记录和人工修改量记录
- 起点男频、番茄男频可编辑质量基线，明确标注为非官方规则
- 全局写作模板库与项目模板快照；模板修改不会影响已应用作品
- TXT/Markdown 长篇流式分析，支持 UTF-8/UTF-16，不将几百万字正文一次性加载进内存
- 小说关系索引包含章节统计、高频概念、跨章共现和结构证据；默认 AI 综合输入硬上限为 80,000 估算 Token
- 模板只保存抽象文风、结构、节奏、爽点、伏笔和钩子策略，不保存上传小说原文
- TXT、Markdown、当前章节与工程备份导出
- API Key 存储在 iOS Keychain，工程和日志均不包含密钥
- 正文独立文件懒加载；打开百万字工程时不会一次加载全部正文
- 受保护的持久化脱敏诊断和确定性运行自检，可导出 Markdown/JSON 报告
- 自检覆盖工程引用、备份编解码、Agent 恢复、Keychain、磁盘、文件保护、模型配置、模板索引和临时目录

## 技术结构

- `Sources/NovelCore`：跨平台数据模型、Agent 协议、流式长篇分析、仓库、上下文预算、提示词、质检和差异算法
- `App`：iOS 应用、Keychain、网络客户端、状态和 SwiftUI/UIKit 界面
- `Tests/NovelCoreTests`：可在 Windows/macOS 运行的核心测试
- `AppTests`、`AppUITests`：iOS 单元测试和模拟器 UI 截图测试
- `project.yml`：XcodeGen 工程定义，不提交生成的 `.xcodeproj`
- `.github/workflows`：固定 Xcode 的测试、未签名 IPA 和 TrollStore IPA 流水线

## 本地开发限制

Windows 不能运行 Apple 的 iOS Simulator。换成 Flutter 或 React Native 也不能改变这个限制，因为最终的 iOS 系统编译和模拟仍依赖 macOS/Xcode。

推荐工作方式：

1. 在 Windows 使用 VS Code 编辑代码。
2. 安装 Swift 6.1 后运行核心测试：

   ```powershell
   swift test --parallel
   ```

3. 推送到 GitHub，由 `macos-15` runner 使用固定 Xcode 16.4 完成 iOS 编译、单元测试、UI 测试和截图。
4. 下载 Actions artifact，在 iOS 16.6.1 真机安装验证。

当前工作区机器没有安装 Swift，因此本地无法实际运行 `swift test`；GitHub Actions 是本项目的编译验证来源。

## GitHub Actions

公开仓库推送后，`CI` 工作流运行：

- Linux Swift 6.2：`NovelCore` 第二平台测试
- macOS 15 + Xcode 16.4：`NovelCore`、iOS 单元测试和 UI 测试
- iPhone 模拟器截图附件
- 无 Apple 证书的 Debug device app 和 unsigned IPA
- 源码密钥、ATS 放行、证书文件审计

发布 tag，例如 `v0.2.0`，或手动运行 `Release IPA`，会得到：

- `LongformStudio-unsigned.ipa`：原始无 Apple 签名 IPA
- `LongformStudio-TrollStore.ipa`：固定 `ldid v2.1.5-procursus7` ad-hoc/fakesign 后的推荐安装包
- `SHA256SUMS.txt`：两个 IPA 的校验值

流水线固定并校验：

- XcodeGen `2.41.0`
- Xcode `16.4`
- ldid `v2.1.5-procursus7` macOS arm64

如果 GitHub runner 不再提供 Xcode 16.4，构建会明确失败，不会自动漂移到未经验证的版本。

## TrollStore 安装

你的 iOS 16.6.1 位于 TrollStore 官方支持范围内。优先安装 `LongformStudio-TrollStore.ipa`：

1. 从 GitHub Actions artifact 或 GitHub Release 下载 IPA。
2. 在系统分享菜单中选择 TrollStore，或从 TrollStore 打开 IPA。
3. 更新应用前先导出 `.novelproj` 备份。

应用使用普通沙箱，不申请私有 entitlement、root 权限或无沙箱能力。

## 模型接口

设置中添加模型配置：

- Endpoint：完整 HTTPS Chat Completions 地址，例如 `https://example.com/v1/chat/completions`
- Model：服务商要求的模型名
- Header：默认 `Authorization`
- Prefix：默认 `Bearer `
- API Key：仅存 Keychain
- 上下文、输出上限、temperature、超时和流式开关

当前版本支持 OpenAI Chat Completions 的基本请求形状：

```json
{
  "model": "model-name",
  "messages": [{"role": "user", "content": "..."}],
  "temperature": 0.8,
  "max_tokens": 4096,
  "stream": true
}
```

应用拒绝 HTTP endpoint，未配置全局 ATS 例外。专有 Responses API、特殊鉴权签名或非兼容返回格式需要新增适配器。

## 数据与隐私

- 工程位于应用的 Application Support 目录。
- 每个章节、版本和正文使用独立文件；正文按需加载。
- 自动保存使用原子写入，并为工程文件应用 iOS Data Protection。
- `.novelproj` 包含规划、正文版本、审稿、事实、Agent 对话/任务记录和项目模板快照，但不包含 API Key。
- 长篇分析正文只存在于受保护的临时任务目录，完成或取消后删除；全局索引和模板不保存整书原文。
- 诊断日志会删除认证 header、API Key 和长文本，不上传任何服务器。
- iCloud/CloudKit、团队同步、账号计费、应用退出后的云端持续生成和自动投稿不在当前范围内。

## Agent 边界

- 监督模式自动执行中间步骤，但作品方案、执行范围和章节定稿需要确认。
- Pass 模式不使用人工覆盖理由绕过质量门禁，每章最多自动修订两轮。
- 候选事实与正式台账冲突、模型连续失败、JSON 两次无法解析或达到调用预算时，Agent 会暂停请求决定。
- Pass 不自动删除工程、覆盖历史版本、导出投稿或扩大用户已确认的章节范围。
- iOS 不允许应用退出后无限运行生成请求；进入后台会取消当前请求并持久化安全恢复位置。

## 质量边界

“生产级”在此项目中表示流程可控、连续性可追踪、问题可审查、版本可恢复，并不表示 AI 可以独立保证商业成功。

自动批准要求：

- 情节、连续性、文字、平台四类审稿全部完成
- 综合分至少 85
- 每个配置维度至少 75
- 没有未解决的 high/critical 问题
- 本地扫描没有 high/critical 问题

人工可以覆盖门禁，但必须填写原因，原因会写入版本记录。投稿前仍需人工定稿并核对平台当时的规则、AI 内容标识要求和权利归属。

Pass 模式不会调用人工覆盖。存在事实冲突或质量阻断时必须暂停处理。

## 真机验收

首次 Release 前按 [真机验收清单](Docs/DEVICE_ACCEPTANCE.md) 在 iOS 16.6.1 上完整执行。模拟器不能替代中文输入法、Files、前后台中断、TrollStore 安装和真实网络环境验证。
