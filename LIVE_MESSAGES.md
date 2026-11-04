# OpenMac：消息接收与转发

将文字、图片和音频消息发送到 OpenMac，由本机完成语音转写、图片 OCR 和消息整理，并可将结果转发到 Bark。应用支持后台运行和登录后自动启动。

## 安装与使用

需要 macOS 13+ 和 Xcode。中文离线语音识别取决于设备及系统语言模型是否支持。

```sh
bash scripts/install-live.sh
```

应用安装到 `~/Applications/OpenMac Live.app`。

1. 启动 OpenMac，设置 HTTP 端口（默认 **8080**），打开服务开关。
2. 在“消息转发”页填写 Bark 完整地址，例如 `https://api.day.app/设备Key/`，点击“保存设置”。
3. 如需处理音频，点击“授权语音识别”，并开启系统设置 → 键盘 → 听写。
4. 让发送端把消息和附件发送到本机服务，无需令牌。
5. 在 Config 中开启 **Launch at Login**，即可登录后自动启动。应用会保存服务开关和端口。

关闭窗口后服务继续运行，可以通过菜单栏打开设置或退出应用。登录自动启动可能需要在系统登录项设置中确认；它在用户登录后生效。

配置和消息保存在 `~/Library/Application Support/OpenMacLive/`：

- `config.json`：Bark 地址。
- `queue.json`：收到的消息、识别结果和转发队列。
- `media/`：发送端上传的原始媒体文件。

## 消息处理

- **文字**：保留内容并整理发送者、时间等信息。
- **图片**：使用 Vision 识别简体中文、繁体中文和英文。
- **音频**：使用 Speech 在本机转写；较长音频自动分成最多 50 秒一段。
- **关联图片**：音频所附图片也可识别，与转写结果一起整理。
- **Bark 转发**：按消息顺序汇总，长通知自动拆分，使用“OpenMac 消息”分组。

没有填写 Bark 地址时，消息仍会保存和处理，通知留在本地等待。识别结果按文件内容缓存，重复附件无需再次识别。

识别失败会重试三次，之后保留原始消息并发送错误说明。修复权限或其他问题后，可点击“重新识别失败消息”。语音识别可能出现同音词错误，不会自动改写原意。

Bark 转发失败每 30 秒重试。成功回执表示 Bark 服务接受，不能证明手机已经展示通知。如果服务接受后、写入本机确认前应用退出，重试可能重复通知。

## 导出 Markdown

发送端可将消息批次的 `notify` 设为 `false`，只进行识别和整理，不创建 Bark 通知。已有消息直接复用结果；同一消息之后用于正常转发时，仍可发送一次。

通过 `POST /api/live/export` 查询导出进度：

```json
{"appId":"app_example","aliveId":"source_example","roomId":"room_example","title":"消息记录","commentIds":["message_1","message_2"]}
```

响应的 `data.document` 包含：

- `total`：去重后的消息总数。
- `completed`：已完成处理的条数（包含最终失败）。
- `failed`：最终识别失败的条数。
- `missing`：尚未接收的消息 ID，可只上传这些消息及其附件。
- `markdown`：全部处理完成时提供，内容按时间排列，标明识别失败，不附带音频文件。

实时转发任务优先于批量导出处理；已有识别结果和附件缓存共用。导出复用已完成结果；旧版中文 OCR 和只保留最后一句的语音缓存会先重新处理再输出。语音按音频时间合并分句结果，空的最终回调不覆盖前文；真正的空转写进入失败重试，不作为成功缓存。缓存升级保留已有推送标记，不重复发送通知。

## 本机 HTTP 接口

服务只监听 `127.0.0.1`，无需 Authorization 请求头。

| 接口 | 用途 |
|---|---|
| `POST /api/live/messages` | 接收消息和附件，持久化成功后返回确认 |
| `GET /api/live/status` | 查看消息处理与转发状态 |
| `POST /api/live/export` | 查询指定消息的处理进度，完成后返回 Markdown |
| `POST /api/live/retry` | 将识别失败的消息重新入队 |

消息接口使用 `multipart/form-data`：

- `metadata` 字段存放 UTF-8 JSON，包含批次信息、消息数组及附件对应关系。
- `media0`、`media1` 等字段存放原始图片或音频二进制。
- `metadata.media` 用 `{ "url": "原始资源地址", "field": "media0" }` 将消息中的资源地址与上传文件对应。

发送端应直接上传 PNG/JPG/MP3，不需要 Base64，也不需要提前转换 WAV。OpenMac 优先处理已上传的本地文件，无需重新访问受登录保护的资源。单次附件总大小最多 30MB，HTTP 请求上限 32MB。

`metadata` 中的 `appId`、`aliveId`、`roomId` 及 `comment_id` 沿用现有发送端的数据格式，用于确定消息来源和去重。当前解码器兼容既有消息格式；其他发送端需按该格式适配，并非任意 JSON 都可直接接入。

接口也接受用于调试的 JSON 请求。未上传媒体时会尝试下载原地址，此兼容路径仅支持现有资源域名，不保证能够获取受登录保护的文件。

成功响应示例：

```json
{"success":true,"timeCost":2,"data":{"accepted":1},"message":""}
```

`accepted` 表示新增消息数量；重复提交返回 `0`，不会再次入队。状态接口通过 `data.text` 返回队列状态。

## 开发与验证

```sh
bash scripts/test-live.sh
xcodebuild -project openmac.xcodeproj -scheme openmac -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

测试覆盖持久化恢复、去重、转发确认与失败重试、通知分段、图片去重、HTTP 校验、multipart 二进制保真、上传落盘、中文 OCR、Markdown 导出与推送隔离。测试使用模拟通知传输，不访问真实 Bark。

安装脚本为本机开发版本固定签名要求，避免重编译导致隐私授权丢失。对外发布应使用自己的 Developer ID 签名并公证。

消息及附件目前不会自动清理，长期使用可以退出应用后备份、整理数据目录。
