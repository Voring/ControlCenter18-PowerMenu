# C18 Power Menu

给 **ControlCenter18** 的控制中心右上角电源按钮换一套行为：点一下不再直接进入关机，而是弹出一个原生 `UIAlertController` 菜单。

| 菜单项 | 实际动作 |
| --- | --- |
| 注销 | `killall -9 SpringBoard` |
| 重启 | `reboot` |
| 关机 | 调用系统原本的关机滑条（安全、可取消） |
| 安全模式 | `killall -SEGV SpringBoard` |
| 软重启设备 | `ldrestart` |
| 重启用户空间 | `launchctl reboot userspace` |

## 环境要求

- 隐根（roothide）Dopamine 越狱
- iOS 16.0 – 17.x，arm64e 设备（iPhone）
- 已安装 [ControlCenter18](https://repo.ya-ebal.mom)（`com.evgeniy558.controlcenter18`）
- bootstrap 内存在 `/usr/bin/killall`、`/usr/bin/ldrestart`、`/usr/bin/launchctl`、`/usr/bin/reboot`

本插件不修改 ControlCenter18 的任何文件，也不改动任何系统二进制；它只是一个独立的 SpringBoard tweak，运行时 hook 电源按钮最终调用的
`-presentPowerDownTransientOverlay` 方法，所以不会和 CC18 的二进制更新打架。

## 安装

从 Release / `dist/` 下载 deb，用 Sileo / Filza 安装，然后 respring。

安装后不需要任何设置。卸载后立即恢复原版关机行为。

## 从源码编译

arm64e 必须用 macOS 的 Xcode 工具链（Linux 的 lld 不支持 arm64e 的 authenticated pointer relocation）：

```bash
export THEOS=/path/to/theos
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless ARCHS=arm64e
```

本仓库的 GitHub Actions 会自动在 macOS runner 上构建，并把 deb 提交到 `dist/`。

## 实现要点

- hook 目标不是硬编码类名：启动时遍历 `objc_getClassList`，找到真正实现 `presentPowerDownTransientOverlay` 的类（CC18 内部调用的是
  `SBLockScreenManager` 的该方法），再用 `method_setImplementation` 接管，原 IMP 保留用于“关机”。
- 菜单从当前最顶层的 ViewController 弹出；若 SpringBoard 没有可用的 root VC，则临时创建一个 `UIWindowLevelAlert + 1` 的窗口承载，
  避免“没有 window 可 present”的崩溃。
- 所有 hook 体都包在 `@try/@catch` 中，异常时回落到原方法，不会因为菜单出错把 SpringBoard 打死。
- 路径解析不依赖 `libroothide`：通过 `dladdr` 拿到自身 dylib 路径，向上截到 `/Library/MobileSubstrate/DynamicLibraries/` 之前，
  得到真实的 jbroot，再拼 `/usr/bin/...`。因此隐根随机路径也能正确执行命令。

## 已知边界

- 硬件电源键长按如果也走同一个方法，同样会弹出这个菜单；这是“全局替换关机入口”的预期行为。
- “重启”用的是 bootstrap 的 `reboot`；个别精简 bootstrap 若没有该命令，可用“重启用户空间”替代。
- 本插件只改变入口，不改变关机滑条本身。

## License

MIT
