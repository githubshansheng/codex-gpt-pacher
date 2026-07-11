# Codex Desktop GPT-5.6 Patcher

让 Codex Desktop / ChatGPT Desktop 在第三方 `Responses API` 下显示 GPT-5.6 Sol、Terra、Luna，并解锁 `max` / `ultra` 推理等级的跨平台本地补丁工具。

> 非官方项目。它基于你本机已安装的官方 Desktop 创建补丁副本或本机签名更新包，不下载第三方可执行文件，不读取、复制、打印或内嵌 API Key。

默认第三方中转站：

```text
https://ai.heigh.vip/v1
```

不想使用默认中转站时，可以在向导中填写自己的地址，或使用 `--base-url` 参数覆盖。脚本本身不会主动向该地址发送请求，真正的模型请求发生在你启动 Codex 并使用对应 provider 之后。

## 目录

- [功能亮点](#功能亮点)
- [快速开始](#快速开始)
- [运行模式](#运行模式)
- [新手向导会做什么](#新手向导会做什么)
- [自定义安装目录和多个分身](#自定义安装目录和多个分身)
- [第三方 API 配置](#第三方-api-配置)
- [常用命令](#常用命令)
- [Windows Store / MSIX 说明](#windows-store--msix-说明)
- [回滚](#回滚)
- [实现原理](#实现原理)
- [常见问题](#常见问题)
- [安全边界](#安全边界)
- [文件说明](#文件说明)
- [开发和验证](#开发和验证)
- [许可证](#许可证)

## 功能亮点

- 跨平台：支持 Windows、macOS、Linux。
- 新手友好：无参数运行会进入交互式向导，不需要记住一长串命令参数。
- 可指定安装目录：自动识别失败时，可以手动输入应用目录、`.app`、AppImage、可执行文件或 `app.asar`。
- 默认创建补丁副本：普通安装不会直接覆盖官方安装目录。
- Windows Store 兼容：MSIX 版本可选择重打包替换原安装身份，也可选择创建独立补丁分身。
- 支持多个 Codex 分身：通过不同 `--output` 路径创建多个补丁应用，适合区分工作、个人或不同 provider。
- 备份和验证：写入前保留备份，补丁后校验 `app.asar` 和 model catalog，失败时尽量自动恢复。
- 无 Python 也能用：会退回 Node.js 配置模式，至少完成模型目录和 provider 配置。

## 快速开始

先关闭正在运行的 Codex Desktop / ChatGPT Desktop，再运行下面的入口。

### Windows

下载或克隆仓库后，双击：

```text
patch-windows.cmd
```

也可以在命令行运行：

```powershell
cd C:\path\to\codex-gpt56-patcher
.\patch-windows.cmd
```

如果安装的是 Windows Store / MSIX 版本，向导会询问：

- 是否重打包并替换原安装身份。
- 如果不替换，是否创建独立补丁分身，并显示新的安装路径。

### macOS

如果是从浏览器下载的压缩包，首次运行建议先清除 quarantine 标记：

```bash
cd "/path/to/codex-gpt56-patcher"
xattr -dr com.apple.quarantine .
chmod +x patch-macos.command
./patch-macos.command
```

也可以在 Finder 中双击 `patch-macos.command`。

### Linux

```bash
cd "/path/to/codex-gpt56-patcher"
chmod +x patch-linux.sh
./patch-linux.sh
```

### 获取项目

使用 Git：

```bash
git clone https://github.com/githubshansheng/codex-gpt-pacher.git
cd codex-gpt-pacher
```

已经配置 GitHub SSH Key 的用户也可以使用 `git@github.com:githubshansheng/codex-gpt-pacher.git`。不会使用 Git 的用户可以直接下载仓库压缩包，解压后运行对应系统入口。

## 运行模式

| 模式 | 环境要求 | 修改 Desktop 前端 | 更新 model catalog | 更新 `config.toml` | 能否解决“自定义 / Custom”显示 |
| --- | --- | --- | --- | --- | --- |
| 完整补丁模式 | Python 3.10+、Node.js 20+、npm/npx | 是 | 是 | 按需 | 是 |
| 配置模式 | Node.js 20+ | 否 | 是 | 按需 | 不一定 |

完整补丁模式会复制或重打包 Desktop，并修改复制版中的 `app.asar`。配置模式只修改本机 Codex 配置和模型目录，如果 Desktop 仍受账号白名单限制，界面可能仍显示“自定义 / Custom”。

入口脚本的默认策略：

- 找到 Python 时，运行完整补丁向导。
- 找不到 Python 但找到 Node.js 时，运行配置模式向导。
- 两者都没有时，提示安装依赖。

## 新手向导会做什么

无参数运行 `patch-windows.cmd`、`patch-macos.command` 或 `patch-linux.sh` 时，会进入向导。

向导会依次确认：

- 是否执行完整 Desktop 补丁，还是只更新模型配置。
- 自动识别到的 Codex / ChatGPT 安装目录是否正确。
- 自动识别失败时，手动输入安装目录、`.app`、AppImage、可执行文件或 `app.asar`。
- 补丁副本输出目录，默认路径是否可接受。
- 是否使用默认中转站 `https://ai.heigh.vip/v1`。
- 是否写入或更新 `custom` provider。
- Windows Store / MSIX 场景下，是否替换原安装身份。

已经熟悉命令行的用户仍可直接传参。只要传入任意参数，系统入口会按自动化方式运行：

```bash
python3 patch_codex_gpt56.py --app "/path/to/Codex.app" --output "/custom/path/Codex-GPT56-Patched.app" --yes
```

## 自定义安装目录和多个分身

普通安装默认创建独立补丁副本：

| 系统 | 默认补丁副本路径 |
| --- | --- |
| Windows | `%USERPROFILE%\Applications\Codex-GPT56-Patched` |
| macOS | `~/Applications/Codex-GPT56-Patched.app` |
| Linux | `~/.local/opt/codex-gpt56-patched` |

自动识别安装目录不正确时，用 `--app` 指定来源：

```bash
python3 patch_codex_gpt56.py --app "/path/to/Codex.app" --yes
```

想把补丁副本放到自定义位置，用 `--output`：

```bash
python3 patch_codex_gpt56.py --output "/path/to/Codex-Work.app" --yes
```

你可以重复运行并指定不同输出路径，创建多个 Codex 分身：

```bash
python3 patch_codex_gpt56.py --output "$HOME/Applications/Codex-Work.app" --yes
python3 patch_codex_gpt56.py --output "$HOME/Applications/Codex-Personal.app" --yes
```

这提供了“一台机器多个 Codex 应用入口”的基础。若要让不同分身使用不同账号或配置，通常还需要配合独立的 `CODEX_HOME`、系统用户、快捷方式环境变量或应用数据目录；本工具不会自动迁移 Cookie、登录态或密钥。

## 第三方 API 配置

本工具默认准备 `custom` provider，并写入：

```toml
model_provider = "custom"
model = "gpt-5.6-sol"
review_model = "gpt-5.6-sol"
model_catalog_json = "C:/Users/your-name/.codex/model_catalog.json"

[model_providers.custom]
name = "custom"
base_url = "https://ai.heigh.vip/v1"
wire_api = "responses"
env_key = "CODEX_CUSTOM_API_KEY"
```

API Key 仍由你自己放在环境变量中。

Windows 用户级环境变量示例：

```powershell
[Environment]::SetEnvironmentVariable(
  "CODEX_CUSTOM_API_KEY",
  "你的 API Key",
  "User"
)
```

macOS / Linux 示例：

```bash
export CODEX_CUSTOM_API_KEY="你的 API Key"
```

环境变量变更后，需要完全退出并重新启动 Desktop。

默认添加的模型层级：

| 层级 | 模型 ID | 显示名称 |
| --- | --- | --- |
| `sol` | `gpt-5.6-sol` | GPT-5.6 Sol |
| `terra` | `gpt-5.6-terra` | GPT-5.6 Terra |
| `luna` | `gpt-5.6-luna` | GPT-5.6 Luna |

默认推理等级：

```text
low / medium / high / xhigh / max / ultra
```

`max` 和 `ultra` 是否真的可用，最终由第三方接口决定。若服务商不支持 `ultra`，运行时使用 `--disable-ultra` 隐藏它。

## 常用命令

启动新手向导：

```bash
python3 patch_codex_gpt56.py --guided
```

预览识别结果，不写文件：

```bash
python3 patch_codex_gpt56.py --dry-run --yes
```

指定官方来源应用：

```bash
python3 patch_codex_gpt56.py --app "/path/to/Codex.app" --yes
```

指定补丁输出目录：

```bash
python3 patch_codex_gpt56.py --output "/custom/path/Codex-GPT56-Patched.app" --yes
```

指定中转地址：

```bash
python3 patch_codex_gpt56.py --base-url "https://your-api.example/v1" --yes
```

只更新模型配置：

```bash
python3 patch_codex_gpt56.py --catalog-only --yes
```

无 Python 时使用 Node.js 配置助手：

```bash
node configure_codex_gpt56.mjs --yes
```

只修改 Desktop 代码：

```bash
python3 patch_codex_gpt56.py --desktop-only --yes
```

设置默认模型：

```bash
python3 patch_codex_gpt56.py --default-model sol --yes
```

可选值：

```text
keep / sol / terra / luna
```

只添加指定层级：

```bash
python3 patch_codex_gpt56.py --tiers sol,terra --yes
```

指定 model catalog：

```bash
python3 patch_codex_gpt56.py --catalog ~/.codex/my-model-catalog.json --yes
```

隐藏 Ultra：

```bash
python3 patch_codex_gpt56.py --disable-ultra --yes
```

验证已有补丁：

```bash
python3 patch_codex_gpt56.py --verify-only --app "/path/to/Codex.app" --tiers sol,terra,luna
```

运行脚本自测：

```bash
python3 patch_codex_gpt56.py --self-test
node configure_codex_gpt56.mjs --self-test
```

## Windows Store / MSIX 说明

Windows Store 安装目录位于 `WindowsApps`，受 AppX 部署服务保护，管理员也不适合直接覆盖其中的 `app.asar`。

双击 `patch-windows.cmd` 且未传入 `--output` 时，向导会让你选择：

| 选择 | 行为 | 适合场景 |
| --- | --- | --- |
| 替换原安装身份 | 从当前 Store 包生成本机签名 MSIX 更新包，保留 `OpenAI.Codex_2p2nqsd0c76g0!App` 启动身份 | 希望开始菜单、任务栏固定项继续指向同一个应用 |
| 不替换 | 创建独立补丁分身，并显示新的安装路径 | 希望保留官方 Store 应用不动 |

同身份更新流程会：

- 复制当前 Store 包到临时构建目录。
- 补丁构建目录中的 `app.asar`。
- 复用或创建当前用户的本地代码签名证书。
- 临时允许本地签名更新包部署，部署完成后恢复系统设置。
- 校验已部署包版本和 `app.asar` 的 SHA256。
- 保留可回退记录。

生成的包和部署记录通常位于：

```text
<磁盘>:\CodexGPT56Patcher\packages
%USERPROFILE%\.codex\backups\codex-gpt56\store-packages
```

如果你明确不想走 Store 同身份更新流程，使用 `--output` 创建独立分身。

## 回滚

配置文件备份位于 `~/.codex`：

```text
config.toml.backup-YYYYMMDD-HHMMSS
model_catalog.json.backup-YYYYMMDD-HHMMSS
```

完全退出 Codex Desktop 后，用最近的备份覆盖当前文件即可。

补丁副本会保留原始 ASAR：

```text
resources/app.asar.original
resources/app.asar.backup-YYYYMMDD-HHMMSS
```

需要恢复时，把 `resources/app.asar.original` 复制回 `resources/app.asar`。macOS 补丁副本恢复后需要重新执行本地签名：

```bash
codesign --force --deep --sign - ~/Applications/Codex-GPT56-Patched.app
xattr -cr ~/Applications/Codex-GPT56-Patched.app
```

Windows Store / MSIX 可通过 Windows“设置 -> 应用 -> Codex -> 高级选项 -> 修复/重置”，或从 Microsoft Store 重新安装来恢复官方签名包。MSIX 修复、更新或重新安装会恢复官方文件，也会移除补丁。

AppImage 来源不会覆盖原始 `Codex.AppImage`。可删除补丁目录 `~/.local/opt/codex-gpt56-patched` 或你指定的 `--output` 目录，再重新生成。

## 实现原理

Codex Desktop 的模型下拉不是直接展示 `config.toml` 或 model catalog 中的全部模型。Desktop 会先调用：

```text
list-models-for-host
app-server model/list
```

随后根据账号动态配置执行过滤：

- 使用 `available_models` 白名单过滤模型。
- 使用 `enabledReasoningEfforts` 过滤推理强度。

因此只修改：

```toml
model = "gpt-5.6-sol"
model_catalog_json = "model_catalog.json"
```

通常不能让 Desktop 下拉出现 GPT-5.6，也不能让 `max` 出现在推理强度菜单中。

完整补丁会做这些事：

- 创建独立应用副本，或在 Windows Store 场景下按用户选择生成同身份 MSIX 更新包。
- 解包 `app.asar`，定位包含模型过滤逻辑的 JavaScript bundle。
- 将模型展示逻辑调整为只排除 `hidden=true` 的模型。
- 将推理等级展示逻辑调整为使用 model catalog 声明的有效等级。
- 默认显示 `ultra`，使用 `--disable-ultra` 时排除它。
- 写入 GPT-5.6 Sol、Terra、Luna 到 model catalog。
- 按需更新 `config.toml` 中的 provider、`base_url`、默认模型和 catalog 路径。
- 对修改结果做验证，失败时停止并尽量恢复备份。

该修改只影响本地展示和配置，不会绕过第三方服务端权限。

## 常见问题

### 运行后仍显示“自定义 / Custom”

确认这次运行的是完整补丁模式，而不是 Node.js 配置模式。完整补丁输出中应包含 `app.asar` 验证通过的信息。

还需要确认：

- 补丁时 Desktop 已完全退出。
- 启动的是补丁副本，而不是原官方应用。
- Windows Store 应用没有被修复、重置或自动更新覆盖。
- 官方 Desktop 更新后，已经基于新版应用重新运行补丁。

### 下拉出现模型，但请求报 `Model not found`

model catalog 只控制本地展示。第三方服务商没有开放对应模型时，请求仍会失败。

只添加已确认可用的模型：

```bash
python3 patch_codex_gpt56.py --tiers sol,terra --yes
```

### Max 或 Ultra 请求失败怎么办

`max` 和 `ultra` 是否可用取决于第三方接口。你可以先用第三方 `Responses API` 测试：

```json
{
  "model": "gpt-5.6-sol",
  "input": "Reply exactly MAX_OK",
  "reasoning": {
    "effort": "max"
  }
}
```

如果接口明确不支持 `ultra`，重新运行：

```bash
python3 patch_codex_gpt56.py --disable-ultra --yes
```

### macOS 提示应用已损坏或无法验证

如果被拦截的是 `patch-macos.command`，在补丁目录执行：

```bash
xattr -dr com.apple.quarantine .
chmod +x patch-macos.command
./patch-macos.command
```

如果被拦截的是补丁副本应用，按真实路径重新签名：

```bash
codesign --force --deep --sign - ~/Applications/Codex-GPT56-Patched.app
xattr -cr ~/Applications/Codex-GPT56-Patched.app
open ~/Applications/Codex-GPT56-Patched.app
```

只对明确下载并信任的本项目目录清除 quarantine，不要对整个 `~/Downloads`、`/Applications` 或系统目录递归执行该命令。

### Windows 无法读取 WindowsApps

可以从 PowerShell 获取安装位置：

```powershell
Get-AppxPackage OpenAI.Codex | Select-Object InstallLocation
```

然后通过 `--app` 显式传入 `InstallLocation\app`。双击 `patch-windows.cmd` 时会自动请求 UAC，并调用 AppX 部署服务安装同身份更新包。不要直接修改 `WindowsApps` ACL 或手动覆盖 `app.asar`。

### Windows 中文用户名路径下 JSON 报错

旧版入口可能在中文用户名或中文下载目录下报：

```text
ConvertFrom-Json : 无法识别的转义序列
```

新版入口会用显式 UTF-8 写入和读取提权临时 invocation 文件，并先进入脚本目录再调用 PowerShell，避免 Windows PowerShell 5.1 默认编码误读。通常不需要把项目移动到英文路径。

### Linux 找不到安装位置

通过 `--app` 传入应用目录、AppImage 或 `app.asar`：

```bash
./patch-linux.sh --app ~/Downloads/Codex.AppImage
```

### 不登录 ChatGPT 账号能用吗

可以使用第三方 provider 的 API Key 模式。工具会按需设置 `requires_openai_auth = false`，但不会帮你生成 API Key，也不会修改 ChatGPT Cookie、会话或订阅权限。

## 安全边界

- 不是 OpenAI 官方补丁。
- 普通安装默认创建补丁副本，不修改官方安装目录。
- Windows Store / MSIX 只有在你选择替换时，才会安装本机签名的同身份更新包。
- 不读取、显示、复制、迁移或上传 API Key。
- 不修改 ChatGPT Cookie、登录态、订阅权限或服务端权限。
- 不修改 `codex.exe` / `codex` 命令行程序本体。
- 不保证第三方服务商开放 catalog 中的全部模型。
- 不保证 `max` / `ultra` 被第三方接口接受。
- 配置模式不能绕过 Desktop 前端账号白名单。
- Desktop 自动更新、Store 修复或重置后，可能需要重新执行补丁。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `patch_codex_gpt56.py` | 完整补丁主程序，负责应用识别、复制、ASAR 修改、catalog/config 更新和验证 |
| `configure_codex_gpt56.mjs` | Node.js 配置助手，只更新 model catalog 和 `config.toml` |
| `patch-windows.cmd` | Windows 一键入口 |
| `patch-windows.ps1` | Windows 入口逻辑，包含 Store/MSIX 分流 |
| `patch-windows-store.ps1` | Windows Store/MSIX 重打包和部署流程 |
| `patch-macos.command` | macOS 一键入口 |
| `patch-linux.sh` | Linux 一键入口 |
| `patch-unix.sh` | Unix 通用入口 |
| `test_patcher.py` | Python 单元测试 |
| `RUN-ON-MACOS.txt` | macOS 运行提示 |

## 开发和验证

本地检查命令：

```bash
python -m unittest -v
python patch_codex_gpt56.py --self-test
python -m py_compile patch_codex_gpt56.py test_patcher.py
node --check configure_codex_gpt56.mjs
node configure_codex_gpt56.mjs --self-test
```

PowerShell 脚本语法检查：

```powershell
[System.Management.Automation.Language.Parser]::ParseFile(
  "patch-windows.ps1",
  [ref]$null,
  [ref]$null
) | Out-Null
```

提交问题时建议提供：

- 操作系统和版本。
- Desktop 来源：官网安装、Windows Store/MSIX、`.app`、AppImage 等。
- 运行的完整命令。
- 报错输出。
- `--dry-run --yes` 的识别结果。

## 许可证

当前仓库未包含独立 `LICENSE` 文件。发布或二次分发前，建议补充明确的开源许可证。
