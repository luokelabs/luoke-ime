#!/bin/zsh
# 编译语音引擎：只有一个 Swift 文件，提示词和示例在同一个文件夹里，运行时按相对路径读。
set -euo pipefail
cd ${0:A:h}
export MACOSX_DEPLOYMENT_TARGET=14.0   # 同壳的最低系统版本
swiftc -O -target arm64-apple-macos$MACOSX_DEPLOYMENT_TARGET -o voice main.swift
