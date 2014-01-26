//
//  FCModelTest_Tests.m
//  FCModelTest Tests
//
//  Created by Denis Hennessy on 25/09/2013.
//  Copyright (c) 2013 Marco Arment. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "FCModel.h"
#import "FCModel+Subclass.h"
#import "FCModel+Testing.h"
#import "Person.h"

@interface SimpleModel : FCModel
@property (nonatomic, copy) NSString *uniqueID;
@property (nonatomic, copy) NSString *name;
@end

@implementation SimpleModel
@end

@interface FCModelTest_Tests : XCTestCase

@end

@implementation FCModelTest_Tests

- (void)setUp
{
    [super setUp];
    [[NSFileManager defaultManager] removeItemAtPath:self.dbPath error:nil];
    [self openDatabase];
    
    assert([Person database] == nil);
}

- (void)tearDown
{
    [self closeDatabase];
    [super tearDown];
}

- (void)testBasicStoreRetrieve
{
    SimpleModel *entity1 = [SimpleModel instanceWithPrimaryKey:@"a"];
    entity1.name = @"Alice";
    XCTAssertFalse(entity1.existsInDatabase);
    XCTAssertEqual([entity1 save], FCModelSaveSucceeded);
    XCTAssertTrue(entity1.existsInDatabase);

    SimpleModel *entity2 = [SimpleModel instanceWithPrimaryKey:@"a"];
    XCTAssertTrue(entity2.existsInDatabase);
    XCTAssertTrue([entity1.name isEqualToString:entity2.name]);
}

- (void)testEntityUniquing
{
    SimpleModel *entity1 = [SimpleModel instanceWithPrimaryKey:@"a"];
    entity1.name = [NSString stringWithFormat:@"%f",CFAbsoluteTimeGetCurrent()];
    [entity1 save];
    
    SimpleModel *entity2 = [SimpleModel instanceWithPrimaryKey:@"a"];
    XCTAssertTrue([entity2.name isEqualToString:entity1.name], @"%@ == %@",entity1.name,entity2.name);
}

- (void)testDatabaseCloseFlushesCache
{
    SimpleModel *entity1 = [SimpleModel instanceWithPrimaryKey:@"a"];
    entity1.name = @"Alice222";
    [entity1 save];
    
    [self closeDatabase];
    [self openDatabase];
    
    SimpleModel *entity2 = [SimpleModel instanceWithPrimaryKey:@"a"];
    XCTAssertTrue(entity2.existsInDatabase);
    XCTAssertTrue([entity2.name isEqualToString:entity1.name]);
}

#pragma mark - Helper methods

- (void)openDatabase
{

    FCDefaultDatabase *database = [FCDefaultDatabase open:[self dbPath] builder:^(FMDatabase *db, int *schemaVersion) {
        [db setCrashOnErrors:YES];
        db.traceExecution = YES;
        [db beginTransaction];
        
        void (^failedAt)(int statement) = ^(int statement){
            int lastErrorCode = db.lastErrorCode;
            NSString *lastErrorMessage = db.lastErrorMessage;
            [db rollback];
            NSAssert3(0, @"Migration statement %d failed, code %d: %@", statement, lastErrorCode, lastErrorMessage);
        };
        
        if (*schemaVersion < 1) {
            if (! [db executeUpdate:
                   @"CREATE TABLE SimpleModel ("
                   @"    uniqueID     TEXT PRIMARY KEY,"
                   @"    name         TEXT"
                   @");"
                   ]) failedAt(1);
            *schemaVersion = 1;
        }
        [db commit];
    }];
    
    [SimpleModel setDatabase:database];
}

- (void)closeDatabase
{
//    [FCModel closeDatabase];
}

- (NSString *)dbPath
{
    return [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"testDB.sqlite3"];
}

@end
