//
//  RecentRecordsViewController.h
//  WisefidoBle
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, RecentRecordType) {
    RecentRecordTypeServer,
    RecentRecordTypeWiFi
};

typedef void (^RecentRecordSelectionHandler)(NSDictionary *selectedRecord);
typedef BOOL (^RecentRecordDeleteHandler)(NSUInteger index);

@interface RecentRecordsViewController : UIViewController

@property (nonatomic, assign, readonly) RecentRecordType type;
@property (nonatomic, copy, readonly) RecentRecordSelectionHandler selectionHandler;
@property (nonatomic, copy, readonly) RecentRecordDeleteHandler deleteHandler;

- (instancetype)initWithType:(RecentRecordType)type
                     records:(NSArray<NSDictionary *> *)records
            selectionHandler:(RecentRecordSelectionHandler)selectionHandler
               deleteHandler:(RecentRecordDeleteHandler)deleteHandler;

@end

NS_ASSUME_NONNULL_END

