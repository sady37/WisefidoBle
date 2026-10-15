WisefidoBle
20250402   v1.0  完成sleepBoard scan/config,Esp scan/config/query
20251112   v1.1  重建Radar查询/配置：添加预热流程、查询管线和ESP独立Wi-Fi扫描；完善主界面状态显示与历史记录体验。
20261015   v1.2  同步 Android 版 UI/QR：主页改 STEP 1/2/3 布局；STEP 1 行加 QR 扫码按钮，扫到码后自动匹配设备（BM 开头走 Sleepace，其它走雷达；3 秒未命中用 TSBLU+后 6 位回退，10 秒超时）；Recent Servers 行加 TLS Encryption 开关（自动填 29015/29010，iOS Sleepace SDK 无 portEncrypt 参数只靠端口）；Query/Pair 无设备时置灰；雷达扫描去重缓存每次扫描清空（修二次扫描扫不到）。新增 QrScanViewController（AVFoundation），Info.plist 加 NSCameraUsageDescription。
                 


服务UUID：

是硬件设备的固有特性
对同一类型的设备来说是相同的
不同手机扫描同一设备时，获取到的服务UUID是一致的
可以用于识别设备类型


设备标识符UUID：

由iOS的CoreBluetooth框架分配
对于同一设备，不同的iOS设备会分配不同的标识符UUID
主要用于特定iOS设备上跟踪已发现的蓝牙设备



您提出的解决方案非常恰当：

将服务UUID存储在DeviceInfo的uuid字段中
将设备标识符UUID存储在DeviceInfo的uid字段中