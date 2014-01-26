//
//  FCDatabase.h
//  FCModelTest
//
//  Created by 张光宇 on 1/25/14.
//  Copyright (c) 2014 Marco Arment. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifdef COCOAPODS
#import <FMDB/FMDatabase.h>
#import <FMDB/FMDatabaseQueue.h>
#else
#import "FMDatabase.h"
#import "FMDatabaseQueue.h"
#endif



// FCFieldInfo is used for NULL/NOT NULL rules and default values
typedef NS_ENUM(NSInteger, FCFieldType) {
    FCFieldTypeOther = 0,
    FCFieldTypeText,
    FCFieldTypeInteger,
    FCFieldTypeDouble,
    FCFieldTypeBool
};

@interface FCFieldInfo : NSObject
@property (nonatomic, assign) BOOL nullAllowed;
@property (nonatomic, assign) FCFieldType type;
@property (nonatomic) id defaultValue;
@end


@protocol FCDatabase <NSObject>
- (id)initWithPath:(NSString *)path;
- (void)inDatabase:(void (^)(FMDatabase *db))block;
- (void)close;

- (NSDictionary *)fieldInfos:(Class)clazz;
- (NSString *)primaryKeyName:(Class)clazz;
- (FCFieldInfo *)primaryFieldInfo:(Class)clazz;
@end

@interface FCDefaultDatabase : NSObject<FCDatabase>
+ (instancetype)open:(NSString *)path builder:(void (^)(FMDatabase *db, int *schemaVersion))schemaBuilder;
@end


