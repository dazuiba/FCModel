//
//  AppDelegate.m
//  FCModelTest
//
//  Created by Marco Arment on 9/14/13.
//  Copyright (c) 2013 Marco Arment. All rights reserved.
//

#import "AppDelegate.h"
#import "ViewController.h"
#import "FCModel.h"
#import "Person.h"
#import "RandomThings.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{

    if (false) {
        
    Color *testUniqueRed0 = [Color instanceWithPrimaryKey:@"red"];

    // Prepopulate the Color table
    [@{
        @"red" : @"FF3838",
        @"orange" : @"FF9335",
        @"yellow" : @"FFC947",
        @"green" : @"44D875",
        @"blue1" : @"2DAAD6",
        @"blue2" : @"007CF4",
        @"purple" : @"5959CE",
        @"pink" : @"FF2B56",
        @"gray1" : @"8E8E93",
        @"gray2" : @"C6C6CC",
    } enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *hex, BOOL *stop) {
        Color *c = [Color instanceWithPrimaryKey:name];
        c.hex = hex;
        [c save];
    }];
    
    Color *testUniqueRed1 = [Color instanceWithPrimaryKey:@"red"];
    NSArray *allColors = [Color allInstances];
    Color *testUniqueRed2 = [Color instanceWithPrimaryKey:@"red"];
    
//    NSAssert(testUniqueRed0 == testUniqueRed1, @"Instance-uniqueness check 1 failed");
//    NSAssert(testUniqueRed1 == testUniqueRed2, @"Instance-uniqueness check 2 failed");


    // Comment/uncomment this to see caching/retention behavior.
    // Without retaining these, scroll the collectionview, and you'll see each cell performing a SELECT to look up its color.
    // By retaining these, all of the colors are kept in memory by primary key, and those requests become cache hits.
    self.cachedColors = allColors;
    
    NSMutableSet *colorsUsedAlready = [NSMutableSet set];
    
    // Put some data in the table if there's not enough
    int numPeople = [[Person firstValueFromQuery:@"SELECT COUNT(*) FROM $T"] intValue];
    while (numPeople < 26) {
        Person *p = [Person new];
        p.name = [RandomThings randomName];
        
        if (colorsUsedAlready.count >= allColors.count) [colorsUsedAlready removeAllObjects];
        
        Color *color;
        do {
            color = (Color *) allColors[([RandomThings randomUInt32] % allColors.count)];
        } while ([colorsUsedAlready member:color] && colorsUsedAlready.count < allColors.count);

        [colorsUsedAlready addObject:color];
        p.color = color;
        
        if ([p save]) numPeople++;
    }
    }

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
							
@end
