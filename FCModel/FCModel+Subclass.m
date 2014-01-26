//
//  FCModel+Subclass.m
//  FCModelTest
//
//  Created by 张光宇 on 1/25/14.
//  Copyright (c) 2014 Marco Arment. All rights reserved.
//

#import <objc/runtime.h>
#import "FCModel+Subclass.h"
#import "FCDatabase.h"

@implementation FCModel (Subclass)



#pragma mark - For subclasses to override

- (BOOL)shouldInsert { return YES; }
- (BOOL)shouldUpdate { return YES; }
- (BOOL)shouldDelete { return YES; }
- (void)didInsert { }
- (void)didUpdate { }
- (void)didDelete { }
- (void)saveWasRefused { }
- (void)saveDidFail { }

- (id)serializedDatabaseRepresentationOfValue:(id)instanceValue forPropertyNamed:(NSString *)propertyName
{
    if ([instanceValue isKindOfClass:NSArray.class] || [instanceValue isKindOfClass:NSDictionary.class]) {
        NSError *error = nil;
        NSData *bplist = [NSPropertyListSerialization dataWithPropertyList:instanceValue format:NSPropertyListBinaryFormat_v1_0 options:NSPropertyListImmutable error:&error];
        if (error) {
            [[NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:
                                                                               @"Cannot serialize %@ to plist for %@.%@: %@", NSStringFromClass(((NSObject *)instanceValue).class), NSStringFromClass(self.class), propertyName, error.localizedDescription
                                                                               ] userInfo:nil] raise];
        }
        return bplist;
    } else if ([instanceValue isKindOfClass:NSURL.class]) {
        return [(NSURL *)instanceValue absoluteString];
    } else if ([instanceValue isKindOfClass:NSDate.class]) {
        return [NSNumber numberWithInteger:[(NSDate *)instanceValue timeIntervalSince1970]];
    }
    
    return instanceValue;
}


- (id)unserializedRepresentationOfDatabaseValue:(id)databaseValue forPropertyNamed:(NSString *)propertyName
{
    objc_property_t property = class_getProperty(self.class, propertyName.UTF8String);
    if (property) {
        const char *attrs = property_getAttributes(property);
        if (attrs[0] == 'T' && attrs[1] == '@' && attrs[2] == '"') attrs = &(attrs[3]);
        
        if (databaseValue && strncmp(attrs, "NSURL", 5) == 0) {
            return [NSURL URLWithString:databaseValue];
        } else if (databaseValue && strncmp(attrs, "NSDate", 6) == 0) {
            return [NSDate dateWithTimeIntervalSince1970:[databaseValue integerValue]];
        } else if (databaseValue && strncmp(attrs, "NSDictionary", 12) == 0) {
            NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:databaseValue options:kCFPropertyListImmutable format:NULL error:NULL];
            return dict && [dict isKindOfClass:NSDictionary.class] ? dict : @{};
        } else if (databaseValue && strncmp(attrs, "NSArray", 7) == 0) {
            NSArray *array = [NSPropertyListSerialization propertyListWithData:databaseValue options:kCFPropertyListImmutable format:NULL error:NULL];
            return array && [array isKindOfClass:NSArray.class] ? array : @[];
        }
    }
    
    return databaseValue;
}

//- (id)valueOfFieldName:(NSString *)fieldName byResolvingReloadConflictWithDatabaseValue:(id)valueInDatabase
//{
//    // A very simple subclass implementation could just always accept the locally modified value:
//    //     return [self valueForKeyPath:fieldName]
//    //
//    // ...or always accept the database value:
//    //     return valueInDatabase;
//    //
//    // But this is a decision that you should really make knowingly and deliberately in each case.
//    
//    [[NSException exceptionWithName:@"FCReloadConflict" reason:
//      [NSString stringWithFormat:@"%@ ID %@ cannot resolve reload conflict for \"%@\"", NSStringFromClass(self.class), self.primaryKey, fieldName]
//                           userInfo:nil] raise];
//    return nil;
//}

@end
