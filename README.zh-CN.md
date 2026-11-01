# Battery Hog 简体中文版

Battery Hog 是适用于 Apple 芯片 Mac 的免费开源电池监测工具，提供实时整机功耗、电池历史、应用资源占用、开发负载和耗电建议。项目采用 [MIT 许可证](LICENSE)。

界面支持简体中文和英文；覆盖仪表盘六个页面、图表、菜单栏、通知及操作提示。应用跟随 macOS 语言设置，也可在“系统设置 → 通用 → 语言与地区 → 应用程序”中单独指定语言，修改后重新启动应用。其他语言默认显示英文；应用名、项目名、命令和系统原始诊断文本保留原样。

需要 Apple 芯片 Mac、macOS 11 或更高版本，以及 Xcode 命令行工具。构建预览不会安装到“应用程序”目录：

```bash
git clone https://github.com/luke-fairbanks/BatteryHog.git
cd BatteryHog
SKIP_DMG=1 bash src/package.sh
open "dist/Battery Hog.app"
```

`src/build.sh` 会构建并替换 `/Applications/Battery Hog.app`；仅查看或测试时可使用上面的打包命令。本地构建采用临时签名，未经过 Apple 公证。

翻译维护、语言扩展和测试说明见 [国际化开发文档](docs/localization.md)。功能、数据来源与隐私说明见 [英文 README](README.md)。
