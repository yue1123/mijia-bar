# MijiaBar

菜单栏里控制米家 Wi-Fi 设备：手动开关，电脑睡眠 / 息屏时自动关、唤醒 / 亮屏时自动开，天黑后打开电脑自动开灯、天黑时提醒开灯。控制走局域网 miio 协议，不经过小米云。

## 构建

```bash
./build.sh                       # 产物在 build/MijiaBar.app
cp -R build/MijiaBar.app /Applications/
```

## 添加设备

设置窗口侧栏底部点「导入」，用米家 App 扫码登录，勾选设备。IP、token、开关属性（按型号查 miot-spec）自动填好，
token 直接进钥匙串，不落地文件。设备重置过、token 变了，再扫一次导入即可，已有的设备只更新 IP 和 token。

## 命令行

调试设备用，和 App 共用同一套协议实现：

```bash
swift run miio <ip> <token> info
swift run miio <ip> <token> get 2 1
swift run miio <ip> <token> set 2 1 on
```

## 说明

- 扫码登录和设备列表接口照 [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)（MIT）的扫码流程重写（`MiCloud.swift`），非官方接口，只查中国大陆服务器。登录状态不保存。
- 开关属性取型号 spec 里 siid 最小的那个可写布尔 `on`（插座是主开关而不是指示灯）。不对的话在设置里手改，可以对照 [home.miot-spec.com](https://home.miot-spec.com)。
- 只支持有 IP 的 Wi-Fi 设备；蓝牙、Zigbee 子设备不行。
- 睡眠：IOKit 的 `kIOMessageSystemWillSleep`，命令发完才放行（系统最多等 30 秒）。
  唤醒：`NSWorkspace.didWakeNotification`，失败每 2 秒重试，最多 15 次。
  息屏 / 亮屏：`screensDidSleepNotification` / `screensDidWakeNotification`，按设备选触发时机。
- 夜间：按本机时间设天黑 / 天亮（默认 18:00–07:00）。天黑后唤醒 / 亮屏 / 解锁（按触发时机）或开机（需打开「登录时启动」，开机 10 分钟内）时直接开灯，白天不开；
  到天黑那一刻电脑在用（没息屏、没锁屏）、灯关着，发系统通知，点通知开灯。每分钟检查一次，中间睡过就不提醒，交给唤醒处理。
- 日志：`log stream --predicate 'subsystem == "me.dh.mijia-bar"'`
- 有 Apple Development 证书时用它签名，钥匙串的「始终允许」重新构建后仍然有效；没有证书退回 ad-hoc，每次重新构建都要重新授权。
