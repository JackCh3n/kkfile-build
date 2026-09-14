# 额外字体目录

把 `.ttf` / `.ttc` / `.otf` 字体文件直接放进本目录，构建时会随镜像一起安装到
`/usr/share/fonts/kkfileview-extra/` 并执行 `fc-cache`。

用途：LibreOffice 转换 Word/PPT 时依赖字体度量，缺少文档里用到的字体（尤其是
宋体/黑体/仿宋/楷体以及 Arial、Times New Roman 等西文字体）会导致排版错位或乱码。
镜像已内置文泉驿（微米黑/正黑）与 Noto CJK，覆盖绝大多数简体中文场景；若你的
文档使用特殊字体，把字体文件放这里即可。

注意：
* 请自行确认字体的授权许可，不要提交无权分发的商业字体；
* 本目录下的字体文件会进入 Docker 镜像与发行包，注意镜像体积；
* 裸机（tar.gz 离线安装）场景：把字体拷到 `/usr/share/fonts/` 后执行 `fc-cache -fv`。
