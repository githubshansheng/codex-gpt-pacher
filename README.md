# Codex Desktop GPT-5.6 跨平台补丁

这个工具用于解决以下问题：

- 第三方 `Responses API`（响应接口）已经支持 GPT-5.6，但 Codex Desktop 模型下拉仍只显示账号白名单中的官方模型。
- 支持不登录 ChatGPT 账号：对当前第三方 provider 自动设置 `requires_openai_auth = false`，仅使用用户已有的 API Key 鉴权。
- 默认提供 GPT-5.6 Sol、Terra、Luna，并显示 `low / medium / high / xhigh / max / ultra` 全部思考量。
- `config.toml`（配置文件）和 model catalog（模型目录）已经配置 `gpt-5.6-sol`，当前模型标签却显示“自定义 / Custom”。
- `app-server model/list`（桌面模型列表接口）已经返回 GPT-5.6，Desktop 前端仍将它过滤掉。
- model catalog 已声明 `max`（最大推理量），Desktop 推理强度下拉仍只显示到 `xhigh`（极高）。

普通安装的完整补丁默认创建独立应用副本，不直接覆盖官方安装目录。Windows Store/MSIX 版本继续使用当前项目的同身份更新包方案，以保留开始菜单和任务栏快捷方式身份。

## 先看结论

工具有两种运行模式：

| 模式 | 环境要求 | 修改 Desktop 代码 | 修改模型目录 | 修改配置文件 | 解决“自定义”显示 |
| --- | --- | --- | --- | --- | --- |
| 完整补丁模式 | Python 3.10+、Node.js 20+、npm/npx | 是 | 是 | 按需 | 是 |
| 配置模式 | Node.js 20+ | 否 | 是 | 按需 | 不一定 |

没有 Python 时，Windows、macOS、Linux 入口会自动改用纯 `Node.js`（JavaScript 运行环境）的配置助手：

```text
configure_codex_gpt56.mjs
```

配置模式可以安全添加 GPT-5.6 模型以及 `max` / `ultra` 推理等级（`ultra` 默认启用，可用 `--disable-ultra` 隐藏），但不会修改 Desktop 的 `app.asar`（应用资源包）。如果当前 Desktop 仍受账号白名单限制，模型可能仍显示为“自定义”，这时需要安装 Python 后重新执行完整补丁。

## 补丁是否来自官方

不是官方发布的补丁。

补丁以本机已安装的官方 Codex Desktop / ChatGPT Desktop 文件为基础，复制一份独立应用，再修改复制版中的前端 JavaScript 资源。它不会下载第三方修改过的可执行文件，也不会替换普通官方安装。

补丁不会修改：

- ChatGPT 账号、Cookie、会话或订阅权限；无需 ChatGPT 登录时会使用第三方 provider 的 API Key 模式。
- API 请求地址、API Key 或认证令牌；脚本不会读取、复制、输出或内嵌密钥。
- 第三方服务商的模型权限。
- `codex.exe` / `codex`（Codex 命令行程序）本体。
- 普通官方安装目录中的原始程序。

## 根因说明

Codex Desktop 的模型下拉并不是直接显示 `config.toml` 或 model catalog 中的全部模型。

Desktop 会先调用：

```text
list-models-for-host
```

或底层：

```text
app-server model/list
```

取得模型列表，然后再根据账号动态配置执行两层过滤：

1. 使用 `available_models`（账号可用模型白名单）过滤模型。
2. 使用 `enabledReasoningEfforts`（启用推理等级集合）过滤推理强度。

因此只修改：

```toml
model = "gpt-5.6-sol"
model_catalog_json = "model_catalog.json"
```

通常不能让 Desktop 下拉出现 GPT-5.6，也不能让 `max` 出现在推理强度菜单中。

## 详细改动清单

### 1. 创建独立应用副本

普通目录安装会优先复制官方应用到用户目录，再修改复制版中的 `app.asar`。默认目标路径：

| 系统 | 补丁副本路径 |
| --- | --- |
| Windows | `%USERPROFILE%\Applications\Codex-GPT56-Patched` |
| macOS | `~/Applications/Codex-GPT56-Patched.app` |
| Linux | `~/.local/opt/codex-gpt56-patched` |

如果目标目录已存在，脚本会在隐藏的临时目录中完成构建和签名，验证通过后原位替换固定路径。带有本补丁标记的旧时间戳备份会被清理；无法确认来源的同名目录只提示、不删除。

补丁副本内会保留：

```text
resources/app.asar.original
resources/app.asar.backup-YYYYMMDD-HHMMSS
```

如果写入或验证失败，脚本会用最新的 `app.asar.backup-*` 自动恢复。

Windows Store / MSIX 安装目录受 AppX 部署服务保护，管理员也不能直接覆盖其中的 `app.asar`。Windows 一键入口在未指定 `--output` 时会保留当前项目的同身份更新流程：

- 从当前 Store 包生成干净构建目录。
- 在构建目录中补丁 `app.asar`。
- 保留 `OpenAI.Codex` 包身份和 `App` 应用标识，仅增加版本修订号。
- 复用或创建当前用户的本地代码签名证书，并导入本机 `TrustedPeople` 信任区后生成 MSIX 更新包。
- 通过 Windows AppX 部署服务安装更新包，安装时临时允许本地签名更新包部署，结束后恢复原系统设置。
- 安装后校验包版本和已部署 `app.asar` 的 SHA256。

因此原开始菜单、任务栏固定项和快捷方式仍使用：

```text
OpenAI.Codex_2p2nqsd0c76g0!App
```

构建盘会自动选择至少 8GB 可用空间的可写磁盘，生成的 MSIX 和部署记录分别保存在：

```text
<磁盘>:\CodexGPT56Patcher\packages
%USERPROFILE%\.codex\backups\codex-gpt56\store-packages
```

成功部署并完成哈希校验后，临时构建目录 `<磁盘>:\CodexGPT56Patcher\build-*` 会自动清理；如果打包、签名或部署失败，构建目录会保留，方便排查和手动清理。最终可回退的安装包仍保留在 `packages` 目录中。

如需绕过 Store 同身份更新流程，也可以显式使用 `--output` 创建独立副本。

### 2. 修改模型白名单过滤

原始逻辑大致为：

```js
if (useHiddenModels ? availableModels.has(model.model) : !model.hidden)
```

压缩后的代码可能类似：

```js
if (u ? n.has(r.model) : !r.hidden)
```

补丁修改为：

```js
if (!model.hidden)
```

含义是：

- 不再根据 ChatGPT 账号的 `available_models` 白名单过滤第三方模型。
- 只要 model catalog 返回 `hidden=false`，模型就可以出现在下拉中。
- 该修改只影响展示，不会绕过服务端调用权限。

### 3. 修改推理等级过滤

原版还会执行类似逻辑：

```js
supportedReasoningEfforts.filter(
  ({ reasoningEffort }) =>
    isValidReasoningEffort(reasoningEffort) &&
    enabledReasoningEfforts.has(reasoningEffort)
)
```

完整补丁默认改为：

```js
supportedReasoningEfforts.filter(
  ({ reasoningEffort }) =>
    isValidReasoningEffort(reasoningEffort)
)
```

这样 model catalog 声明的 `max` 和默认 `ultra` 可以显示，不再依赖账号动态配置是否开放对应推理等级。

使用 `--disable-ultra` 时，补丁会额外加入 Ultra 排除条件：

```js
supportedReasoningEfforts.filter(
  ({ reasoningEffort }) =>
    isValidReasoningEffort(reasoningEffort) &&
    reasoningEffort !== "ultra"
)
```

### 4. 默认启用 Ultra，可按需关闭

普通 GPT-5.6 API 的 `reasoning.effort`（推理强度）支持：

```text
low / medium / high / xhigh / max / ultra
```

`ultra`（超高并行模式）不是所有 API 或第三方中转都支持。v3 完整补丁默认显示 `ultra`，以便已经验证支持的 provider 直接使用完整能力。

如果第三方接口尚未实测接受：

```json
{
  "reasoning": {
    "effort": "ultra"
  }
}
```

请使用：

```bash
python3 patch_codex_gpt56.py --disable-ultra --yes
```

仅仅让 UI 显示 Ultra 不会获得官方 Ultra 权限。接口不支持时，请求仍会失败。

### 5. 更新 model catalog

默认补充或更新以下模型：

```text
gpt-5.6-sol    -> GPT-5.6 Sol
gpt-5.6-terra  -> GPT-5.6 Terra
gpt-5.6-luna   -> GPT-5.6 Luna
```

每个模型默认声明：

```text
low / medium / high / xhigh / max / ultra
```

关键字段示例：

```json
{
  "slug": "gpt-5.6-sol",
  "display_name": "GPT-5.6 Sol",
  "description": "GPT-5.6 Sol",
  "visibility": "list",
  "supported_in_api": true,
  "supported_reasoning_levels": [
    { "effort": "low", "description": "Fast responses with lighter reasoning" },
    { "effort": "medium", "description": "Balances speed and reasoning depth for everyday tasks" },
    { "effort": "high", "description": "Greater reasoning depth for complex problems" },
    { "effort": "xhigh", "description": "Extra high reasoning depth for complex problems" },
    { "effort": "max", "description": "Maximum reasoning depth for the hardest problems" },
    { "effort": "ultra", "description": "Ultra parallel reasoning; requires explicit provider support" }
  ]
}
```

如果模型已经存在，脚本只更新关键显示和推理等级字段，不会清空整个 catalog。

### 6. 按需修改 config.toml

如果 `config.toml` 没有配置 `model_catalog_json`，脚本会创建：

```text
~/.codex/model_catalog.json
```

并写入绝对路径：

```toml
model_catalog_json = "/absolute/path/to/model_catalog.json"
```

默认会把当前模型设为 Sol：

```toml
model = "gpt-5.6-sol"
```

如需保留用户当前默认模型，可使用：

```bash
--default-model keep
```

也可以显式选择：

```bash
--default-model keep
--default-model sol
--default-model terra
--default-model luna
```

对当前激活的第三方 provider，脚本会自动启用 API-key/no-ChatGPT-login 模式：

```toml
requires_openai_auth = false
```

如果激活的是 `openai` / `chatgpt` provider，或该 provider 的 `base_url` 指向 `https://api.openai.com`，脚本不会改写登录要求。

工具不会自动修改以下内容：

```toml
model_provider
base_url
wire_api
env_key
```

也不会读取、复制或迁移 API Key。

### 7. 自动备份

修改已有 model catalog 或 `config.toml` 前，脚本会在同目录创建备份：

```text
config.toml.backup-YYYYMMDD-HHMMSS
model_catalog.json.backup-YYYYMMDD-HHMMSS
```

普通补丁副本内还会保留原始资源包和本次写入前备份：

```text
resources/app.asar.original
resources/app.asar.backup-YYYYMMDD-HHMMSS
```

如果 `app.asar` 写入或验证失败，脚本会自动用本次时间戳备份恢复。Windows Store / MSIX 构建包在打包前会移除这些内部备份，部署记录见回滚章节。

### 8. 保留原生模块结构

Electron 应用的部分原生模块必须位于：

```text
app.asar.unpacked
```

脚本会先解包定位目标 JavaScript bundle，再对原始 `app.asar` 做等长字节替换；不会重新打包整个 ASAR。这样可以保留原始 ASAR header、文件偏移和 `app.asar.unpacked` 布局，避免出现模型菜单修好了，但终端、SQLite 或其他原生功能无法启动的问题。

### 9. macOS 本地签名

修改 `app.asar` 后，应用签名会失效。macOS 模式会对补丁副本执行 ad-hoc 本地签名：

```bash
codesign --force --deep --sign - ~/Applications/Codex-GPT56-Patched.app
xattr -cr ~/Applications/Codex-GPT56-Patched.app
```

这只处理补丁副本，不修改 `/Applications` 中的官方应用。

### 10. CLI 验证

完整补丁完成后，脚本会使用补丁版自带的 `Codex CLI` 调用：

```text
app-server model/list
```

并验证：

- GPT-5.6 模型已经返回。
- `displayName` 正确。
- `hidden=false`。
- 推理等级包含 `max`。
- 默认包含 `ultra`；使用 `--disable-ultra` 时不包含 `ultra`。

该验证确认 Desktop 后端已经正确读取 catalog，但不会发送计费模型请求。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `patch_codex_gpt56.py` | 完整跨平台补丁，包含应用复制、ASAR 等长修改、catalog 更新、备份和验证 |
| `configure_codex_gpt56.mjs` | 无 Python 时的配置助手，只修改 catalog 和 config.toml |
| `patch-windows.cmd` | Windows 双击入口，自动选择 Python 或 Node.js |
| `patch-windows.ps1` | Windows UAC 提权和参数转发入口 |
| `patch-windows-store.ps1` | Windows Store 同身份 MSIX 构建、签名和更新部署 |
| `patch-macos.command` | macOS 双击入口，自动选择 Python 或 Node.js |
| `patch-linux.sh` | Linux 入口，自动选择 Python 或 Node.js |
| `patch-unix.sh` | 通用 Unix 入口 |

## 环境要求

### 完整补丁模式

需要：

- Python 3.10 或更高版本。
- Node.js 20 或更高版本。
- `npm` / `npx`（Node 包执行器）。

脚本通过：

```text
npx @electron/asar
```

解包和校验应用资源，不要求全局安装 `asar`。

### 无 Python 配置模式

只需要：

- Node.js 20 或更高版本。

可以完成：

- 创建或更新 model catalog。
- 添加 Sol、Terra、Luna。
- 添加 `max` 和 `ultra` 推理等级；可用 `--disable-ultra` 关闭 `ultra`。
- 默认设置 Sol；可用 `--default-model keep` 保留当前模型。
- 按需写入 `model_catalog_json`。
- 对当前第三方 provider 启用 `requires_openai_auth = false`。
- 自动备份配置文件。

不能完成：

- 修改 Desktop `app.asar`。
- 绕过账号 `available_models` 白名单。
- 绕过账号 `enabledReasoningEfforts` 过滤。
- 保证 Desktop 不再显示“自定义”。

## 一键使用

### Windows

支持自动识别：

```text
C:\Program Files\WindowsApps\OpenAI.Codex_*\app
%LOCALAPPDATA%\Programs\Codex
%LOCALAPPDATA%\Programs\ChatGPT
%LOCALAPPDATA%\OpenAI\Codex
%LOCALAPPDATA%\OpenAI\ChatGPT
```

Microsoft Store 版本还会通过 PowerShell 的 `Get-AppxPackage OpenAI.Codex` 读取真实 `InstallLocation`，避免只依赖 `WindowsApps` 目录枚举。

双击：

```text
patch-windows.cmd
```

入口执行顺序：

1. 优先查找 `py -3`。
2. 其次查找 `python`。
3. 没有 Python 时查找 `node`，进入配置模式。
4. Python 和 Node.js 都不存在时停止并显示安装提示。

普通 Windows 目录安装默认生成到：

```text
%USERPROFILE%\Applications\Codex-GPT56-Patched
```

启动补丁副本：

```text
%USERPROFILE%\Applications\Codex-GPT56-Patched\ChatGPT.exe
```

Microsoft Store 版本在未指定 `--output` 时会弹出 UAC 提权窗口。脚本不会直接写入受保护的 `WindowsApps` 文件，而是生成并安装同身份的 MSIX 更新包。

完成后仍从原来的开始菜单入口启动 Codex。

MSIX 重打包需要 `makeappx.exe` 和 `signtool.exe`。脚本会优先使用本机已安装的 Windows 10/11 SDK；如果没有安装 SDK，会自动从微软官方 NuGet 下载 `Microsoft.Windows.SDK.BuildTools`，优先选择兼容 Windows 10/11 的 `10.0.26100.*` 稳定版本。

下载的打包工具会缓存到 `%LOCALAPPDATA%\CodexGPT56Patcher\tools\Microsoft.Windows.SDK.BuildTools\<version>`。如果没有 `%LOCALAPPDATA%`，会退到 `%TEMP%\CodexGPT56Patcher\tools`。首次自动下载需要能访问 `api.nuget.org`，无需单独安装完整 SDK。

构建阶段需要某个磁盘至少约 8GB 可用空间，系统盘安装阶段需要至少约 3GB 可用空间。

脚本会为本机创建或复用友好名称为 `Codex GPT56 Local MSIX` 的本地签名证书。该证书只用于给本机生成的同身份 MSIX 更新包签名；如果证书尚未存在于 `LocalMachine\TrustedPeople`，脚本会导入一次。以后不再使用 Store/MSIX 同身份补丁时，可以根据部署记录里的 `signingCertificateThumbprint`，在管理员 PowerShell 中移除该本地信任证书：

```powershell
$metadata = Get-Content "$env:USERPROFILE\.codex\backups\codex-gpt56\store-packages\YYYYMMDD-HHMMSS.json" | ConvertFrom-Json
Get-ChildItem "Cert:\LocalMachine\TrustedPeople\$($metadata.signingCertificateThumbprint)" |
  Remove-Item
```

注意：Microsoft Store 更新或重新安装可能覆盖本地签名更新包。遇到这种情况重新运行补丁，或显式改用独立副本模式：

```powershell
py -3 patch_codex_gpt56.py `
  --output "$env:USERPROFILE\Applications\Codex-GPT56-Patched" `
  --yes
```

### macOS

支持自动识别：

```text
/Applications/Codex.app
/Applications/ChatGPT.app
~/Applications/Codex.app
~/Applications/ChatGPT.app
```

也会通过 Spotlight `mdfind` 搜索其他位置的 `Codex.app` 和 `ChatGPT.app`。

从浏览器、微信、网盘或邮件下载后，macOS 通常会给整个补丁目录添加 quarantine（下载隔离属性）。此时直接双击 `patch-macos.command` 会出现“Apple 无法验证”并只提供“移到废纸篓”。

不要关闭全局 Gatekeeper（系统应用安全检查），也不需要执行 `sudo spctl --master-disable`。只清除这个补丁目录的隔离属性即可。

假设补丁目录位于“下载”文件夹，打开 Terminal（终端）执行：

```bash
cd ~/Downloads/codex-gpt56-patcher
xattr -dr com.apple.quarantine .
chmod +x patch-macos.command patch-linux.sh patch-unix.sh
./patch-macos.command
```

如果目录名称或位置不同，可以把 Finder 中的补丁文件夹直接拖到 Terminal 窗口，自动填入真实路径。例如：

```bash
xattr -dr com.apple.quarantine "/实际路径/codex-gpt56-patcher"
chmod +x "/实际路径/codex-gpt56-patcher/patch-macos.command"
"/实际路径/codex-gpt56-patcher/patch-macos.command"
```

也可以完全不双击 `.command` 文件，直接在终端运行核心脚本：

```bash
cd ~/Downloads/codex-gpt56-patcher
xattr -dr com.apple.quarantine .
python3 patch_codex_gpt56.py --yes
```

如果没有 Python、但已经安装 Node.js：

```bash
cd ~/Downloads/codex-gpt56-patcher
xattr -dr com.apple.quarantine .
node configure_codex_gpt56.mjs --yes
```

注意：Node.js 模式只修改配置和模型目录，不会修改 Desktop 前端过滤逻辑。

完整补丁默认复制自动识别到的原应用，并生成补丁副本：

```text
~/Applications/Codex-GPT56-Patched.app
```

完成后启动补丁副本：

```bash
open ~/Applications/Codex-GPT56-Patched.app
```

### Linux

支持常见目录安装：

```text
/opt/Codex
/opt/codex
/opt/ChatGPT
/opt/chatgpt
/usr/lib/codex
/usr/lib/codex-desktop
/usr/lib/chatgpt
/usr/share/codex
/usr/share/codex-desktop
/usr/share/chatgpt
/usr/local/lib/codex
~/.local/share/codex
~/.local/share/codex-desktop
~/.local/share/chatgpt
~/.local/opt/codex
```

也会从 `PATH` 中的 `codex-desktop`、`codex-app`、`chatgpt` 反查安装目录。

同时支持在以下位置搜索 `AppImage`（便携镜像）：

```text
~/Applications
~/Downloads
/opt
```

执行：

```bash
chmod +x patch-linux.sh
./patch-linux.sh
```

完整补丁默认生成到：

```text
~/.local/opt/codex-gpt56-patched
```

如果来源是 AppImage，补丁目录通过以下文件启动：

```text
~/.local/opt/codex-gpt56-patched/AppRun
```

也可以显式指定输出目录：

```bash
python3 patch_codex_gpt56.py \
  --app ~/Downloads/Codex.AppImage \
  --output ~/.local/opt/codex-gpt56-patched \
  --yes
```

## 常用命令

### 预览识别结果，不写文件

```bash
python3 patch_codex_gpt56.py --dry-run --yes
```

### 指定安装路径

支持传入 `.app`、AppImage、应用目录、可执行文件或 `app.asar`：

```bash
python3 patch_codex_gpt56.py --app "/path/to/Codex.app" --yes
```

Windows 示例：

```powershell
py -3 patch_codex_gpt56.py `
  --app "C:\Program Files\WindowsApps\OpenAI.Codex_xxx\app" `
  --dry-run `
  --yes
```

`--app` 只指定官方来源应用；未配合 `--output` 时仍使用默认补丁副本路径。Windows Store 一键入口在未指定 `--output` 时会走同身份 MSIX 更新流程。

### 指定补丁输出目录

```bash
python3 patch_codex_gpt56.py \
  --output "/custom/path/Codex-GPT56-Patched.app" \
  --yes
```

`--output` 会指定补丁副本位置，不修改普通官方安装目录。

### 只更新模型配置

有 Python：

```bash
python3 patch_codex_gpt56.py --catalog-only --yes
```

无 Python：

```bash
node configure_codex_gpt56.mjs --yes
```

### 只修改 Desktop 代码

```bash
python3 patch_codex_gpt56.py --desktop-only --yes
```

### 设置默认模型

Sol：

```bash
python3 patch_codex_gpt56.py --default-model sol --yes
```

无 Python时：

```bash
node configure_codex_gpt56.mjs --default-model sol --yes
```

可选值：

```text
keep / sol / terra / luna
```

默认值是 `sol`。使用 `keep` 可保留用户当前默认模型。

### 只添加指定层级

```bash
python3 patch_codex_gpt56.py --tiers sol,terra --yes
```

无 Python时：

```bash
node configure_codex_gpt56.mjs --tiers sol,terra --yes
```

### 指定 model catalog

```bash
python3 patch_codex_gpt56.py \
  --catalog ~/.codex/my-model-catalog.json \
  --yes
```

### 关闭 Ultra 展示

默认会展示 Ultra。第三方接口尚未确认支持时使用：

```bash
python3 patch_codex_gpt56.py --disable-ultra --yes
```

配置模式：

```bash
node configure_codex_gpt56.mjs --disable-ultra --yes
```

### 验证已有补丁

```bash
python3 patch_codex_gpt56.py \
  --verify-only \
  --app "/path/to/Codex.app" \
  --tiers sol,terra,luna
```

### 运行脚本自测

完整补丁自测：

```bash
python3 patch_codex_gpt56.py --self-test
```

配置助手自测：

```bash
node configure_codex_gpt56.mjs --self-test
```

## 第三方 API 配置示例

本工具不会自动填写 API 地址和密钥。第三方 `Responses API` 配置仍由用户维护。

示例：

```toml
model_provider = "custom"
model = "gpt-5.6-sol"
review_model = "gpt-5.6-sol"
model_catalog_json = "C:/Users/your-name/.codex/model_catalog.json"

[model_providers.custom]
name = "custom"
base_url = "https://your-api.example/v1"
wire_api = "responses"
env_key = "CODEX_CUSTOM_API_KEY"
```

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

## 如何判断第三方接口是否支持 Max

model catalog 中添加 `max` 只表示 UI 允许选择，不代表服务端一定接受。

可以直接调用第三方 `Responses API`：

```json
{
  "model": "gpt-5.6-sol",
  "input": "Reply exactly MAX_OK",
  "reasoning": {
    "effort": "max"
  }
}
```

也可以使用 Codex CLI：

```bash
codex exec \
  --skip-git-repo-check \
  --ephemeral \
  -m gpt-5.6-sol \
  -c 'model_reasoning_effort="max"' \
  "Reply exactly MAX_OK"
```

如果接口返回“不支持 max”或列出其他有效等级，应从对应模型的 `supported_reasoning_levels` 中删除 `max`。

## 登录和未登录状态的影响

补丁只修改前端模型展示与推理等级展示，不修改登录逻辑。

已登录 ChatGPT：

- 第三方 catalog 中的非隐藏模型会出现在下拉中。
- 使用官方 ChatGPT/Codex 服务时，账号没有权限的模型仍可能调用失败。
- 使用自定义 `base_url` 时，实际权限由第三方接口决定。

未登录或仅使用 API Key：

- model catalog 和自定义 provider 仍可被 Codex 后端读取。
- 是否能正常对话取决于 `base_url`、`wire_api` 和 API Key 是否正确。
- 补丁不会帮用户登录，也不会生成或替换密钥。

## 回滚

### 恢复配置

在 `~/.codex` 中找到最近的备份文件：

```text
config.toml.backup-YYYYMMDD-HHMMSS
model_catalog.json.backup-YYYYMMDD-HHMMSS
```

退出 Codex Desktop 后，用备份覆盖当前文件即可。

### 恢复补丁副本的原始 ASAR

补丁副本目录内保留：

```text
resources/app.asar.original
```

可在完全退出 Desktop 后，将它复制回：

```text
resources/app.asar
```

macOS 补丁副本恢复后需要重新执行本地签名。

### 恢复 Windows Store / MSIX 安装

本地签名更新包的部署记录位于：

```text
%USERPROFILE%\.codex\backups\codex-gpt56\store-packages\YYYYMMDD-HHMMSS.json
```

通过 Windows“设置 -> 应用 -> Codex -> 高级选项 -> 修复/重置”，或从 Microsoft Store 重新安装，即可恢复官方签名包。

MSIX 修复、更新或重新安装会恢复官方文件，也会移除补丁。

### 恢复 AppImage 来源的补丁副本

当前版本不会覆盖原始 `Codex.AppImage`，也不会生成相邻的 `Codex.AppImage.backup-*`。AppImage 会先解包到补丁目录，恢复方式与普通 Linux 补丁副本相同。

退出应用后，用补丁目录内的原始资源包覆盖当前资源包：

```text
resources/app.asar.original -> resources/app.asar
```

也可以直接删除默认补丁目录 `~/.local/opt/codex-gpt56-patched`，或删除你通过 `--output` 指定的补丁目录，再基于原 AppImage 重新生成。

## Desktop 更新后的处理

官方更新通常会更换：

- Desktop 版本号。
- JavaScript bundle 文件名及哈希。
- 模型过滤函数的压缩变量名。
- `app.asar` 内容和签名。

官方更新后通常会更换来源应用。普通独立副本不会被自动更新覆盖，但建议重新运行脚本，基于新版 `app.asar` 生成新的补丁副本。Windows Store/MSIX 同身份更新包可能被修复、重置或自动更新覆盖，遇到这种情况重新运行 Windows 入口。

脚本不会盲目替换固定文件名，而是搜索包含模型过滤结构的 bundle。如果新版结构已经改变且无法安全匹配，脚本会停止并报错，不会继续生成未经验证的补丁。

## 常见问题

### 运行后仍显示“自定义”

确认脚本输出包含 `app.asar in-place verification passed; original native-module layout preserved`，并且 Desktop 在补丁时已经完全退出。Windows Store 入口还会继续执行 catalog 更新和已部署包验证；若官方应用随后自动更新，需要重新运行补丁。

如果入口提示使用了配置模式，说明没有找到 Python，Desktop 代码没有被修改。安装 Python 后重新运行完整补丁。

### 下拉出现模型，但请求报 Model not found

model catalog 只控制本地展示。第三方服务商没有开放该模型时，请求仍会失败。

使用以下参数仅添加真实可用的模型：

```bash
--tiers sol,terra
```

### 下拉出现 Max，但请求报不支持

第三方接口可能只支持到 `xhigh`。这时需要从 model catalog 对应模型中删除 `max`，或者让服务商增加支持。

### Ultra 请求失败怎么办

Ultra 可能是账号功能、并行编排能力或专用服务模式，不一定等于普通 API 的 `reasoning.effort="ultra"`。

当前第三方接口没有明确支持时，使用以下参数隐藏 Ultra：

```bash
--disable-ultra
```

### macOS 提示应用已损坏或无法验证

需要先判断被拦截的是哪个文件。

如果被拦截的是 `patch-macos.command`，说明脚本尚未运行。对下载后的补丁目录执行：

```bash
cd "/补丁目录"
xattr -dr com.apple.quarantine .
chmod +x patch-macos.command
./patch-macos.command
```

也可以在 Finder 中按住 Control 点击 `patch-macos.command`，选择“打开”，再确认“打开”。但对于只显示“移到废纸篓”的情况，终端清除 quarantine 更稳定。

如果被拦截的是补丁副本应用，按真实补丁路径重新签名，例如：

```bash
codesign --force --deep --sign - ~/Applications/Codex-GPT56-Patched.app
xattr -cr ~/Applications/Codex-GPT56-Patched.app
```

然后通过：

```bash
open ~/Applications/Codex-GPT56-Patched.app
```

只应对明确下载并信任的本补丁目录清除 quarantine，不要对整个 `~/Downloads`、`/Applications` 或系统目录递归执行该命令。

### Windows 无法读取 WindowsApps

当前用户通常对已安装 MSIX 应用具有读取权限。如果自动识别失败，可从 PowerShell 获取安装位置：

```powershell
Get-AppxPackage OpenAI.Codex | Select-Object InstallLocation
```

然后通过 `--app` 显式传入 `InstallLocation\app`。

双击 `patch-windows.cmd` 时会自动请求 UAC，并调用 AppX 部署服务安装同身份更新包。不要直接修改 `WindowsApps` ACL 或尝试手动覆盖 `app.asar`。

### Windows 中文用户名路径下 JSON 报错

如果用户名或下载目录包含中文，旧版入口可能在 Store/MSIX 提权流程中报：

```text
ConvertFrom-Json : 无法识别的转义序列
```

新版入口会用显式 UTF-8 写入和读取提权临时 invocation 文件，并先进入脚本目录再调用 PowerShell，避免中文路径被 Windows PowerShell 5.1 默认编码误读。

### Linux 找不到安装位置

通过 `--app` 传入应用目录、AppImage 或 `app.asar`：

```bash
./patch-linux.sh --app ~/Downloads/Codex.AppImage
```

## 安全边界与限制

- 普通安装默认创建补丁副本，不修改官方安装目录；Windows Store/MSIX 在未指定 `--output` 时会安装本机签名的同身份更新包。
- 不修改 ChatGPT Cookie、会话和账号权限；第三方 provider 会按需启用 API-key/no-ChatGPT-login 模式。
- 不读取、显示、复制或迁移 API Key。
- 不保证第三方服务商开放 catalog 中的所有模型。
- `max` 是否可用最终由第三方接口决定。
- `ultra` 默认显示，但不代表获得服务端权限；不支持时使用 `--disable-ultra`。
- 配置模式不能绕过 Desktop 前端账号白名单。
- Desktop 自动更新后需要重新执行完整补丁。
- 补丁是本地非官方修改版，使用者需要自行决定是否接受本地应用签名变化。
- Windows Store / MSIX 补丁会安装本机签名的同身份更新包，可能被修复功能或自动更新覆盖。
