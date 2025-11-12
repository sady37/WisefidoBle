//
//  MainViewController.m
//

#import "MainViewController.h"
#import "RadarBleManager.h"
#import "SleepaceBleManager.h"
#import "ConfigStorage.h"
#import "ScanViewController.h"
#import "RecentRecordsViewController.h"
#import <os/log.h>


// 日志宏定义
#define MAINLOG(fmt, ...) NSLog((@"[MainViewController] " fmt), ##__VA_ARGS__)

@interface MainViewController () <UIPopoverPresentationControllerDelegate>

// UI组件
@property (nonatomic, strong) UIView *deviceInfoView;
@property (nonatomic, strong) UILabel *deviceNameLabel;
@property (nonatomic, strong) UILabel *deviceIdLabel;
@property (nonatomic, strong) UILabel *deviceRssiLabel;

@property (nonatomic, strong) UITextField *serverAddressTextField;
@property (nonatomic, strong) UITextField *serverPortTextField;
@property (nonatomic, strong) UITextField *wifiNameTextField;
@property (nonatomic, strong) UITextField *wifiPasswordTextField;

@property (nonatomic, strong) UILabel *deviceTitleLabel; // Device 标题
@property (nonatomic, strong) UIStackView *headerStackView; // 水平容器
@property (nonatomic, strong) UIButton *pairButton;
@property (nonatomic, strong) UIButton *queryButton;
@property (nonatomic, strong) UIButton *searchButton;




@property (nonatomic, strong) UITextView *statusOutputTextView;
@property (nonatomic, strong) UIButton *recentServerButton;
@property (nonatomic, strong) UIButton *recentWifiButton;
@property (nonatomic, strong) UILabel *configTitle;
@property (nonatomic, strong) UILabel *serverInfoLabel;
@property (nonatomic, strong) UILabel *wifiInfoLabel;
@property (nonatomic, strong) UIView *historyContainer;
@property (nonatomic, strong) UIView *buttonContainer;

@property (nonatomic, strong) UIButton *passwordRevealButton;
@property (nonatomic, strong, nullable) NSTimer *passwordRevealTimer;
@property (nonatomic, assign) BOOL passwordTemporarilyVisible;

// 属性
@property (nonatomic, strong) DeviceInfo *selectedDevice;
@property (nonatomic, strong) ConfigStorage *configStorage;
@property (nonatomic, strong) CBCentralManager *tempManagerForPermission;


// 方法声明
- (void)handlePairButton:(id)sender;
- (void)handleQueryButton:(id)sender;
//- (void)handleSearchButton:(id)sender;  //.h中已有
- (void)showServerHistoryMenu:(id)sender;
- (void)showWifiHistoryMenu:(id)sender;
- (void)handleRadarPreheatNotification:(NSNotification *)notification;

// 其他原有的方法声明
- (instancetype)initWithCentralManager:(CBCentralManager *)centralManager;
- (void)updateDeviceInfo:(DeviceInfo *)deviceInfo;

@end

@implementation MainViewController



#pragma mark - 生命周期方法
- (instancetype)init {
    self = [super init];
    if (self) {
        // 设置默认值
        _selectedDevice = nil;
        _configStorage = [[ConfigStorage alloc] init];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 初始化
    self.configStorage = [[ConfigStorage alloc] init];
    
    // 设置视图
    [self setupViews];
    [self setupConstraints];
    [self setupActions];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
[self.view addGestureRecognizer:tap];
       
    // 加载最近配置
    [self loadRecentConfigs];
    
    // 设置默认值
    self.serverAddressTextField.text = @"app.wisefido.com";
    self.serverPortTextField.text = @"tcp29010";

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRadarPreheatNotification:)
                                                 name:RadarBlePreheatDidFinishNotification
                                               object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self hidePasswordAndInvalidateTimer];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


#pragma mark - 初始化UI
- (void)setupViews {
    // ------------ 标题和背景 ------------
    self.title = @"BLE WiFi Config";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // ------------ 头部容器布局 ------------
    _headerStackView = [[UIStackView alloc] init];
    _headerStackView.axis = UILayoutConstraintAxisHorizontal;
    _headerStackView.distribution = UIStackViewDistributionEqualSpacing;
	//_headerStackView.distribution = UIStackViewDistributionFill;
	//_headerStackView.distribution = UIStackViewDistributionFillProportionally;
    _headerStackView.alignment = UIStackViewAlignmentCenter;
    _headerStackView.spacing = 16;
    _headerStackView.translatesAutoresizingMaskIntoConstraints = NO;
	_headerStackView.userInteractionEnabled = YES;
    [self.view addSubview:_headerStackView];

    // Device 标题
    _deviceTitleLabel = [[UILabel alloc] init];
    _deviceTitleLabel.text = @"Device";
    _deviceTitleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
	[_deviceTitleLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
	_deviceTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[_headerStackView addArrangedSubview:_deviceTitleLabel];

	    // Pair 按钮
    _pairButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_pairButton setTitle:@"Pair" forState:UIControlStateNormal];
    _pairButton.layer.cornerRadius = 20.0;
    _pairButton.backgroundColor = [UIColor systemBlueColor];
    [_pairButton setTitleColor:[UIColor systemBackgroundColor] forState:UIControlStateNormal];
    [_headerStackView addArrangedSubview:_pairButton];

    // Query 按钮
    _queryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_queryButton setTitle:@"Query" forState:UIControlStateNormal];
    _queryButton.layer.cornerRadius = 20.0;
    _queryButton.backgroundColor = [UIColor systemGreenColor];
    [_queryButton setTitleColor:[UIColor systemBackgroundColor] forState:UIControlStateNormal];
    [_headerStackView addArrangedSubview:_queryButton];

    // 自适应填充空格的 UIView
    UIView *spacerView = [[UIView alloc] init];
    spacerView.translatesAutoresizingMaskIntoConstraints = NO;
    [spacerView setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_headerStackView addArrangedSubview:spacerView];

    // Search 按钮
    _searchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        [_searchButton setImage:[UIImage systemImageNamed:@"magnifyingglass"] forState:UIControlStateNormal];
    } else {
        [_searchButton setTitle:@"Search" forState:UIControlStateNormal];
    }
    [_headerStackView addArrangedSubview:_searchButton];

    // ------------ 设备信息区域 ------------
    _deviceInfoView = [[UIView alloc] init];
    _deviceInfoView.backgroundColor = [UIColor systemBackgroundColor];
    _deviceInfoView.layer.cornerRadius = 8.0;
    _deviceInfoView.layer.borderWidth = 1.0;
    _deviceInfoView.layer.borderColor = [UIColor systemGrayColor].CGColor;
    _deviceInfoView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_deviceInfoView];

    // 设备ID标签
    _deviceIdLabel = [[UILabel alloc] init];
    _deviceIdLabel.text = @"No ID";
    _deviceIdLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _deviceIdLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_deviceInfoView addSubview:_deviceIdLabel];

    // 设备名称标签
    _deviceNameLabel = [[UILabel alloc] init];
    _deviceNameLabel.text = @"No Device";
    _deviceNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _deviceNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_deviceInfoView addSubview:_deviceNameLabel];

    // 信号强度标签（统一使用实例变量）
    _deviceRssiLabel = [[UILabel alloc] init];
    _deviceRssiLabel.text = @"--";
    _deviceRssiLabel.font = [UIFont systemFontOfSize:14];
    _deviceRssiLabel.textColor = [UIColor systemGrayColor];
    _deviceRssiLabel.textAlignment = NSTextAlignmentRight;
    _deviceRssiLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_deviceInfoView addSubview:_deviceRssiLabel];

    // ------------ 配置区域 ------------
    _configTitle = [[UILabel alloc] init];
    _configTitle.text = @"Config";
    _configTitle.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _configTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_configTitle];

    // 服务器配置说明
    _serverInfoLabel = [[UILabel alloc] init];
    _serverInfoLabel.text = @"Server information to be connected by the device";
    _serverInfoLabel.font = [UIFont systemFontOfSize:14];
    _serverInfoLabel.textColor = [UIColor systemGrayColor];
    _serverInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_serverInfoLabel];

    // 服务器地址输入框（统一使用实例变量）
    _serverAddressTextField = [[UITextField alloc] init];
    _serverAddressTextField.placeholder = @"example: app.wisefido.com or 47.90.180.176";
    _serverAddressTextField.borderStyle = UITextBorderStyleRoundedRect;
    _serverAddressTextField.delegate = self;
    _serverAddressTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_serverAddressTextField];

    // 服务器端口输入框（统一使用实例变量）
    _serverPortTextField = [[UITextField alloc] init];
    _serverPortTextField.placeholder = @"tcp29010";
    _serverPortTextField.borderStyle = UITextBorderStyleRoundedRect;
    _serverPortTextField.delegate = self;
    _serverPortTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_serverPortTextField];

    // ------------ WiFi配置区域 ------------
    _wifiInfoLabel = [[UILabel alloc] init];
    _wifiInfoLabel.text = @"Select WLAN to connect device";
    _wifiInfoLabel.font = [UIFont systemFontOfSize:14];
    _wifiInfoLabel.textColor = [UIColor systemGrayColor];
    _wifiInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_wifiInfoLabel];

    // WiFi名称输入框（统一使用实例变量）
    _wifiNameTextField = [[UITextField alloc] init];
    _wifiNameTextField.placeholder = @"WiFi Name";
    _wifiNameTextField.borderStyle = UITextBorderStyleRoundedRect;
    _wifiNameTextField.delegate = self;
    _wifiNameTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_wifiNameTextField];

    // WiFi密码输入框（统一使用实例变量）
    _wifiPasswordTextField = [[UITextField alloc] init];
    _wifiPasswordTextField.placeholder = @"Password";
    _wifiPasswordTextField.borderStyle = UITextBorderStyleRoundedRect;
    _wifiPasswordTextField.secureTextEntry = YES;
    _wifiPasswordTextField.delegate = self;
    _wifiPasswordTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_wifiPasswordTextField];

    _passwordRevealButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _passwordRevealButton.frame = CGRectMake(0, 0, 36, 36);
    if (@available(iOS 13.0, *)) {
        UIImage *eyeImage = [UIImage systemImageNamed:@"eye"];
        [_passwordRevealButton setImage:eyeImage forState:UIControlStateNormal];
        _passwordRevealButton.tintColor = [UIColor secondaryLabelColor];
    } else {
        [_passwordRevealButton setTitle:@"Show" forState:UIControlStateNormal];
        [_passwordRevealButton setTitleColor:[UIColor darkTextColor] forState:UIControlStateNormal];
    }
    [_passwordRevealButton addTarget:self action:@selector(handlePasswordRevealTap:) forControlEvents:UIControlEventTouchUpInside];
    _wifiPasswordTextField.rightView = _passwordRevealButton;
    _wifiPasswordTextField.rightViewMode = UITextFieldViewModeAlways;
    [self updatePasswordRevealButtonAppearance:NO];

        // ------------ 历史记录区域 ------------
    _historyContainer = [[UIView alloc] init];
    _historyContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_historyContainer];

    // 服务器历史按钮（统一使用实例变量）
    _recentServerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_recentServerButton setTitle:@"Recent Servers (0)" forState:UIControlStateNormal];
    _recentServerButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    if (@available(iOS 13.0, *)) {
        [_recentServerButton setImage:[UIImage systemImageNamed:@"clock"] forState:UIControlStateNormal];
    }
    _recentServerButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_historyContainer addSubview:_recentServerButton];



    // WiFi历史按钮（统一使用实例变量）
    _recentWifiButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_recentWifiButton setTitle:@"Recent Wifi (0)" forState:UIControlStateNormal];
    _recentWifiButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    if (@available(iOS 13.0, *)) {
        [_recentWifiButton setImage:[UIImage systemImageNamed:@"clock"] forState:UIControlStateNormal];
    }
    _recentWifiButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_historyContainer addSubview:_recentWifiButton];

    // ------------ 状态输出区域 ------------
    _statusOutputTextView = [[UITextView alloc] init];
    _statusOutputTextView.font = [UIFont fontWithName:@"Menlo" size:14];
    _statusOutputTextView.editable = NO;
    _statusOutputTextView.layer.borderWidth = 1.0;
    _statusOutputTextView.layer.borderColor = [UIColor systemGrayColor].CGColor;
    _statusOutputTextView.layer.cornerRadius = 8.0;
    _statusOutputTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusOutputTextView];
}

- (void)setupConstraints {
    // 水平容器的约束
    [NSLayoutConstraint activateConstraints:@[
        [_headerStackView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [_headerStackView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_headerStackView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_headerStackView.heightAnchor constraintEqualToConstant:48]
    ]];
    


    [NSLayoutConstraint activateConstraints:@[
        [_pairButton.widthAnchor constraintEqualToConstant:65],
        [_pairButton.heightAnchor constraintEqualToConstant:40],
        [_queryButton.widthAnchor constraintEqualToConstant:65],
        [_queryButton.heightAnchor constraintEqualToConstant:40],
        [_searchButton.widthAnchor constraintEqualToConstant:44],
        [_searchButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // 设备信息视图约束
    [NSLayoutConstraint activateConstraints:@[
        [_deviceInfoView.topAnchor constraintEqualToAnchor:_headerStackView.bottomAnchor constant:16],
        [_deviceInfoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_deviceInfoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_deviceInfoView.heightAnchor constraintEqualToConstant:60]
    ]];
    

    // 设备ID和名称标签约束
    [NSLayoutConstraint activateConstraints:@[
        // 设置对齐和边距
        [_deviceNameLabel.leadingAnchor constraintEqualToAnchor:_deviceInfoView.leadingAnchor constant:16],
        [_deviceNameLabel.centerYAnchor constraintEqualToAnchor:_deviceInfoView.centerYAnchor],        
        [_deviceIdLabel.centerYAnchor constraintEqualToAnchor:_deviceInfoView.centerYAnchor],        
        [_deviceRssiLabel.trailingAnchor constraintEqualToAnchor:_deviceInfoView.trailingAnchor constant:-16],
        [_deviceRssiLabel.centerYAnchor constraintEqualToAnchor:_deviceInfoView.centerYAnchor],
        
        // 按5/3/2比例分配空间
        [_deviceNameLabel.widthAnchor constraintEqualToAnchor:_deviceInfoView.widthAnchor multiplier:0.5],
        [_deviceRssiLabel.widthAnchor constraintEqualToAnchor:_deviceInfoView.widthAnchor multiplier:0.2],
        
        // 设置元素之间的连接关系
        [_deviceIdLabel.leadingAnchor constraintEqualToAnchor:_deviceNameLabel.trailingAnchor],
        [_deviceRssiLabel.leadingAnchor constraintEqualToAnchor:_deviceIdLabel.trailingAnchor],
    ]];
    
    // 配置标题约束
    [NSLayoutConstraint activateConstraints:@[
        [_configTitle.topAnchor constraintEqualToAnchor:_deviceInfoView.bottomAnchor constant:24],
        [_configTitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_configTitle.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]
    ]];
    
    // 服务器信息标签约束
    [NSLayoutConstraint activateConstraints:@[
        [_serverInfoLabel.topAnchor constraintEqualToAnchor:_configTitle.bottomAnchor constant:8],
        [_serverInfoLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_serverInfoLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]
    ]];
    

// 服务器地址和端口输入框约束
	[NSLayoutConstraint activateConstraints:@[
	    // 地址输入框
	    [_serverAddressTextField.topAnchor constraintEqualToAnchor:_serverInfoLabel.bottomAnchor constant:8],
	    [_serverAddressTextField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
	    [_serverAddressTextField.trailingAnchor constraintEqualToAnchor:self.serverPortTextField.leadingAnchor constant:-8], // 间距8
	    [_serverAddressTextField.heightAnchor constraintEqualToConstant:44],
	    
	    // 端口输入框
	    [_serverPortTextField.topAnchor constraintEqualToAnchor:_serverInfoLabel.bottomAnchor constant:8],
	    [_serverPortTextField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
	    [_serverPortTextField.heightAnchor constraintEqualToConstant:44],
	    
	    // 关键修改：设置6:4的宽度比例（移除硬编码的widthAnchor约束）
	    //[_serverAddressTextField.widthAnchor constraintEqualToAnchor:self.serverPortTextField.widthAnchor multiplier:6.0/4.0]
            [_serverAddressTextField.widthAnchor constraintEqualToAnchor:self.serverPortTextField.widthAnchor multiplier:1.5] // 6.0/4.0=1.5
        
	]];

    // WiFi信息标签约束
    [NSLayoutConstraint activateConstraints:@[
        [_wifiInfoLabel.topAnchor constraintEqualToAnchor:_serverPortTextField.bottomAnchor constant:16],
        [_wifiInfoLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_wifiInfoLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]
    ]];

    // WiFi名称和密码输入框约束
    [NSLayoutConstraint activateConstraints:@[
        [_wifiNameTextField.topAnchor constraintEqualToAnchor:_wifiInfoLabel.bottomAnchor constant:8],
        [_wifiNameTextField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_wifiNameTextField.trailingAnchor constraintEqualToAnchor:self.wifiPasswordTextField.leadingAnchor constant:-8], // 间距8
        [_wifiNameTextField.heightAnchor constraintEqualToConstant:44],
        
        [_wifiPasswordTextField.topAnchor constraintEqualToAnchor:_wifiInfoLabel.bottomAnchor constant:8],
        [_wifiPasswordTextField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_wifiPasswordTextField.heightAnchor constraintEqualToConstant:44],
        
        // 关键修改：设置6:4的宽度比例
        //[_wifiNameTextField.widthAnchor constraintEqualToAnchor:self.wifiPasswordTextField.widthAnchor multiplier:6.0/4.0]
            [_wifiNameTextField.widthAnchor constraintEqualToAnchor:_wifiPasswordTextField.widthAnchor], // 1:1基础比例
        
        
        // 最小宽度保护（新增）
        [_wifiNameTextField.widthAnchor constraintGreaterThanOrEqualToConstant:120],
        [_wifiPasswordTextField.widthAnchor constraintGreaterThanOrEqualToConstant:100]
    ]];
    
    // 历史容器约束
    [NSLayoutConstraint activateConstraints:@[
        [_historyContainer.topAnchor constraintEqualToAnchor:self.wifiPasswordTextField.bottomAnchor constant:8],
        [_historyContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_historyContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_historyContainer.heightAnchor constraintEqualToConstant:44]
    ]];
    
    // 历史按钮50%宽度约束
    [NSLayoutConstraint activateConstraints:@[
        [_recentServerButton.leadingAnchor constraintEqualToAnchor:_historyContainer.leadingAnchor],
        [_recentServerButton.centerYAnchor constraintEqualToAnchor:_historyContainer.centerYAnchor],
        [_recentServerButton.widthAnchor constraintEqualToAnchor:_historyContainer.widthAnchor multiplier:0.5],
        [_recentServerButton.heightAnchor constraintEqualToConstant:44],
        
        
        [_recentWifiButton.trailingAnchor constraintEqualToAnchor:_historyContainer.trailingAnchor],
        [_recentWifiButton.centerYAnchor constraintEqualToAnchor:_historyContainer.centerYAnchor],
        [_recentWifiButton.widthAnchor constraintEqualToAnchor:_historyContainer.widthAnchor multiplier:0.5],
        [_recentWifiButton.heightAnchor constraintEqualToConstant:44]
    ]];
    


    // 状态输出区域约束
    [NSLayoutConstraint activateConstraints:@[
        [_statusOutputTextView.topAnchor constraintEqualToAnchor:self.historyContainer.bottomAnchor constant:16],
        [_statusOutputTextView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_statusOutputTextView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_statusOutputTextView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16]
    ]];
}

- (void)setupActions {
    [self.pairButton addTarget:self action:@selector(handlePairButton:) forControlEvents:UIControlEventTouchUpInside];
    [self.queryButton addTarget:self action:@selector(handleQueryButton:) forControlEvents:UIControlEventTouchUpInside];
    [self.searchButton addTarget:self action:@selector(handleSearchButton:) forControlEvents:UIControlEventTouchUpInside];
    [self.recentServerButton addTarget:self action:@selector(showServerHistoryMenu:) forControlEvents:UIControlEventTouchUpInside];
    [self.recentWifiButton addTarget:self action:@selector(showWifiHistoryMenu:) forControlEvents:UIControlEventTouchUpInside];
}

#pragma mark - 密码显示控制

- (void)handlePasswordRevealTap:(id)sender {
    if (self.passwordTemporarilyVisible) {
        [self hidePasswordAndInvalidateTimer];
    } else {
        [self revealPasswordTemporarily];
    }
}

- (void)revealPasswordTemporarily {
    self.passwordTemporarilyVisible = YES;
    [self updatePasswordSecureEntry:NO];
    [self invalidatePasswordRevealTimer];
    NSTimer *timer = [NSTimer timerWithTimeInterval:3.0
                                             target:self
                                           selector:@selector(passwordRevealTimerFired:)
                                           userInfo:nil
                                            repeats:NO];
    self.passwordRevealTimer = timer;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)hidePasswordAndInvalidateTimer {
    self.passwordTemporarilyVisible = NO;
    [self invalidatePasswordRevealTimer];
    [self updatePasswordSecureEntry:YES];
}

- (void)passwordRevealTimerFired:(NSTimer *)timer {
    [self hidePasswordAndInvalidateTimer];
}

- (void)invalidatePasswordRevealTimer {
    if (self.passwordRevealTimer) {
        [self.passwordRevealTimer invalidate];
        self.passwordRevealTimer = nil;
    }
}

- (void)updatePasswordSecureEntry:(BOOL)secure {
    if (self.wifiPasswordTextField.secureTextEntry == secure) {
        [self updatePasswordRevealButtonAppearance:!secure];
        return;
    }

    BOOL wasFirstResponder = self.wifiPasswordTextField.isFirstResponder;
    NSString *currentText = self.wifiPasswordTextField.text ?: @"";
    self.wifiPasswordTextField.secureTextEntry = secure;
    self.wifiPasswordTextField.text = @"";
    self.wifiPasswordTextField.text = currentText;
    if (wasFirstResponder) {
        [self.wifiPasswordTextField becomeFirstResponder];
        UITextPosition *endPosition = self.wifiPasswordTextField.endOfDocument;
        if (endPosition) {
            UITextRange *range = [self.wifiPasswordTextField textRangeFromPosition:endPosition toPosition:endPosition];
            [self.wifiPasswordTextField setSelectedTextRange:range];
        }
    }
    [self updatePasswordRevealButtonAppearance:!secure];
}

- (void)updatePasswordRevealButtonAppearance:(BOOL)isRevealed {
    if (@available(iOS 13.0, *)) {
        NSString *symbolName = isRevealed ? @"eye.slash" : @"eye";
        UIImage *image = [UIImage systemImageNamed:symbolName];
        [self.passwordRevealButton setImage:image forState:UIControlStateNormal];
        self.passwordRevealButton.tintColor = isRevealed ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    } else {
        NSString *title = isRevealed ? @"Hide" : @"Show";
        [self.passwordRevealButton setTitle:title forState:UIControlStateNormal];
        UIColor *color = isRevealed ? [UIColor blueColor] : [UIColor darkTextColor];
        [self.passwordRevealButton setTitleColor:color forState:UIControlStateNormal];
    }
}

#pragma mark - 数据加载

- (void)loadRecentConfigs {
    // 加载最近的服务器配置
    NSArray<NSDictionary *> *recentServers = [self.configStorage getServerConfigs];
    if (recentServers.count > 0) {
        [self.recentServerButton setTitle:[NSString stringWithFormat:@"Recent Servers (%lu)", (unsigned long)MIN(recentServers.count, 5)] forState:UIControlStateNormal];
        self.recentServerButton.hidden = NO;
    } else {
        self.recentServerButton.hidden = NO;
    }
    
    // 加载最近的WiFi配置
    NSArray<NSDictionary<NSString *, NSString *> *> *recentWifis = [self.configStorage getWiFiConfigs];
    if (recentWifis.count > 0) {
        [self.recentWifiButton setTitle:[NSString stringWithFormat:@"Recent Wifi (%lu)", (unsigned long)MIN(recentWifis.count, 5)] forState:UIControlStateNormal];
        self.recentWifiButton.hidden = NO;
    } else {
        self.recentWifiButton.hidden = NO;
    }
}

#pragma mark - 按钮处理
- (void)handlePairButton:(id)sender {
    // 检查设备选择
    if (!self.selectedDevice) {
        [self showMessage:@"Please select a device first"];
        return;
    }
 
    // 获取配置参数
    NSString *serverAddress = self.serverAddressTextField.text ?: @"";
    NSString *portInput = self.serverPortTextField.text ?: @"";
    NSArray *protocolAndPort = [self parseProtocolAndPort:portInput];
    if (!serverAddress.length || protocolAndPort.count != 2) {
        [self showMessage:@"Invalid server address or port"];
        return;
    }
    NSString *serverProtocol = protocolAndPort[0];
    NSInteger serverPort = [protocolAndPort[1] integerValue];
    NSString *wifiSsid = self.wifiNameTextField.text;
    NSString *wifiPassword = self.wifiPasswordTextField.text;
    
    // 验证参数
    if (self.selectedDevice.productorName == ProductorSleepBoardHS && !wifiSsid.length) {
        [self showMessage:@"SleepBoard devices require WiFi configuration"];
        return;
    }
    
    // 保存配置历史
    if (wifiSsid.length) {
        [self.configStorage saveWiFiConfigWithSsid:wifiSsid password:wifiPassword];
    }
    [self.configStorage saveServerConfig:serverAddress port:serverPort protocol:serverProtocol];
    
    // 执行设备配置
    [self configureDevice:self.selectedDevice
            serverAddress:serverAddress.length ? serverAddress : nil
              serverPort:serverPort > 0 ? serverPort : 0
           serverProtocol:serverProtocol
                 wifiSsid:wifiSsid.length ? wifiSsid : nil
             wifiPassword:wifiPassword
               completion:nil]; // 这里不需要额外的回调，因为方法内部已经处理了UI更新
}

- (void)handleQueryButton:(id)sender  {
    MAINLOG(@"Query button tapped!!");
    // 检查设备选择
    if (!self.selectedDevice) {
        [self showMessage:@"Please select a device first"];
        return;
    }
    
    // 根据设备类型进行不同的状态查询
    switch (self.selectedDevice.productorName) {
        case ProductorRadarQL:
        case ProductorEspBle:
            // 查询Radar设备状态
            [self queryRadarStatus:self.selectedDevice];
            break;
            
        case ProductorSleepBoardHS:
            // 查询Sleepace设备状态
            [self querySleepaceStatus:self.selectedDevice];
            break;
    }
}
//#pragma mark - 扫描设备	
- (void)handleSearchButton:(id)sender {
    MAINLOG(@"Search button tapped!");
    // 清理资源：断开当前设备连接
    if (self.selectedDevice != nil) {
        // 根据设备类型断开连接
        switch (self.selectedDevice.productorName) {
            case ProductorSleepBoardHS:
                [[SleepaceBleManager getInstance:self] disconnect];
                break;
                
            case ProductorRadarQL:
            case ProductorEspBle:
                [[RadarBleManager sharedManager] disconnect];
                break;
                
            default:
                MAINLOG(@"Unknown device type to disconnect");
                break;
        }
        
    // 置空当前设备
    self.selectedDevice = nil;
    [self updateDeviceInfo:nil];
    }

    // 创建ScanViewController
    ScanViewController *scanVC = [[ScanViewController alloc] init]; // 使用新的初始化方法
    scanVC.delegate = self;
    
    // 创建导航控制器包装ScanViewController
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:scanVC];
    navController.modalPresentationStyle = UIModalPresentationFullScreen;

    // 模态展示
    [self presentViewController:navController animated:YES completion:nil];
}

//#pragma mark - 更新设备信息
- (void)updateDeviceInfo:(nullable DeviceInfo *)deviceInfo {
    if (!deviceInfo) {
        // 如果 deviceInfo 为空，显示默认值
        self.deviceNameLabel.text = @"No Device";
        self.deviceIdLabel.text = @"No ID";
        self.deviceRssiLabel.text = @"--";
        return;
    }
    // 获取设备ID的最后4位
    NSString *displayId = deviceInfo.deviceId.length > 4 ? 
        [deviceInfo.deviceId substringFromIndex:deviceInfo.deviceId.length - 4] : 
        deviceInfo.deviceId;

    // 更新设备信息
    self.deviceNameLabel.text = deviceInfo.deviceName ? [NSString stringWithFormat:@"Name: %@", deviceInfo.deviceName] : @"Name: Unknown";
    self.deviceIdLabel.text = [NSString stringWithFormat:@"%@", displayId];
    self.deviceRssiLabel.text = [NSString stringWithFormat:@"RSSI: %ld dBm", (long)deviceInfo.rssi];
}
//#pragma mark - 设置按钮处理

- (void)showServerHistoryMenu:(id)sender  {
    NSArray<NSDictionary *> *recentServers = [self.configStorage getServerConfigs];
    if (recentServers.count == 0) {
        [self showMessage:@"No recent servers available"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    RecentRecordsViewController *recordsVC = [[RecentRecordsViewController alloc] initWithType:RecentRecordTypeServer
                                                                                        records:recentServers
                                                                               selectionHandler:^(NSDictionary *selectedRecord) {
        weakSelf.serverAddressTextField.text = selectedRecord[@"serverAddress"];
        NSNumber *portNumber = selectedRecord[@"serverPort"];
        NSString *protocol = selectedRecord[@"serverProtocol"] ?: @"tcp";
        NSString *portString = portNumber ? [portNumber stringValue] : @"";
        if (portString.length > 0) {
            weakSelf.serverPortTextField.text = [NSString stringWithFormat:@"%@%@", protocol, portString];
        } else {
            weakSelf.serverPortTextField.text = protocol;
        }
    } deleteHandler:^BOOL(NSUInteger index) {
        return [weakSelf.configStorage deleteServerConfigAtIndex:index];
    }];

    UIPopoverPresentationController *popover = recordsVC.popoverPresentationController;
    popover.sourceView = self.recentServerButton;
    popover.sourceRect = self.recentServerButton.bounds;
    popover.delegate = self;
    [self presentViewController:recordsVC animated:YES completion:nil];
}

- (void)showWifiHistoryMenu:(id)sender  {
    NSArray<NSDictionary<NSString *, NSString *> *> *recentWifis = [self.configStorage getWiFiConfigs];
    if (recentWifis.count == 0) {
        [self showMessage:@"No recent Wi-Fi records"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    RecentRecordsViewController *recordsVC = [[RecentRecordsViewController alloc] initWithType:RecentRecordTypeWiFi
                                                                                        records:recentWifis
                                                                               selectionHandler:^(NSDictionary *selectedRecord) {
        weakSelf.wifiNameTextField.text = selectedRecord[@"ssid"];
        weakSelf.wifiPasswordTextField.text = selectedRecord[@"password"];
    } deleteHandler:^BOOL(NSUInteger index) {
        return [weakSelf.configStorage deleteWiFiConfigAtIndex:index];
    }];

    UIPopoverPresentationController *popover = recordsVC.popoverPresentationController;
    popover.sourceView = self.recentWifiButton;
    popover.sourceRect = self.recentWifiButton.bounds;
    popover.delegate = self;
    [self presentViewController:recordsVC animated:YES completion:nil];
}

#pragma mark - 配置验证

- (BOOL)validateServerConfigWithAddress:(NSString **)address port:(NSInteger *)port protocol:(NSString **)protocol {
    NSString *addressText = self.serverAddressTextField.text;
    NSString *portInput = self.serverPortTextField.text;
    
    // 地址和端口都必须有效
    if (addressText.length == 0 || portInput.length == 0) {
        MAINLOG(@"The server address or port is empty: address=%@, port=%@", addressText, portInput);
        return NO;
    }
    
    // 解析协议和端口
    NSArray *protocolAndPort = [self parseProtocolAndPort:portInput];
    
    if (protocolAndPort && protocolAndPort.count == 2) {
        if (address) *address = addressText;
        if (protocol) *protocol = protocolAndPort[0];
        if (port) *port = [protocolAndPort[1] integerValue];
        
        // 保存到 ConfigStorage
        [self.configStorage saveServerConfig:addressText port:[protocolAndPort[1] integerValue] protocol:protocolAndPort[0]];
        return YES;
    }
    
    MAINLOG(@"Invalid server configuration: address=%@, port=%@", addressText, portInput);
    return NO;
}

- (BOOL)validateWifiConfigWithSSID:(NSString **)ssid password:(NSString **)password {
    NSString *ssidText = self.wifiNameTextField.text;
    if (ssidText.length == 0) {
		MAINLOG(@"WiFi name is empty");
        return NO;
    }
    
    if (ssid) *ssid = ssidText;
    if (password) *password = self.wifiPasswordTextField.text ?: @"";
    
    return YES;
}

- (NSArray *)parseProtocolAndPort:(NSString *)input {
    if (!input || input.length == 0) {
		MAINLOG(@"Port input is empty");
        return nil;
    }
    
    // 匹配协议和端口，例如"tcp80"或"80"
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(tcp|udp)?(\\d+)$"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&error];
    if (error) {
        MAINLOG(@"Regular expression error: %@", error);
        return nil;
    }
    
    NSTextCheckingResult *match = [regex firstMatchInString:input
                                                    options:0
                                                      range:NSMakeRange(0, input.length)];
    
    if (match) {
        NSString *serverProtocol;
        NSString *portStr;
        
        // 获取协议
        if (match.numberOfRanges > 1) {
            NSRange protocolRange = [match rangeAtIndex:1];
            if (protocolRange.location != NSNotFound && protocolRange.length > 0) {
                serverProtocol = [[input substringWithRange:protocolRange] lowercaseString];
            } else {
                serverProtocol = @"tcp"; // 默认协议
            }
        } else {
            serverProtocol = @"tcp"; // 默认协议
        }
        
        // 获取端口
        if (match.numberOfRanges > 2) {
            NSRange portRange = [match rangeAtIndex:2];
            portStr = [input substringWithRange:portRange];
            NSInteger port = [portStr integerValue];
            
            if (port > 0 && port <= 65535) {
                return @[serverProtocol, portStr];
            }
        }
    }
    MAINLOG(@"Protocol and port parsing failed: %@", input);
    return nil;
}

#pragma mark - 设备操作
- (void)configureDevice:(DeviceInfo *)device
          serverAddress:(nullable NSString *)serverAddress
            serverPort:(NSInteger)serverPort
         serverProtocol:(nullable NSString *)serverProtocol
               wifiSsid:(nullable NSString *)wifiSsid
           wifiPassword:(nullable NSString *)wifiPassword
             completion:(void(^)(BOOL success, NSDictionary *result))completion {
    
    [self showMessage:@"Configuring device..."];
    
    // 根据设备类型选择适当的管理器
    switch (device.productorName) {
        case ProductorRadarQL:
        case ProductorEspBle: {
            // 使用RadarBleManager配置
            [[RadarBleManager sharedManager] configureDevice:device
                                              serverAddress:serverAddress
                                                serverPort:serverPort
                                             serverProtocol:serverProtocol
                                                   wifiSsid:wifiSsid
                                               wifiPassword:wifiPassword
                                                 completion:^(BOOL success, NSDictionary *result) {
                // 处理配置结果
                if (success) {
                    NSString *message = result[@"message"] ?: @"Configuration successful";
                    [self showMessage:message];
                } else {
                    NSString *error = result[@"error"] ?: @"Unknown error";
                    [self showMessage:[NSString stringWithFormat:@"Configuration failed: %@", error]];
                }
                
                // 传递结果给原始调用者
                if (completion) {
                    completion(success, result);
                }
            }];
            break;
        }
            
        case ProductorSleepBoardHS: {
            // 使用SleepaceBleManager配置
            [[SleepaceBleManager getInstance:self] configureDevice:device
                                                         wifiSsid:wifiSsid
                                                     wifiPassword:wifiPassword
                                                    serverAddress:serverAddress
                                                       serverPort:serverPort
                                                   serverProtocol:serverProtocol
                                                       completion:^(BOOL success, NSDictionary *result) {
                // 处理配置结果
                if (success) {
                    NSString *message = result[@"message"] ?: @"Configuration successful";
                    [self showMessage:message];
                } else {
                    NSString *error = result[@"error"] ?: @"Unknown error";
                    [self showMessage:[NSString stringWithFormat:@"Configuration failed: %@", error]];
                }
                
                // 传递结果给原始调用者
                if (completion) {
                    completion(success, result);
                }
            }];
            break;
        }
    }
}
// Radar设备的配置方法
- (void)configureRadarDeviceWithWifiSsid:(NSString *)wifiSsid
                           wifiPassword:(NSString *)wifiPassword
                          serverAddress:(nullable NSString *)serverAddress
                             serverPort:(NSInteger)serverPort
                         serverProtocol:(nullable NSString *)serverProtocol {
    [self showMessage:@"Configuring Radar device..."];

    
    // 调用RadarBleManager配置方法
	[[RadarBleManager sharedManager] configureDevice:self.selectedDevice
	                                    serverAddress:serverAddress
	                                      serverPort:serverPort
	                                   serverProtocol:serverProtocol
	                                         wifiSsid:wifiSsid
	                                     wifiPassword:wifiPassword
	                                       completion:^(BOOL success, NSDictionary *result) {
        if (success) {
            [self showMessage:@"Configuration successful, please wait for the device to reboot"];
            
            // 更新设备信息
            self.selectedDevice.wifiSsid = wifiSsid;
            self.selectedDevice.wifiPassword = wifiPassword;
            self.selectedDevice.serverAddress = serverAddress;
            self.selectedDevice.serverPort = serverPort;
            self.selectedDevice.serverProtocol = serverProtocol;
            self.selectedDevice.lastUpdateTime = [[NSDate date] timeIntervalSince1970];
        } else {
            NSString *errorMsg = result[@"error"] ?: @"Unknown error";
            [self showMessage:[NSString stringWithFormat:@"Configuration failed: %@", errorMsg]];
        }
    }];
}

// Sleepace设备的新配置方法
- (void)configureSleepaceDeviceWithWifiSsid:(NSString *)wifiSsid
                              wifiPassword:(NSString *)wifiPassword
                             serverAddress:(nullable NSString *)serverAddress
                                serverPort:(NSInteger)serverPort
                            serverProtocol:(nullable NSString *)serverProtocol {
    [self showMessage:@"Configuring Sleepace device..."];
    
    
    // 调用SleepaceBleManager配置方法
    [[SleepaceBleManager getInstance:self] configureDevice:self.selectedDevice
                                                 wifiSsid:wifiSsid
                                             wifiPassword:wifiPassword
                                            serverAddress:serverAddress
                                               serverPort:serverPort
                                           serverProtocol:serverProtocol
                                               completion:^(BOOL success, NSDictionary *result) {
        if (success) {
            [self showMessage:@"Configuration successful, please wait for the device to reboot"];
            
            // 更新设备信息
            self.selectedDevice.wifiSsid = wifiSsid;
            self.selectedDevice.wifiPassword = wifiPassword;
            self.selectedDevice.serverAddress = serverAddress;
            self.selectedDevice.serverPort = serverPort;
            self.selectedDevice.serverProtocol = serverProtocol;
            self.selectedDevice.lastUpdateTime = [[NSDate date] timeIntervalSince1970];
        } else {
            NSString *errorMsg = result[@"error"] ?: @"Unknown error";
            [self showMessage:[NSString stringWithFormat:@"Configuration failed: %@", errorMsg]];
        }
    }];
}

#pragma mark - 设备状态查询方法

- (void)queryRadarStatus:(DeviceInfo *)device {
    [self showMessage:@"Querying Radar device status..."];
    
    [[RadarBleManager sharedManager] queryDeviceStatus:device completion:^(DeviceInfo *updatedDevice, BOOL success) {
        if (!success) {
            [self showMessage:@"Failed to query Radar device status"];
            return;
        }
        
        // 更新设备信息
        self.selectedDevice = updatedDevice;
        [self updateStatusDisplay:updatedDevice];
    }];
}

- (void)querySleepaceStatus:(DeviceInfo *)device {
    [self showMessage:@"Querying Sleepace device status..."];
    
    [[SleepaceBleManager getInstance:self] queryDeviceStatus:device completion:^(DeviceInfo *updatedDevice, BOOL success) {
        if (!success) {
            [self showMessage:@"Failed, please rescan;deviceType BM8701_2 is not support query"];
            return;
        }
        
        // 更新设备信息
        self.selectedDevice = updatedDevice;
        [self updateStatusDisplay:updatedDevice];
    }];
}

// 统一的状态显示方法
- (void)updateStatusDisplay:(DeviceInfo *)device {
    NSMutableString *info = [NSMutableString string];

    // Basic information
    if (device.deviceName) {
        [info appendFormat:@"deviceName:%@\n", device.deviceName];
    }
    if (device.deviceId) {
        [info appendFormat:@"deviceId:%@\n", device.deviceId];
    }
    if (device.deviceType) {
        [info appendFormat:@"deviceType:%@\n", device.deviceType];
    }
    if (device.uid) {
        [info appendFormat:@"uid:%@\n", device.uid];
    }
    if (device.macAddress) {
        [info appendFormat:@"macAddress:%@\n", device.macAddress];
    } else {
        [info appendString:@"macAddress:\n"];
    }
    if (device.uuid) {
        [info appendFormat:@"uuid:%@\n", device.uuid];
    }
    if (device.rssi != -255) {
        [info appendFormat:@"BLErssi:%lddBm\n", (long)device.rssi];
    }

    // Wi-Fi information
    NSString *displayWifiMode = device.wifiMode.length > 0 ? device.wifiMode : nil;
    NSInteger displayWifiSignal = device.wifiSignal;
    NSString *displayWifiSsid = device.wifiSsid.length > 0 ? device.wifiSsid : @"";
    
    if (displayWifiSignal == -255 && device.nearbyWiFiNetworks.count > 0) {
        NSDictionary *matchedEntry = nil;
        if (displayWifiSsid.length > 0) {
            for (NSDictionary *entry in device.nearbyWiFiNetworks) {
                if ([displayWifiSsid isEqualToString:entry[@"ssid"]]) {
                    matchedEntry = entry;
                    break;
                }
            }
        }
        if (!matchedEntry) {
            matchedEntry = device.nearbyWiFiNetworks.firstObject;
        }
        NSNumber *rssiValue = matchedEntry[@"rssi"];
        if ([rssiValue isKindOfClass:[NSNumber class]]) {
            displayWifiSignal = [rssiValue integerValue];
        }
    }
    if (displayWifiSignal == 0) {
        displayWifiSignal = -255;
    }
    
    if (device.wifiMode.length == 0 && displayWifiMode.length > 0) {
        device.wifiMode = displayWifiMode;
    }
    if (device.wifiSignal == -255 && displayWifiSignal != -255) {
        device.wifiSignal = displayWifiSignal;
    }
    [info appendFormat:@"wifiMode:%@   wifiRssi:%@\n",
                       displayWifiMode.length > 0 ? displayWifiMode : @"Unknown",
                       displayWifiSignal == -255 ? @"-255,not signal" : @(displayWifiSignal)];
    if (displayWifiSsid.length > 0) {
        [info appendFormat:@"wifiSsid:%@\n", displayWifiSsid];
    } else {
        [info appendString:@"wifiSsid:\n"];
    }
    
    // Radar run status
    if (device.radarRunStatus.length > 0) {
        [info appendFormat:@"radarRunStatus:%@\n", device.radarRunStatus];
    }
    
    // Nearby Wi-Fi networks
    if (device.nearbyWiFiNetworks.count > 0) {
        [info appendString:@"nearbyWiFi:\n"];
        NSInteger index = 1;
        for (NSDictionary *entry in device.nearbyWiFiNetworks) {
            NSString *ssid = entry[@"ssid"] ?: @"";
            NSNumber *rssiNumber = entry[@"rssi"];
            NSString *rssiString = [rssiNumber isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%@", rssiNumber] : @"";
            [info appendFormat:@"  %ld. %@ (RSSI:%@ dBm)\n", (long)index, ssid, rssiString];
            index++;
        }
    } else {
        [info appendString:@"nearbyWiFi:\n"];
    }

    // Extension area
    if (device.version) {
        [info appendFormat:@"version:%@\n", device.version];
    }
    if (device.lastUpdateTime > 0) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:device.lastUpdateTime];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        [info appendFormat:@"lastUpdateTime:%@\n", [formatter stringFromDate:date]];
    }

    // Update the status output text view
    self.statusOutputTextView.text = info;
    [self showMessage:@"Query updated"];
}

#pragma mark - 辅助方法

- (void)updateDeviceDisplay:(DeviceInfo *)device {
    if (!device) {
        self.deviceNameLabel.text = @"No Device";
        self.deviceIdLabel.text = @"No ID";
        self.deviceRssiLabel.text = @"--";
        return;
    }

        // 获取设备ID的最后4位
    NSString *displayId = device.deviceId.length > 4 ? [device.deviceId substringFromIndex:device.deviceId.length - 4] :
    device.deviceId;
    
    // 更新设备信息显示
    self.deviceNameLabel.text = device.deviceName;
    //self.deviceIdLabel.text = device.deviceId;
    self.deviceIdLabel.text = [NSString stringWithFormat:@"%@", displayId];
    self.deviceRssiLabel.text = [NSString stringWithFormat:@"%lddBm", (long)device.rssi];
}

- (void)showMessage:(NSString *)message {
    // 将消息添加到状态输出
    NSString *currentText = self.statusOutputTextView.text ?: @"";
    NSString *newText;
    
    if (currentText.length == 0) {
        newText = message;
    } else {
        newText = [NSString stringWithFormat:@"%@\n%@", currentText, message];
    }
    
    self.statusOutputTextView.text = newText;
    
    // 滚动到底部
    NSRange bottom = NSMakeRange(newText.length, 0);
    [self.statusOutputTextView scrollRangeToVisible:bottom];
    
    // 输出日志（使用 os_log 避免阻塞主线程）
    if (@available(iOS 10.0, *)) {
        static os_log_t mainViewLog;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            mainViewLog = os_log_create("com.wisefido.ble", "MainViewController");
        });
        os_log_with_type(mainViewLog, OS_LOG_TYPE_INFO, "%{public}@", message);
    } else {
        NSLog(@"%@", message);
    }
}

#pragma mark - ScanViewControllerDelegate

- (void)scanViewController:(ScanViewController *)controller didSelectDevice:(DeviceInfo *)device {
    NSLog(@"=== MainVC strat  ===");
    // 保存选中的设备并更新UI
    self.selectedDevice = device;
    [self updateDeviceDisplay:device];
    
    // 输出日志
    //NSLog(@"device select: %@ (%@, RSSI: %ld)", device.deviceName, device.deviceId, (long)device.rssi);
    
    // 显示消息
    [self showMessage:[NSString stringWithFormat:@"Device selected: %@", device.deviceName]];
}

- (void)handleRadarPreheatNotification:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleRadarPreheatNotification:notification];
        });
        return;
    }
    
    if (!notification) {
        return;
    }
    
    id object = notification.object;
    if (self.selectedDevice && object && object != self.selectedDevice) {
        return;
    }
    
    NSDictionary *userInfo = notification.userInfo;
    BOOL success = [userInfo[RadarBlePreheatResultKeySuccess] boolValue];
    NSString *uid = userInfo[RadarBlePreheatResultKeyUID];
    
    if (success && uid.length > 0 && self.selectedDevice) {
        self.selectedDevice.uid = uid;
    }
    
    NSString *message;
    if (success) {
        if (uid.length > 0) {
            message = [NSString stringWithFormat:@"Preheat success, UID:%@", uid];
        } else {
            message = @"Preheat success, UID unavailable";
        }
    } else {
        message = @"Preheat failed";
    }
    
    [self showMessage:message];
}

#pragma mark - UITextFieldDelegate
- (void)textFieldDidEndEditing:(UITextField *)textField {
    // 输入结束时自动去除头尾空格
    textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    // 实时禁止输入空格（适用于所有输入框）
    //if ([string containsString:@" "]) {
    //    return NO;
    //}
    
    // 服务器端口框：仅允许数字和协议前缀（tcp/udp）
    if (textField == self.serverPortTextField) {
        NSCharacterSet *allowedChars = [NSCharacterSet characterSetWithCharactersInString:@"0123456789tcpudpTCPUDP"];
        return [string rangeOfCharacterFromSet:[allowedChars invertedSet]].location == NSNotFound;
    }
    
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (nonnull instancetype)initWithCentralManager:(nonnull CBCentralManager *)centralManager {
    self = [super init];
    if (self) {
        _centralManager = centralManager;
    }
    return self;}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    switch (central.state) {
        case CBManagerStatePoweredOn:
            MAINLOG(@"Bluetooth is powered on and ready.");
            break;
        case CBManagerStatePoweredOff:
            MAINLOG(@"Bluetooth is powered off.");
            break;
        case CBManagerStateUnauthorized:
            MAINLOG(@"Bluetooth is unauthorized.");
            break;
        case CBManagerStateUnsupported:
            MAINLOG(@"Bluetooth is unsupported on this device.");
            break;
        case CBManagerStateResetting:
            MAINLOG(@"Bluetooth is resetting.");
            break;
        case CBManagerStateUnknown:
            MAINLOG(@"Bluetooth state is unknown.");
            break;
        default:
            MAINLOG(@"Bluetooth state is not handled.");
            break;
    }
}

- (void)encodeWithCoder:(nonnull NSCoder *)coder { 
    
}

//- (void)traitCollectionDidChange:(nullable UITraitCollection *)previousTraitCollection { }

- (void)preferredContentSizeDidChangeForChildContentContainer:(nonnull id<UIContentContainer>)container { 
    
}

- (CGSize)sizeForChildContentContainer:(nonnull id<UIContentContainer>)container withParentContainerSize:(CGSize)parentSize {
    return CGSizeMake(100, 100); // 根据实际情况返回合适的尺寸
}

- (void)systemLayoutFittingSizeDidChangeForChildContentContainer:(nonnull id<UIContentContainer>)container { 
    [super systemLayoutFittingSizeDidChangeForChildContentContainer:container];
    
    // 获取子容器的新大小
    CGSize newSize = [container preferredContentSize];
    
    // 根据子容器的新大小调整布局
    [self adjustLayoutForChildContainer:container withSize:newSize];
    
    // 输出日志
    MAINLOG(@"Child container size changed to: %@", NSStringFromCGSize(newSize));
}

- (void)adjustLayoutForChildContainer:(id<UIContentContainer>)container withSize:(CGSize)size {
    // 根据子容器的新大小调整布局
    // 例如，更新约束或重新布局视图
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(nonnull id<UIViewControllerTransitionCoordinator>)coordinator { 
    
}

- (void)willTransitionToTraitCollection:(nonnull UITraitCollection *)newCollection withTransitionCoordinator:(nonnull id<UIViewControllerTransitionCoordinator>)coordinator { 
    
}

- (void)didUpdateFocusInContext:(nonnull UIFocusUpdateContext *)context withAnimationCoordinator:(nonnull UIFocusAnimationCoordinator *)coordinator { 
    
}

- (void)setNeedsFocusUpdate { 
    
}


- (void)updateFocusIfNeeded { 
    
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller {
    return UIModalPresentationNone;
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

@end

    
