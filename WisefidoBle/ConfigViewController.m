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
@property (nonatomic, strong) UIStackView *rulesStack;  // 在线模板规则，条数不限，动态生成
@property (nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *prefixFields;  // 规则 name -> 前缀输入框
@property (nonatomic, strong) UITextField *customPrefixTextField;
@property (nonatomic, strong) UITextField *customServerTextField;
@property (nonatomic, strong) UITextField *customPortTextField;
@property (nonatomic, strong) UISwitch *customTlsSwitch;
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

- (UILabel *)serverValueLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 1;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    return label;
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

    // 默认设备服务器：标题 + Reset
    UILabel *serverTitle = [self labelWithText:@"Default Device Server:" bold:YES];
    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetButton setTitle:@"Reset" forState:UIControlStateNormal];
    [resetButton addTarget:self action:@selector(handleResetButton) forControlEvents:UIControlEventTouchUpInside];
    [resetButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *serverTitleRow = [[UIStackView alloc] initWithArrangedSubviews:@[serverTitle, resetButton]];
    serverTitleRow.axis = UILayoutConstraintAxisHorizontal;
    [_contentStack addArrangedSubview:serverTitleRow];

    // 在线模板规则：前缀可改，服务器跟随在线模板
    _rulesStack = [[UIStackView alloc] init];
    _rulesStack.axis = UILayoutConstraintAxisVertical;
    _rulesStack.spacing = 6;
    [_contentStack addArrangedSubview:_rulesStack];
    [_contentStack setCustomSpacing:20 afterView:_rulesStack];
    _prefixFields = [NSMutableDictionary dictionary];

    // 本地自定义规则（优先级最高）：前缀、服务器、端口、TLS 都可改
    _customPrefixTextField = [self textFieldWithPlaceholder:@""];
    _customServerTextField = [self textFieldWithPlaceholder:@"app.wisefido.com"];
    _customServerTextField.keyboardType = UIKeyboardTypeURL;
    _customPortTextField = [self textFieldWithPlaceholder:@"29010"];
    _customPortTextField.keyboardType = UIKeyboardTypeNumberPad;
    _customTlsSwitch = [[UISwitch alloc] init];
    UILabel *tlsLabel = [self labelWithText:@"TLS" bold:NO];
    tlsLabel.font = [UIFont systemFontOfSize:14];
    [tlsLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_customTlsSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *portStack = [[UIStackView alloc] initWithArrangedSubviews:@[_customPortTextField, tlsLabel, _customTlsSwitch]];
    portStack.axis = UILayoutConstraintAxisHorizontal;
    portStack.alignment = UIStackViewAlignmentCenter;
    portStack.spacing = 8;

    [_contentStack addArrangedSubview:[self rowWithTitle:@"Custom Prefix:" content:_customPrefixTextField]];
    [_contentStack addArrangedSubview:[self rowWithTitle:@"Custom Server:" content:_customServerTextField]];
    [_contentStack addArrangedSubview:[self rowWithTitle:@"Port:" content:portStack]];

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

/// 每条规则两行：「<name> Prefix: [输入框]」+「Server: host:port  TLS=Y/N」
- (void)fillServerRules:(NSArray<NSDictionary<NSString *, id> *> *)rules custom:(nullable NSDictionary<NSString *, id> *)custom {
    for (UIView *view in _rulesStack.arrangedSubviews) {
        [view removeFromSuperview];
    }
    [_prefixFields removeAllObjects];
    for (NSDictionary *rule in rules) {
        NSString *name = rule[kDeviceServerRuleNameKey];
        UITextField *prefixField = [self textFieldWithPlaceholder:@""];
        prefixField.text = rule[kDeviceServerRulePrefixKey];
        _prefixFields[name] = prefixField;
        UILabel *serverLabel = [self serverValueLabel];
        serverLabel.text = [DeviceServerRules displayServerForRule:rule];
        [_rulesStack addArrangedSubview:[self rowWithTitle:[NSString stringWithFormat:@"%@ Prefix:", name] content:prefixField]];
        [_rulesStack addArrangedSubview:[self rowWithTitle:@"Server:" labelWidth:56 content:serverLabel]];
    }
    _customPrefixTextField.text = custom[kDeviceServerRulePrefixKey];
    _customServerTextField.text = custom[kDeviceServerRuleServerKey];
    _customPortTextField.text = custom[kDeviceServerRulePortKey];
    _customTlsSwitch.on = [custom[kDeviceServerRuleTlsKey] boolValue];
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

/// 恢复默认服务器规则（在线模板，无则内置）并清空自定义，确认后才清除本地修改
- (void)handleResetButton {
    [self fillServerRules:[DeviceServerRules defaultRules] custom:nil];
}

- (void)handleCancelButton {
    CONFIGLOG(@"Click Cancel Button");
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleConfirmButton {
    // 自定义服务器填了但端口不对时提示，避免静默丢弃
    NSCharacterSet *spaces = [NSCharacterSet whitespaceCharacterSet];
    NSString *customServer = [_customServerTextField.text stringByTrimmingCharactersInSet:spaces] ?: @"";
    NSString *customPort = [_customPortTextField.text stringByTrimmingCharactersInSet:spaces] ?: @"";
    if (customServer.length > 0 && ![DeviceServerRules isValidPort:customPort]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                       message:@"Custom server needs a valid port (1-65535)"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // 获取用户输入的雷达设备名
    NSString *radarName = _radarNameTextField.text;
    radarName = [radarName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; // 去除前后空格

    if (radarName.length == 0) {
        radarName = @"TSBLU"; // 默认值
    } else {
        // Save directly to storage
        [_configStorage saveRadarDeviceName:radarName];
    }

    FilterType filterType = _currentFilterType;
    [_configStorage saveFilterType:filterType];

    // 保存默认设备服务器规则
    [_prefixFields enumerateKeysAndObjectsUsingBlock:^(NSString *name, UITextField *field, BOOL *stop) {
        [DeviceServerRules saveUserPrefix:field.text forRuleName:name];
    }];
    [DeviceServerRules saveCustomRuleWithPrefix:_customPrefixTextField.text server:customServer port:customPort tls:_customTlsSwitch.isOn];

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
