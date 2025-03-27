WisefidoBle

SDK 层创建 CBCentralManager:

RadarBleManager 和 SleepaceBleManager 在内部创建各自的 CBCentralManager 实例
执行扫描操作后，将这些实例向上返回给调用者


ScanViewController 使用 SDK 返回的实例:

ScanViewController 不自己创建 CBCentralManager
它调用 SDK 的扫描方法，获取 SDK 创建并返回的 CBCentralManager 实例
使用这个返回的实例进行后续操作


MainViewController 同样使用 SDK 返回的实例:

从 ScanViewController 获取 SDK 返回的 CBCentralManager 实例
用于查询、连接等操作


CBCentralManager 实例的生命周期:

SDK 扫描前会关闭之前可能存在的实例
创建新的实例用于扫描
扫描完成后返回给上层使用
上层代码负责在适当时机释放这些实例

CBPeripheral *peripheral = peripheralInfo.peripheral;
NSString *name = peripheralInfo.name ?: peripheral.name ?: @"Unknown";

NSString *uuid = peripheral.identifier.UUIDString;

SLPLOG(@"SDK扫描结果 - peripheralInfo: %@, 
peripheral: %@, name: %@, UUID: %@, model: %@", peripheralInfo, peripheral, name, uuid, deviceModel);
SLPLOG(@"SDK扫描结果 - peripheralInfo: %@, peripheral: %@, name: %@, UUID: %@", peripheralInfo, peripheral, name, uuid);

[SleepaceBleManager]   - deviceType: 0
[SleepaceBleManager]   - SDK解析的设备名称: (null)

[SleepaceBleManager] SDK扫描结果 - 
peripheralInfo: <SLPPeripheralInfo: 0x300f6ebc0>,
peripheral: <CBPeripheral: 0x3034d0820, 
identifier = 28080FBD-A986-AA9E-699D-3316422A0470, 
peripheral.name = bm8701-2-ble, mtu = 0,
state = disconnected>, 
peripheralInfo.name: BM87224601903, 
UUID: 28080FBD-A986-AA9E-699D-3316422A0470

你的日志来看，确实出现了两个 name：

peripheral.name（来自 CBPeripheral）：日志显示 name = bm8701-2-ble
这是设备广播的原始名称（Bluetooth Advertising Name）。
peripheralInfo.name（来自 SLPPeripheralInfo）：日志显示 name: BM87224601903
这可能是 SDK 或业务层自定义的名称（比如从服务端获取的别名，或解析广播数据得到的名称）。
原因分析：

peripheral.name 是 iOS CBPeripheral 提供的默认名称，通常来自设备的广播数据（Advertising Data）。
peripheralInfo.name 可能是 SDK（如 SleepaceBleManager）额外存储的名称，可能是：
从设备的 GATT Service 读取的（比如 Device Information Service 里的 Firmware Name）。
从服务器或本地数据库匹配的别名（比如用户自定义名称）。
解析广播数据（Manufacturer Specific Data）得到的更友好的名称。

@property (nonatomic, copy) NSString *deviceName;           // 设备名称 peripheralInfo.name（来自 SLPPeripheralInfo）：: BM87224601903

@property (nonatomic, assign) NSInteger sleepaceDeviceType;   // Sleepace设备类型 peripheral.name=bm8701-2-ble

deviceInfo.deviceName = peripheralInfo.name
deviceInfo.sleepaceDeviceType = peripheral.name

