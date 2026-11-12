# 久坐提醒 SitReminder

[English](README.en.md) | 简体中文

一个 macOS 菜单栏小工具。每坐满设定时间，它会在所有屏幕上弹出全屏提醒，要求你离开电脑走动一会儿。

![设置面板](docs/panel.png)

截图用于展示布局，实际毛玻璃效果随桌面背景和系统设置变化。

## 功能

- **四种界面语言**：简体中文、English、繁體中文、日本語。默认跟随系统，点击面板底部的地球图标可即时切换并记住选择；切换语言不重置计时。系统首选语言无匹配项时使用英文。
- **毛玻璃控制面板**：自动适配浅色和深色，时长居中补齐，快捷间隔等宽排列；开启系统「减少透明度」时改用实色背景。
- **全屏强制休息**：时间到后，所有显示器同时显示全屏遮挡。插拔显示器时自动重建遮挡。
- **轻柔休息动画**：毛玻璃背景配合约 6 秒一轮的呼吸光晕，可单独暂停动画，不改变休息倒计时；遵循系统「减少动态效果」。
- **必须离开电脑**：休息倒计时只在不碰键盘和鼠标时进行。一碰键鼠，计时就暂停。
- **推迟与跳过**：每次提醒可以推迟一次。紧急情况点两次「紧急跳过」退出。
- **安全预览**：预览时可单击「结束预览」或按 Esc 退出；正式休息仍保留两次确认跳过。
- **自动识别离开**：锁屏和合盖时停止计时。离开或锁屏超过设定时长，回来后从头计时。
- **开机自启**：首次启动时自动开启，可以在面板里关闭。
- **事件日志**：日志写在 `~/Library/Logs/SitReminder.log`，面板里点「查看日志」即可打开。

![全屏提醒](docs/overlay.png)

## 安装

1. 打开 [Releases 页面](https://github.com/liyan527/SitReminder/releases/latest)，下载 `SitReminder-<版本>.dmg`。
2. 双击打开 DMG，把 `SitReminder` 拖到旁边的「Applications」文件夹，然后在「应用程序」里双击打开。
   也可以下载 `SitReminder-<版本>.zip`，解压后把 `SitReminder.app` 拖到「应用程序」。
3. 如果系统提示「无法验证开发者」，按下面任一方式处理：
   - 打开「系统设置 > 隐私与安全性」，在底部点「仍要打开」。
   - 在终端运行 `xattr -dr com.apple.quarantine /Applications/SitReminder.app`，然后重新打开。
4. 启动后，菜单栏右上角会出现一个站立小人图标和倒计时。点击图标即可设置。

出现这个提示，是因为应用只做了本机签名（ad-hoc），没有经过 Apple 公证。

系统要求：macOS 13 或更高版本，支持 Apple 芯片和 Intel 芯片。

## 卸载

1. 点菜单栏图标，在面板里关掉「开机自动启动」。
2. 点面板底部的「退出久坐提醒」。
3. 把「应用程序」里的 `SitReminder.app` 移到废纸篓。

## 从源码构建

只需要 Xcode 命令行工具（`xcode-select --install`），不需要完整的 Xcode。

```sh
./build.sh            # 编译通用版本到 build/SitReminder.app
./build.sh --install  # 编译后安装到 ~/Applications 并启动
./build.sh --zip      # 编译后生成 dist/SitReminder-<版本>.zip
./build.sh --dmg      # 编译后生成 dist/SitReminder-<版本>.dmg
./build.sh --release  # 同时生成 zip 和 dmg
```

## 文件

| 文件 | 说明 |
|---|---|
| `Sources/SitReminder.swift` | 应用界面和提醒逻辑（SwiftUI + AppKit） |
| `Sources/Localization.swift` | 四语文案、语言匹配和独立语言偏好 |
| `Resources/*.lproj/` | 系统显示的本地化应用名称 |
| `Info.plist` | 应用配置：菜单栏应用，不显示 Dock 图标 |
| `make_icon.swift` | 生成应用图标 |
| `build.sh` | 编译、签名和打包 |
| `docs/` | README 使用的截图 |
