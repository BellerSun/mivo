# Mivo B01 图标

项目自有图标，随仓库采用 [MIT License](../../LICENSE)。

B01 设计：折线 M 与麦克风一体连线，两侧末端与底座对齐。

只维护 `mivo.svg`：黑色线条、透明背景，是唯一图标源文件。

macOS 打包需要 ICNS。构建脚本自动从 SVG 生成带白色圆角底板的 App 图标，将 ICNS 和中间文件写入已被 Git 忽略的 `.build/icons/`，无需手动维护或提交。删除 `.build` 后，下次构建会自动重新生成。生成过程使用 macOS 内置工具，无第三方依赖。

需要其他格式时运行：

```bash
python3 scripts/generate-icons.py --export
```

导出的黑色、白色透明 PNG（16–1024 像素）、白色 SVG、多分辨率 ICO 和 App 图标同样位于 `.build/icons/`。

打包脚本将生成的 `Mivo.icns` 复制到应用的 `Contents/Resources/`，由 `Info.plist` 的 `CFBundleIconFile` 引用。仅图标变化也会触发重新打包。菜单栏既有状态图标保留原有状态表达。
