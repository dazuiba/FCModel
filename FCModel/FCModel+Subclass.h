//
//  FCModel+Subclass.h
//  FCModelTest
//
//  Created by 张光宇 on 1/25/14.
//  Copyright (c) 2014 Marco Arment. All rights reserved.
//

#import "FCModel.h"


// For subclasses to override

@interface FCModel (Subclass)


//optional:
- (BOOL)shouldInsert;
- (BOOL)shouldUpdate;
- (BOOL)shouldDelete;
- (void)didInsert;
- (void)didUpdate;
- (void)didDelete;
- (void)saveWasRefused;
- (void)saveDidFail;



// Subclasses can customize how properties are serialized for the database.
//
// FCModel automatically handles numeric primitives, NSString, NSNumber, NSData, NSURL, NSDate, NSDictionary, and NSArray.
// (Note that NSDate is stored as a time_t, so values before 1970 won't serialize properly.)
//
// To override this behavior or customize it for other types, you can implement these methods.
// You MUST call the super implementation for values that you're not handling.
//
// Database values may be NSString or NSNumber for INTEGER/FLOAT/TEXT columns, or NSData for BLOB columns.
//
- (id)serializedDatabaseRepresentationOfValue:(id)instanceValue forPropertyNamed:(NSString *)propertyName;
- (id)unserializedRepresentationOfDatabaseValue:(id)databaseValue forPropertyNamed:(NSString *)propertyName;

// Called on subclasses if there's a reload conflict:
//  - The instance changes field X but doesn't save the changes to the database.
//  - Database updates are executed outside of FCModel that cause instances to reload their data.
//  - This instance's value for field X in the database is different from the unsaved value it has.
//
// The default implementation raises an exception, so implement this if you use +dataWasUpdatedExternally or +executeUpdateQuery,
//  and don't call super.
//
//- (id)valueOfFieldName:(NSString *)fieldName byResolvingReloadConflictWithDatabaseValue:(id)valueInDatabase;

@end
