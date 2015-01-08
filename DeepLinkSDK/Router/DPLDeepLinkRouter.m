#import "DPLDeepLinkRouter.h"
#import "DPLDeepLinkRouteMatcher.h"
#import "DPLDeepLink.h"
#import "DPLRouteHandler.h"
#import "NSString+DPLTrim.h"
#import "DPLErrors.h"
#import <objc/runtime.h>

@interface DPLDeepLinkRouter ()

@property (nonatomic, copy) DPLApplicationCanHandleDeepLinksBlock applicationCanHandleDeepLinksBlock;
@property (nonatomic, copy) DPLRouteCompletionBlock               routeCompletionHandler;

@property (nonatomic, strong) NSMutableOrderedSet *routes;
@property (nonatomic, strong) NSMutableDictionary *classesByRoute;
@property (nonatomic, strong) NSMutableDictionary *blocksByRoute;

@end


@implementation DPLDeepLinkRouter

- (instancetype)init {
    self = [super init];
    if (self) {
        _routes         = [NSMutableOrderedSet orderedSet];
        _classesByRoute = [NSMutableDictionary dictionary];
        _blocksByRoute  = [NSMutableDictionary dictionary];
    }
    return self;
}


#pragma mark - Configuration

- (BOOL)applicationCanHandleDeepLinks {
    if (self.applicationCanHandleDeepLinksBlock) {
        return self.applicationCanHandleDeepLinksBlock();
    }
    
    return YES;
}


#pragma mark - Registering Routes

- (void)registerHandlerClass:(Class <DPLRouteHandler>)handlerClass forRoute:(NSString *)route {

    route = [route DPL_trimPath];
    
    if (handlerClass && [route length]) {
        [self.routes addObject:route];
        [self.blocksByRoute removeObjectForKey:route];
        self.classesByRoute[route] = handlerClass;
    }
}


- (void)registerBlock:(DPLRouteHandlerBlock)routeHandlerBlock forRoute:(NSString *)route {

    route = [route DPL_trimPath];
    
    if (routeHandlerBlock && [route length]) {
        [self.routes addObject:route];
        [self.classesByRoute removeObjectForKey:route];
        self.blocksByRoute[route] = [routeHandlerBlock copy];
    }
}


#pragma mark - Registering Routes via Object Subscripting

- (id)objectForKeyedSubscript:(id <NSCopying>)key {

    NSString *route = (NSString *)key;
    id obj = nil;
    
    if ([route isKindOfClass:[NSString class]] && [route length]) {
        obj = self.classesByRoute[route];
        if (!obj) {
            obj = self.blocksByRoute[route];
        }
    }
    
    return obj;
}


- (void)setObject:(id)obj forKeyedSubscript:(id <NSCopying>)key {
    
    NSString *route = (NSString *)key;
    if (!([route isKindOfClass:[NSString class]] && [route length])) {
        return;
    }
    
    if (!obj) {
        [self.routes removeObject:route];
        [self.classesByRoute removeObjectForKey:route];
        [self.blocksByRoute removeObjectForKey:route];
    }
    else if ([obj isKindOfClass:NSClassFromString(@"NSBlock")]) {
        [self registerBlock:obj forRoute:route];
    }
    else if (class_isMetaClass(object_getClass(obj)) &&
             [obj isSubclassOfClass:[DPLRouteHandler class]]) {
        [self registerHandlerClass:obj forRoute:route];
    }
}


#pragma mark - Routing Deep Links

- (void)handleURL:(NSURL *)url withCompletion:(DPLRouteCompletionBlock)completionHandler; {
    self.routeCompletionHandler = completionHandler;
    if (!url) {
        return;
    }
    
    if (![self applicationCanHandleDeepLinks]) {
        [self completeRouteWithSuccess:NO error:nil];
        return;
    }

    __block BOOL isHandled = NO;
    NSError      *error;
    DPLDeepLink  *deepLink;
    for (NSString *route in self.routes) {
        DPLDeepLinkRouteMatcher *matcher = [DPLDeepLinkRouteMatcher matcherWithRoute:route];
        deepLink = [matcher deepLinkWithURL:url];
        if (deepLink) {
            isHandled = [self handleRoute:route withDeepLink:deepLink error:&error];
            break;
        }
    }
    
    if (!deepLink) {
        NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(@"The passed URL does not match a registered route.", nil) };
        error = [NSError errorWithDomain:DPLErrorDomain code:DPLRouteNotFoundError userInfo:userInfo];
    }
    
    [self completeRouteWithSuccess:isHandled error:error];
}


- (BOOL)handleRoute:(NSString *)route withDeepLink:(DPLDeepLink *)deepLink error:(NSError *__autoreleasing *)error {
    id handler = self[route];
    
    if ([handler isKindOfClass:NSClassFromString(@"NSBlock")]) {
        DPLRouteHandlerBlock routeHandlerBlock = handler;
        routeHandlerBlock(deepLink);
    }
    else if (class_isMetaClass(object_getClass(handler)) &&
             [handler isSubclassOfClass:[DPLRouteHandler class]]) {
        DPLRouteHandler *routeHandler = [[handler alloc] init];

        if (![routeHandler shouldHandleDeepLink:deepLink]) {
            return NO;
        }
        
        UIViewController *presentingViewController = [routeHandler viewControllerForPresentingDeepLink:deepLink];
        UIViewController <DPLTargetViewController> *targetViewController = [routeHandler targetViewController];
        
        if (targetViewController) {
            
            [targetViewController configureWithDeepLink:deepLink];
            
            if ([routeHandler preferModalPresentation] ||
                ![presentingViewController isKindOfClass:[UINavigationController class]]) {
                
                [presentingViewController presentViewController:targetViewController animated:NO completion:NULL];
            }
            else if ([presentingViewController isKindOfClass:[UINavigationController class]]) {
                
                [self placeTargetViewController:targetViewController
                         inNavigationController:(UINavigationController *)presentingViewController
                                   withDeepLink:deepLink];
            }
        }
        else {
            
            NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(@"The matched route handler does not specify a target view controller.", nil)};
            *error = [NSError errorWithDomain:DPLErrorDomain code:DPLRouteHandlerTargetNotSpecifiedError userInfo:userInfo];
            
            return NO;
        }
    }
    
    return YES;
}


- (void)placeTargetViewController:(UIViewController *)targetViewController
           inNavigationController:(UINavigationController *)navigationController
                     withDeepLink:(DPLDeepLink *)deepLink {
    
    if ([navigationController.viewControllers containsObject:targetViewController]) {
        [navigationController popToViewController:targetViewController animated:NO];
    }
    else {
        
        for (UIViewController *controller in navigationController.viewControllers) {
            if ([controller isMemberOfClass:[targetViewController class]]) {
                
                [navigationController popToViewController:controller animated:NO];
                [navigationController popViewControllerAnimated:NO];
                
                if ([controller isEqual:navigationController.topViewController]) {
                    [navigationController setViewControllers:@[targetViewController] animated:NO];
                }
                
                break;
            }
        }
        
        if (![navigationController.topViewController isEqual:targetViewController]) {
            [navigationController pushViewController:targetViewController animated:NO];
        }
    }
}


- (void)completeRouteWithSuccess:(BOOL)handled error:(NSError *)error {
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.routeCompletionHandler) {
            self.routeCompletionHandler(handled, error);
        }
    });
}

@end
