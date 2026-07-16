#!/bin/zsh
set -euo pipefail

PACKETLOGGER="/Users/zhanghongsheng/Applications/Developer Tools/PacketLogger.app/Contents/Resources/packetlogger"
DECODER_ZIP="/Users/zhanghongsheng/Projects/SiriRemoteVoiceDecoder/Release/SiriRemoteVoiceDecoder.zip"
OUTROOT="$HOME/Desktop/SiriRemoteVoiceProbe-$(date +%Y%m%d-%H%M%S)"
FIRST_ADDR="78:9F:70:74:38:01"      # DN9QD1WEGQQT / ProductID 0x0266 / first-gen candidate
SECOND_ADDR="60:BE:C4:30:A1:A2"     # DJ7G72MD17FC / ProductID 0x0314 / second-gen BLE candidate

mkdir -p "$OUTROOT/first-gen-0266" "$OUTROOT/second-gen-0314"
unzip -o "$DECODER_ZIP" -d "$OUTROOT/decoder" >/dev/null
chmod +x "$OUTROOT/decoder/SiriRemoteVoiceDecoder" || true

echo "Apple TV Remote 麦克风双路抓包探针"
echo "输出目录: $OUTROOT"
echo ""
echo "候选 1: 一代 DN9QD1WEGQQT  $FIRST_ADDR  ProductID 0x0266"
echo "候选 2: 二代 DJ7G72MD17FC  $SECOND_ADDR ProductID 0x0314"
echo ""
echo "启动后请分别长按两个遥控器的麦克风/Siri 键说话 3-5 秒。"
echo "结束按 Ctrl-C。成功时对应目录会出现 frames.txt / decoded.wav。"
echo ""

if [[ ! -x "$PACKETLOGGER" ]]; then
  echo "找不到 PacketLogger: $PACKETLOGGER"
  exit 2
fi

# Enable verbose bluetooth/HID traces. Harmless if keys are ignored by current macOS.
echo "需要管理员密码开启 HCI 抓包……"
sudo defaults write com.apple.MobileBluetooth.debug HCITraces -dict-add \
  rawAudio -bool true \
  RawAudioTrace -bool true \
  HIDTrace -bool true \
  enableHIDLogging -bool true \
  StackDebugEnabled -bool true || true
sudo defaults write com.apple.MobileBluetooth.debugSettings enableHIDLogging -bool true || true
sudo killall -30 bluetoothd 2>/dev/null || true
sleep 1

RAW="$OUTROOT/packetlogger-raw.txt"
echo "开始抓包。原始日志: $RAW"
echo ""

# One privileged HCI stream, decoded by two parser instances in isolated directories.
sudo "$PACKETLOGGER" convert -s -f nhdr \
  | tee "$RAW" \
  | tee >(cd "$OUTROOT/first-gen-0266" && "$OUTROOT/decoder/SiriRemoteVoiceDecoder" "$FIRST_ADDR" > decoder.log 2>&1) \
  | (cd "$OUTROOT/second-gen-0314" && "$OUTROOT/decoder/SiriRemoteVoiceDecoder" "$SECOND_ADDR" > decoder.log 2>&1)
