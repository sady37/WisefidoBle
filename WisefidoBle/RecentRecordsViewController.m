//
//  RecentRecordsViewController.m
//  WisefidoBle
//

#import "RecentRecordsViewController.h"

@interface RecentRecordCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UIButton *revealButton;
@property (nonatomic, copy, nullable) NSString *maskedText;
@property (nonatomic, copy, nullable) NSString *revealedText;
@property (nonatomic, strong, nullable) NSTimer *revealTimer;
@property (nonatomic, strong) NSLayoutConstraint *revealWidthConstraint;
- (void)configureForServerWithAddress:(NSString *)address port:(NSNumber *)port protocol:(NSString *)protocol;
- (void)configureForWiFiWithSSID:(NSString *)ssid password:(NSString *)password;
- (void)cancelRevealTimer;
@end

@implementation RecentRecordCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_deleteButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_deleteButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        if (@available(iOS 15.0, *)) {
            UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
            configuration.title = @"Del";
            configuration.baseBackgroundColor = [UIColor systemRedColor];
            configuration.baseForegroundColor = [UIColor whiteColor];
            configuration.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 10.0, 4.0, 10.0);
            _deleteButton.configuration = configuration;
        } else {
            [_deleteButton setTitle:@"Del" forState:UIControlStateNormal];
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            _deleteButton.contentEdgeInsets = UIEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
            #pragma clang diagnostic pop
            if (@available(iOS 13.0, *)) {
                _deleteButton.backgroundColor = [UIColor systemRedColor];
            } else {
                _deleteButton.backgroundColor = [UIColor redColor];
            }
            [_deleteButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            _deleteButton.layer.cornerRadius = 6.0;
            _deleteButton.layer.masksToBounds = YES;
        }
        [self.contentView addSubview:_deleteButton];

        _revealButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _revealButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_revealButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_revealButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        if (@available(iOS 13.0, *)) {
            UIImage *eyeImage = [UIImage systemImageNamed:@"eye"];
            [_revealButton setImage:eyeImage forState:UIControlStateNormal];
            _revealButton.tintColor = [UIColor labelColor];
        } else {
            [_revealButton setTitle:@"Show" forState:UIControlStateNormal];
            [_revealButton setTitleColor:[UIColor darkTextColor] forState:UIControlStateNormal];
        }
        _revealButton.hidden = YES;
        [self.contentView addSubview:_revealButton];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.numberOfLines = 1;
        [self.contentView addSubview:_titleLabel];

        self.revealWidthConstraint = [_revealButton.widthAnchor constraintEqualToConstant:0.0];

        [NSLayoutConstraint activateConstraints:@[
            [_deleteButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12.0],
            [_deleteButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

            [_revealButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12.0],
            [_revealButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            self.revealWidthConstraint,

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_deleteButton.trailingAnchor constant:12.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_revealButton.leadingAnchor constant:-12.0],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]
        ]];

        [_revealButton addTarget:self action:@selector(handleRevealButtonTap) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self cancelRevealTimer];
    self.maskedText = nil;
    self.revealedText = nil;
    self.titleLabel.text = @"";
    self.revealButton.hidden = YES;
    self.revealWidthConstraint.constant = 0.0;
}

- (void)dealloc {
    [self cancelRevealTimer];
}

- (void)configureForServerWithAddress:(NSString *)address port:(NSNumber *)port protocol:(NSString *)protocol {
    [self cancelRevealTimer];
    NSString *normalizedProtocol = protocol.length ? protocol.lowercaseString : @"tcp";
    NSInteger portValue = port ? port.integerValue : 0;
    NSString *portString = (portValue > 0) ? [NSString stringWithFormat:@"%ld", (long)portValue] : @"";
    NSString *protocolPort = portString.length ? [NSString stringWithFormat:@"%@%@", normalizedProtocol, portString] : normalizedProtocol;
    self.titleLabel.text = address.length ? [NSString stringWithFormat:@"%@:%@", address, protocolPort] : protocolPort;
    self.revealButton.hidden = YES;
    self.revealWidthConstraint.constant = 0.0;
    self.revealButton.accessibilityLabel = nil;
}

- (void)configureForWiFiWithSSID:(NSString *)ssid password:(NSString *)password {
    [self cancelRevealTimer];
    NSString *displaySSID = ssid ?: @"";
    if (password.length > 0) {
        NSString *maskedPassword = @"••••";
        NSString *separator = displaySSID.length ? @": " : @"";
        self.maskedText = [NSString stringWithFormat:@"%@%@%@", displaySSID, separator, maskedPassword];
        self.revealedText = [NSString stringWithFormat:@"%@%@%@", displaySSID, separator, password];
        self.titleLabel.text = self.maskedText;
        self.revealButton.hidden = NO;
        self.revealButton.accessibilityLabel = @"Show Password";
        self.revealWidthConstraint.constant = 44.0;
    } else {
        self.maskedText = displaySSID;
        self.revealedText = nil;
        self.titleLabel.text = displaySSID;
        self.revealButton.hidden = YES;
        self.revealWidthConstraint.constant = 0.0;
    }
}

- (void)handleRevealButtonTap {
    if (self.revealedText.length == 0) {
        return;
    }
    self.titleLabel.text = self.revealedText;
    [self cancelRevealTimer];
    NSTimer *timer = [NSTimer timerWithTimeInterval:3.0 target:self selector:@selector(hidePassword) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.revealTimer = timer;
}

- (void)hidePassword {
    self.titleLabel.text = self.maskedText;
    [self cancelRevealTimer];
}

- (void)cancelRevealTimer {
    NSTimer *timer = self.revealTimer;
    if (timer) {
        [timer invalidate];
        self.revealTimer = nil;
    }
}

@end

@interface RecentRecordsViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *mutableRecords;

@end

@implementation RecentRecordsViewController

- (instancetype)initWithType:(RecentRecordType)type
                     records:(NSArray<NSDictionary *> *)records
            selectionHandler:(RecentRecordSelectionHandler)selectionHandler
               deleteHandler:(RecentRecordDeleteHandler)deleteHandler {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _type = type;
        _mutableRecords = [records mutableCopy] ?: [NSMutableArray array];
        _selectionHandler = [selectionHandler copy];
        _deleteHandler = [deleteHandler copy];
        self.modalPresentationStyle = UIModalPresentationPopover;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        self.view.backgroundColor = [UIColor whiteColor];
    }
    self.title = (self.type == RecentRecordTypeServer) ? @"server:tcp/udp port" : @"Recent Wi-Fi";

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    _tableView.rowHeight = 48.0;
    [_tableView registerClass:[RecentRecordCell class] forCellReuseIdentifier:@"RecentRecordCell"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    [self updatePreferredContentSize];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updatePreferredContentSize];
}

- (void)updatePreferredContentSize {
    CGFloat rowHeight = 48.0;
    NSUInteger rowCount = self.mutableRecords.count + 1; // include Close row
    CGFloat height = MIN(MAX(rowCount, 1) * rowHeight, 6 * rowHeight);
    self.preferredContentSize = CGSizeMake(360.0, height);
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.mutableRecords.count + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == self.mutableRecords.count) {
        UITableViewCell *closeCell = [tableView dequeueReusableCellWithIdentifier:@"CloseCell"];
        if (!closeCell) {
            closeCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"CloseCell"];
            closeCell.textLabel.textAlignment = NSTextAlignmentCenter;
            if (@available(iOS 13.0, *)) {
                closeCell.textLabel.textColor = [UIColor systemBlueColor];
            } else {
                closeCell.textLabel.textColor = [UIColor blueColor];
            }
        }
        closeCell.textLabel.text = @"Close";
        closeCell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return closeCell;
    }

    RecentRecordCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RecentRecordCell" forIndexPath:indexPath];
    NSDictionary *record = self.mutableRecords[indexPath.row];

    if (self.type == RecentRecordTypeServer) {
        NSString *address = record[@"serverAddress"] ?: @"";
        NSNumber *port = record[@"serverPort"] ?: @(0);
        NSString *protocol = record[@"serverProtocol"] ?: @"tcp";
        [cell configureForServerWithAddress:address port:port protocol:protocol];
    } else {
        NSString *ssid = record[@"ssid"] ?: @"";
        NSString *password = record[@"password"] ?: @"";
        [cell configureForWiFiWithSSID:ssid password:password];
    }

    cell.deleteButton.tag = indexPath.row;
    [cell.deleteButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [cell.deleteButton addTarget:self action:@selector(handleDeleteButton:) forControlEvents:UIControlEventTouchUpInside];

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == self.mutableRecords.count) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (self.selectionHandler && indexPath.row < self.mutableRecords.count) {
        self.selectionHandler(self.mutableRecords[indexPath.row]);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Actions

- (void)handleDeleteButton:(UIButton *)sender {
    NSUInteger index = sender.tag;
    if (index >= self.mutableRecords.count) {
        return;
    }

    if (self.deleteHandler && !self.deleteHandler(index)) {
        return;
    }

    [self.mutableRecords removeObjectAtIndex:index];
    [self.tableView reloadData];
    [self updatePreferredContentSize];

    if (self.mutableRecords.count == 0) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end

