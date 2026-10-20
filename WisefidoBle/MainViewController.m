//
//  MainViewController.m
//

#import "MainViewController.h"
#import "RadarBleManager.h"
#import "SleepaceBleManager.h"
#import "ConfigStorage.h"
#import "ScanViewController.h"
#import "RecentRecordsViewController.h"
#import "DeviceServerRules.h"
#import "QrScanViewController.h"
#import <os/log.h>


// 日志宏定义
#define MAINLOG(fmt, ...) NSLog((@"[MainViewController] " fmt), ##__VA_ARGS__)

@interface MainViewController () <UIPopoverPresentationControllerDelegate, QrScanViewControllerDelegate>

// UI组件
@property (nonatomic, strong) UIView *deviceInfoView;
@property (nonatomic, strong) UILabel *deviceNameLabel;
@property (nonatomic, strong) UILabel *deviceIdLabel;
@property (nonatomic, strong) UILabel *deviceRssiLabel;
@property (nonatomic, strong) UILabel *deviceUidLabel;        // 设备栏中间：QR 码或 MAC
@property (nonatomic, copy, nullable) NSString *selectedQrCode; // QR 匹配选中时记录原始 QR 码

@property (nonatomic, strong) UITextField *serverAddressTextField;
@property (nonatomic, strong) UITextField *serverPortTextField;
@property (nonatomic, strong) UITextField *wifiNameTextField;
@property (nonatomic, strong) UITextField *wifiPasswordTextField;

@property (nonatomic, strong) UILabel *deviceTitleLabel; // Device 标题
@property (nonatomic, strong) UIStackView *headerStackView; // 水平容器
@property (nonatomic, strong) UIButton *pairButton;
@property (nonatomic, strong) UIButton *queryButton;
@property (nonatomic, strong) UIButton *searchButton;
@property (nonatomic, weak, nullable) QrScanViewController *activeQrVC; // 顶部扫码面板
@property (nonatomic, strong) UIButton *qrScanButton;      // STEP 1 行：扫码匹配
@property (nonatomic, strong) UIView *serverHistoryRow;    // Recent Servers + Recent WiFi（WiFi 输入框下方）
@property (nonatomic, strong) UIStackView *stepThreeStackView; // STEP 3 | Pair
@property (nonatomic, strong) UILabel *stepThreeLabel;

// 首页扫码匹配状态（对应 Android startQrMatch 流程）
@property (nonatomic, assign) BOOL qrMatching;
@property (nonatomic, copy) NSString *qrMatchCode;
@property (nonatomic, copy) NSString *qrOriginalCode;
@property (nonatomic, strong) NSMutableSet<NSString *> *qrSeenDevices; // 本次匹配中已打印到状态栏的设备
@property (nonatomic, strong, nullable) NSTimer *qrStage1Timer;
@property (nonatomic, strong, nullable) NSTimer *qrTimeoutTimer;




@property (nonatomic, strong) UITextView *statusOutputTextView;
@property (nonatomic, strong) UIButton *recentServerButton;
@property (nonatomic, strong) UIButton *recentWifiButton;
@property (nonatomic, strong) UILabel *configTitle;
@property (nonatomic, strong) UILabel *serverInfoLabel;
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
- (void)queryEspStatus:(DeviceInfo *)device;

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
    self.serverPortTextField.text = @"29010";
    [self updateActionButtonsState];

    // 拉取在线设备服务器模板（失败则用缓存/内置默认）
    [DeviceServerRules refreshFromRemoteWithCompletion:nil];

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
/// Android 同款 SVG（intrinsic 200pt）缩放到 header 图标尺寸，保持模板着色
- (UIImage *)headerIconNamed:(NSString *)name {
    const CGFloat side = 26;
    UIImage *src = [UIImage imageNamed:name];
    if (!src) return nil;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [src drawInRect:CGRectMake(0, 0, side, side)];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)setupViews {
    // ------------ 标题和背景 ------------
    self.title = @"BLE WiFi Config";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // ------------ STEP 1 行：STEP 1 | (spacer) | QR | BLE ------------
    _headerStackView = [[UIStackView alloc] init];
    _headerStackView.axis = UILayoutConstraintAxisHorizontal;
    _headerStackView.distribution = UIStackViewDistributionFill;
    _headerStackView.alignment = UIStackViewAlignmentCenter;
    _headerStackView.spacing = 12;
    _headerStackView.translatesAutoresizingMaskIntoConstraints = NO;
    _headerStackView.userInteractionEnabled = YES;
    [self.view addSubview:_headerStackView];

    _deviceTitleLabel = [[UILabel alloc] init];
    _deviceTitleLabel.text = @"STEP 1";
    _deviceTitleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [_deviceTitleLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_deviceTitleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_headerStackView addArrangedSubview:_deviceTitleLabel];

    // 自适应填充空格的 UIView
    UIView *spacerView = [[UIView alloc] init];
    [spacerView setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [spacerView setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_headerStackView addArrangedSubview:spacerView];

    // QR 扫码按钮
    _qrScanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_qrScanButton setImage:[self headerIconNamed:@"QRScan"] forState:UIControlStateNormal];
    _qrScanButton.accessibilityLabel = @"QRScan";
    [_headerStackView addArrangedSubview:_qrScanButton];

    // BLE 扫描按钮
    _searchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_searchButton setImage:[self headerIconNamed:@"BleScan"] forState:UIControlStateNormal];
    _searchButton.accessibilityLabel = @"BleScan";
    [_headerStackView addArrangedSubview:_searchButton];

    // ------------ 设备信息区域 ------------
    _deviceInfoView = [[UIView alloc] init];
    _deviceInfoView.backgroundColor = [UIColor systemBackgroundColor];
    _deviceInfoView.layer.cornerRadius = 8.0;
    _deviceInfoView.layer.borderWidth = 1.0;
    _deviceInfoView.layer.borderColor = [UIColor systemGrayColor].CGColor;
    _deviceInfoView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_deviceInfoView];

    _deviceIdLabel = [[UILabel alloc] init];
    _deviceIdLabel.text = @"Scan QR or BLE to select device";
    _deviceIdLabel.textColor = [UIColor systemGrayColor];
    _deviceIdLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _deviceIdLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_deviceInfoView addSubview:_deviceIdLabel];

    _deviceNameLabel = [[UILabel alloc] init];
    _deviceNameLabel.text = @"No Device";
    _deviceNameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _deviceNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _deviceNameLabel.hidden = YES; // 保留属性以兼容旧代码，界面不显示
    [_deviceInfoView addSubview:_deviceNameLabel];

    _deviceUidLabel = [[UILabel alloc] init];
    _deviceUidLabel.text = @"";
    _deviceUidLabel.font = [UIFont systemFontOfSize:14];
    _deviceUidLabel.textColor = [UIColor systemGrayColor];
    _deviceUidLabel.textAlignment = NSTextAlignmentCenter;
    _deviceUidLabel.adjustsFontSizeToFitWidth = YES;
    _deviceUidLabel.minimumScaleFactor = 0.75;
    _deviceUidLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_deviceInfoView addSubview:_deviceUidLabel];

    _deviceRssiLabel = [[UILabel alloc] init];
    _deviceRssiLabel.text = @"";
    _deviceRssiLabel.font = [UIFont systemFontOfSize:14];
    _deviceRssiLabel.textColor = [UIColor systemGrayColor];
    _deviceRssiLabel.textAlignment = NSTextAlignmentRight;
    [_deviceRssiLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_deviceRssiLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_deviceIdLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_deviceIdLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _deviceRssiLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_deviceInfoView addSubview:_deviceRssiLabel];

    // ------------ STEP 2：服务器 ------------
    _configTitle = [[UILabel alloc] init];
    _configTitle.text = @"STEP 2";
    _configTitle.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    _configTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_configTitle];

    _serverInfoLabel = [[UILabel alloc] init];
    _serverInfoLabel.text = @"Server address the device will connect to";
    _serverInfoLabel.font = [UIFont systemFontOfSize:14];
    _serverInfoLabel.textColor = [UIColor systemGrayColor];
    _serverInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_serverInfoLabel];

    _serverAddressTextField = [[UITextField alloc] init];
    _serverAddressTextField.placeholder = @"app.wisefido.com or 47.90.180.176";
    _serverAddressTextField.borderStyle = UITextBorderStyleRoundedRect;
    _serverAddressTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    _serverAddressTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _serverAddressTextField.delegate = self;
    _serverAddressTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_serverAddressTextField];

    _serverPortTextField = [[UITextField alloc] init];
    _serverPortTextField.placeholder = @"8443(TLS) or 29010";
    _serverPortTextField.borderStyle = UITextBorderStyleRoundedRect;
    _serverPortTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    _serverPortTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _serverPortTextField.delegate = self;
    _serverPortTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_serverPortTextField];

    // Recent Servers + Recent WiFi 一行（布局在 WiFi 输入框下方）
    _serverHistoryRow = [[UIView alloc] init];
    _serverHistoryRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_serverHistoryRow];

    _recentServerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_recentServerButton setTitle:@"Recent Servers (0)" forState:UIControlStateNormal];
    _recentServerButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [_recentServerButton setImage:[UIImage systemImageNamed:@"clock"] forState:UIControlStateNormal];
    _recentServerButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_serverHistoryRow addSubview:_recentServerButton];

    // Recent WiFi 与 Recent Servers 同一行，右对齐
    _recentWifiButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_recentWifiButton setTitle:@"Recent Wifi (0)" forState:UIControlStateNormal];
    _recentWifiButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [_recentWifiButton setImage:[UIImage systemImageNamed:@"clock"] forState:UIControlStateNormal];
    _recentWifiButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_serverHistoryRow addSubview:_recentWifiButton];

    // ------------ STEP 3 行：STEP 3 | (spacer) | Query | Pair ------------
    _stepThreeStackView = [[UIStackView alloc] init];
    _stepThreeStackView.axis = UILayoutConstraintAxisHorizontal;
    _stepThreeStackView.distribution = UIStackViewDistributionFill;
    _stepThreeStackView.alignment = UIStackViewAlignmentCenter;
    _stepThreeStackView.spacing = 12;
    _stepThreeStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_stepThreeStackView];

    _stepThreeLabel = [[UILabel alloc] init];
    _stepThreeLabel.text = @"STEP 3";
    _stepThreeLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [_stepThreeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_stepThreeStackView addArrangedSubview:_stepThreeLabel];

    UIView *stepThreeSpacer = [[UIView alloc] init];
    [stepThreeSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [stepThreeSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_stepThreeStackView addArrangedSubview:stepThreeSpacer];

    _wifiNameTextField = [[UITextField alloc] init];
    _wifiNameTextField.placeholder = @"WiFi Name";
    _wifiNameTextField.borderStyle = UITextBorderStyleRoundedRect;
    _wifiNameTextField.delegate = self;
    _wifiNameTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_wifiNameTextField];

    _wifiPasswordTextField = [[UITextField alloc] init];
    _wifiPasswordTextField.placeholder = @"Password";
    _wifiPasswordTextField.borderStyle = UITextBorderStyleRoundedRect;
    _wifiPasswordTextField.secureTextEntry = YES;
    _wifiPasswordTextField.delegate = self;
    _wifiPasswordTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_wifiPasswordTextField];

    _passwordRevealButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _passwordRevealButton.frame = CGRectMake(0, 0, 36, 36);
    [_passwordRevealButton setImage:[UIImage systemImageNamed:@"eye"] forState:UIControlStateNormal];
    _passwordRevealButton.tintColor = [UIColor secondaryLabelColor];
    [_passwordRevealButton addTarget:self action:@selector(handlePasswordRevealTap:) forControlEvents:UIControlEventTouchUpInside];
    _wifiPasswordTextField.rightView = _passwordRevealButton;
    _wifiPasswordTextField.rightViewMode = UITextFieldViewModeAlways;
    [self updatePasswordRevealButtonAppearance:NO];

    // Query 在前、Pair 在后（Pair 后设备断开，无法再 Query），右对齐
    _queryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_queryButton setTitle:@"Query" forState:UIControlStateNormal];
    _queryButton.layer.cornerRadius = 20.0;
    _queryButton.backgroundColor = [UIColor systemGreenColor];
    [_queryButton setTitleColor:[UIColor systemBackgroundColor] forState:UIControlStateNormal];
    [_stepThreeStackView addArrangedSubview:_queryButton];


    _pairButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_pairButton setTitle:@"Pair" forState:UIControlStateNormal];
    _pairButton.layer.cornerRadius = 20.0;
    _pairButton.backgroundColor = [UIColor systemBlueColor];
    [_pairButton setTitleColor:[UIColor systemBackgroundColor] forState:UIControlStateNormal];

    [_stepThreeStackView addArrangedSubview:_pairButton];


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
    // STEP 1 行
    [NSLayoutConstraint activateConstraints:@[
        [_headerStackView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [_headerStackView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_headerStackView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_headerStackView.heightAnchor constraintEqualToConstant:44],

        [_queryButton.widthAnchor constraintEqualToConstant:65],
        [_queryButton.heightAnchor constraintEqualToConstant:40],
        [_qrScanButton.heightAnchor constraintEqualToConstant:44],
        [_qrScanButton.widthAnchor constraintEqualToConstant:44],
        [_searchButton.widthAnchor constraintEqualToConstant:44],
        [_searchButton.heightAnchor constraintEqualToConstant:44],

    ]];

    // 设备信息视图
    [NSLayoutConstraint activateConstraints:@[
        [_deviceInfoView.topAnchor constraintEqualToAnchor:_headerStackView.bottomAnchor constant:8],
        [_deviceInfoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_deviceInfoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_deviceInfoView.heightAnchor constraintEqualToConstant:60],

        // 与 Android 一致：只显示设备 ID（左）+ 信号强度（右），不再单独显示设备名
        [_deviceIdLabel.leadingAnchor constraintEqualToAnchor:_deviceInfoView.leadingAnchor constant:16],
        [_deviceIdLabel.centerYAnchor constraintEqualToAnchor:_deviceInfoView.centerYAnchor],
        [_deviceUidLabel.leadingAnchor constraintEqualToAnchor:_deviceIdLabel.trailingAnchor constant:8],
        [_deviceUidLabel.trailingAnchor constraintEqualToAnchor:_deviceRssiLabel.leadingAnchor constant:-8],
        [_deviceUidLabel.centerYAnchor constraintEqualToAnchor:_deviceInfoView.centerYAnchor],
        [_deviceRssiLabel.trailingAnchor constraintEqualToAnchor:_deviceInfoView.trailingAnchor constant:-16],
        [_deviceRssiLabel.centerYAnchor constraintEqualToAnchor:_deviceInfoView.centerYAnchor],
    ]];

    // STEP 2：标题、说明、地址/端口
    [NSLayoutConstraint activateConstraints:@[
        [_configTitle.topAnchor constraintEqualToAnchor:_deviceInfoView.bottomAnchor constant:16],
        [_configTitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],

        // 说明文字放在 STEP 2 标题后面，节省高度
        [_serverInfoLabel.firstBaselineAnchor constraintEqualToAnchor:_configTitle.firstBaselineAnchor],
        [_serverInfoLabel.leadingAnchor constraintEqualToAnchor:_configTitle.trailingAnchor constant:8],
        [_serverInfoLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_serverAddressTextField.topAnchor constraintEqualToAnchor:_configTitle.bottomAnchor constant:8],
        [_serverAddressTextField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_serverAddressTextField.trailingAnchor constraintEqualToAnchor:_serverPortTextField.leadingAnchor constant:-8],
        [_serverAddressTextField.heightAnchor constraintEqualToConstant:44],

        [_serverPortTextField.topAnchor constraintEqualToAnchor:_configTitle.bottomAnchor constant:8],
        [_serverPortTextField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_serverPortTextField.heightAnchor constraintEqualToConstant:44],
        [_serverAddressTextField.widthAnchor constraintEqualToAnchor:_serverPortTextField.widthAnchor multiplier:1.5],
    ]];

    // Recent Servers + Recent WiFi（WiFi 输入框下方）
    [NSLayoutConstraint activateConstraints:@[
        // 放在 WiFi 输入框下方，远离 Pair 防误触
        [_serverHistoryRow.topAnchor constraintEqualToAnchor:_wifiPasswordTextField.bottomAnchor constant:4],
        [_serverHistoryRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_serverHistoryRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_serverHistoryRow.heightAnchor constraintEqualToConstant:44],

        [_recentServerButton.leadingAnchor constraintEqualToAnchor:_serverHistoryRow.leadingAnchor],
        [_recentServerButton.centerYAnchor constraintEqualToAnchor:_serverHistoryRow.centerYAnchor],
        [_recentServerButton.heightAnchor constraintEqualToConstant:44],
        [_recentServerButton.trailingAnchor constraintLessThanOrEqualToAnchor:_recentWifiButton.leadingAnchor constant:-8],

        [_recentWifiButton.trailingAnchor constraintEqualToAnchor:_serverHistoryRow.trailingAnchor],
        [_recentWifiButton.centerYAnchor constraintEqualToAnchor:_serverHistoryRow.centerYAnchor],
        [_recentWifiButton.heightAnchor constraintEqualToConstant:44],
    ]];

    // STEP 3 行
    [NSLayoutConstraint activateConstraints:@[
        [_stepThreeStackView.topAnchor constraintEqualToAnchor:_serverPortTextField.bottomAnchor constant:12],
        [_stepThreeStackView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_stepThreeStackView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_stepThreeStackView.heightAnchor constraintEqualToConstant:44],
    ]];

    // WiFi 名称/密码
    [NSLayoutConstraint activateConstraints:@[
        [_wifiNameTextField.topAnchor constraintEqualToAnchor:_stepThreeStackView.bottomAnchor constant:8],
        [_wifiNameTextField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_wifiNameTextField.trailingAnchor constraintEqualToAnchor:_wifiPasswordTextField.leadingAnchor constant:-8],
        [_wifiNameTextField.heightAnchor constraintEqualToConstant:44],

        [_wifiPasswordTextField.topAnchor constraintEqualToAnchor:_stepThreeStackView.bottomAnchor constant:8],
        [_wifiPasswordTextField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_wifiPasswordTextField.heightAnchor constraintEqualToConstant:44],
        [_wifiNameTextField.widthAnchor constraintEqualToAnchor:_wifiPasswordTextField.widthAnchor],
        [_wifiNameTextField.widthAnchor constraintGreaterThanOrEqualToConstant:120],
        [_wifiPasswordTextField.widthAnchor constraintGreaterThanOrEqualToConstant:100],
    ]];

    // Pair 宽高（与 Query 一致）
    [NSLayoutConstraint activateConstraints:@[
        [_pairButton.widthAnchor constraintEqualToConstant:65],
        [_pairButton.heightAnchor constraintEqualToConstant:40],
    ]];

    // 状态输出：占满剩余高度，最少 120
    [NSLayoutConstraint activateConstraints:@[
        [_statusOutputTextView.topAnchor constraintEqualToAnchor:_serverHistoryRow.bottomAnchor constant:8],
        [_statusOutputTextView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_statusOutputTextView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_statusOutputTextView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [_statusOutputTextView.heightAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];
}

- (void)setupActions {
    [self.pairButton addTarget:self action:@selector(handlePairButton:) forControlEvents:UIControlEventTouchUpInside];
    [self.queryButton addTarget:self action:@selector(handleQueryButton:) forControlEvents:UIControlEventTouchUpInside];
    [self.searchButton addTarget:self action:@selector(handleSearchButton:) forControlEvents:UIControlEventTouchUpInside];
    [self.qrScanButton addTarget:self action:@selector(handleQrScanButton:) forControlEvents:UIControlEventTouchUpInside];
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
    [self setHistoryButton:self.recentServerButton hasRecords:recentServers.count > 0];
    
    // 加载最近的WiFi配置
    NSArray<NSDictionary<NSString *, NSString *> *> *recentWifis = [self.configStorage getWiFiConfigs];
    if (recentWifis.count > 0) {
        [self.recentWifiButton setTitle:[NSString stringWithFormat:@"Recent Wifi (%lu)", (unsigned long)MIN(recentWifis.count, 5)] forState:UIControlStateNormal];
        self.recentWifiButton.hidden = NO;
    } else {
        self.recentWifiButton.hidden = NO;
    }
    [self setHistoryButton:self.recentWifiButton hasRecords:recentWifis.count > 0];
}

/// 有记录时用主题蓝（文字 + 时钟图标），无记录时灰色
- (void)setHistoryButton:(UIButton *)button hasRecords:(BOOL)hasRecords {
    UIColor *color = hasRecords ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    button.tintColor = color;
    [button setTitleColor:color forState:UIControlStateNormal];
}

/// 每个动作（QR / BLE 扫描、Query、Pair）开始时清空状态栏，只保留本次动作的输出
- (void)clearStatus {
    self.statusOutputTextView.text = @"";
}

/// 断开雷达与 Sleepace 当前的 GATT 连接
- (void)disconnectAllGatt {
    [[RadarBleManager sharedManager] disconnect];
    [[SleepaceBleManager getInstance:self] disconnect];
}

#pragma mark - 按钮处理
- (void)handlePairButton:(id)sender {
    [self.view endEditing:YES]; // 收起键盘；SSID 结束编辑时会去掉首尾空格
    [self clearStatus];
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
    // 先显示实际使用的服务器和 TLS 判断（TLS 由 Default Device Server 规则决定，首页无开关）
    [self showMessage:[NSString stringWithFormat:@"Server: %@:%ld  TLS=%@", serverAddress, (long)serverPort, [self currentPortIsTls] ? @"Y" : @"N"]];
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
    [self loadRecentConfigs]; // 刷新 Recent 数量和颜色
    
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
    [self.view endEditing:YES];
    [self clearStatus];
    // 检查设备选择
    if (!self.selectedDevice) {
        [self showMessage:@"Please select a device first"];
        return;
    }
    
    // 根据设备类型进行不同的状态查询
    switch (self.selectedDevice.productorName) {
        case ProductorRadarQL:
            // 查询Radar设备状态
            [self queryRadarStatus:self.selectedDevice];
            break;
        case ProductorEspBle:
            [self queryEspStatus:self.selectedDevice];
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
    [self clearStatus];
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
    self.selectedQrCode = nil;
    [self updateDeviceInfo:nil];
    }

    // 进入扫描前取消扫码匹配、断开残留的 GATT 连接：设备被连接时停止广播，会扫不到
    [self stopQrMatch];
    [self disconnectAllGatt];

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
/// 未选设备时显示灰色提示，选中后显示设备 ID + 信号强度
- (void)showDeviceId:(nullable NSString *)deviceId rssi:(nullable NSString *)rssi {
    BOOL has = deviceId.length > 0;
    // 中间列：QR 匹配选中时显示原始 QR 码，否则显示 MAC
    NSString *uid = self.selectedQrCode.length > 0 ? self.selectedQrCode : self.selectedDevice.macAddress;
    self.deviceUidLabel.text = has ? (uid ?: @"") : @"";
    self.deviceIdLabel.text = has ? deviceId : @"Scan QR or BLE to select device";
    self.deviceIdLabel.textColor = has ? [UIColor labelColor] : [UIColor systemGrayColor];
    self.deviceIdLabel.font = [UIFont systemFontOfSize:16 weight:has ? UIFontWeightMedium : UIFontWeightRegular];
    self.deviceRssiLabel.text = has ? rssi : @"";
}

- (void)updateDeviceInfo:(nullable DeviceInfo *)deviceInfo {
    if (!deviceInfo) {
        // 如果 deviceInfo 为空，显示默认值
        self.deviceNameLabel.text = @"";
        [self showDeviceId:nil rssi:nil];
        [self updateActionButtonsState];
        return;
    }
    // 与 Android 一致：显示完整设备 ID（无则退回设备名）+ 信号强度
    NSString *displayId = deviceInfo.deviceId.length > 0 ? deviceInfo.deviceId : (deviceInfo.deviceName ?: @"Unknown");
    self.deviceNameLabel.text = deviceInfo.deviceName ?: @"";
    [self showDeviceId:displayId rssi:[NSString stringWithFormat:@"%lddBm", (long)deviceInfo.rssi]];
    [self updateActionButtonsState];
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
                                                           useTls:[self currentPortIsTls]
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

- (void)queryEspStatus:(DeviceInfo *)device {
    [self showMessage:@"Querying ESP nearby Wi-Fi..."];
    
    [[RadarBleManager sharedManager] scanNearbyWiFiForDevice:device completion:^(DeviceInfo *updatedDevice, BOOL success) {
        if (!success) {
            [self showMessage:@"Failed to scan ESP nearby Wi-Fi"];
            return;
        }
        
        self.selectedDevice = updatedDevice;
        [self updateStatusDisplay:updatedDevice];
    }];
}

/// Sleepace 查询：只能读 WiFi 设置（SSID / 密码 / DHCP 或静态 IP），读不到服务器地址和 TLS
- (void)querySleepaceStatus:(DeviceInfo *)device {
    [self showMessage:@"Querying Sleepace device status..."];
    [[SleepaceBleManager getInstance:self] queryWiFiSettings:device completion:^(BOOL success, NSDictionary *info, NSString *error) {
        NSMutableString *text = [NSMutableString string];
        [text appendFormat:@"deviceName:%@\n", device.deviceName ?: @""];
        if (info[@"version"]) [text appendFormat:@"version:%@\n", info[@"version"]];
        [text appendFormat:@"BLErssi:%lddBm\n", (long)device.rssi];
        if (success) {
            [text appendFormat:@"wifiSsid:%@\n", info[@"ssid"] ?: @""];
            [text appendFormat:@"wifiPwd:%@\n", info[@"password"] ?: @""];
            if ([info[@"ipType"] isEqualToString:@"0"] || !info[@"ipType"]) {
                [text appendString:@"ipType:DHCP\n"];
            } else {
                [text appendFormat:@"ipType:Static ip:%@ mask:%@ gw:%@\n", info[@"staticIp"], info[@"subnetMask"], info[@"gateway"]];
            }
            [text appendString:@"(server/TLS not readable via Sleepace protocol)"];
        } else {
            [text appendFormat:@"Query failed: %@", error ?: @"unknown error"];
        }
        [self showMessage:text];
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
    NSString *wifiRssiDisplay = (displayWifiSignal == -255 ? @"-255,not signal" : [NSString stringWithFormat:@"%ld", (long)displayWifiSignal]);
    [info appendFormat:@"wifiMode:%@\n",
                       displayWifiMode.length > 0 ? displayWifiMode : @"Unknown"];
    if (displayWifiSsid.length > 0) {
        [info appendFormat:@"wifiSsid:%@   wifiRssi:%@\n", displayWifiSsid, wifiRssiDisplay];
    } else {
        [info appendFormat:@"wifiSsid:   wifiRssi:%@\n", wifiRssiDisplay];
    }
    
    // Radar run status
    if (device.radarRunStatus.length > 0) {
        [info appendString:@"radarRunStatus:\n"];
        [info appendString:device.radarRunStatus];
        if (![device.radarRunStatus hasSuffix:@"\n"]) {
            [info appendString:@"\n"];
        }
        [info appendString:@"\n"];
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
        self.deviceNameLabel.text = @"";
        [self showDeviceId:nil rssi:nil];
        [self updateActionButtonsState];
        return;
    }

    // 与 Android 一致：显示完整设备 ID（无则退回设备名）
    NSString *displayId = device.deviceId.length > 0 ? device.deviceId : (device.deviceName ?: @"Unknown");
    self.deviceNameLabel.text = device.deviceName ?: @"";
    [self showDeviceId:displayId rssi:[NSString stringWithFormat:@"%lddBm", (long)device.rssi]];
    [self updateActionButtonsState];
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

#pragma mark - 选中设备 / 按钮状态

/// 选中设备的统一入口（ScanViewController 返回 / QR 匹配命中共用）
- (void)onDeviceSelected:(DeviceInfo *)device {
    self.selectedDevice = device;
    if (device.productorName == ProductorSleepBoardHS) {
        // 与 ScanViewController 选中路径一致：Sleepace 需先登记 peripheral
        [[SleepaceBleManager getInstance:self] setCurrentDevice:device];
    }
    [self updateDeviceDisplay:device];
    [self showMessage:[NSString stringWithFormat:@"Device selected: %@", device.deviceName]];
    [self applyDefaultServerForDevice:device];
}

/// 按设备前缀（Config 页 Default Device Server）自动填写服务器地址和端口
- (void)applyDefaultServerForDevice:(DeviceInfo *)device {
    NSDictionary<NSString *, id> *rule = [DeviceServerRules ruleForDevice:device qrCode:self.selectedQrCode];
    if (!rule) return;
    self.serverAddressTextField.text = rule[kDeviceServerRuleServerKey];
    // udp 规则端口框带 udp 前缀（parseProtocolAndPort: 支持 tcp/udp 前缀），tcp 填纯数字
    BOOL udp = [[rule[kDeviceServerRuleProtocolKey] lowercaseString] isEqualToString:kDeviceServerProtocolUdp];
    self.serverPortTextField.text = [NSString stringWithFormat:@"%@%@", udp ? @"udp" : @"", rule[kDeviceServerRulePortKey]];
    [self showMessage:[NSString stringWithFormat:@"Server set by prefix %@: %@", rule[kDeviceServerRulePrefixKey],
                       [DeviceServerRules displayServerForRule:rule]]];
}

/// 当前地址+端口是否走 TLS（由 Default Device Server 规则决定）；端口无效时按明文处理
- (BOOL)currentPortIsTls {
    NSArray *protocolAndPort = [self parseProtocolAndPort:self.serverPortTextField.text ?: @""];
    if (protocolAndPort.count != 2) return NO;
    return [DeviceServerRules isTlsPort:[protocolAndPort[1] integerValue] server:self.serverAddressTextField.text];
}


/// 根据是否有选中设备，统一更新 Query / Pair 按钮可用状态
- (void)updateActionButtonsState {
    BOOL hasDevice = (self.selectedDevice != nil);
    self.queryButton.enabled = hasDevice;
    self.pairButton.enabled = hasDevice;
    self.queryButton.alpha = hasDevice ? 1.0 : 0.5;
    self.pairButton.alpha = hasDevice ? 1.0 : 0.5;
}

#pragma mark - 首页扫码匹配（对应 Android startQrMatch）

static const NSTimeInterval kQrMatchStage1Timeout = 3.0;   // 3 秒未命中 → TSBLU+后 6 位回退
static const NSTimeInterval kQrMatchTotalTimeout = 10.0;   // 总超时

- (void)handleQrScanButton:(id)sender {
    // 匹配进行中再点一次 = 取消匹配（不再弹进度框）
    if (self.qrMatching) {
        [self cancelQrMatch];
        return;
    }
    if (self.activeQrVC.parentViewController) { // 面板仍挂在界面上就不重复弹
        return;
    }
    // 新动作开始：清空状态栏，断开当前 GATT 连接
    [self clearStatus];
    [self disconnectAllGatt];
    // 顶部浮层（不用底部 sheet：单手操作时底部不顺手），与 Android 顶部扫码小窗一致
    QrScanViewController *qrVC = [[QrScanViewController alloc] init];
    qrVC.delegate = self;
    [self addChildViewController:qrVC];
    UIView *panel = qrVC.view;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 16;
    panel.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    panel.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.25;
    panel.layer.shadowRadius = 8;
    panel.layer.shadowOffset = CGSizeMake(0, 3);
    [self.view addSubview:panel];
    [NSLayoutConstraint activateConstraints:@[
        [panel.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    [qrVC didMoveToParentViewController:self];
    self.activeQrVC = qrVC;
    [self.view layoutIfNeeded];
    panel.transform = CGAffineTransformMakeTranslation(0, -panel.bounds.size.height);
    [UIView animateWithDuration:0.25 animations:^{ panel.transform = CGAffineTransformIdentity; }];
    [self showMessage:@"Scan device QR code"];
}

- (void)qrScanViewController:(QrScanViewController *)controller didScanCode:(NSString *)code {
    self.activeQrVC = nil;
    [self startQrMatch:code];
}

/// 扫码成功后开始匹配设备：BM 开头走 Sleepace 直接匹配 QR 码（无兜底）；
/// 否则按 ESP 雷达处理，先用 "TSBLU"+后 6 位匹配，3 秒未命中再用完整 QR 码兜底
- (void)startQrMatch:(NSString *)code {
    if (code.length == 0) return;
    [self stopQrMatch];
    self.qrMatching = YES;
    self.qrOriginalCode = code;
    if ([[code uppercaseString] hasPrefix:@"BM"]) {
        self.qrMatchCode = code;
    } else {
        NSString *tail = code.length > 6 ? [code substringFromIndex:code.length - 6] : code;
        self.qrMatchCode = [@"TSBLU" stringByAppendingString:[tail uppercaseString]];
    }
    self.qrSeenDevices = [NSMutableSet set];
    [self showMessage:[NSString stringWithFormat:@"QR code: %@, matching device: %@", code, self.qrMatchCode]];

    // 匹配前断开残留的 GATT 连接，让设备恢复广播
    [self disconnectAllGatt];
    [self startQrStage1];

    __weak typeof(self) weakSelf = self;
    self.qrStage1Timer = [NSTimer scheduledTimerWithTimeInterval:kQrMatchStage1Timeout repeats:NO block:^(NSTimer * _Nonnull timer) {
        [weakSelf startQrStage2];
    }];
    self.qrTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:kQrMatchTotalTimeout repeats:NO block:^(NSTimer * _Nonnull timer) {
        [weakSelf onQrMatchTimeout];
    }];

    // 不再弹进度框：匹配过程只在状态栏显示，再点一次扫码图标可取消
    [self showMessage:@"Matching... tap the QR icon again to cancel"];
}

- (void)startQrStage1 {
    __weak typeof(self) weakSelf = self;
    if ([[self.qrMatchCode uppercaseString] hasPrefix:@"BM"]) {
        // Sleepace 设备
        SleepaceBleManager *sleepace = [SleepaceBleManager getInstance:self];
        [sleepace setScanCallback:^(DeviceInfo * _Nonnull deviceInfo) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.qrMatching) return;
            if ([strongSelf qrDeviceMatches:deviceInfo code:strongSelf.qrMatchCode]) {
                [strongSelf onQrMatchHit:deviceInfo];
            }
        }];
        [sleepace startScanWithTimeout:kQrMatchTotalTimeout filterPrefix:nil filterType:FilterTypeDeviceName];
    } else {
        // ESP 雷达设备：不过滤扫全部，回调里逐个比对
        [self startQrRadarScan];
    }
}

/// 3 秒未命中：ESP 雷达改用完整 QR 码兜底匹配；Sleepace（BM）无兜底，继续原扫描
- (void)startQrStage2 {
    if (!self.qrMatching) return;
    NSString *code = self.qrOriginalCode ?: @"";
    if ([[code uppercaseString] hasPrefix:@"BM"]) return;
    [self showMessage:[NSString stringWithFormat:@"Trying fallback device id: %@", code]];
    self.qrMatchCode = code;
    [self stopQrScans];
    [self startQrRadarScan];
}

/// 匹配过程中把扫到的设备实时打到状态栏，方便确认设备是否在广播
- (void)reportQrScannedDevice:(DeviceInfo *)dev {
    NSString *key = dev.macAddress ?: dev.deviceId ?: dev.deviceName;
    if (key.length == 0 || [self.qrSeenDevices containsObject:key]) return;
    [self.qrSeenDevices addObject:key];
    [self showMessage:[NSString stringWithFormat:@"Scanned: %@ (%@)", dev.deviceName ?: @"", dev.macAddress ?: @""]];
}

- (void)startQrRadarScan {
    __weak typeof(self) weakSelf = self;
    RadarBleManager *radar = [RadarBleManager sharedManager];
    [radar setScanCallback:^(DeviceInfo * _Nonnull deviceInfo) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.qrMatching) return;
        [strongSelf reportQrScannedDevice:deviceInfo];
        if ([strongSelf qrDeviceMatches:deviceInfo code:strongSelf.qrMatchCode]) {
            [strongSelf onQrMatchHit:deviceInfo];
        }
    }];
    [radar startScanWithTimeout:kQrMatchTotalTimeout filterPrefix:nil filterType:FilterTypeDeviceName];
}

/// 非空且忽略大小写相等（对 nil 发 caseInsensitiveCompare 会返回 0 = NSOrderedSame，必须先判空）
static BOOL QrCodeEquals(NSString * _Nullable a, NSString *b) {
    return a.length > 0 && [a caseInsensitiveCompare:b] == NSOrderedSame;
}

- (BOOL)qrDeviceMatches:(DeviceInfo *)dev code:(NSString *)code {
    NSString *c = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (c.length == 0) return NO;
    NSString *cNoColon = [c stringByReplacingOccurrencesOfString:@":" withString:@""];
    NSString *macNoColon = [dev.macAddress stringByReplacingOccurrencesOfString:@":" withString:@""];
    return QrCodeEquals(dev.deviceId, c)
        || QrCodeEquals(dev.deviceName, c)
        || QrCodeEquals(dev.macAddress, c)
        || QrCodeEquals(macNoColon, cNoColon)
        || [self qrSuffixMatches:dev code:cNoColon macNoColon:macNoColon];
}

/// 设备广播名为 "TSBLU"+MAC 后 6 位；QR 码是完整 MAC/序列号时做后缀匹配
- (BOOL)qrSuffixMatches:(DeviceInfo *)dev code:(NSString *)cNoColon macNoColon:(NSString *)macNoColon {
    if (cNoColon.length < 6) return NO;
    NSString *suffix6 = [cNoColon substringFromIndex:cNoColon.length - 6];
    NSString *tsblu = [@"TSBLU" stringByAppendingString:suffix6];
    if (QrCodeEquals(dev.deviceName, tsblu) || QrCodeEquals(dev.deviceId, tsblu)) return YES;
    return macNoColon.length >= 6 && [macNoColon rangeOfString:suffix6 options:NSCaseInsensitiveSearch | NSBackwardsSearch | NSAnchoredSearch].location != NSNotFound;
}

- (void)onQrMatchHit:(DeviceInfo *)device {
    NSString *qr = self.qrOriginalCode;
    [self stopQrMatch];
    self.selectedQrCode = qr;
    [self showMessage:[NSString stringWithFormat:@"QR matched device: %@", device.deviceId]];
    [self onDeviceSelected:device];
}

- (void)onQrMatchTimeout {
    if (!self.qrMatching) return;
    NSString *code = self.qrOriginalCode ?: @"";
    [self stopQrMatch];
    [self showMessage:[NSString stringWithFormat:@"Device not found: %@", code]];
}

- (void)stopQrScans {
    [[RadarBleManager sharedManager] stopScan];
    [[SleepaceBleManager getInstance:self] stopScan];
}

- (void)stopQrMatch {
    BOOL wasMatching = self.qrMatching;
    self.qrMatching = NO;
    [self.qrStage1Timer invalidate];
    self.qrStage1Timer = nil;
    [self.qrTimeoutTimer invalidate];
    self.qrTimeoutTimer = nil;
    if (wasMatching) {
        [self stopQrScans];
    }
}

- (void)cancelQrMatch {
    [self stopQrMatch];
    [self showMessage:@"QR match canceled"];
}

#pragma mark - ScanViewControllerDelegate

- (void)scanViewController:(ScanViewController *)controller didSelectDevice:(DeviceInfo *)device {
    self.selectedQrCode = nil;  // BLE 手动选择没有 QR 码
    [self onDeviceSelected:device];
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
    // 输入结束时自动去除头尾空格（密码允许首尾空格，不处理）
    if (textField == self.wifiPasswordTextField) return;
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

    
