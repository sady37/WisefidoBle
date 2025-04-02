//
//  ScanViewController.m
//

#import "ScanViewController.h"
#import "RadarBleManager.h"
#import "SleepaceBleManager.h"
#import "ConfigStorage.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import "ConfigViewController.h"
#import "ConfigModels.h"


// 日志宏定义
#define SCANLOG(fmt, ...) NSLog((@"[ScanViewController] " fmt), ##__VA_ARGS__)
// 扫描超时常量定义
#define RADAR_SCAN_TIMEOUT     6.0  // 雷达设备扫描超时时间（秒）
#define SLEEPACE_SCAN_TIMEOUT  4.0  // Radar设备扫描超时时间（秒）
#define RSSI_SCAN_TIMEOUT      6.0  // RSSI扫描超时时间（秒）

#pragma mark - DeviceTableViewCell 声明

// 设备单元格类 - 用于展示设备信息
@interface DeviceTableViewCell : UITableViewCell

@property (nonatomic, strong) UILabel *deviceNameLabel;        // 设备名称标签
@property (nonatomic, strong) UILabel *macAddressLabel;        // MAC地址标签
@property (nonatomic, strong) UILabel *rssiLabel;              // 信号强度标签
@property (nonatomic, strong) UIView *signalIndicatorView;     // 信号强度指示器

- (void)configure:(DeviceInfo *)device;

@end

#pragma mark - ScanViewController 私有接口

@interface ScanViewController () <CBPeripheralDelegate>

// UI 组件
@property (nonatomic, strong) UITableView *tableView; //显示设备列表
//@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) UITextField *filterTextField;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *configButton;          
@property (nonatomic, strong) UILabel *filterLabel;            

// 数据
@property (nonatomic, strong) NSMutableArray<DeviceInfo *> *deviceList;
@property (nonatomic, assign) Productor currentScanModule;
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, strong) ConfigStorage *configStorage;
@property (nonatomic, assign) FilterType currentFilterType;
@property (nonatomic, copy) NSString *currentFilterPrefix;
@property (nonatomic, strong) CBCentralManager *cbManager;// iOS 蓝牙管理器用于RSSI更新
@property (nonatomic, assign) BOOL isRssiScanning; // 标记是否正在进行RSSI扫描
@property (nonatomic, strong) NSTimer *radarScanTimer; // Radar扫描定时器
@property (nonatomic, strong) NSTimer *sleepaceScanTimer; // Sleepace扫描定时器
@property (nonatomic, strong) NSTimer *rssiScanTimer; // RSSI扫描定时器
@property (nonatomic, weak) DeviceInfo *currentScanningDevice; // 添加这行
@end



#pragma mark - DeviceTableViewCell 实现

@implementation DeviceTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        // 初始化设备名称标签
        _deviceNameLabel = [[UILabel alloc] init];
        _deviceNameLabel.font = [UIFont boldSystemFontOfSize:16];
        [self.contentView addSubview:_deviceNameLabel];
        
        // 初始化MAC地址标签
        _macAddressLabel = [[UILabel alloc] init];
        _macAddressLabel.font = [UIFont systemFontOfSize:14];
        //_macAddressLabel.textColor = [UIColor darkGrayColor];
        [self.contentView addSubview:_macAddressLabel];
        
        // 初始化信号强度指示器
        _signalIndicatorView = [[UIView alloc] init];
        _signalIndicatorView.layer.cornerRadius = 4;
        _signalIndicatorView.clipsToBounds = YES;
        [self.contentView addSubview:_signalIndicatorView];
        
        // 初始化RSSI标签
        _rssiLabel = [[UILabel alloc] init];
        _rssiLabel.font = [UIFont systemFontOfSize:14];
        _rssiLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_rssiLabel];
        
        // 设置约束
        [self setupConstraints];
    }
    return self;
}

- (void)setupConstraints {
    // 禁用自动转换约束
    _deviceNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _macAddressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _signalIndicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    _rssiLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // 1. deviceNameLabel (左对齐，自适应宽度)
    [_deviceNameLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [_deviceNameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [_deviceNameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_deviceNameLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.contentView.widthAnchor multiplier:0.4],
        [_deviceNameLabel.widthAnchor constraintGreaterThanOrEqualToConstant:80]
    ]];

    // 2. rssiLabel (右对齐，固定宽度)
    [_rssiLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [_rssiLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_rssiLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_rssiLabel.widthAnchor constraintGreaterThanOrEqualToConstant:50]
    ]];

    // 3. signalIndicatorView (紧贴rssiLabel左侧)
    [NSLayoutConstraint activateConstraints:@[
        [_signalIndicatorView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_signalIndicatorView.trailingAnchor constraintEqualToAnchor:_rssiLabel.leadingAnchor constant:-4],
        [_signalIndicatorView.widthAnchor constraintEqualToConstant:8],
        [_signalIndicatorView.heightAnchor constraintEqualToConstant:8]
    ]];

    // 4. macAddressLabel (居中，占用剩余空间)
    _macAddressLabel.textAlignment = NSTextAlignmentCenter;
    [NSLayoutConstraint activateConstraints:@[
        [_macAddressLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_macAddressLabel.leadingAnchor constraintEqualToAnchor:_deviceNameLabel.trailingAnchor constant:8],
        [_macAddressLabel.trailingAnchor constraintEqualToAnchor:_signalIndicatorView.leadingAnchor constant:-8]
    ]];
}

- (void)configure:(DeviceInfo *)device {
    _deviceNameLabel.text = device.deviceName;
    _macAddressLabel.text = device.deviceType ?: device.macAddress ?: @"Unknown";
    _rssiLabel.text = [NSString stringWithFormat:@"%ld dBm", (long)device.rssi]; // Explicit cast to 'long'
    
    // 根据RSSI值设置信号强度指示器颜色
    if (device.rssi > -70) {
        _signalIndicatorView.backgroundColor = [UIColor systemGreenColor]; // 强信号
    } else if (device.rssi > -85) {
        _signalIndicatorView.backgroundColor = [UIColor systemYellowColor]; // 中等信号
    } else {
        _signalIndicatorView.backgroundColor = [UIColor systemRedColor]; // 弱信号
    }
}

@end

#pragma mark - ScanViewController 实现

@implementation ScanViewController

#pragma mark - 初始化方法
- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceList = [NSMutableArray array];
        _configStorage = [[ConfigStorage alloc] init];
        _currentScanModule = ProductorRadarQL; // 默认使用雷达模块
        _isScanning = NO;
        _currentFilterType = FilterTypeDeviceName; // 初始化为默认值
    }
    return self;
}

#pragma mark - 生命周期方法

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Scan Devices";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    // 初始化UI组件
    [self setupViews];
    [self setupConstraints];
    [self setupActions];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
[self.view addGestureRecognizer:tap];

    
	// 初始化设置
    _currentScanModule = ProductorRadarQL; // 默认选择Radar模式
    _currentFilterType = FilterTypeDeviceName; // Radar模式下默认使用设备名称过滤
    
	// 检查蓝牙权限
    //[self checkBluetoothPermissions];


    // 更新UI显示
    [self updateFilterHint];
	[self updateScanButtonState]; // 初始化扫描按钮状态为未扫描
	[self.segmentedControl setSelectedSegmentIndex:0]; // 默认选择第一个分段
	[self.tableView reloadData]; // 确保表格视图加载完成    
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 视图即将出现时可以添加额外逻辑
          // 确保状态正确初始化
      _isScanning = NO;
      [self updateScanButtonState];

      // 强制重置 SleepaceBleManager 的状态
      if (_currentScanModule == ProductorSleepBoardHS) {
          SleepaceBleManager *manager = [SleepaceBleManager getInstance:self];
          // 调用一个简单的方法来确保状态重置
          [manager stopScan];
      }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 视图即将消失时停止扫描
    [self stopScan];
}

// 添加懒加载方法
- (CBCentralManager *)cbManager {
    if (!_cbManager) {
        SCANLOG(@"Delay init CBCentralManager (only when need)");
        
        // 使用专用队列而非主队列，避免阻塞UI
        dispatch_queue_t queue = dispatch_queue_create("com.app.bleQueue", DISPATCH_QUEUE_SERIAL);
        
        NSDictionary *options = @{
            CBCentralManagerOptionShowPowerAlertKey: @NO,  // 不显示系统蓝牙提示
        };
        
        _cbManager = [[CBCentralManager alloc] initWithDelegate:self 
                                                        queue:queue 
                                                    options:options];
    }
    return _cbManager;
}

- (void)dealloc {
    // 确保停止扫描
    [self stopScan];
    
    // 清理资源
    _cbManager.delegate = nil;
    _cbManager = nil;
    
    _deviceList = nil;
    _configStorage = nil;
}

#pragma mark - UI 设置

- (void)setupViews {
// 初始化返回按钮
    _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        [_backButton setImage:[UIImage systemImageNamed:@"arrow.left"] forState:UIControlStateNormal];
    } else {
        [_backButton setTitle:@"<" forState:UIControlStateNormal];
    }

    [_backButton addTarget:self action:@selector(dismissViewController) forControlEvents:UIControlEventTouchUpInside];
    _backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_backButton];


    // 初始化配置按钮
    _configButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        [_configButton setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
    } else {
        [_configButton setTitle:@"⚙️" forState:UIControlStateNormal];
    }
    [_configButton addTarget:self action:@selector(showConfigDialog) forControlEvents:UIControlEventTouchUpInside];
    _configButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_configButton];
    
    // 初始化分段控制器
    _segmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Radar", @"SleepBoard", @"Filter"]];
    _segmentedControl.selectedSegmentIndex = 0;
	if (@available(iOS 13.0, *)) {
	    _segmentedControl.backgroundColor = [UIColor systemBackgroundColor];
	    _segmentedControl.selectedSegmentTintColor = [UIColor systemBlueColor];
	    [_segmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor labelColor]} forState:UIControlStateSelected];
	    [_segmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor labelColor]} forState:UIControlStateNormal];
	}
    [self.view addSubview:_segmentedControl];

	// 初始化过滤标签
	_filterLabel = [[UILabel alloc] init];
	_filterLabel.text = @"FilterDeviceName";
	_filterLabel.font = [UIFont systemFontOfSize:14];
	[self.view addSubview:_filterLabel];
    
    // 初始化过滤文本框
    _filterTextField = [[UITextField alloc] init];
    _filterTextField.placeholder = @"Filter by name, ID, MAC...";
    _filterTextField.borderStyle = UITextBorderStyleRoundedRect;
    _filterTextField.returnKeyType = UIReturnKeySearch;
    _filterTextField.delegate = self;
    [self.view addSubview:_filterTextField];
    
    // 初始化扫描按钮
    _scanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_scanButton setTitle:@"Scan" forState:UIControlStateNormal];
    [_scanButton setTitle:@"Stop" forState:UIControlStateSelected];
	[_scanButton setTitleColor:[UIColor systemBackgroundColor] forState:UIControlStateNormal];
    _scanButton.backgroundColor = [UIColor systemBlueColor];
    _scanButton.layer.cornerRadius = 5.0;
    [self.view addSubview:_scanButton];
  
    // 初始化表格视图
    _tableView = [[UITableView alloc] init];
    [_tableView registerClass:[DeviceTableViewCell class] forCellReuseIdentifier:@"DeviceCell"];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.rowHeight = 50; // 不需要显示历史记录70/50
    _tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    [self.view addSubview:_tableView];

	// 更新过滤提示信息
	[self updateFilterHint];
}

- (void)setupConstraints {
    // 禁用自动转换约束
    _segmentedControl.translatesAutoresizingMaskIntoConstraints = NO;
	_filterLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _filterTextField.translatesAutoresizingMaskIntoConstraints = NO;
    _scanButton.translatesAutoresizingMaskIntoConstraints = NO;
	_configButton.translatesAutoresizingMaskIntoConstraints = NO;
 	_tableView.translatesAutoresizingMaskIntoConstraints = NO;

	// 设置返回按钮的约束
	[NSLayoutConstraint activateConstraints:@[
	    [_backButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20], // 距离左边 20 点
	    [_backButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:0], // 距离顶部 10 点
	    [_backButton.widthAnchor constraintEqualToConstant:44], // 宽度设为 44
	    [_backButton.heightAnchor constraintEqualToConstant:44] // 高度设为 44
	]];

    // 设置配置按钮的约束
    [NSLayoutConstraint activateConstraints:@[
        [_configButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20], // 距离右边 20 点
        [_configButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:0], // 距离顶部 20 点
        [_configButton.widthAnchor constraintEqualToConstant:44], // 宽度设为 60
        [_configButton.heightAnchor constraintEqualToConstant:44] // 高度设为 60
    ]];

    // 设置分段控制器约束
    [NSLayoutConstraint activateConstraints:@[
		[_segmentedControl.topAnchor constraintEqualToAnchor:_backButton.bottomAnchor constant:5], // 距离 backButton 底部 20 点
        [_segmentedControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:70],//头边距
        [_segmentedControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-70],//尾边距
    ]];
	    
	// 设置过滤标签约束 - 与文本框同行
	[NSLayoutConstraint activateConstraints:@[
	    [_filterLabel.topAnchor constraintEqualToAnchor:_segmentedControl.bottomAnchor constant:16],
	    [_filterLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
   		//[_filterLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_filterTextField.leadingAnchor constant:-8], // 自适应宽度
    	[_filterLabel.centerYAnchor constraintEqualToAnchor:_filterTextField.centerYAnchor],
		// 宽度约束
        [_filterLabel.widthAnchor constraintGreaterThanOrEqualToConstant:40], // 最小宽度40
        //[_filterLabel.widthAnchor constraintLessThanOrEqualToConstant:180]    // 最大宽度180
	]];

	// 设置过滤文本框约束（最小100，弹性填充）
	[NSLayoutConstraint activateConstraints:@[
	    [_filterTextField.topAnchor constraintEqualToAnchor:_segmentedControl.bottomAnchor constant:16],
	    [_filterTextField.leadingAnchor constraintEqualToAnchor:_filterLabel.trailingAnchor constant:8],
	    [_filterTextField.trailingAnchor constraintEqualToAnchor:_scanButton.leadingAnchor constant:-8],
		[_filterLabel.centerYAnchor constraintEqualToAnchor:_filterTextField.centerYAnchor],
		        // 宽度约束
        [_filterTextField.widthAnchor constraintGreaterThanOrEqualToConstant:100] // 最小宽度100
	]];
	    
    // 设置扫描按钮约束
    [NSLayoutConstraint activateConstraints:@[
        [_scanButton.centerYAnchor constraintEqualToAnchor:_filterTextField.centerYAnchor],
        [_scanButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_scanButton.widthAnchor constraintEqualToConstant:60]
    ]];
    
    // 设置表格视图约束
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:_filterTextField.bottomAnchor constant:16],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];

}

- (void)setupActions {
    // 设置扫描按钮动作
    [_scanButton addTarget:self action:@selector(toggleScan) forControlEvents:UIControlEventTouchUpInside];

	    // 设置配置按钮动作
    [_configButton addTarget:self action:@selector(showConfigDialog) forControlEvents:UIControlEventTouchUpInside];
    
   
    // 设置分段控制器动作
    [_segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
}


#pragma mark - 扫描控制

- (void)toggleScan {
    // 添加静态变量记录上次点击时间
    static NSTimeInterval lastToggleTime = 0;
    NSTimeInterval currentTime = [NSDate date].timeIntervalSince1970;
    
    // 如果间隔小于0.5秒，忽略此次操作
    if (currentTime - lastToggleTime < 0.5) {
        SCANLOG(@"Ignoring scan toggle - too soon after last operation");
        return;
    }
    
    // 更新上次点击时间
    lastToggleTime = currentTime;
    
    // 原有逻辑
    if (_isScanning) {
        [self stopScan];
    } else {
        [self startScan];
    }
}

- (void)updateScanButtonState {
    // 确保在主线程执行UI更新
    dispatch_async(dispatch_get_main_queue(), ^{
        // 按钮应该反映当前的扫描状态
        [self.scanButton setTitle:(self->_isScanning ? @"STOP" : @"SCAN") forState:UIControlStateNormal];
        self.scanButton.backgroundColor = self->_isScanning ? [UIColor systemRedColor] : [UIColor systemBlueColor];
        
        // 确保按钮状态立即更新
        [self.scanButton layoutIfNeeded];
        
        SCANLOG(@"Button state updated to reflect isScanning=%d", self->_isScanning);
    });
}

- (void)startScan {
    SCANLOG(@"Starting scan with filter prefix:"); 
    // 根据当前选择的模块获取正确的过滤前缀
    switch (_currentScanModule) {
        case ProductorRadarQL:
            _currentFilterPrefix = [_configStorage getRadarDeviceName];
            _currentFilterType = FilterTypeDeviceName;
            break;
        case ProductorSleepBoardHS:
            // 对于SleepBoard不使用过滤
            _currentFilterPrefix = @"";
            _currentFilterType = FilterTypeDeviceName;
            break;
        case ProductorEspBle:
            _currentFilterPrefix = _filterTextField.text;
            _currentFilterType = [_configStorage getFilterType];
            break;
    }
    
    // 清空设备列表
    [_deviceList removeAllObjects];
    [_tableView reloadData];
    

    // 更新UI状态
    _isScanning = YES;
    [self updateScanButtonState];
    
    // 开始相应的扫描
    switch (_currentScanModule) {
        case ProductorRadarQL:
        case ProductorEspBle:
            [self startRadarScan];
            break;
        case ProductorSleepBoardHS:
            [self startSleepaceScan];
            break;
    }
}

- (void)startRadarScan {
    SCANLOG(@"Starting Radar scan with filter prefix: %@, type: %@", 
           _currentFilterPrefix ?: @"None", 
           (long)_currentFilterType == FilterTypeDeviceName ? @"DeviceName" : (_currentFilterType == FilterTypeMac ? @"MAC" : @"UUID"));
    
    // 使用 RadarBleManager 单例扫描
    RadarBleManager *manager = [RadarBleManager sharedManager];
    
    // 设置扫描回调
    __weak typeof(self) weakSelf = self;
    [manager setScanCallback:^(DeviceInfo * _Nonnull deviceInfo) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        SCANLOG(@"Received device: %@, deviceType:%@, UUID: %@", deviceInfo.deviceName,deviceInfo.deviceType,deviceInfo.uuid);
        
        // 阶段1：去重检查
        //if (![self checkAndStoreInDictionary:deviceInfo]) return;
        
        // 阶段2：过滤判断
        if (![self filterDevice:deviceInfo]) return;
        
        // 阶段3：加入显示列表
        [self addToDisplayList:deviceInfo];
    }];
    
    // 开始扫描
    SCANLOG(@"will apply  RadarBleManager' startScan");
    [manager startScanWithTimeout:RADAR_SCAN_TIMEOUT 
                     filterPrefix:_currentFilterPrefix 
                       filterType:_currentFilterType];
    SCANLOG(@"RadarBleManager end Scan");

    // 设置扫描超时定时器
    self.radarScanTimer = [NSTimer scheduledTimerWithTimeInterval:(RADAR_SCAN_TIMEOUT+0.1)
                                                        target:self
                                                        selector:@selector(radarScanTimeout)
                                                        userInfo:nil
                                                        repeats:NO];
}

// Radar扫描超时处理
- (void)radarScanTimeout {
    SCANLOG(@"Radar scan timeout reached");
    [[RadarBleManager sharedManager] stopScan];
    _isScanning = NO;
    [self updateScanButtonState];
}

- (void)startSleepaceScan {
    SCANLOG(@"Starting Sleep scan");
    
    // 获取 SleepaceBleManager 单例
    SleepaceBleManager *manager = [SleepaceBleManager getInstance:self];
    SCANLOG(@"SleepBleManager instance: %@", manager ? @"vail" : @"NULL");
    
    // 设置扫描回调
    __weak typeof(self) weakSelf = self;
    [manager setScanCallback:^(DeviceInfo * _Nonnull deviceInfo) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 检查设备ID是否为错误标记
        if ([deviceInfo.deviceId isEqualToString:@"error"]) {
            // 显示蓝牙错误提示
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController 
                    alertControllerWithTitle:@"Bluetooth Error" 
                    message:deviceInfo.deviceName
                    preferredStyle:UIAlertControllerStyleAlert];
                
                [alert addAction:[UIAlertAction 
                    actionWithTitle:@"OK" 
                    style:UIAlertActionStyleDefault 
                    handler:nil]];
                
                [self presentViewController:alert animated:YES completion:nil];                
                // 更新UI状态
                self->_isScanning = NO; // 设置扫描状态为未扫描
                [self updateScanButtonState];
            });
            return;
        }
        SCANLOG(@"Received Sleep device: %@, deviceType:%@, UUID: %@", deviceInfo.deviceName, deviceInfo.deviceType,deviceInfo.uuid);
        
        // 阶段1：去重检查
        //if (![self checkAndStoreInDictionary:deviceInfo]) return;
        
        // 阶段2：过滤判断
        if (![self filterDevice:deviceInfo]) return;
        
        // 阶段3：加入显示列表
        [self addToDisplayList:deviceInfo];
    }];

    // 启动扫描
    SCANLOG(@"will apply SleepaceBleManager startScan");
    [manager startScanWithTimeout:SLEEPACE_SCAN_TIMEOUT 
                     filterPrefix:_currentFilterPrefix 
                       filterType:_currentFilterType];
    SCANLOG(@"SleepaceBleManager end Scan");


    // 设置扫描超时定时器
    self.sleepaceScanTimer = [NSTimer scheduledTimerWithTimeInterval:(SLEEPACE_SCAN_TIMEOUT+0.1)
                                                            target:self
                                                        selector:@selector(sleepaceScanTimeout)
                                                        userInfo:nil
                                                            repeats:NO];
    
}

// Sleepace扫描超时处理
- (void)sleepaceScanTimeout {
    SCANLOG(@"Sleepace scan timeout reached");
    
    // 停止Sleepace扫描
    [[SleepaceBleManager getInstance:self] stopScan];

    // 2. 检查设备列表
    if (_deviceList.count == 0) {
        // 如果没有设备，直接结束扫描
        _isScanning = NO;
        [self updateScanButtonState];
        [self stopScan];
        return;
    }
    
    // 3. 延迟500ms再开始RSSI扫描，确保Sleepace扫描完全停止
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 4. 开始RSSI扫描
        [self startRssiScan];
    });
}

- (void)addToDisplayList:(DeviceInfo *)device {
    // 使用主线程执行所有操作
    dispatch_async(dispatch_get_main_queue(), ^{
        // 添加到数组
        [self->_deviceList addObject:device];
        
        // 刷新整个表格，避免索引问题
        [self->_tableView reloadData];
    });
}

// 新增辅助方法，更新特定行的表格
- (void)updateDeviceInTableView:(DeviceInfo *)device {
    NSInteger index = [_deviceList indexOfObject:device];
    if (index != NSNotFound) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
        [_tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}


//  stopScan 方法
// 在 stopScan 方法开始处立即停止蓝牙扫描，不要等待其他操作
- (void)stopScan {
    SCANLOG(@"stopScan called, current isScanning=%d", _isScanning);
    
    if (!_isScanning) {
        SCANLOG(@"No scan in progress, ignoring stop request");
        return;
    }
   
    // 1. 立即保存状态并更新标志（放在最前面）
    _isScanning = NO;
    
    // 2. 立即更新 UI（使用主线程）
    [self updateScanButtonState];
    
    // 3. 在主线程或后台线程中执行停止扫描的操作
    // 使用后台线程执行停止操作，防止阻塞
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 停止所有蓝牙扫描活动
        @try {
            [self.cbManager stopScan];
            SCANLOG(@"CoreBluetooth scanning stopped");
        } @catch (NSException *exception) {
            SCANLOG(@"Exception stopping CoreBluetooth scan: %@", exception);
        }
        
        // 根据当前扫描模块，停止特定SDK的扫描
        @try {
            switch (self->_currentScanModule) {
                case ProductorRadarQL:
                case ProductorEspBle:
                    SCANLOG(@"Stopping RadarBleManager scan");
                    [[RadarBleManager sharedManager] stopScan];
                    break;
                case ProductorSleepBoardHS:
                    SCANLOG(@"Stopping SleepaceBleManager scan");
                    [[SleepaceBleManager getInstance:self] stopScan];
                    break;
            }
        } @catch (NSException *exception) {
            SCANLOG(@"Exception stopping manager scan: %@", exception);
        }
        
        // 返回主线程处理定时器和UI更新
        dispatch_async(dispatch_get_main_queue(), ^{
            // 取消所有定时器
            if (self->_rssiScanTimer && [self->_rssiScanTimer isValid]) {
                [self->_rssiScanTimer invalidate];
                self->_rssiScanTimer = nil;
            }
            
            if (self->_radarScanTimer && [self->_radarScanTimer isValid]) {
                [self->_radarScanTimer invalidate];
                self->_radarScanTimer = nil;
            }
            
            if (self->_sleepaceScanTimer && [self->_sleepaceScanTimer isValid]) {
                [self->_sleepaceScanTimer invalidate];
                self->_sleepaceScanTimer = nil;
            }
            
            SCANLOG(@"All scan operations and timers stopped");
        });
    });
}

#pragma mark - RSSI扫描
// RSSI扫描的方法
- (void)startRssiScan {
    // 确保设备列表不为空
    if (_deviceList.count == 0) {
        SCANLOG(@"No devices to perform RSSI scan");
        _isScanning = NO;
        [self updateScanButtonState];
        return;
    }
    _isScanning = YES;
    [self updateScanButtonState];

    // 通过懒加载获取 cbManager
    if (self.cbManager.state != CBManagerStatePoweredOn) {
        SCANLOG(@"Bluetooth not ready, delaying RSSI scan");
        
        // 延迟500ms再尝试
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            if (strongSelf.cbManager.state == CBManagerStatePoweredOn) {
                [strongSelf startRssiScan];
            } else {
                SCANLOG(@"Bluetooth still not ready, aborting RSSI scan");
                strongSelf.isScanning = NO;
                [strongSelf updateScanButtonState];
            }
        });
        return;
    }
    
    // 设置RSSI扫描标志
    _isRssiScanning = YES;
    
    // 开始通用扫描（不指定服务UUID）
    NSDictionary *options = @{
        CBCentralManagerScanOptionAllowDuplicatesKey: @NO
    };
    
    SCANLOG(@"Starting RSSI scan for all devices");
    [self.cbManager scanForPeripheralsWithServices:nil options:options];
    
    // 设置扫描超时
    self.rssiScanTimer = [NSTimer scheduledTimerWithTimeInterval:RSSI_SCAN_TIMEOUT
                                                         target:self
                                                       selector:@selector(stopScan)
                                                       userInfo:nil
                                                        repeats:NO];
}


//蓝牙回调 connect device to get rssi
- (void)centralManager:(CBCentralManager *)central 
 didDiscoverPeripheral:(CBPeripheral *)peripheral 
     advertisementData:(NSDictionary *)advertisementData 
                  RSSI:(NSNumber *)RSSI 
{
    NSString *uuid = peripheral.identifier.UUIDString;
    NSInteger rssiValue = [RSSI integerValue];
    
    SCANLOG(@"BLE callback - Discovered peripheral: %@, UUID: %@, RSSI: %ld", 
           peripheral.name ?: @"Unknown", uuid, (long)rssiValue);
    
    // 在设备列表中查找匹配的设备
    BOOL deviceUpdated = NO;
    for (DeviceInfo *device in _deviceList) {
        if ([device.uuid isEqualToString:uuid]) {
            // 找到匹配设备，更新RSSI
            device.rssi = rssiValue;
            device.lastUpdateTime = [[NSDate date] timeIntervalSince1970];
            deviceUpdated = YES;
            
            SCANLOG(@"Updated RSSI for device: %@", device.deviceName);
            break;
        }
    }
    
    // 如果更新了设备，刷新表格
    if (deviceUpdated) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData]; // 全表刷新
        });
    }
}

#pragma mark - UITableViewDelegate & UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
   return _deviceList ? _deviceList.count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DeviceTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DeviceCell" forIndexPath:indexPath];
    // 确保索引在有效范围内
    if (indexPath.row < _deviceList.count) {
        // 获取设备信息
        DeviceInfo *device = _deviceList[indexPath.row];
        
        // 配置单元格
        [cell configure:device];
    }
    
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 50.0;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // 取消选中高亮状态
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // 确保索引在有效范围内
    if (indexPath.row < 0 || indexPath.row >= _deviceList.count) {
        NSLog(@"Invalid indexPath.row: %ld", (long)indexPath.row);
        return;
    }
    
    // 获取选中的设备
    DeviceInfo *device = _deviceList[indexPath.row];
        // 根据设备类型处理选取逻辑
    switch (device.productorName) {
        case ProductorSleepBoardHS: {
            // Sleepace设备处理
            //[[SleepaceBleManager getInstance:self] setCurrentDevice:device];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[SleepaceBleManager getInstance:self] setCurrentDevice:device];
            });
            //SCANLOG(@"Sleepace device selected: %@", device.deviceName);
            break;
        }
            
        case ProductorRadarQL: {
            // Radar设备处理
            //[[RadarBleManager sharedManager] setCurrentDevice:device];
            //SCANLOG(@"Radar device selected: %@", device.deviceName);
            break;
        }
            
        case ProductorEspBle: {
            // ESP设备处理
            //[[RadarBleManager sharedManager] setCurrentDevice:device];
            //SCANLOG(@"ESP device selected: %@", device.deviceName);
            break;
        }
            
        default:
            //SCANLOG(@"Unknown device type: %@", device.deviceName);
            break;
    }
    /*
    // 针对Sleepace设备，传递设备信息到对应的管理器
    if (device.productorName == ProductorSleepBoardHS) {
        // 获取SleepaceBleManager实例并传入设备信息
        [[SleepaceBleManager getInstance:self] setCurrentDevice:device];        
        SCANLOG(@"Connected Sleepace device: %@", device.deviceName);
    }*/ 

    // 停止扫描
    [self stopScan];
    
    // 使用主线程确保UI操作的安全性
    dispatch_async(dispatch_get_main_queue(), ^{
        // 通知代理
        if (self.delegate && [self.delegate respondsToSelector:@selector(scanViewController:didSelectDevice:)]) {
            NSLog(@"调用代理方法");
            [self.delegate scanViewController:self didSelectDevice:device];
            NSLog(@"代理方法已调用");
        } else {
            NSLog(@"代理不存在或不响应方法");
        }
        
        // 延迟关闭视图，确保代理方法完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"关闭视图");
            [self dismissViewControllerAnimated:YES completion:nil];
        });
    });
}


#pragma mark - UITextFieldDelegate


#pragma mark - 设备过滤 
- (BOOL)filterDevice:(DeviceInfo *)device {
    // 1. 获取当前过滤条件
    NSString *filterText = [self getCurrentFilterText];
    
    // 2. 无过滤条件时直接通过
    if (filterText.length == 0 || _currentScanModule == ProductorSleepBoardHS) {
        return YES;
    }
    
    // 3. 标准化过滤文本
    NSString *normalizedFilter = [[filterText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    
    // 4. 根据类型执行过滤
    switch (_currentFilterType) {
        case FilterTypeDeviceName: {
            NSString *deviceName = [[device.deviceName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
            return deviceName.length > 0 && [deviceName containsString:normalizedFilter];
        }
            
        case FilterTypeMac: {
            NSString *mac = [[device.macAddress stringByReplacingOccurrencesOfString:@":" withString:@""] lowercaseString];
            NSString *filterMac = [normalizedFilter stringByReplacingOccurrencesOfString:@":" withString:@""];
            return mac.length > 0 && [mac containsString:filterMac];
        }
            
        case FilterTypeUUID: {
            NSString *uuid = [[device.uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
            NSString *filterUuid = [normalizedFilter stringByReplacingOccurrencesOfString:@"-" withString:@""];
            return uuid.length > 0 && [uuid containsString:filterUuid];
        }
            
        default:
            return YES;
    }
}
- (NSString *)getCurrentFilterText {
    @synchronized (self) {
        switch (_currentScanModule) {
            case ProductorRadarQL:
                return [_configStorage getRadarDeviceName];
            case ProductorEspBle:
                return _filterTextField.text;
            default:
                return @"";
        }
    }
}
#pragma mark - 配置管理

/**
 * 更新过滤提示信息
 */
- (void)updateFilterHint {
    
    // Update label and placeholder based on current filter type
    switch (_currentFilterType) {
        case FilterTypeDeviceName:
            _filterLabel.text = @"DeviceName";
            _filterTextField.placeholder = @"TSBLU,...";
            break;
        case FilterTypeMac:
            _filterLabel.text = @"MAC";
            _filterTextField.placeholder = @"XX:XX:XX:XX:XX:XX";
            break;
        case FilterTypeUUID:
            _filterLabel.text = @"UUID";
            _filterTextField.placeholder = @"XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX";
            break;
    }
	if (_currentScanModule != ProductorEspBle) {
		_filterLabel.text = @"Filter:invaild"; // 仅在非Esp模式下设置过滤前缀
	}
}

/**
 * 显示配置对话框
 */
- (void)showConfigDialog {
    SCANLOG(@"display config dialog");
    
    // 创建并配置ConfigViewController
    ConfigViewController *configVC = [[ConfigViewController alloc] 
                                      initWithRadarDeviceName:_currentFilterPrefix 
                                      filterType:_currentFilterType // Pass enum directly
                                      completion:^(NSString *radarDeviceName, FilterType filterType) {
        // 更新当前配置
        //self->_currentFilterPrefix = radarDeviceName;
        self->_currentFilterType = filterType;
        [self updateFilterHint];
        
        // 如果正在扫描，停止并重新开始
        if (self->_isScanning) {
            [self stopScan];
        }
    }];
    
    // 显示配置视图控制器
    [self presentViewController:configVC animated:YES completion:nil];
}

#pragma mark - 其他方法
// CBCentralManagerDelegate 方法 检测bluetooth状态
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSString *stateString;
    switch (central.state) {
        case CBManagerStatePoweredOn:
            stateString = @"Powered ON";
            break;
        case CBManagerStatePoweredOff:
            stateString = @"Powered OFF";
            break;
        case CBManagerStateUnauthorized:
            stateString = @"Unauthorized";
            break;
        case CBManagerStateUnsupported:
            stateString = @"Unsupported";
            break;
        case CBManagerStateResetting:
            stateString = @"Resetting";
            break;
        case CBManagerStateUnknown:
            stateString = @"Unknown";
            break;
        default:
            stateString = @"Invalid State";
            break;
    }
    
    SCANLOG(@"CoreBluetooth state updated: %@", stateString);
}

- (void)checkBluetoothPermissions {
    if (@available(iOS 13.0, *)) {
        CBCentralManager *tempManager = [[CBCentralManager alloc] initWithDelegate:nil queue:nil options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
        
        if (tempManager.state == CBManagerStateUnauthorized) {
            // 显示权限提示
            UIAlertController *alert = [UIAlertController 
                alertControllerWithTitle:@"Bluetooth Permission Required" 
                message:@"Please enable Bluetooth in Settings to scan for devices." 
                preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction 
                actionWithTitle:@"Open Settings" 
                style:UIAlertActionStyleDefault 
                handler:^(UIAlertAction * _Nonnull action) {
                    NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
                    if ([[UIApplication sharedApplication] canOpenURL:settingsURL]) {
                        [[UIApplication sharedApplication] openURL:settingsURL options:@{} completionHandler:nil];
                    }
                }]];
            
            [alert addAction:[UIAlertAction 
                actionWithTitle:@"Cancel" 
                style:UIAlertActionStyleCancel 
                handler:nil]];
            
            [self presentViewController:alert animated:YES completion:nil];
        }
    }
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    // 更新当前扫描模块
    switch (sender.selectedSegmentIndex) {
        case 0:
            _currentScanModule = ProductorRadarQL;
            _currentFilterType = FilterTypeDeviceName; // Reset to device name for Radar
            break;
        case 1:
            _currentScanModule = ProductorSleepBoardHS;
            _currentFilterType = FilterTypeDeviceName; // Reset to device name for SleepBoard
            break;
        case 2:
            _currentScanModule = ProductorEspBle;
            _currentFilterType = [_configStorage getFilterType]; // Use stored filter type for Esp
            break;
        default:
            _currentScanModule = ProductorRadarQL;
            _currentFilterType = FilterTypeDeviceName;
            break;
    }
    
	// Update UI to reflect the new settings
    [self updateFilterHint];

    // 如果正在扫描，重新开始扫描
    if (_isScanning) {
        [self stopScan];
    }
}

  - (void)dismissViewController {
      // 先停止所有扫描和清理资源（在后台线程执行）
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          // 停止扫描
          [self stopScan];

          // 在主线程关闭视图
          dispatch_async(dispatch_get_main_queue(), ^{
              [self dismissViewControllerAnimated:YES completion:nil];
          });
      });
  }

    - (void)dismissKeyboard {
    [self.view endEditing:YES];}

@end

