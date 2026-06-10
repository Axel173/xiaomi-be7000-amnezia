@echo off
chcp 65001 > nul
title BE7000 - AmneziaWG (setup + manage)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0be7000.ps1" %*
