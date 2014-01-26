//
//  FCModel.m
//
//  Created by Marco Arment on 7/18/13.
//  Copyright (c) 2013 Marco Arment. All rights reserved.
//

#import <objc/runtime.h>
#import <string.h>
#import <sqlite3.h>

#import "FCModel.h"
#import "FCModel+Subclass.h" 
static char kFCModelDatabaseKey;

@interface FMDatabase (HackForVAListsSinceThisIsPrivate)
- (FMResultSet *)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray*)arrayArgs orDictionary:(NSDictionary *)dictionaryArgs orVAList:(va_list)args;
- (BOOL)executeUpdate:(NSString*)sql error:(NSError**)outErr withArgumentsInArray:(NSArray*)arrayArgs orDictionary:(NSDictionary *)dictionaryArgs orVAList:(va_list)args;
@end



@interface FCModel () {
    BOOL _primaryKeySet;
    BOOL _deleted;
    BOOL _primaryKeyLocked;
}
@property (nonatomic, strong) NSDictionary *databaseFieldNames;
@property (nonatomic, strong) NSMutableDictionary *changedProperties;
@property (nonatomic, copy) NSError *_lastSQLiteError;

@property (nonatomic,assign) BOOL existsInDatabase;

@end


@implementation FCModel



+ (void)setDatabase:(id<FCDatabase>)database{
    objc_setAssociatedObject(self, &kFCModelDatabaseKey, database, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (id<FCDatabase>)database{
    return (id<FCDatabase>)objc_getAssociatedObject(self, &kFCModelDatabaseKey);
}

- (NSError *)lastSQLiteError { return self._lastSQLiteError; }

#pragma mark query
+ (id)_instancesWhere:(NSString *)query andArgs:(va_list)args orArgsArray:(NSArray *)argsArray orResultSet:(FMResultSet *)existingResultSet onlyFirst:(BOOL)onlyFirst keyed:(BOOL)keyed
{
    NSMutableArray *instances;
    NSMutableDictionary *keyedInstances;
    __block FCModel *instance = nil;
    
    if (! onlyFirst) {
        if (keyed) keyedInstances = [NSMutableDictionary dictionary];
        else instances = [NSMutableArray array];
    }
    
    void (^processResult)(FMResultSet *, BOOL *) = ^(FMResultSet *s, BOOL *stop){
        NSDictionary *rowDictionary = s.resultDictionary;
        instance = [self instanceWithPrimaryKey:rowDictionary[self.primaryFieldName] databaseRowValues:rowDictionary createIfNonexistent:NO];
        if (onlyFirst) {
            *stop = YES;
            return;
        }
        if (keyed) [keyedInstances setValue:instance forKey:[instance primaryKey]];
        else [instances addObject:instance];
    };
    
    if (existingResultSet) {
        BOOL stop = NO;
        while (! stop && [existingResultSet next]) processResult(existingResultSet, &stop);
    } else {
        [self.database inDatabase:^(FMDatabase *db) {
            FMResultSet *s = [db
                              executeQuery:(
                                            query ?
                                            [self expandQuery:[@"SELECT * FROM \"$T\" WHERE " stringByAppendingString:query]] :
                                            [self expandQuery:@"SELECT * FROM \"$T\""]
                                            )
                              withArgumentsInArray:argsArray
                              orDictionary:nil
                              orVAList:args
                              ];
            if (! s) [self queryFailedInDatabase:db];
            BOOL stop = NO;
            while (! stop && [s next]) processResult(s, &stop);
            [s close];
        }];
    }
    
    return onlyFirst ? instance : (keyed ? keyedInstances : instances);
}

+ (NSArray *)instancesFromResultSet:(FMResultSet *)rs { return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:rs onlyFirst:NO keyed:NO]; }
+ (NSDictionary *)keyedInstancesFromResultSet:(FMResultSet *)rs { return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:rs onlyFirst:NO keyed:YES]; }
+ (instancetype)firstInstanceFromResultSet:(FMResultSet *)rs { return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:rs onlyFirst:YES keyed:NO]; }

+ (instancetype)firstInstanceWhere:(NSString *)query, ...
{
    va_list args;
    va_start(args, query);
    id result = [self _instancesWhere:query andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:YES keyed:NO];
    va_end(args);
    return result;
}

+ (NSArray *)instancesWhere:(NSString *)query, ...
{
    va_list args;
    va_start(args, query);
    NSArray *results = [self _instancesWhere:query andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:NO];
    va_end(args);
    return results;
}

+ (NSDictionary *)keyedInstancesWhere:(NSString *)query, ...
{
    va_list args;
    va_start(args, query);
    NSDictionary *results = [self _instancesWhere:query andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:NO];
    va_end(args);
    return results;
}

+ (instancetype)firstInstanceOrderedBy:(NSString *)query, ...
{
    va_list args;
    va_start(args, query);
    id result = [self _instancesWhere:[@"1 ORDER BY " stringByAppendingString:query] andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:YES keyed:NO];
    va_end(args);
    return result;
}

+ (NSArray *)instancesOrderedBy:(NSString *)query, ...
{
    va_list args;
    va_start(args, query);
    id result = [self _instancesWhere:[@"1 ORDER BY " stringByAppendingString:query] andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:NO];
    va_end(args);
    return result;
}

+ (NSArray *)allInstances { return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:NO]; }
+ (NSDictionary *)keyedAllInstances { return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:YES]; }

+ (NSArray *)instancesWithPrimaryKeyValues:(NSArray *)primaryKeyValues
{
    if (primaryKeyValues.count == 0) return @[];
    
    __block int maxParameterCount = 0;
    [self.database inDatabase:^(FMDatabase *db) {
        maxParameterCount = sqlite3_limit(db.sqliteHandle, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
    }];
    
    __block NSArray *allFoundInstances = nil;
    NSMutableArray *valuesArray = [NSMutableArray arrayWithCapacity:MIN(primaryKeyValues.count, maxParameterCount)];
    NSMutableString *whereClause = [NSMutableString stringWithFormat:@"%@ IN (", self.class.primaryFieldName];
    
    void (^fetchChunk)() = ^{
        if (valuesArray.count == 0) return;
        [whereClause appendString:@")"];
        NSArray *newInstancesThisChunk = [self _instancesWhere:whereClause andArgs:NULL orArgsArray:valuesArray orResultSet:nil onlyFirst:NO keyed:NO];
        allFoundInstances = allFoundInstances ? [allFoundInstances arrayByAddingObjectsFromArray:newInstancesThisChunk] : newInstancesThisChunk;
        
        // reset state for next chunk
        [whereClause deleteCharactersInRange:NSMakeRange(7, whereClause.length - 7)];
        [valuesArray removeAllObjects];
    };
    
    for (id pkValue in primaryKeyValues) {
        [whereClause appendString:(valuesArray.count ? @",?" : @"?")];
        [valuesArray addObject:pkValue];
        if (valuesArray.count == maxParameterCount) fetchChunk();
    }
    fetchChunk();
    
    return allFoundInstances;
}

+ (NSDictionary *)keyedInstancesWithPrimaryKeyValues:(NSArray *)primaryKeyValues
{
    NSArray *instances = [self instancesWithPrimaryKeyValues:primaryKeyValues];
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:instances.count];
    for (FCModel *instance in instances) [dictionary setObject:instance forKey:instance.primaryKey];
    return dictionary;
}

+ (NSArray *)firstColumnArrayFromQuery:(NSString *)query, ...
{
    NSMutableArray *columnArray = [NSMutableArray array];
    va_list args;
    va_list *foolTheStaticAnalyzer = &args;
    va_start(args, query);
    [self.database inDatabase:^(FMDatabase *db) {
        FMResultSet *s = [db executeQuery:[self expandQuery:query] withArgumentsInArray:nil orDictionary:nil orVAList:*foolTheStaticAnalyzer];
        if (! s) [self queryFailedInDatabase:db];
        while ([s next]) [columnArray addObject:[s objectForColumnIndex:0]];
        [s close];
    }];
    va_end(args);
    return columnArray;
}

+ (NSArray *)resultDictionariesFromQuery:(NSString *)query, ...
{
    NSMutableArray *rows = [NSMutableArray array];
    va_list args;
    va_list *foolTheStaticAnalyzer = &args;
    va_start(args, query);
    [self.database inDatabase:^(FMDatabase *db) {
        FMResultSet *s = [db executeQuery:[self expandQuery:query] withArgumentsInArray:nil orDictionary:nil orVAList:*foolTheStaticAnalyzer];
        if (! s) [self queryFailedInDatabase:db];
        while ([s next]) [rows addObject:s.resultDictionary];
        [s close];
    }];
    va_end(args);
    return rows;
}

+ (id)firstValueFromQuery:(NSString *)query, ...
{
    __block id firstValue = nil;
    va_list args;
    va_list *foolTheStaticAnalyzer = &args;
    va_start(args, query);
    [self.database inDatabase:^(FMDatabase *db) {
        FMResultSet *s = [db executeQuery:[self expandQuery:query] withArgumentsInArray:nil orDictionary:nil orVAList:*foolTheStaticAnalyzer];
        if (! s) [self queryFailedInDatabase:db];
        if ([s next]) firstValue = [[s objectForColumnIndex:0] copy];
        [s close];
    }];
    va_end(args);
    return firstValue;
}

+ (void)queryFailedInDatabase:(FMDatabase *)db
{
    [[NSException exceptionWithName:@"FCModelSQLiteException" reason:db.lastErrorMessage userInfo:nil] raise];
}

#pragma mark - Instance tracking and uniquing

+ (instancetype)instanceWithPrimaryKey:(id)primaryKeyValue { return [self instanceWithPrimaryKey:primaryKeyValue databaseRowValues:nil createIfNonexistent:YES]; }
+ (instancetype)instanceWithPrimaryKey:(id)primaryKeyValue createIfNonexistent:(BOOL)create { return [self instanceWithPrimaryKey:primaryKeyValue databaseRowValues:nil createIfNonexistent:create]; }

+ (instancetype)instanceWithPrimaryKey:(id)primaryKeyValue databaseRowValues:(NSDictionary *)fieldValues createIfNonexistent:(BOOL)create
{
    if (! primaryKeyValue || primaryKeyValue == [NSNull null]) return [self new];
    
    primaryKeyValue = [self normalizedPrimaryKeyValue:primaryKeyValue];
    
    FCModel *instance = NULL;
    
    if (! instance) {
        // Not in memory yet. Check DB.
        instance = fieldValues ? [[self alloc] initWithFieldValues:fieldValues existsInDatabaseAlready:YES] : [self instanceFromDatabaseWithPrimaryKey:primaryKeyValue];
        if (! instance && create) {
            // Create new with this key.
            
            instance = [[self alloc] initWithFieldValues:@{ self.class.primaryFieldName : primaryKeyValue } existsInDatabaseAlready:NO];
        }
    }

    return instance;
}

+ (instancetype)instanceFromDatabaseWithPrimaryKey:(id)key
{
    __block FCModel *model = NULL;
    [self.database inDatabase:^(FMDatabase *db) {
        FMResultSet *s = [db executeQuery:[self expandQuery:@"SELECT * FROM \"$T\" WHERE \"$PK\"=?"], key];
        if (! s) [self queryFailedInDatabase:db];
        if ([s next]) model = [[self alloc] initWithFieldValues:s.resultDictionary existsInDatabaseAlready:YES];
        [s close];
    }];
    
    return model;
}


#pragma mark - Mapping properties to database fields

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:[self.class.database primaryKeyName:self.class]]) _primaryKeySet = YES;
    if (! _primaryKeyLocked) return;
    NSObject *oldValue, *newValue;

    if ( (oldValue = change[NSKeyValueChangeOldKey]) && (newValue = change[NSKeyValueChangeNewKey]) ) {
        if ([oldValue isKindOfClass:[NSURL class]]) oldValue = ((NSURL *)oldValue).absoluteString;
        else if ([oldValue isKindOfClass:[NSDate class]]) oldValue = [NSNumber numberWithInteger:[(NSDate *)oldValue timeIntervalSince1970]];

        if ([newValue isKindOfClass:[NSURL class]]) newValue = ((NSURL *)newValue).absoluteString;
        else if ([newValue isKindOfClass:[NSDate class]]) newValue = [NSNumber numberWithInteger:[(NSDate *)newValue timeIntervalSince1970]];

        if ([oldValue isEqual:newValue]) return;
    }
    
    BOOL isPrimaryKey = [keyPath isEqualToString:self.class.primaryFieldName];
    if (_existsInDatabase && isPrimaryKey) {
        if (_primaryKeyLocked) [[NSException exceptionWithName:NSInvalidArgumentException reason:@"Cannot change primary key value for already-saved FCModel" userInfo:nil] raise];
    } else if (isPrimaryKey) {
        _primaryKeySet = YES;
    }

    if (! isPrimaryKey && self.changedProperties && ! self.changedProperties[keyPath]) [self.changedProperties setObject:(oldValue ?: [NSNull null]) forKey:keyPath];
}


- (id)encodedValueForFieldName:(NSString *)fieldName
{
    id value = [self serializedDatabaseRepresentationOfValue:[self valueForKey:fieldName] forPropertyNamed:fieldName];
    return value ?: [NSNull null];
}

- (void)decodeFieldValue:(id)value intoPropertyName:(NSString *)propertyName
{
    if (value == [NSNull null]) value = nil;
    if (class_getProperty(self.class, propertyName.UTF8String)) {
        [self setValue:[self unserializedRepresentationOfDatabaseValue:value forPropertyNamed:propertyName] forKeyPath:propertyName];
    }
}

+ (NSArray *)databaseFieldNames     { return [self.class.database fieldInfos:self].allKeys; }
+ (NSString *)primaryFieldName { return [self.class.database primaryKeyName:self]; }

// For unique-instance consistency:
// Resolve discrepancies between supplied primary-key value type and the column type that comes out of the database.
// Without this, it's possible to e.g. pull objects with key @(1) and key @"1" as two different instances of the same record.
+ (id)normalizedPrimaryKeyValue:(id)value
{
    static NSNumberFormatter *numberFormatter;
    static dispatch_once_t onceToken;

    if (! value) return value;
    
    FCFieldInfo *primaryKeyInfo = [self.database primaryFieldInfo:self];
    
    if ([value isKindOfClass:NSString.class] && (primaryKeyInfo.type == FCFieldTypeInteger || primaryKeyInfo.type == FCFieldTypeDouble || primaryKeyInfo.type == FCFieldTypeBool)) {
        dispatch_once(&onceToken, ^{ numberFormatter = [[NSNumberFormatter alloc] init]; });
        value = [numberFormatter numberFromString:value];
    } else if (! [value isKindOfClass:NSString.class] && primaryKeyInfo.type == FCFieldTypeText) {
        value = [value stringValue];
    }

    return value;
}

#pragma mark - Find methods

+ (NSError *)executeUpdateQuery:(NSString *)query, ...
{
    va_list args;
    va_list *foolTheStaticAnalyzer = &args;
    va_start(args, query);

    __block BOOL success = NO;
    __block NSError *error = nil;
    [self.database inDatabase:^(FMDatabase *db) {
        success = [db executeUpdate:[self expandQuery:query] error:nil withArgumentsInArray:nil orDictionary:nil orVAList:*foolTheStaticAnalyzer];
        if (! success) error = [db.lastError copy];
    }];

    va_end(args);
    return error;
}

#pragma mark - Attributes and CRUD

+ (instancetype)new  { return [[self alloc] initWithFieldValues:@{} existsInDatabaseAlready:NO]; }
- (instancetype)init { return [self initWithFieldValues:@{} existsInDatabaseAlready:NO]; }

- (instancetype)initWithFieldValues:(NSDictionary *)fieldValues existsInDatabaseAlready:(BOOL)existsInDB
{
    if ( (self = [super init]) ) {
        _existsInDatabase = existsInDB;
        _deleted = NO;
        _primaryKeyLocked = NO;
        _primaryKeySet = _existsInDatabase;
        [[self.class.database fieldInfos:self.class] enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            FCFieldInfo *info = (FCFieldInfo *)obj;
            if (info.defaultValue) [self setValue:info.defaultValue forKey:key];
            [self addObserver:self forKeyPath:key options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld) context:NULL];
        }];

        [fieldValues enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            [self decodeFieldValue:obj intoPropertyName:key];
        }];
        
        _primaryKeyLocked = YES;
        self.changedProperties = [NSMutableDictionary dictionary];
    }
    return self;
}



- (FCModelSaveResult)revertUnsavedChanges
{
    if (self.changedProperties.count == 0) return FCModelSaveNoChanges;
    [self.changedProperties enumerateKeysAndObjectsUsingBlock:^(NSString *fieldName, id oldValue, BOOL *stop) {
        [self setValue:(oldValue == [NSNull null] ? nil : oldValue) forKeyPath:fieldName];
    }];
    [self.changedProperties removeAllObjects];
    return FCModelSaveSucceeded;
}

- (FCModelSaveResult)revertUnsavedChangeToFieldName:(NSString *)fieldName
{
    id oldValue = self.changedProperties[fieldName];
    if (oldValue) {
        [self setValue:(oldValue == [NSNull null] ? nil : oldValue) forKeyPath:fieldName];
        [self.changedProperties removeObjectForKey:fieldName];
        return FCModelSaveSucceeded;
    } else {
        return FCModelSaveNoChanges;
    }
}

- (void)dealloc
{
    [[self.class.database fieldInfos:self.class] enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [self removeObserver:self forKeyPath:key];
    }];
}

- (BOOL)hasUnsavedChanges { return ! _existsInDatabase || self.changedProperties.count; }

- (FCModelSaveResult)save
{
    if (_deleted) [[NSException exceptionWithName:@"FCAttemptToSaveAfterDelete" reason:@"Cannot save deleted instance" userInfo:nil] raise];
    BOOL dirty = self.changedProperties.count;
    if (! dirty && _existsInDatabase) return FCModelSaveNoChanges;
    
    BOOL update = _existsInDatabase;
    NSArray *columnNames;
    NSMutableArray *values;
    
    NSString *tableName = NSStringFromClass(self.class);
    NSString *pkName = self.class.primaryFieldName;
    id primaryKey = _primaryKeySet ? [self encodedValueForFieldName:pkName] : nil;
    if (! primaryKey) {
        NSAssert1(! update, @"Cannot update %@ without primary key", NSStringFromClass(self.class));
        primaryKey = [NSNull null];
    }

    // Validate NOT NULL columns
    [[self.class.database fieldInfos:self.class] enumerateKeysAndObjectsUsingBlock:^(id key, FCFieldInfo *info, BOOL *stop) {
        if (info.nullAllowed) return;
    
        id value = [self valueForKey:key];
        if (! value || value == [NSNull null]) {
            [[NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"Cannot save NULL to NOT NULL property %@.%@", tableName, key] userInfo:nil] raise];
        }
    }];
    
    if (update) {
        if (! [self shouldUpdate]) {
            [self saveWasRefused];
            return FCModelSaveRefused;
        }
        columnNames = [self.changedProperties allKeys];
    } else {
        if (! [self shouldInsert]) {
            [self saveWasRefused];
            return FCModelSaveRefused;
        }
        NSMutableSet *columnNamesMinusPK = [[NSSet setWithArray:[[self.class.database fieldInfos:self.class] allKeys]] mutableCopy];
        [columnNamesMinusPK removeObject:pkName];
        columnNames = [columnNamesMinusPK allObjects];
    }

    values = [NSMutableArray arrayWithCapacity:columnNames.count];
    [columnNames enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        [values addObject:[self encodedValueForFieldName:obj]];
    }];
    [values addObject:primaryKey];

    NSString *query;
    if (update) {
        query = [NSString stringWithFormat:
            @"UPDATE \"%@\" SET \"%@\"=? WHERE \"%@\"=?",
            tableName,
            [columnNames componentsJoinedByString:@"\"=?,\""],
            pkName
        ];
    } else {
        if (columnNames.count > 0) {
            query = [NSString stringWithFormat:
                @"INSERT INTO \"%@\" (\"%@\",\"%@\") VALUES (%@?)",
                tableName,
                [columnNames componentsJoinedByString:@"\",\""],
                pkName,
                [@"" stringByPaddingToLength:(columnNames.count * 2) withString:@"?," startingAtIndex:0]
            ];
        } else {
            query = [NSString stringWithFormat:
                @"INSERT INTO \"%@\" (\"%@\") VALUES (?)",
                tableName,
                pkName
            ];
        }
    }

    __block BOOL success = NO;
    __block sqlite_int64 lastInsertID;
    [self.class.database inDatabase:^(FMDatabase *db) {
        success = [db executeUpdate:query withArgumentsInArray:values];
        if (success) {
            lastInsertID = [db lastInsertRowId];
            self._lastSQLiteError = nil;
        } else {
            self._lastSQLiteError = db.lastError;
        }
    }];
    
    if (! success) {
        [self saveDidFail];
        return FCModelSaveFailed;
    }

    if (! primaryKey || primaryKey == [NSNull null]) {
         [self setValue:[NSNumber numberWithUnsignedLongLong:lastInsertID] forKey:self.class.primaryFieldName];
    }
    
    [self.changedProperties removeAllObjects];
    _primaryKeySet = YES;
    _existsInDatabase = YES;
    
    if (update) {
        [self didUpdate];
    } else {
        [self didInsert];
    }
    
    return FCModelSaveSucceeded;
}

- (FCModelSaveResult)delete
{
    if (_deleted) return FCModelSaveNoChanges;
    if (! [self shouldDelete]) {
        [self saveWasRefused];
        return FCModelSaveRefused;
    }
    
    __block BOOL success = NO;
    [self.class.database inDatabase:^(FMDatabase *db) {
        NSString *query = [self.class expandQuery:@"DELETE FROM \"$T\" WHERE \"$PK\" = ?"];
        success = [db executeUpdate:query, [self primaryKey]];
        self._lastSQLiteError = success ? nil : db.lastError;
    }];

    if (! success) {
        [self saveDidFail];
        return FCModelSaveFailed;
    }
    
    _deleted = YES;
    _existsInDatabase = NO;
    [self didDelete];
    return FCModelSaveSucceeded;
}


#pragma mark - Utilities

- (id)primaryKey { return [self valueForKey:self.class.primaryFieldName]; }

+ (NSString *)expandQuery:(NSString *)query
{
    if (self == FCModel.class) return query;
    query = [query stringByReplacingOccurrencesOfString:@"$PK" withString:self.primaryFieldName];
    return [query stringByReplacingOccurrencesOfString:@"$T" withString:NSStringFromClass(self)];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@#%@: 0x%p>", NSStringFromClass(self.class), self.primaryKey, self];
}

- (NSDictionary *)allFields
{
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [[self.class databaseFieldNames] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        id value = [self valueForKey:obj];
        if (value) [dictionary setObject:value forKey:obj];
    }];
    return dictionary;
}

- (NSUInteger)hash
{
    return ((NSObject *)self.primaryKey).hash;
}

@end
