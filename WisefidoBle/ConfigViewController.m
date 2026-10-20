//
//  ConfigViewController.m
//

#import "ConfigViewController.h"
#import "ConfigStorage.h"
#import "DeviceServerRules.h"

// 日志宏定义
#define CONFIGLOG(fmt, ...) NSLog((@"[ConfigViewController] " fmt), ##__VA_ARGS__)

static const CGFloat kLabelWidth = 110;

@interface ConfigViewController () <UITextFieldDelegate> // Ensure conformance to UITextFieldDelegate

// UI组件
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UITextField *radarNameTextField;           // Device Prefix（扫描过滤）
@property (nonatomic, strong) NSArray<UIButton *> *filterTypeButtons;    // Device Prefix | MAC Addr | UUID
@property (nonatomic, strong) UIStackView *rulesStack;  // 规则（含 Custom），条数不限，动态生成
@property (nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *prefixFields;  // 规则 name -> 前缀输入框
@property (nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *serverFields;  // 规则 name -> host:port 输入框
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISwitch *> *tlsSwitches;      // 规则 name -> TLS 滑钮
@property (nonatomic, strong) UIButton *configSyncButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *confirmButton;
@property (nonatomic, strong) ConfigStorage *configStorage;

// 数据和回调
@property (nonatomic, copy) NSString *currentRadarName;
@property (nonatomic, assign) FilterType currentFilterType;
@property (nonatomic, copy) ConfigCompletionBlock completionBlock;

@end

@implementation ConfigViewController

#pragma mark - 初始化方法
- (instancetype)initWithRadarDeviceName:(NSString *)radarDeviceName
                             filterType:(FilterType)filterType
                             completion:(ConfigCompletionBlock)completion {
    self = [super init];
    if (self) {
        // Initialize ConfigStorage first
        _configStorage = [[ConfigStorage alloc] init];

        // If radarDeviceName is empty, try to get it from storage
        if (radarDeviceName.length == 0) {
            _currentRadarName = [_configStorage getRadarDeviceName];
        } else {
            _currentRadarName = [radarDeviceName copy];
        }

        _currentFilterType = filterType;
        _completionBlock = [completion copy];

        // 设置模态展示样式
        // 全屏显示，避免内容多时放不下
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    }
    return self;
}
#pragma mark - 视图生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    // 设置背景
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 初始化UI组件
    [self setupViews];
    [self setupConstraints];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    // 更新UI以反映当前配置
    [self updateUIWithCurrentConfig];
}

#pragma mark - UI设置

- (UILabel *)labelWithText:(NSString *)text bold:(BOOL)bold {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = bold ? [UIFont boldSystemFontOfSize:16] : [UIFont systemFontOfSize:16];
    return label;
}

- (UITextField *)textFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *textField = [[UITextField alloc] init];
    textField.placeholder = placeholder;
    textField.borderStyle = UITextBorderStyleRoundedRect;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.delegate = self;
    textField.font = [UIFont systemFontOfSize:14];
    [textField.heightAnchor constraintEqualToConstant:36].active = YES;
    return textField;
}

/// 输入框标错：红色边框 + 红色占位提示
- (void)markServerFieldError:(UITextField *)field placeholder:(NSString *)message {
    field.layer.borderColor = [UIColor systemRedColor].CGColor;
    field.layer.borderWidth = 1;
    field.layer.cornerRadius = 5;
    field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:message attributes:@{NSForegroundColorAttributeName: [UIColor systemRedColor]}];
    [field becomeFirstResponder];
}

/// 一行：固定宽度标签 + 右侧内容
- (UIStackView *)rowWithTitle:(NSString *)title content:(UIView *)content {
    return [self rowWithTitle:title labelWidth:kLabelWidth content:content];
}

- (UIStackView *)rowWithTitle:(NSString *)title labelWidth:(CGFloat)labelWidth content:(UIView *)content {
    UILabel *label = [self labelWithText:title bold:NO];
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor secondaryLabelColor];
    [label.widthAnchor constraintEqualToConstant:labelWidth].active = YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, content]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;
    return row;
}

- (void)setupViews {
    _scrollView = [[UIScrollView alloc] init];
    _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scrollView];

    _contentStack = [[UIStackView alloc] init];
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.spacing = 12;
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_contentStack];

    // 标题标签
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"Configuration";
    _titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_contentStack addArrangedSubview:_titleLabel];

    // 扫描过滤前缀
    _radarNameTextField = [self textFieldWithPlaceholder:@"TSBLU"];
    [_contentStack addArrangedSubview:[self rowWithTitle:@"Device Prefix" content:_radarNameTextField]];

    // 过滤类型：三个独立按钮，单选
    [_contentStack addArrangedSubview:[self labelWithText:@"FilterType:" bold:YES]];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    NSArray<NSString *> *titles = @[@"Device Prefix", @"MAC Addr", @"UUID"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:titles[i] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.layer.cornerRadius = 8;
        button.layer.borderWidth = 1;
        button.layer.borderColor = [UIColor systemBlueColor].CGColor;
        button.tag = i;
        [button addTarget:self action:@selector(handleFilterTypeButton:) forControlEvents:UIControlEventTouchUpInside];
        [button.heightAnchor constraintEqualToConstant:36].active = YES;
        [buttons addObject:button];
    }
    _filterTypeButtons = buttons;
    UIStackView *filterRow = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    filterRow.axis = UILayoutConstraintAxisHorizontal;
    filterRow.distribution = UIStackViewDistributionFillEqually;
    filterRow.spacing = 12;
    [_contentStack addArrangedSubview:filterRow];
    [_contentStack setCustomSpacing:24 afterView:filterRow];

    // 默认设备服务器：标题 + Config Sync
    UILabel *serverTitle = [self labelWithText:@"Default Device Server:" bold:YES];
    _configSyncButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_configSyncButton setTitle:@"Config Sync" forState:UIControlStateNormal];
    [_configSyncButton addTarget:self action:@selector(handleConfigSyncButton) forControlEvents:UIControlEventTouchUpInside];
    [_configSyncButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *serverTitleRow = [[UIStackView alloc] initWithArrangedSubviews:@[serverTitle, _configSyncButton]];
    serverTitleRow.axis = UILayoutConstraintAxisHorizontal;
    [_contentStack addArrangedSubview:serverTitleRow];

    // 规则（含最后一条 Custom）：同一两行格式动态生成
    _rulesStack = [[UIStackView alloc] init];
    _rulesStack.axis = UILayoutConstraintAxisVertical;
    _rulesStack.spacing = 6;
    [_contentStack addArrangedSubview:_rulesStack];
    [_contentStack setCustomSpacing:20 afterView:_rulesStack];
    _prefixFields = [NSMutableDictionary dictionary];
    _serverFields = [NSMutableDictionary dictionary];
    _tlsSwitches = [NSMutableDictionary dictionary];

    // 取消按钮
    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    [_cancelButton addTarget:self action:@selector(handleCancelButton) forControlEvents:UIControlEventTouchUpInside];
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_cancelButton];

    // 确认按钮
    _confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_confirmButton setTitle:@"Confirm" forState:UIControlStateNormal];
    _confirmButton.backgroundColor = [UIColor systemBlueColor];
    [_confirmButton setTitleColor:[UIColor systemBackgroundColor] forState:UIControlStateNormal];
    _confirmButton.layer.cornerRadius = 5.0;
    [_confirmButton addTarget:self action:@selector(handleConfirmButton) forControlEvents:UIControlEventTouchUpInside];
    _confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_confirmButton];
}

- (void)setupConstraints {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:_confirmButton.topAnchor constant:-12],

        [_contentStack.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor constant:20],
        [_contentStack.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor constant:-20],
        [_contentStack.leadingAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.leadingAnchor constant:16],
        [_contentStack.trailingAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.trailingAnchor constant:-16],

        // 取消按钮
        [_cancelButton.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-20],
        [_cancelButton.trailingAnchor constraintEqualToAnchor:self.view.centerXAnchor constant:-10],
        [_cancelButton.widthAnchor constraintEqualToConstant:100],
        [_cancelButton.heightAnchor constraintEqualToConstant:44],

        // 确认按钮
        [_confirmButton.bottomAnchor constraintEqualToAnchor:_cancelButton.bottomAnchor],
        [_confirmButton.leadingAnchor constraintEqualToAnchor:self.view.centerXAnchor constant:10],
        [_confirmButton.widthAnchor constraintEqualToConstant:100],
        [_confirmButton.heightAnchor constraintEqualToConstant:44]
    ]];
}

- (void)updateUIWithCurrentConfig {
    // 设置扫描过滤前缀
    _radarNameTextField.text = _currentRadarName;
    [self updateFilterTypeButtons];
    [self fillServerRules:[DeviceServerRules currentRules] custom:[DeviceServerRules customRule]];
}

/// 每条规则（含 Custom）两行：「<name> Prefix: [输入框] [TLS 滑钮]」+「Server: [host:port 输入框]」；Custom 无配置时显示空输入框
- (void)fillServerRules:(NSArray<NSDictionary<NSString *, id> *> *)rules custom:(nullable NSDictionary<NSString *, id> *)custom {
    for (UIView *view in _rulesStack.arrangedSubviews) {
        [view removeFromSuperview];
    }
    [_prefixFields removeAllObjects];
    [_serverFields removeAllObjects];
    [_tlsSwitches removeAllObjects];

    NSMutableArray<NSDictionary<NSString *, id> *> *allRules = [rules mutableCopy];
    [allRules addObject:custom ?: @{kDeviceServerRuleNameKey: @"Custom"}];
    for (NSDictionary *rule in allRules) {
        NSString *name = rule[kDeviceServerRuleNameKey];

        UITextField *prefixField = [self textFieldWithPlaceholder:@""];
        prefixField.text = rule[kDeviceServerRulePrefixKey] ?: @"";
        _prefixFields[name] = prefixField;
        UISwitch *tlsSwitch = [[UISwitch alloc] init];
        tlsSwitch.on = [rule[kDeviceServerRuleTlsKey] boolValue];
        _tlsSwitches[name] = tlsSwitch;
        [tlsSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *prefixRow = [[UIStackView alloc] initWithArrangedSubviews:@[prefixField, tlsSwitch]];
        prefixRow.axis = UILayoutConstraintAxisHorizontal;
        prefixRow.alignment = UIStackViewAlignmentCenter;
        prefixRow.spacing = 8;

        UITextField *serverField = [self textFieldWithPlaceholder:@"xxx.com:port"];
        serverField.keyboardType = UIKeyboardTypeURL;
        NSString *server = rule[kDeviceServerRuleServerKey] ?: @"";
        NSString *port = rule[kDeviceServerRulePortKey] ?: @"";
        BOOL udp = [[rule[kDeviceServerRuleProtocolKey] lowercaseString] isEqualToString:kDeviceServerProtocolUdp];
        serverField.text = server.length > 0 && port.length > 0 ? [NSString stringWithFormat:@"%@:%@%@", server, udp ? @"udp" : @"", port] : @"";
        _serverFields[name] = serverField;

        [_rulesStack addArrangedSubview:[self rowWithTitle:[NSString stringWithFormat:@"%@ Prefix:", name] content:prefixRow]];
        [_rulesStack addArrangedSubview:[self rowWithTitle:@"Server:" labelWidth:56 content:serverField]];
    }
}

- (void)updateFilterTypeButtons {
    for (UIButton *button in _filterTypeButtons) {
        BOOL selected = (button.tag == _currentFilterType);
        button.backgroundColor = selected ? [UIColor systemBlueColor] : [UIColor clearColor];
        [button setTitleColor:selected ? [UIColor whiteColor] : [UIColor systemBlueColor] forState:UIControlStateNormal];
    }
}

#pragma mark - 按钮事件

- (void)handleFilterTypeButton:(UIButton *)sender {
    switch (sender.tag) {
        case 1:
            _currentFilterType = FilterTypeMac;
            break;
        case 2:
            _currentFilterType = FilterTypeUUID;
            break;
        default:
            _currentFilterType = FilterTypeDeviceName;
            break;
    }
    [self updateFilterTypeButtons];
}

/// 同步最新在线模板（失败则用缓存/内置），并清除本地规则修改与自定义
- (void)handleConfigSyncButton {
    _configSyncButton.enabled = NO;
    [DeviceServerRules refreshFromRemoteWithCompletion:^(BOOL updated) {
        [DeviceServerRules clearUserOverrides];
        [self fillServerRules:[DeviceServerRules defaultRules] custom:nil];
        self->_configSyncButton.enabled = YES;
    }];
}

- (void)handleCancelButton {
    CONFIGLOG(@"Click Cancel Button");
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleConfirmButton {
    NSCharacterSet *spaces = [NSCharacterSet whitespaceCharacterSet];
    NSRegularExpression *portRegex = [NSRegularExpression regularExpressionWithPattern:@"^(tcp|udp)?(\\d+)$" options:NSRegularExpressionCaseInsensitive error:nil];

    // 逐行解析 host:[tcp|udp]port；协议前缀可省略（默认 tcp），tcp/udp 均支持
    for (NSString *name in _serverFields) {
        UITextField *input = _serverFields[name];
        input.layer.borderColor = [UIColor clearColor].CGColor;
        NSString *text = [input.text stringByTrimmingCharactersInSet:spaces] ?: @"";
        NSRange colonRange = [text rangeOfString:@":" options:NSBackwardsSearch];
        NSString *host = colonRange.location != NSNotFound && colonRange.location > 0 ? [[text substringToIndex:colonRange.location] stringByTrimmingCharactersInSet:spaces] : @"";
        NSString *portText = colonRange.location != NSNotFound && colonRange.location > 0 ? [[text substringFromIndex:colonRange.location + 1] stringByTrimmingCharactersInSet:spaces] : @"";
        NSTextCheckingResult *match = [portRegex firstMatchInString:portText options:0 range:NSMakeRange(0, portText.length)];
        NSString *protocol = match && [match rangeAtIndex:1].location != NSNotFound ? [[portText substringWithRange:[match rangeAtIndex:1]] lowercaseString] : kDeviceServerProtocolTcp;
        NSString *port = match ? [portText substringWithRange:[match rangeAtIndex:2]] : nil;
        NSString *prefix = _prefixFields[name].text ?: @"";
        BOOL tls = _tlsSwitches[name].isOn;
        if ([name isEqualToString:@"Custom"]) {
            // 填了服务器但端口不对时提示，避免静默丢弃；留空走 saveCustomRule 的清除语义
            if (host.length > 0 && ![DeviceServerRules isValidPort:port]) {
                [self markServerFieldError:input placeholder:@"host:port (1-65535)"];
                return;
            }
            [DeviceServerRules saveCustomRuleWithPrefix:prefix server:host port:port tls:tls protocol:protocol];
        } else {
            if (host.length == 0 || ![DeviceServerRules isValidPort:port]) {
                [self markServerFieldError:input placeholder:@"host:port (1-65535)"];
                return;
            }
            [DeviceServerRules saveUserRuleForName:name prefix:prefix server:host port:port tls:tls protocol:protocol];
        }
    }

    // 获取用户输入的雷达设备名
    NSString *radarName = _radarNameTextField.text;
    radarName = [radarName stringByTrimmingCharactersInSet:spaces]; // 去除前后空格

    if (radarName.length == 0) {
        radarName = @"TSBLU"; // 默认值
    } else {
        // Save directly to storage
        [_configStorage saveRadarDeviceName:radarName];
    }

    FilterType filterType = _currentFilterType;
    [_configStorage saveFilterType:filterType];

    CONFIGLOG(@"Confirm configuration: devicename=%@, filter type=%ld, server rules=%@", radarName, (long)filterType, [DeviceServerRules currentRules]);

    // 调用回调
    if (_completionBlock) {
        _completionBlock(radarName, filterType);
    }

    // 关闭界面
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}
@end
