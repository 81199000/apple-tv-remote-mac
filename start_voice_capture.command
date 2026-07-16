#!/bin/zsh

set -o pipefail

PACKETLOGGER="/Users/zhanghongsheng/Applications/Developer Tools/PacketLogger.app/Contents/Resources/packetlogger"
OUTPUT="/tmp/remotastic-hci-live.txt"

echo "正在启动 Apple 蓝牙实时抓包……"
echo "请输入这台 Mac 的管理员密码后按回车（输入时不会显示字符）。"
echo "启动成功后，请按住 Siri 遥控器的麦克风键讲话。"
echo ""

echo "正在停止旧版抓包进程……"
sudo pkill -TERM -f "^${PACKETLOGGER} convert -s -f nhdr$" 2>/dev/null || true
sleep 1

echo "正在重新同步 Apple 蓝牙日志描述文件……"
sudo profiles sync -type configuration -user "$USER" >/tmp/remotastic-profile-sync.log 2>&1 || true

if [[ ! -e /tmp/remotastic-hci-traces-before.txt ]]; then
    sudo defaults read com.apple.MobileBluetooth.debug HCITraces \
        >/tmp/remotastic-hci-traces-before.txt 2>/dev/null || true
fi

echo "正在补全官方描述文件未落盘的 HCITraces 设置……"
sudo defaults write com.apple.MobileBluetooth.debug HCITraces -dict-add \
    rawAudio -bool true \
    RawAudioTrace -bool true \
    HIDTrace -bool true \
    enableHIDLogging -bool true \
    StackDebugEnabled -bool true

# On current macOS releases the developer HID switch is also consulted from a
# separate debug-settings domain.  Enabling both is necessary for long HID-over-
# GATT reports (including the remote's 101-byte Opus microphone frames) to be
# present in PacketLogger output.
sudo defaults write com.apple.MobileBluetooth.debugSettings enableHIDLogging -bool true

echo "正在通知蓝牙服务重新载入日志配置……"
sudo killall -30 bluetoothd 2>/dev/null || true
sleep 2

rm -f "$OUTPUT"
sudo "$PACKETLOGGER" convert -s -f nhdr | tee "$OUTPUT"

status=$?
echo ""
echo "抓包已结束，退出状态：$status"
echo "可以关闭此窗口。"
read -k 1
