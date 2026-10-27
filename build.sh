#!/bin/bash
# 编译并打包成 build/MijiaBar.app
#
# 有 Apple Development 证书就用它签：钥匙串的「始终允许」认的是签名的指定要求，
# ad-hoc 签名的指定要求是这次产物的 cdhash，每次编译都变，钥匙串就会重新要密码；
# 证书签名的指定要求是「Bundle ID + 证书」，重新编译不变。没有证书时退回 ad-hoc。
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
app=build/MijiaBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/MijiaBar "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')
codesign --force --sign "${identity:--}" "$app"
echo "$app"
