# OpenMac Live：小鹅通直播消息

本分支基于 OpenMac，保留原有 API，新增直播消息接收、原生 Speech 转写、中文 Vision OCR、持久化队列及 Bark 推送。纯 Swift，无 Python/Node 服务依赖。

## 安装与启动

需要 macOS 13+ 和 Xcode。中文离线识别还取决于设备与系统语言模型是否支持。

```sh
bash scripts/install-live.sh
```

应用安装到 `~/Applications/OpenMac Live.app`，使用独立 bundle ID `com.chenpx976.openmac.live`，不会覆盖上游 OpenMac。

1. 启动应用，HTTP 端口设为 **8080**，打开服务开关。
2. 在“直播消息”页填入 Bark 完整地址 `https://api.day.app/设备Key/`，保存。
3. 点击“授权语音识别”，允许系统弹窗；同时开启系统设置 → 键盘 → 听写。Speech 仅使用本地识别，不自动切换云端。
4. 把此页的访问令牌复制到小鹅通插件中，点击插件“开始监听”。
5. Config → **Launch at Login** 开启登录启动。系统可能要求在登录项设置中确认。HTTP 开关和端口会保存，登录后自动恢复；关闭窗口不会退出应用，菜单栏可显示设置或退出。

这是登录后启动，不是在用户尚未登录时启动的系统守护进程。可用以下启动参数触发初次配置：

```sh
open "$HOME/Applications/OpenMac Live.app" --args --authorize-speech --enable-login
```

安装脚本为本地开发固定签名要求，避免重编译后反复丢失授权；对外发布仍应使用自己的 Developer ID 签名并公证。

## 传输协议

HTTP 服务只监听 `127.0.0.1`。以下直播 API 均要求：

```text
Authorization: Bearer <直播消息页的访问令牌>
```

**POST `/api/live/messages`** 推荐使用 `multipart/form-data`，不要手动设置 boundary：

- `metadata`：UTF-8 JSON。
- `media0`、`media1` 等：原始文件二进制。图片保持 PNG/JPG，音频保持 MP3，不使用 Base64，不提前转换 WAV。

`metadata` 示例（可一次提交多个消息，但插件按单条提交，限制峰值内存）：

```json
{
  "appId": "app_example",
  "aliveId": "l_example",
  "roomId": "XET#example",
  "title": "直播标题",
  "messages": [
    {
      "comment_id": "message_1",
      "content_type": 3,
      "user_type": 1,
      "org_msg_content": "audio_id",
      "created_timestamp": 1700000000,
      "wx_nickname": "主播",
      "more_info": {"url": "https://wxresource.example.xiaoeknow.com/audio.mp3"}
    }
  ],
  "media": [
    {"url": "https://wxresource.example.xiaoeknow.com/audio.mp3", "field": "media0"}
  ]
}
```

插件在后台携带浏览器已有 Cookie 获取媒体，下载失败或返回登录页面时保留断点重试。只有文件内容、资源 URL 和消息信息传入 OpenMac，浏览器 Cookie 不会传入。原图和缩略图去重，语音关联的 `more_info.target_ppt.pic_url` 也会下载。

媒体按内容哈希落盘，相同文件不重复保存。单条消息附件总大小最多 30MB，HTTP 请求上限 32MB。文件和消息均保存成功后才确认入队：

```json
{"success":true,"timeCost":2,"data":{"accepted":1},"message":""}
```

重复消息返回 `accepted: 0`。为兼容脚本调试，也接受 `application/json`；没有上传的媒体会尝试从原 URL 下载，这种旧方式不保证支持受登录保护的文件。

**GET `/api/live/status`**：`data.text` 返回队列状态。

**POST `/api/live/retry`**：重新识别失败消息，也可使用界面按钮。重试成功后会发送一条新的识别结果。

## 处理、恢复和推送

- 支持文字（0）、独立图片（2）、语音（3）与关联课件；其他类型保留原始内容。
- OCR 显式指定简体中文、繁体中文和英文，避免上游默认语言造成中文乱码。
- 音频在本机切成最多 50 秒一段，再调用 Speech 离线识别。识别结果可能有同音词错误；不进行自动改写。
- 语音、图片识别按文件哈希缓存；重复课件可复用 OCR 结果。
- 队列、识别结果、待发送通知以原子文件写入。识别失败退避重试三次，之后保留并推送原文、媒体地址与错误说明。
- 每个房间按消息时间汇总，较早消息重试时后续消息等待它；最长等待包括下载、识别超时与重试时间。
- 通知按 UTF-8 1800 字节拆分，为 APNs 标题等字段留出空间。Bark 失败每 30 秒重试。
- Bark 返回成功仅表示服务接受，不能验证手机是否展示。服务接受后、本机确认前若进程退出，可能重复推送；这是至少一次投递。

本地文件（未提交到仓库）：

```text
~/Library/Application Support/OpenMacLive/config.json  # 访问令牌、Bark 地址
~/Library/Application Support/OpenMacLive/queue.json   # 消息、结果、通知队列
~/Library/Application Support/OpenMacLive/media/       # 上传的原始媒体
```

队列和媒体目前不会自动清理；长期运行可在退出应用后备份并整理目录。不要在运行中编辑队列文件。

## 验证

```sh
bash scripts/test-live.sh
xcodebuild -project openmac.xcodeproj -scheme openmac -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

验证覆盖持久化恢复、去重、推送确认及重试、通知分段、原图去重、鉴权、HTTP 长度校验、multipart 二进制保真、上传落盘以及原生中文 OCR。测试推送使用模拟传输，不访问实际 Bark，不需要填写设备密钥。
