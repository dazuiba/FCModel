
//
//  FCDatabase.m
//  FCModelTest
//
//  Created by 张光宇 on 1/25/14.
//  Copyright (c) 2014 Marco Arment. All rights reserved.
//

#import "FCDatabase.h"
#import "FMDatabase.h"
#import "FMDatabaseQueue.h"

#import <objc/runtime.h>
#import <string.h>
#import <sqlite3.h>
#import "FCModel.h"

@interface FCDefaultDatabase()
@property(nonatomic,strong)FMDatabaseQueue *databaseQueue;

@property(nonatomic,strong)NSDictionary *fieldInfoDict;
@property(nonatomic,strong)NSDictionary *primaryKeyFieldNameDict;
@end

@implementation FCDefaultDatabase

+ (instancetype)open:(NSString *)path builder:(void (^)(FMDatabase *db, int *schemaVersion))schemaBuilder{
   FCDefaultDatabase *database =  [[self alloc] initWithPath:path];
   [database migrateWithSchemaBuilder:schemaBuilder];
   return database;
}

- (id)initWithPath:(NSString *)path
{
    self = [super init];
    if (self) {
        self.databaseQueue = [FMDatabaseQueue databaseQueueWithPath:path];
    }
    return self;
}

- (NSArray *)fieldNames:(Class)clazz{
    return [self fieldInfos:clazz].allKeys;
}

- (NSDictionary *)fieldInfos:(Class)clazz{
    return self.fieldInfoDict[clazz];
}


- (FCFieldInfo *)primaryFieldInfo:(Class)clazz{
   return self.fieldInfoDict[clazz][[self primaryKeyName:clazz]];
}

- (NSString *)primaryKeyName:(Class)clazz{
    return self.primaryKeyFieldNameDict[clazz];
}

- (void)migrateWithSchemaBuilder:(void (^)(FMDatabase *db, int *schemaVersion))schemaBuilder {
    NSMutableDictionary *mutableFieldInfo = [NSMutableDictionary dictionary];
    NSMutableDictionary *mutablePrimaryKeyFieldName = [NSMutableDictionary dictionary];
    
    [self.databaseQueue inDatabase:^(FMDatabase *db) {
        
        int startingSchemaVersion = 0;
        FMResultSet *rs = [db executeQuery:@"SELECT value FROM _FCModelMetadata WHERE key = 'schema_version'"];
        if ([rs next]) {
            startingSchemaVersion = [rs intForColumnIndex:0];
        } else {
            [db executeUpdate:@"CREATE TABLE _FCModelMetadata (key TEXT, value TEXT, PRIMARY KEY (key))"];
            [db executeUpdate:@"INSERT INTO _FCModelMetadata VALUES ('schema_version', 0)"];
        }
        [rs close];
        
        int newSchemaVersion = startingSchemaVersion;
        schemaBuilder(db, &newSchemaVersion);
        if (newSchemaVersion != startingSchemaVersion) {
            [db executeUpdate:@"UPDATE _FCModelMetadata SET value = ? WHERE key = 'schema_version'", @(newSchemaVersion)];
        }
        
        // Read schema for field names and primary keys
        FMResultSet *tablesRS = [db executeQuery:
                                 @"SELECT DISTINCT tbl_name FROM (SELECT * FROM sqlite_master UNION ALL SELECT * FROM sqlite_temp_master) WHERE type != 'meta' AND name NOT LIKE 'sqlite_%' AND name != '_FCModelMetadata'"
                                 ];
        while ([tablesRS next]) {
            NSString *tableName = [tablesRS stringForColumnIndex:0];
            Class tableModelClass = NSClassFromString(tableName);
            if (! tableModelClass || ! [tableModelClass isSubclassOfClass:FCModel.class]) continue;
            
            NSString *primaryKeyName = nil;
            BOOL isMultiColumnPrimaryKey = NO;
            NSMutableDictionary *fields = [NSMutableDictionary dictionary];
            FMResultSet *columnsRS = [db executeQuery:[NSString stringWithFormat: @"PRAGMA table_info('%@')", tableName]];
            while ([columnsRS next]) {
                NSString *fieldName = [columnsRS stringForColumnIndex:1];
                if (NULL == class_getProperty(tableModelClass, [fieldName UTF8String])) {
                    NSLog(@"[FCModel] ignoring column %@.%@, no matching model property", tableName, fieldName);
                    continue;
                }
                
                int isPK = [columnsRS intForColumnIndex:5];
                if (isPK == 1) primaryKeyName = fieldName;
                else if (isPK > 1) isMultiColumnPrimaryKey = YES;
                
                NSString *fieldType = [columnsRS stringForColumnIndex:2];
                FCFieldInfo *info = [FCFieldInfo new];
                info.nullAllowed = ! [columnsRS boolForColumnIndex:3];
                
                // Type-parsing algorithm from SQLite's column-affinity rules: http://www.sqlite.org/datatype3.html
                // except the addition of BOOL as its own recognized type
                if ([fieldType rangeOfString:@"INT"].location != NSNotFound) {
                    info.type = FCFieldTypeInteger;
                    if ([fieldType rangeOfString:@"UNSIGNED"].location != NSNotFound) {
                        info.defaultValue = [NSNumber numberWithUnsignedLongLong:[columnsRS unsignedLongLongIntForColumnIndex:4]];
                    } else {
                        info.defaultValue = [NSNumber numberWithLongLong:[columnsRS longLongIntForColumnIndex:4]];
                    }
                } else if ([fieldType rangeOfString:@"BOOL"].location != NSNotFound) {
                    info.type = FCFieldTypeBool;
                    info.defaultValue = [NSNumber numberWithBool:[columnsRS boolForColumnIndex:4]];
                } else if (
                           [fieldType rangeOfString:@"TEXT"].location != NSNotFound ||
                           [fieldType rangeOfString:@"CHAR"].location != NSNotFound ||
                           [fieldType rangeOfString:@"CLOB"].location != NSNotFound
                           ) {
                    info.type = FCFieldTypeText;
                    info.defaultValue = [[[columnsRS stringForColumnIndex:4]
                                          stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"'"]]
                                         stringByReplacingOccurrencesOfString:@"''" withString:@"'"
                                         ];
                } else if (
                           [fieldType rangeOfString:@"REAL"].location != NSNotFound ||
                           [fieldType rangeOfString:@"FLOA"].location != NSNotFound ||
                           [fieldType rangeOfString:@"DOUB"].location != NSNotFound
                           ) {
                    info.type = FCFieldTypeDouble;
                    info.defaultValue = [NSNumber numberWithDouble:[columnsRS doubleForColumnIndex:4]];
                } else {
                    info.type = FCFieldTypeOther;
                    info.defaultValue = nil;
                }
                
                if (isPK) info.defaultValue = nil;
                else if ([[columnsRS stringForColumnIndex:4] isEqualToString:@"NULL"]) info.defaultValue = nil;
                
                [fields setObject:info forKey:fieldName];
            }
            
            if (! primaryKeyName || isMultiColumnPrimaryKey) {
                [[NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"FCModel tables must have a single-column primary key, not found in %@", tableName] userInfo:nil] raise];
            }
            
            id classKey = tableModelClass;
            [mutableFieldInfo setObject:fields forKey:classKey];
            [mutablePrimaryKeyFieldName setObject:primaryKeyName forKey:classKey];
            [columnsRS close];
        }
        [tablesRS close];
        
        self.fieldInfoDict = [mutableFieldInfo copy];
        self.primaryKeyFieldNameDict = [mutablePrimaryKeyFieldName copy];
    }];

}

- (void)inDatabase:(void (^)(FMDatabase *))block{
    [self.databaseQueue inDatabase:block];
}

- (void)close{
    [self.databaseQueue close];
}

@end



@implementation FCFieldInfo
- (NSString *)description
{
    return [NSString stringWithFormat:@"<FCFieldInfo {%@ %@, default=%@}>",
            (_type == FCFieldTypeText ? @"text" : (_type == FCFieldTypeInteger ? @"integer" : (_type == FCFieldTypeDouble ? @"double" : (_type == FCFieldTypeBool ? @"bool" : @"other")))),
            _nullAllowed ? @"NULL" : @"NOT NULL",
            _defaultValue ? _defaultValue : @"NULL"
            ];
}
@end

