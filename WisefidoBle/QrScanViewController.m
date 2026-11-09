//
//  QrScanViewController.m
//

#import "QrScanViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "WisefidoBle-Swift.h"

@interface QrScanViewController () <AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *previewContainer;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *closeButton;

@property (nonatomic, strong, nullable) AVCaptureSession *session;
@property (nonatomic, strong, nullable) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, assign) BOOL didDeliverCode;
// 同一画面旁路识别盒底 ArUco 码（测高入口），只在 arucoQueue 上访问 arucoWorker
@property (nonatomic, strong) dispatch_queue_t arucoQueue;
@property (nonatomic, strong) ArucoScanWorker *arucoWorker;

@end

@implementation QrScanViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _sessionQueue = dispatch_queue_create("com.wisefido.ble.qrscan", DISPATCH_QUEUE_SERIAL);
    _arucoQueue = dispatch_queue_create("com.wisefido.ble.qrscan.aruco", DISPATCH_QUEUE_SERIAL);
    _arucoWorker = [[ArucoScanWorker alloc] init];
    [self setupViews];
    [self requestCameraAndStart];
}

- (void)setupViews {
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"Scan device QR code";
    _titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_titleLabel];

    // 取景框：高约屏幕 26%，面板贴顶显示（单手好够）
    _previewContainer = [[UIView alloc] init];
    _previewContainer.backgroundColor = [UIColor blackColor];
    _previewContainer.layer.cornerRadius = 8.0;
    _previewContainer.clipsToBounds = YES;
    _previewContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_previewContainer];

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.text = @"Point the camera at the device QR code, or at the ArUco label on the box bottom to measure radar height";
    _hintLabel.font = [UIFont systemFontOfSize:14];
    _hintLabel.textColor = [UIColor secondaryLabelColor];
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.numberOfLines = 0;
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_hintLabel];

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setTitle:@"Back" forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [_closeButton addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
    _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_closeButton];

    CGFloat previewHeight = floor(UIScreen.mainScreen.bounds.size.height * 0.26);
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_previewContainer.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:12],
        [_previewContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_previewContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_previewContainer.heightAnchor constraintEqualToConstant:previewHeight],

        [_hintLabel.topAnchor constraintEqualToAnchor:_previewContainer.bottomAnchor constant:8],
        [_hintLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_hintLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_closeButton.topAnchor constraintEqualToAnchor:_hintLabel.bottomAnchor constant:8],
        [_closeButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_closeButton.heightAnchor constraintEqualToConstant:44],
        // 面板高度由内容决定（作为顶部浮层，父视图只约束 top/leading/trailing）
        [self.view.bottomAnchor constraintEqualToAnchor:_closeButton.bottomAnchor constant:12],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _previewLayer.frame = _previewContainer.bounds;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopSession];
}

#pragma mark - Camera

- (void)requestCameraAndStart {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    switch (status) {
        case AVAuthorizationStatusAuthorized:
            [self startSession];
            break;
        case AVAuthorizationStatusNotDetermined: {
            __weak typeof(self) weakSelf = self;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    if (granted) {
                        [strongSelf startSession];
                    } else {
                        [strongSelf showCameraDenied];
                    }
                });
            }];
            break;
        }
        default:
            [self showCameraDenied];
            break;
    }
}

- (void)showCameraDenied {
    _hintLabel.text = @"Camera access denied. Enable it in Settings > WisefidoBle > Camera.";
    _hintLabel.textColor = [UIColor systemRedColor];
}

- (void)showCameraError:(NSString *)reason {
    _hintLabel.text = [NSString stringWithFormat:@"Camera unavailable: %@", reason];
    _hintLabel.textColor = [UIColor systemRedColor];
}

- (void)startSession {
    if (_session) return;

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!camera) {
        [self showCameraError:@"no camera"];
        return;
    }
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&error];
    if (!input || ![session canAddInput:input]) {
        [self showCameraError:error.localizedDescription ?: @"input rejected"];
        return;
    }
    [session addInput:input];

    AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
    if (![session canAddOutput:output]) {
        [self showCameraError:@"metadata output rejected"];
        return;
    }
    [session addOutput:output];
    [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    if ([output.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode]) {
        output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
    }

    // ArUco 旁路：BGRA 帧，丢弃迟到帧（检测比帧率慢）
    AVCaptureVideoDataOutput *video = [[AVCaptureVideoDataOutput alloc] init];
    video.alwaysDiscardsLateVideoFrames = YES;
    video.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    if ([session canAddOutput:video]) {
        [session addOutput:video];
        [video setSampleBufferDelegate:self queue:_arucoQueue];
    }

    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _previewLayer.frame = _previewContainer.bounds;
    [_previewContainer.layer addSublayer:_previewLayer];

    _session = session;
    dispatch_async(_sessionQueue, ^{
        [session startRunning];
    });
}

- (void)stopSession {
    AVCaptureSession *session = _session;
    if (!session) return;
    dispatch_async(_sessionQueue, ^{
        if (session.isRunning) {
            [session stopRunning];
        }
    });
}

- (void)handleClose {
    [self closeAnimated:YES completion:nil];
}

- (void)closeAnimated:(BOOL)animated completion:(void (^)(void))completion {
    [self stopSession];
    if (self.parentViewController) {
        // 作为顶部子控制器：上滑并淡出后移除
        UIView *panel = self.view;
        void (^finish)(void) = ^{
            [self willMoveToParentViewController:nil];
            [panel removeFromSuperview];
            [self removeFromParentViewController];
            if (completion) completion();
        };
        if (animated) {
            [UIView animateWithDuration:0.22 animations:^{
                panel.transform = CGAffineTransformMakeTranslation(0, -panel.bounds.size.height);
                panel.alpha = 0;
            } completion:^(BOOL done) { finish(); }];
        } else {
            finish();
        }
    } else {
        [self dismissViewControllerAnimated:animated completion:completion];
    }
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate（ArUco）

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!buffer || ![self.arucoWorker processFrame:buffer]) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.didDeliverCode) return;
        self.didDeliverCode = YES;
        [self stopSession];
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
        id<QrScanViewControllerDelegate> delegate = self.delegate;
        [self closeAnimated:YES completion:^{
            if ([delegate respondsToSelector:@selector(qrScanViewControllerDidDetectAruco:)]) {
                [delegate qrScanViewControllerDidDetectAruco:self];
            }
        }];
    });
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection {
    if (_didDeliverCode) return;
    for (AVMetadataObject *obj in metadataObjects) {
        if (![obj isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) continue;
        NSString *raw = ((AVMetadataMachineReadableCodeObject *)obj).stringValue;
        NSString *text = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length == 0) continue;

        _didDeliverCode = YES;
        [self stopSession];
        // 先关扫码页再回调，避免主页面在 dismiss 过程中弹 alert；闭包强持有 self 保证回调执行
        id<QrScanViewControllerDelegate> delegate = self.delegate;
        [self closeAnimated:YES completion:^{
            [delegate qrScanViewController:self didScanCode:text];
        }];
        return;
    }
}

@end
