//
//  RadarBeaconManager.m
//  RadarSDK
//
//  Copyright © 2020 Radar Labs, Inc. All rights reserved.
//

#import "RadarBeaconManager.h"

#import "RadarBeacon+Internal.h"
#import "RadarDelegateHolder.h"
#import "RadarLogger.h"

@interface RadarBeaconManager ()

@property (assign, nonatomic) BOOL started;
@property (nonnull, strong, nonatomic) NSMutableArray<RadarBeaconCompletionHandler> *completionHandlers;
@property (nonnull, strong, nonatomic) NSMutableSet<NSString *> *nearbyBeaconIdentifiers;
@property (nonnull, strong, nonatomic) NSDictionary *nearbyBeaconRSSI;
@property (nonnull, strong, nonatomic) NSDictionary *nearbyBeaconProximity;
@property (nonnull, strong, nonatomic) NSMutableSet<NSString *> *failedBeacons;
@property (nonnull, strong, nonatomic) NSArray<RadarBeacon *> *beacons;

@end

@implementation RadarBeaconManager

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static id sharedInstance;
    if ([NSThread isMainThread]) {
        dispatch_once(&once, ^{
            sharedInstance = [self new];
        });
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            dispatch_once(&once, ^{
                sharedInstance = [self new];
            });
        });
    }
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _locationManager = [CLLocationManager new];
        _locationManager.delegate = self;

        _completionHandlers = [NSMutableArray<RadarBeaconCompletionHandler> new];

        _beacons = @[];
        _nearbyBeaconIdentifiers = [NSMutableSet new];
        _nearbyBeaconRSSI = @{};
        _nearbyBeaconProximity = @{};
        _failedBeacons = [NSMutableSet new];

        _permissionsHelper = [RadarPermissionsHelper new];
    }
    return self;
}

- (void)callCompletionHandlersWithStatus:(RadarStatus)status
                           nearbyBeacons:(NSArray<NSString *> *_Nullable)nearbyBeacons
                        nearbyBeaconRSSI:(NSDictionary *_Nullable)nearbyBeaconRSSI
                   nearbyBeaconProximity:(NSDictionary *_Nullable)nearbyBeaconProximity {
    @synchronized(self) {
        if (!self.completionHandlers.count) {
            return;
        }

        [[RadarLogger sharedInstance]
            logWithLevel:RadarLogLevelDebug
                 message:[NSString stringWithFormat:@"Calling completion handlers | self.completionHandlers.count = %lu", (unsigned long)self.completionHandlers.count]];

        for (RadarBeaconCompletionHandler completionHandler in self.completionHandlers) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(timeoutWithCompletionHandler:) object:completionHandler];

            completionHandler(status, nearbyBeacons, nearbyBeaconRSSI, nearbyBeaconProximity);
        }

        [self.completionHandlers removeAllObjects];
    }
}

- (void)addCompletionHandler:(RadarBeaconCompletionHandler)completionHandler {
    if (!completionHandler) {
        return;
    }

    @synchronized(self) {
        [self.completionHandlers addObject:completionHandler];

        [self performSelector:@selector(timeoutWithCompletionHandler:) withObject:completionHandler afterDelay:5];
    }
}

- (void)cancelTimeouts {
    @synchronized(self) {
        for (RadarLocationCompletionHandler completionHandler in self.completionHandlers) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(timeoutWithCompletionHandler:) object:completionHandler];
        }
    }
}

- (void)timeoutWithCompletionHandler:(RadarBeaconCompletionHandler)completionHandler {
    [[RadarLogger sharedInstance] logWithLevel:RadarLogLevelDebug message:@"Beacon ranging timeout"];

    [self stopRanging];
}

- (void)rangeBeacons:(NSArray<RadarBeacon *> *_Nonnull)beacons completionHandler:(RadarBeaconCompletionHandler)completionHandler {
    CLAuthorizationStatus authorizationStatus = [self.permissionsHelper locationAuthorizationStatus];
    if (!(authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse || authorizationStatus == kCLAuthorizationStatusAuthorizedAlways)) {
        [[RadarDelegateHolder sharedInstance] didFailWithStatus:RadarStatusErrorPermissions];

        if (completionHandler) {
            completionHandler(RadarStatusErrorPermissions, nil, nil, nil);

            return;
        }
    }

    if (!CLLocationManager.isRangingAvailable) {
        [[RadarDelegateHolder sharedInstance] didFailWithStatus:RadarStatusErrorBluetooth];

        [[RadarLogger sharedInstance] logWithLevel:RadarLogLevelDebug message:@"Beacon ranging not available"];

        completionHandler(RadarStatusErrorBluetooth, nil, nil, nil);

        return;
    }

    [self addCompletionHandler:completionHandler];

    if (self.started) {
        [[RadarLogger sharedInstance] logWithLevel:RadarLogLevelDebug message:@"Already ranging beacons"];

        return;
    }

    if (!beacons || !beacons.count) {
        [[RadarLogger sharedInstance] logWithLevel:RadarLogLevelDebug message:@"No beacons to range"];

        completionHandler(RadarStatusSuccess, @[], @{}, @{});

        return;
    }

    self.beacons = beacons;
    self.started = YES;

    for (RadarBeacon *beacon in beacons) {
        [[RadarLogger sharedInstance]
            logWithLevel:RadarLogLevelDebug
                 message:[NSString stringWithFormat:@"Starting ranging beacon | _id = %@; uuid = %@; major = %@; minor = %@", beacon._id, beacon.uuid, beacon.major, beacon.minor]];

        [self.locationManager startRangingBeaconsInRegion:[self regionForBeacon:beacon]];
    }
}

- (void)stopRanging {
    [[RadarLogger sharedInstance] logWithLevel:RadarLogLevelDebug message:[NSString stringWithFormat:@"Stopping ranging"]];

    [self cancelTimeouts];

    for (RadarBeacon *beacon in self.beacons) {
        [self.locationManager stopRangingBeaconsInRegion:[self regionForBeacon:beacon]];
    }

    [self callCompletionHandlersWithStatus:RadarStatusSuccess
                             nearbyBeacons:[self.nearbyBeaconIdentifiers allObjects]
                          nearbyBeaconRSSI:self.nearbyBeaconRSSI
                     nearbyBeaconProximity:self.nearbyBeaconProximity];

    self.beacons = @[];
    self.started = NO;

    [self.nearbyBeaconIdentifiers removeAllObjects];
    self.nearbyBeaconRSSI = @{};
    self.nearbyBeaconProximity = @{};
    [self.failedBeacons removeAllObjects];
}

- (CLBeaconRegion *)regionForBeacon:(RadarBeacon *)beacon {
    return [[CLBeaconRegion alloc] initWithProximityUUID:[[NSUUID alloc] initWithUUIDString:beacon.uuid]
                                                   major:[beacon.major intValue]
                                                   minor:[beacon.minor intValue]
                                              identifier:beacon._id];
}

- (void)handleBeacons {
    if (self.nearbyBeaconIdentifiers.count + self.failedBeacons.count == self.beacons.count) {
        [[RadarLogger sharedInstance] logWithLevel:RadarLogLevelDebug message:[NSString stringWithFormat:@"Finished ranging"]];

        [self stopRanging];
    }
}

- (void)locationManager:(CLLocationManager *)manager monitoringDidFailForRegion:(CLRegion *)region withError:(NSError *)error {
    [[RadarLogger sharedInstance] logWithLevel:RadarLogLevelDebug message:[NSString stringWithFormat:@"Failed to monitor beacon | region.identifier = %@", region.identifier]];

    [self.failedBeacons addObject:region.identifier];

    [self handleBeacons];
}

- (void)locationManager:(CLLocationManager *)manager rangingBeaconsDidFailForRegion:(CLBeaconRegion *)region withError:(NSError *)error {
    [[RadarLogger sharedInstance] logWithLevel:RadarLogLevelDebug message:[NSString stringWithFormat:@"Failed to range beacon | region.identifier = %@", region.identifier]];

    [self.failedBeacons addObject:region.identifier];

    [self handleBeacons];
}

- (void)locationManager:(CLLocationManager *)manager didRangeBeacons:(nonnull NSArray<CLBeacon *> *)beacons inRegion:(nonnull CLBeaconRegion *)region {
    for (CLBeacon *beacon in beacons) {
        [[RadarLogger sharedInstance] logWithLevel:RadarLogLevelDebug
                                           message:[NSString stringWithFormat:@"Ranged beacon | region.identifier = %@; beacon.rssi = %ld; beacon.proximity = %ld",
                                                                              region.identifier, (long)beacon.rssi, (long)beacon.proximity]];

        [self.nearbyBeaconIdentifiers addObject:region.identifier];
        [self.nearbyBeaconRSSI setValue:@(beacon.rssi) forKey:region.identifier];
        [self.nearbyBeaconProximity setValue:@(beacon.proximity) forKey:region.identifier];
    }

    [self handleBeacons];
}

@end
