# doc-reader（买家文档解析组件）

将买家发送的文档转为可注入 LLM 的文本或渲染图：

| 输入 | 输出 |
|---|---|
| 文本型 PDF（文本层 >100 字符） | `kind=pdf-text` + 文本 |
| 扫描件 PDF（文本层不足） | `kind=pdf-scan` + 前 2 页 PNG data URL（走视觉） |
| Excel / CSV | `kind=xlsx` / `kind=csv` + 前 2 sheet / 原文文本 |
| Word docx | `kind=docx` + raw text |
| 其他 | `{"ok":false,"error":"unsupported"}` |

## 用法

```powershell
node read.js <filePath> [--max-chars 6000] [--render-max-pages 2]
```

stdout 输出单行 JSON：

```json
{"ok":true,"kind":"pdf-scan","text":"","images":["data:image/png;base64,..."],"meta":{"pages":1,"rendered":1}}
```

## 实现说明

- PDF 引擎：`@hyzyla/pdfium`（PDFium WASM，MIT 包装）——**不用** pdfjs + native canvas：实测 pdfjs-dist + @napi-rs/canvas 渲染带图片的 PDF 在 Windows/Node 24 下会原生崩溃（0xC0000005 / heap corruption）
- 渲染：pdfium pixmap → `@napi-rs/canvas` 编码 PNG（仅编码，不涉图片解码）
- 解析：xlsx（SheetJS）/ mammoth（docx）
- 零外部服务依赖；测试 `node --test tests/read.test.js`（fixtures 运行时生成，含 image-only PDF 渲染断言）

## 测试

```powershell
node --test tests/read.test.js
```
