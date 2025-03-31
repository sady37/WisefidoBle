//
//  ConfigViewController.m
//

#import "ConfigViewController.h"
#import "ConfigStorage.h"

// 日志宏定义
#define CONFIGLOG(fmt, ...) NSLog((@"[ConfigViewController] " fmt), ##__VA_ARGS__)

@interface ConfigViewController () <UITextFieldDelegate> // Ensure conformance to UITextFieldDelegate

// UI组件
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *radarLabel; 
@property (nonatomic, strong) UITextField *radarNameTextField;
@property (nonatomic, strong) UILabel *filterTypeLabel;
@property (nonatomic, strong) UISegmentedControl *filterTypeSegment;
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
        self.modalPresentationStyle = UIModalPresentationFormSheet;
        self.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    }
    return self;
}
#pragma mark - 视图生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 设置背景
    self.view.backgroundColor = [UIColor systemBackgroundColor];

	_configStorage = [[ConfigStorage alloc] init];    
    // 初始化UI组件
    [self setupViews];
    [self setupConstraints];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
[self.view addGestureRecognizer:tap];

    // 更新UI以反映当前配置
    [self updateUIWithCurrentConfig];
}

#pragma mark - UI设置

- (void)setupViews {
    // 标题标签
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"Configuration";
    _titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_titleLabel];
    
	// 雷达名称标签
    _radarLabel = [[UILabel alloc] init];
    _radarLabel.text = @"RadarName:";
    _radarLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:_radarLabel];

    // Radar设备名称输入框
    _radarNameTextField = [[UITextField alloc] init];
    _radarNameTextField.placeholder = @"TSBLU";
    _radarNameTextField.borderStyle = UITextBorderStyleRoundedRect;
    _radarNameTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _radarNameTextField.returnKeyType = UIReturnKeyDone;
    _radarNameTextField.delegate = self;
    [self.view addSubview:_radarNameTextField];
    
    // 过滤类型标签
    _filterTypeLabel = [[UILabel alloc] init];
    _filterTypeLabel.text = @"FilterType:";
    _filterTypeLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.view addSubview:_filterTypeLabel];
    
    // 过滤类型选择器
    _filterTypeSegment = [[UISegmentedControl alloc] initWithItems:@[@"Device Name", @"MAC Address", @"UUID"]];
    _filterTypeSegment.selectedSegmentIndex = 0; // 默认选择第一项
    [self.view addSubview:_filterTypeSegment];
    
    // 取消按钮
    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    [_cancelButton addTarget:self action:@selector(handleCancelButton) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_cancelButton];
    
    // 确认按钮
    _confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_confirmButton setTitle:@"Confirm" forState:UIControlStateNormal];
    _confirmButton.backgroundColor = [UIColor systemBlueColor];
    [_confirmButton setTitleColor:[UIColor systemBackgroundColor] forState:UIControlStateNormal];
    _confirmButton.layer.cornerRadius = 5.0;
    [_confirmButton addTarget:self action:@selector(handleConfirmButton) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_confirmButton];
}

- (void)setupConstraints {
    // 禁用自动约束转换
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_radarLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _radarNameTextField.translatesAutoresizingMaskIntoConstraints = NO;
    _filterTypeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _filterTypeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    _confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 内容宽度
    CGFloat contentWidth = MIN(300, self.view.bounds.size.width -60); // 限制最大宽度为300或视图宽度的80%
    
[NSLayoutConstraint activateConstraints:@[
	    // 标题标签
	    [_titleLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
	    [_titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
	    [_titleLabel.widthAnchor constraintEqualToConstant:contentWidth],

	    // Radar标签
	    [_radarLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:20],
	    [_radarLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10], // 仅保留父视图左侧约束
	    [_radarLabel.widthAnchor constraintEqualToConstant:80], // 关键修改：固定宽度
	    [_radarLabel.heightAnchor constraintEqualToConstant:30], // 明确高度避免压缩r
	    // Radar输入框（水平排列在标签右侧）
	    [_radarNameTextField.leadingAnchor constraintEqualToAnchor:_radarLabel.trailingAnchor constant:8], // 关键修改
	    [_radarNameTextField.centerYAnchor constraintEqualToAnchor:_radarLabel.centerYAnchor], // 垂直居中
	    [_radarNameTextField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8], // 右侧边界
	    [_radarNameTextField.heightAnchor constraintEqualToConstant:44], 
        
        // 过滤类型标签
        [_filterTypeLabel.topAnchor constraintEqualToAnchor:_radarLabel.bottomAnchor constant:20],
        [_filterTypeLabel.leadingAnchor constraintEqualToAnchor:_radarLabel.leadingAnchor],
        
        // 过滤类型选择器
        [_filterTypeSegment.topAnchor constraintEqualToAnchor:_filterTypeLabel.bottomAnchor constant:10],
        [_filterTypeSegment.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_filterTypeSegment.widthAnchor constraintEqualToConstant:contentWidth],
        
        // 取消按钮
        [_cancelButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [_cancelButton.trailingAnchor constraintEqualToAnchor:self.view.centerXAnchor constant:-10],
        [_cancelButton.widthAnchor constraintEqualToConstant:100],
        [_cancelButton.heightAnchor constraintEqualToConstant:44],
        
        // 确认按钮
        [_confirmButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [_confirmButton.leadingAnchor constraintEqualToAnchor:self.view.centerXAnchor constant:10],
        [_confirmButton.widthAnchor constraintEqualToConstant:100],
        [_confirmButton.heightAnchor constraintEqualToConstant:44]
    ]];
}

- (void)updateUIWithCurrentConfig {
    // 设置雷达设备名
    _radarNameTextField.text = _currentRadarName;
    
    // 设置过滤类型
    switch (_currentFilterType) {
        case FilterTypeDeviceName:
            _filterTypeSegment.selectedSegmentIndex = 0;
            break;
        case FilterTypeMac:
            _filterTypeSegment.selectedSegmentIndex = 1;
            break;
        case FilterTypeUUID:
            _filterTypeSegment.selectedSegmentIndex = 2;
            break;
        default:
            _filterTypeSegment.selectedSegmentIndex = 0;
            break;
    }
}

#pragma mark - 按钮事件

- (void)handleCancelButton {
    CONFIGLOG(@"Click Cancel Button");
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleConfirmButton {
    // 获取用户输入的雷达设备名
    NSString *radarName = _radarNameTextField.text;
    radarName = [radarName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]; // 去除前后空格

    if (radarName.length == 0) {
        radarName = @"TSBLU"; // 默认值
    } else {
        // Save directly to storage
        [_configStorage saveRadarDeviceName:radarName];
    }
    
    // 获取用户选择的过滤类型
    FilterType filterType;
    switch (_filterTypeSegment.selectedSegmentIndex) {
        case 0:
            filterType = FilterTypeDeviceName;
            break;
        case 1:
            filterType = FilterTypeMac;
            break;
        case 2:
            filterType = FilterTypeUUID;
            break;
        default:
            filterType = FilterTypeDeviceName;
            break;
    }
    
    // Save filter type too
    [_configStorage saveFilterType:filterType];
    
    CONFIGLOG(@"Confirm configuration: devicename=%@, filter type=%ld", radarName, (long)filterType);
    
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
