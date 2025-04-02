WisefidoBle
20250402   v1.0  完成sleepBoard scan/config,Esp scan/config/query
                 


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