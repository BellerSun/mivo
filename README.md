# Mivo

**把麦克风上的配对键，变成你的快捷键。**

一个 macOS 菜单栏小工具，用 DJI Mic Mini 2 触发自定义快捷键，适配不同语音输入工具。

- **按住模式**：短按一次按住目标键，再按一次松开；结束后 3 秒内再按可发送回车。
- **点按模式**：每次短按发送一次完整按键，适合单击切换的快捷键。
- **自定义按键**：预设左／右 Command、Fn（实验），也可输入或录入组合键。
- **动作一眼可见**：悬浮提示显示下一步操作，可拖动、切换迷你样式或隐藏。
- **不打断输入**：悬浮提示不抢键盘焦点，随时从菜单栏暂停控制。
- **本地按键控制**：Mivo 不录音、不上传数据，语音识别由目标应用处理。

## 安装

[下载 Apple Silicon 试用包](https://github.com/BellerSun/mivo/releases/tag/v1.0.0)（本机开发签名，未公证）。安装新版前先退出 Mivo，再将解压后的应用放入 `/Applications`。

也可从源码构建：需 macOS 13+、Xcode Command Line Tools、Python 3 和 OpenSSL / 系统 LibreSSL。

```bash
git clone https://github.com/BellerSun/mivo.git
cd mivo
./scripts/setup-signing.py
./scripts/build-and-install.sh
open /Applications/Mivo.app
```

首次配置会创建本机签名身份，后续更新请保留。工具准备、仅构建及签名说明见[开发文档](docs/development.md)。

## 开始使用

1. 通过 USB 连接 DJI Mic Mini 2 **接收器**。
2. 在 Mivo 设置中选择模拟方式和按键，并在目标应用中设置相同的快捷键。
3. 打开 Mivo 设置，开启**辅助功能**与**输入监控**。
4. 将焦点放到输入框，短按**发射器侧面的配对键**，开始说话。

「结束后再按发送」仅用于按住模式，可关闭。快捷键和回车作用于当前前台应用，使用前请确认输入焦点；Fn 需验证目标应用兼容性。

## 文档与反馈

[使用与排障](docs/usage.md) · [开发与签名](docs/development.md) · [参与贡献](CONTRIBUTING.md) · [反馈问题](https://github.com/BellerSun/mivo/issues) · [安全反馈](SECURITY.md)

## 许可证

代码、文档和自有图标采用 [MIT](LICENSE)。本项目为独立开发，与 DJI、千问无官方隶属或背书关系。
