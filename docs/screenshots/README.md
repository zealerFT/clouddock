# App screenshots / 应用截图

These are actual CloudDock captures on macOS, supplied by the maintainer. The app interface is Simplified Chinese; both README languages use the same images. They document the interface at capture time and are not version-specific screenshots of the latest release.

以下图片来自维护者提供的 macOS 实际应用截图。界面为简体中文，中英文 README 共用同一组图片。截图展示拍摄时的界面，不代表最新发布版本。

| Image / 图片 | View / 页面 | Capture date / 截图日期 | Source version / 原图版本 |
| --- | --- | --- | --- |
| [workspace.png](workspace.png) | File workspace / 文件工作台 | 2026-11-02 | 0.5.5 |
| [connection-settings.png](connection-settings.png) | New Connection / 新建连接 | 2026-11-03 | 0.5.7 |
| [share-download.png](share-download.png) | Share Download / 分享下载 | 2026-11-03 | 0.5.7 |
| [operation-history.png](operation-history.png) | Operation History / 操作审计 | 2026-11-03 | 0.5.7 |

## Publication edits / 发布处理

- **Workspace:** cropped to the file browser, above the transfer panel. Private connection and favorite names are covered.
- **Connection settings:** cropped to the dialog. Credential fields are empty; the endpoint is an example placeholder.
- **Share downloads:** cropped to the dialog. The complete signed URL and QR code are covered with explicit redaction labels. Expiry controls and copy/save actions are retained.
- **Operation history:** private connection and favorite names, a private bucket path, and local filesystem paths are covered. Original operation types, timestamps, and success/failure results are retained.
- All images were converted to sRGB and saved without embedded EXIF, XMP, or other image metadata. Published images were reviewed visually and checked with OCR. Original captures are retained privately and are not part of the repository.

- **文件工作台：**裁剪至文件浏览区域，保留传输面板上方内容；遮挡私人连接名称和收藏名称。
- **连接配置：**裁剪至弹窗；凭据输入框为空，Endpoint 为示例占位内容。
- **分享下载：**裁剪至弹窗；完整遮挡签名地址与二维码，并明确标注；保留有效期设置和复制、保存操作。
- **操作审计：**遮挡私人连接名称、收藏名称、私人存储桶路径和本机文件路径；保留原有操作类型、时间及成功或失败结果。
- 全部图片转换为 sRGB 后重新保存，移除 EXIF、XMP 等元数据，并经过目视检查与 OCR 检查。原始截图保留在本地私有备份中，不进入仓库。

The workspace shows a local fake-gcs-server connection. Emulator screenshots do not establish hosted-cloud authentication or permission compatibility.

文件工作台展示的是本地 fake-gcs-server 连接。模拟器截图不能证明真实云服务的鉴权或权限兼容性。
