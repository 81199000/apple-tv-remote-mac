# Apple TV 遥控器，控制 Mac 电脑

![许可证](https://img.shields.io/badge/许可证-MIT-yellow.svg)

![遥控器助手图标](RemotasticIcon.png)

这是一个 macOS 菜单栏应用，可以把第一代 Apple TV Siri Remote（型号 A1513）变成无线触控板、鼠标和键盘遥控器，用遥控器控制 Mac 电脑。

## 支持的遥控器

主要支持第一代 Apple TV 遥控器（A1513）。程序通过蓝牙读取遥控器的按键和触控板数据，并将其转换为 macOS 鼠标、键盘及媒体控制事件。其他型号可能可用，但目前未经过完整测试。

## 功能

- 触控板控制鼠标移动、点击、拖动和双指滚动
- 类似苹果触控板的动态指针加速：慢速移动便于精准定位，快速移动可迅速跨屏
- 播放／暂停、音量、菜单、TV、Siri 等按键自定义映射
- 支持录制单键、右 Command 等修饰键，以及 Command／Option／Control／Shift 组合键
- 按键音效开关
- 触控板鼠标速度调节
- 开机自启动开关
- 多显示器支持
- 中文菜单栏界面和连接状态显示

## 编译和运行

需要 macOS 11 或更高版本，以及 Xcode Command Line Tools：

```bash
xcode-select --install
git clone https://github.com/lauschue/Remotastic.git
cd Remotastic
./build.sh
./create_app_bundle.sh
open "遥控器助手.app"
```

首次运行请在“系统设置 → 隐私与安全性”中授予“辅助功能”和“输入监控”权限。

## 配对遥控器

在遥控器上同时按住“菜单键”和“音量加键”约 5 秒，然后在 macOS“系统设置 → 蓝牙”中完成配对。

## 设置

点击菜单栏中的遥控器图标，可以打开“按键映射”和“设置”：

- **按键音效**：开启或关闭按键提示音
- **触控板鼠标速度**：慢／中／快三档总体速度
- **开机自启动**：控制登录 macOS 后是否自动启动

按键录制会等待整组按键全部松开后再保存，因此可以正确识别组合键。

## 注意事项

- 程序使用 macOS 私有的 MultitouchSupport 接口，不能提交到 Mac App Store。
- 需要辅助功能权限才能发送鼠标和键盘事件。
- 遥控器长时间没有操作时可能断开，按任意遥控器按键即可触发重连。
- 语音麦克风数据受第一代遥控器蓝牙协议限制，当前版本不承诺语音输入功能。

## 许可证

本项目使用 MIT 许可证，详见 [LICENSE](LICENSE)。
